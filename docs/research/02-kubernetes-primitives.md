# Kubernetes primitives available for the job

Verified against Kubernetes `master` (`pkg/features/kube_features.go`) and the upstream website
repository on 2026-08-29. Current stable release: **1.37**.

## 1. Feature-gate status table

| Feature | Gate | Status |
| --- | --- | --- |
| OCI image as a read-only volume | `ImageVolume` | alpha 1.31, beta 1.33 (off), beta-on 1.35, **stable 1.36** |
| User namespaces for pods (`hostUsers: false`) | `UserNamespacesSupport` | alpha 1.25, beta 1.30, beta-on 1.33, **stable + locked 1.36** |
| Volume populators (`dataSourceRef`) | `AnyVolumeDataSource` | beta 1.24, **GA 1.33** |
| In-place pod resize | `InPlacePodVerticalScaling` | alpha 1.27, beta 1.33, **GA 1.35** |
| Per-container restart rules | `ContainerRestartRules` | alpha 1.34, **beta-on 1.35** |
| Custom container stop signal | `ContainerStopSignals` | **alpha 1.33, still alpha, off by default** |
| Container checkpointing (CRIU) | `ContainerCheckpoint` | alpha 1.25, **beta-on 1.30** |
| Bind-mount options on volumeMounts (`noexec`/`nodev`/`nosuid`) | `VolumeBindMountOptions` | **alpha 1.37** |
| Image digest in pod status for image volumes | `ImageVolumeWithDigest` | alpha 1.35 |

Two of these decide the shape of the chart:

- `ImageVolume` being **stable in 1.36** means the seed image can be mounted read-only into the
  pod without being the container's own image. That decouples "what OS goes into the rootfs" from
  "what binary drives the boot".
- `ContainerStopSignals` being **still alpha** means we cannot rely on `lifecycle.stopSignal` to
  send `SIGRTMIN+3` to a guest systemd. A `preStop` hook is the portable answer.

## 2. Init containers as a pre-start hook

Regular init containers run **in declaration order, to completion, on every pod start**, including
after a node reboot or a reschedule. That is precisely the semantics of `lxc.hook.pre-start`.

Consequences:

- Work that must happen once (seeding the rootfs) needs its own idempotency marker inside the
  volume. Kubernetes will not remember that the previous pod already did it.
- Work that must happen every boot (hostname, resolv.conf, network config) simply runs every time,
  which is what we want.
- Init containers share the pod's volumes, so they can write into the PVC before anything else
  opens it.
- Sidecar containers (init containers with `restartPolicy: Always`, GA since 1.29) start before
  the main containers and keep running — useful for anything that must supervise the guest.

## 3. Getting image content into a PVC

Four mechanisms, in increasing order of machinery:

### 3.1 Init container copies from its own rootfs

The init container *is* the seed image; it copies its own `/` into the mounted PVC.

The copy must preserve file capabilities, ACLs and sparseness, or the seeded rootfs is subtly
broken — `ping` and `dumpcap` lose `security.capability`, and a sparse image balloons. Proxmox's
own archive flags (`@PVE::Storage::Plugin::COMMON_TAR_FLAGS`) are the right reference:

```text
--one-file-system
-p --sparse --numeric-owner --acls
--xattrs --xattrs-include=user.* --xattrs-include=security.capability
--warning=no-file-ignored --warning=no-xattr-write
```

giving roughly:

```bash
tar -C / "${COMMON_TAR_FLAGS[@]}" --exclude=./dev/* -cf - . | tar -C /mnt/rootfs -xpf -
```

Works on every cluster, no feature gates, no extra privileges beyond what a normal container has.
Two downsides: the seed image and the provisioning logic must live in the same image, and the
tooling must be **GNU tar or rsync**, because busybox `tar` has no extended-attribute support at
all — see [05](05-open-questions.md) §10a for the verified capability matrix.

### 3.2 `image` volume source (stable since 1.36)

```yaml
volumes:
  - name: seed
    image:
      reference: docker.io/library/debian:13
      pullPolicy: IfNotPresent
```

The image is mounted **read-only** at a single mount path. The provisioning init container can then
be a small, fixed utility image that copies `seed` → PVC. This is the closest analogue to
Proxmox's "template on a storage, extracted into a fresh volume".

Restrictions worth knowing:

- Read-only, always. `subPath` support only from 1.33.
- `fsGroupChangePolicy` has no effect on it.
- The volume is re-resolved when the pod is recreated, so a moving tag silently changes what the
  seed would be — pin by digest, or accept the drift deliberately.
- `AlwaysPullImages` admission applies to it.

### 3.3 Volume populator (`dataSourceRef`, GA 1.33)

A controller watches PVCs whose `dataSourceRef` points at a custom resource, provisions a shadow
PVC, fills it, and rebinds. This is the most "Kubernetes-native" way to express "this volume was
created from this template", and it makes the seeding happen at **PVC creation time** rather than
pod start time — a much better match for Proxmox semantics, where seeding is a create-time
operation on the volume, not a boot-time operation on the container.

Cost: it requires shipping and running a controller, which is out of scope for a Helm chart that
wants to be installable anywhere. Worth keeping as a future optimisation.

### 3.4 An LXC rootfs template

Not an OCI mechanism at all, and worth stating separately because it is the *original* one. A
Proxmox `vztmpl` — `debian-13-standard_13.0-1_amd64.tar.zst` and friends, from `pveam` or from
linuxcontainers.org — is a compressed rootfs tarball fetched over HTTPS. The init container
downloads it and extracts it with the same flags as §3.1.

It differs from the OCI path in ways that matter to the design:

| | OCI image | LXC template |
| --- | --- | --- |
| Identifier | image reference | HTTPS URL |
| Integrity | digest, verified by the container runtime | nothing, unless we check a hash ourselves |
| Credentials | image pull secrets, node credentials, ServiceAccount | none |
| Caching | the node's image store, for free | none; refetched per seeding |
| Decompression | handled by the runtime | needs `zstd`, `xz`, `gzip` in the shim — and busybox has no zstd at all, see [05](05-open-questions.md) §10a |

The integrity row is the important one. Proxmox verifies templates against its signed index; a
chart has no counterpart, so a checksum has to be supplied by the user and enforced. Extracting an
unverified tarball into the root filesystem of a machine that will run privileged is not a risk
worth making optional.

Proxmox's `check_tar_archive()` is worth copying wholesale for the same reason: it rejects an
archive with no `sbin` entry, with fewer than ten members, or containing a multi-volume member,
before anything is unpacked.

### 3.5 A CSI driver that materialises images as volumes

Prior art exists (see [04-prior-art.md](04-prior-art.md)). Same trade-off as 3.3, plus a node
plugin. Out of scope.

## 4. Making a PVC behave like a root filesystem

Kubernetes has no API for "use this volume as the container's rootfs". The container image always
provides `/`. Three ways around it — but first, the obvious idea that does not work.

### 4.0 Why not simply `mountPath: /`?

The most direct reading of the whole project is: seed the PVC in an init container, then give the
main container `volumeMounts: [{name: rootfs, mountPath: /}]` and let it run `/sbin/init`. The API
server accepts this — `ValidateVolumeMounts()` in `pkg/apis/core/validation/validation.go` only
checks that `mountPath` is non-empty and unique, and never rejects `/`. It nevertheless fails, for
two independent reasons.

**Reason 1: runc refuses it.** `libcontainer/rootfs_linux.go`:

```go
if relPath, err := filepath.Rel(rootfs, dstFullPath); err != nil {
    return fmt.Errorf("get relative path of %q: %w", dstFullPath, err)
} else if relPath == "." {
    return fmt.Errorf("mountpoint %q is on the top of rootfs %q", dstFullPath, rootfs)
}
```

The adjacent comment in `prepareRootfs()` reads: *"NOTE that if we need to re-enable support for
mounting on top of container root (see issue 5070), we will need to reopen rootFd after such
mounts."* — so this used to work and was deliberately disabled. It was removed by commit `d40b343`,
the fix for **CVE-2025-52881**, and regressed the previously supported "mount host `/` as the
container root" pattern. [runc#5070](https://github.com/opencontainers/runc/issues/5070) has been
open since December 2025 with no resolution.

crun has no equivalent check, so the same pod may behave differently there. Depending on a single
OCI runtime's tolerance is not a foundation to build on.

**Reason 2: mount ordering shadows the kernel filesystems.** This one is runtime-independent,
because the OCI spec is assembled by containerd's CRI layer
(`internal/cri/opts/spec_linux_opts.go: withMounts()`). The resulting order is:

1. **Default mounts first**: `/proc`, `/dev` (tmpfs), `/dev/pts`, `/dev/shm`, `/dev/mqueue`,
   `/sys`, `/sys/fs/cgroup`.
2. **Then the CRI/volume mounts**, sorted by path depth (`orderedMounts.Less()` compares the number
   of path separators, "so that high level mounts don't shadow other mounts").

The runtime applies them in list order into `<rootfs>/<destination>`. A volume destined for `/`
is therefore mounted **last, directly over the prepared rootfs**, hiding every mount already placed
beneath it. After `pivot_root` the guest sees whatever the PVC contains at `/proc`, `/sys` and
`/dev` — empty directories, since a faithful seed excludes `./dev/*` and never contains `/proc` or
`/sys` content. `/sbin/init` dies immediately.

This cannot be patched from the pod spec: procfs and sysfs are not expressible as Kubernetes
volume sources, so there is no way to re-add them after the `/` mount.

Note that the depth sort does work in our favour for the injected files — `/etc/hosts`,
`/etc/resolv.conf`, `/etc/hostname` and the ServiceAccount token all sort deeper than `/` and would
land *inside* the PVC. That is a nice property, and it is worth remembering when designing the
entrypoint, but it does not rescue the approach.

**Conclusion.** The final mount onto `/` must be performed by the container's own entrypoint,
inside the pod, not declaratively by the kubelet. The entrypoint mounts the kernel filesystems into
the new root *first* and pivots *afterwards* — which is precisely the ordering `lxc-start` enforces,
and precisely why Proxmox needs `lxc.hook.pre-start` and `lxc.hook.autodev` instead of a single
declarative mount. The PVC is mounted at an ordinary path such as `/mnt/rootfs`, which is entirely
legal.

### 4.1 `chroot` into the PVC

`CAP_SYS_CHROOT` **is** in containerd's default capability set
(`pkg/oci/spec.go: defaultUnixCaps()` — `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_FSETID`,
`CAP_FOWNER`, `CAP_MKNOD`, `CAP_NET_RAW`, `CAP_SETGID`, `CAP_SETUID`, `CAP_SETFCAP`,
`CAP_SETPCAP`, `CAP_NET_BIND_SERVICE`, `CAP_SYS_CHROOT`, `CAP_KILL`, `CAP_AUDIT_WRITE`), so the
`chroot(2)` itself is free.

What is *not* free: the new root needs `/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm` and `/run`
mounted inside it, and `mount(2)` requires `CAP_SYS_ADMIN` in the mount namespace's owning user
namespace. So a chroot-based design needs either `privileged: true`, or `CAP_SYS_ADMIN` plus a
relaxed `procMount`, or a user namespace (§5).

### 4.2 `pivot_root` into the PVC

Cleaner than `chroot` — it changes the mount namespace's actual root, so `kubectl exec`, exec
probes and `/proc/1/root` all see the guest rootfs. Same `CAP_SYS_ADMIN` requirement, plus the new
root must be a mount point and the old root must not be shared. In a pod the container root is
typically a private mount, so this is achievable.

The practical difference matters a lot:

| | `chroot` | `pivot_root` |
| --- | --- | --- |
| Guest init sees the PVC as `/` | yes | yes |
| `kubectl exec` lands in the guest | **no** — lands in the shim image | yes |
| `exec` probes run guest binaries | **no** | yes |
| Old root can be unmounted/hidden | no | yes |

With `chroot`, `kubectl exec` and exec probes need a wrapper that does
`nsenter --target 1 --root --wd` to follow PID 1 into the guest root. That is workable but it
leaks into every probe definition and every debugging session.

### 4.3 Selective mounts (no privileges at all)

Do not change the root at all; mount PVC sub-paths over the directories that actually hold state:
`/etc`, `/var`, `/home`, `/root`, `/opt`, `/srv`, `/usr/local`. Ordinary `volumeMounts` with
`subPath`, zero extra capabilities, works on a Restricted PodSecurity namespace.

This is not a stateful rootfs — `/usr`, `/lib`, `/bin` still come from the image and reset on
upgrade — but for a large fraction of "I want my pod to feel like a pet" use cases it is enough,
and it is the only variant that runs unprivileged everywhere today.

## 5. User namespaces change the privilege calculus

`hostUsers: false` is **stable and locked on since 1.36**. Inside such a pod:

- `CAP_SYS_ADMIN` is scoped to the pod's user namespace and is void on the host. Mounting `proc`,
  `sysfs`, `tmpfs`, `devpts`, `mqueue`, bind mounts and (since Linux 5.11) `overlayfs` is permitted
  inside a user namespace.
- Pod Security Standards relax `runAsUser`/`runAsNonRoot` checks for such pods, and Baseline
  relaxes `procMount`.
- **File ownership in volumes is unaffected.** The kubelet uses idmapped mounts, so inodes are
  created with the same UID/GID as if the pod were not using a user namespace. This is strictly
  better than Proxmox's unprivileged containers, where the on-disk ownership is shifted by 100000
  unless idmapped mounts are in play.

Requirements and limits:

- Linux **6.3+** on the node (tmpfs idmap support), and every filesystem used by the pod's volumes
  must support idmapped mounts. btrfs, ext4, xfs, fat, tmpfs, overlayfs do; **NFS does not**.
- containerd **2.0+** or CRI-O 1.25+, with runc 1.2+ or crun 1.9+ (1.13+ recommended).
- `hostNetwork`, `hostIPC`, `hostPID` are forbidden alongside `hostUsers: false`.
- **`volumeDevices` (raw block volumes) cannot be used at all** in a user-namespaced pod. That
  rules out "give the guest a raw block device and let it own the filesystem".
- Default range is 65536 IDs per pod; `KubeletConfiguration.userNamespaces.idsPerPod` can raise it
  (1.33+). Custom ranges need a `kubelet` user with `/etc/subuid` entries and `getsubids`.

So the ideal target is: **user-namespaced pod + `CAP_SYS_ADMIN` inside that namespace +
`pivot_root` into an idmapped PVC.** That is a genuinely unprivileged VM-like container, and it is
a stricter security posture than a Proxmox unprivileged LXC container gets by default.

## 6. Running an init system inside

If the guest runs systemd, it needs:

- **cgroup v2 with a writable, delegated subtree.** Kubernetes mounts `/sys/fs/cgroup` read-only
  by default. Options: run privileged (the runtime then mounts it read-write), or use a runtime
  that delegates (see sysbox in [04-prior-art.md](04-prior-art.md)), or a node-level opt-in where
  the platform offers one.
- A **private cgroup namespace**, which containerd already gives containers on cgroup v2 hosts.
- `/run` and `/tmp` as tmpfs, `/dev/shm`, a `/dev` with the standard nodes, and `/sys` mounted
  (Proxmox uses `sys:mixed` for unprivileged: read-only `/sys` keeps `systemd-networkd` happy).
- systemd ≥ 232 for a pure cgroup v2 environment — Proxmox explicitly checks this at pre-start and
  warns.

If the guest runs a lightweight init instead — OpenRC, runit, s6, dinit, tini — almost all of this
goes away. **Init system choice is the single biggest lever on the required privilege level**, and
the chart should expose it as a first-class value rather than assuming systemd.

## 7. Shutdown semantics

Kubernetes sends `SIGTERM` to PID 1 of each container, waits `terminationGracePeriodSeconds`
(default 30), then `SIGKILL`s.

For systemd, `SIGTERM` means **re-execute yourself**, not shut down. The shutdown signal is
`SIGRTMIN+3` (`poweroff`), `SIGRTMIN+4` (`halt`), or `SIGRTMIN+5` (`reboot`).

Since `ContainerStopSignals` is still alpha, the portable answer is a `preStop` hook. Because the
hook is a script rather than a static field, it can pick the right signal at runtime instead of
requiring the user to declare which init the guest runs — `/run/systemd/system` is systemd's own
canonical "am I booted" marker, the one `sd_booted(3)` tests:

```yaml
lifecycle:
  preStop:
    exec:
      command:
        - /bin/sh
        - -c
        - |
          if [ -d /run/systemd/system ]; then kill -s RTMIN+3 1; else kill -s TERM 1; fi
          while kill -0 1 2>/dev/null; do sleep 1; done
terminationGracePeriodSeconds: 120
```

This matters beyond tidiness: it is what lets the chart drop a `guest.init` values field entirely
(see [05](05-open-questions.md) §4). Sending `SIGRTMIN+3` blindly would be wrong — systemd's own
container interface notes that "since only systemd understands `SIGRTMIN+3` like this, this might
confuse other init systems".

Note that Proxmox's own unit uses `TimeoutStopSec=120s`, which is a reasonable default to copy.
When `ContainerStopSignals` graduates, `lifecycle.stopSignal: SIGRTMIN+3` replaces the hook and
maps one-to-one onto Proxmox's `lxc.signal.halt`.

## 8. Files the kubelet and CRI inject into the container root

containerd bind-mounts three files into every container
(`internal/cri/server/container_create.go: linuxContainerMounts()`, and
`podsandbox/sandbox_run_linux.go: setupSandboxFiles()`):

- `/etc/hostname` — written from the sandbox's hostname
- `/etc/hosts` — copied from the node, plus any `hostAliases`
- `/etc/resolv.conf` — generated from the pod's DNS config

Plus the ServiceAccount token projection, ConfigMap/Secret mounts, and `/dev/termination-log`.

**All of these are bind mounts into the container image's rootfs, not into the PVC.** After a
`chroot`/`pivot_root` into the PVC they are invisible. This is not a bug to work around — it is
exactly the situation Proxmox is in, and it is why `pre_start_hook` writes `/etc/hostname`,
`/etc/hosts` and `/etc/resolv.conf` into the guest rootfs on every boot. The design must do the
same, reading the values from the pod's own injected files and writing them into the PVC.

## 9. Storage constraints

- **Access mode.** A rootfs is inherently `ReadWriteOnce`. That pins the pod to one node at a
  time, which is correct for a pet, and means a `StatefulSet` (or a single-replica workload with a
  fixed PVC) rather than a `Deployment` with a rolling update. `Recreate` strategy is mandatory.
- **Mount options.** A rootfs needs `exec`, `dev` and `suid`. A StorageClass or CSI driver that
  mounts with `nosuid` breaks `sudo`, `ping` and anything else relying on setuid bits. Worth
  documenting as a prerequisite and, ideally, checking at provision time.
- **Filesystem.** Must support the ownership and xattr semantics the distro expects — ext4 or xfs.
  Also must support idmapped mounts if user namespaces are used.
- **`fsGroup`.** Applying `fsGroup` to a whole root filesystem triggers a recursive `chown` of
  every inode on the volume at every mount. On a multi-gigabyte rootfs this is unacceptable. Use
  `fsGroupChangePolicy: OnRootMismatch` at minimum, and preferably do not set `fsGroup` at all for
  the rootfs volume.
- **Snapshots.** `VolumeSnapshot` is the analogue of `vzdump`/`pct snapshot`. Cloning a snapshot
  into a new PVC is the analogue of `pct clone`, and — like Proxmox — the clone must have its
  `/etc/machine-id` cleared and its SSH host keys regenerated, or two "different" instances will
  share an identity.

## 10. Things Kubernetes cannot do here

- **No live migration.** A Proxmox container can be migrated with a short freeze; a pod cannot.
  `ContainerCheckpoint` (beta since 1.30) is explicitly scoped to forensic checkpointing, not
  migration, and does not restore into a running pod. Rescheduling a stateful pod is a reboot.
- **No API for "rootfs from a volume".** Everything here is a userspace trick inside a container
  the runtime still believes is image-rooted.
- **No per-container `/sys/fs/cgroup` delegation knob** in the core API. Either privileged, or a
  platform-specific opt-in, or a different runtime.
