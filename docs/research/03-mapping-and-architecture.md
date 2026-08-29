# Mapping Proxmox LXC onto Kubernetes, and candidate architectures

## 1. The mapping

| Proxmox VE / LXC | Kubernetes equivalent | Fidelity |
| --- | --- | --- |
| `/etc/pve/lxc/<vmid>.conf` | Helm values → Pod spec + ConfigMap | good |
| Template tarball / OCI image on a storage | `image` volume source, or the init container's own image | good |
| `pct create` → allocate + extract + `post_create_hook` | Provisioning init container, guarded by a marker file in the PVC | good |
| rootfs volume (ZFS subvol / LV / RBD) | PVC, `ReadWriteOnce`, ext4 or xfs | good |
| `mp0..mpN` mountpoints | additional PVCs mounted into the guest rootfs | good |
| `lxc.hook.pre-start` | ordered init containers | good |
| `PVE::LXC::Setup->pre_start_hook()` | a "customize" init container writing into the PVC | good |
| `protected_call()` (fork + chroot) | the init container is already confined; still must resolve paths safely | partial |
| `.pve-ignore.<file>` | same marker convention, honoured by the customize step | direct copy |
| `lxc-start` + `lxc.init.cmd = /sbin/init` | main container entrypoint: mount, `pivot_root`, `exec /sbin/init` | partial — needs privileges |
| `lxc.autodev` hook | the shim populates `/dev` in the new root before `exec` | good |
| `lxc.hook.post-stop` | `preStop` hook + normal pod teardown | partial |
| `lxc.signal.halt` | `lifecycle.stopSignal` (alpha) or a `preStop` hook | partial |
| `lxc.cgroup2.memory.max` / `cpu.max` | container `resources`, updatable in place since 1.35 | good |
| `lxc.net.N` veth + bridge | pod network (CNI); Multus for extra interfaces | different model |
| `lxc.idmap` / unprivileged containers | `hostUsers: false` (stable 1.36), with idmapped volume mounts | better |
| `pct snapshot` / `vzdump` | `VolumeSnapshot` + snapshot-restore into a new PVC | good |
| Guest reboot = host stop + start | container restart | good |
| `pct migrate` (live) | — | **no equivalent** |
| `pct enter` | `kubectl exec` (with caveats, see §4.3) | partial |
| Host discards guest init stdout | pod logs would capture it; must be handled deliberately | different |

## 2. Lifecycle design

Following Proxmox's two-phase split:

```text
Pod start
│
├── initContainer[0]  "provision"      (runs every start, acts once)
│     if /mnt/rootfs/.stateful-pods/provisioned is absent:
│         copy seed image → /mnt/rootfs   (excluding /dev, /proc, /sys, /run, /tmp)
│         clear /etc/machine-id
│         generate SSH host keys
│         seed root password / authorized_keys
│         write .stateful-pods/provisioned  {image digest, timestamp, chart version}
│     else:
│         no-op
│
├── initContainer[1]  "customize"      (runs every start, always)
│     write /etc/hostname   from the pod's own /etc/hostname
│     write /etc/hosts      from the pod's own /etc/hosts
│     write /etc/resolv.conf from the pod's own /etc/resolv.conf
│     write network config  (distro plugin, if the guest manages its own network)
│     ensure /dev /proc /sys /run /tmp exist as empty dirs
│     honour .pve-ignore.<name> markers for every managed file
│
└── container  "guest"                 (PID 1 of the guest)
      mount proc/sys/dev/devpts/shm/run inside /mnt/rootfs
      bind the kubelet-injected files if they should stay live
      pivot_root /mnt/rootfs
      exec /sbin/init
```

The `provisioned` marker is the crux. It is what turns "Kubernetes re-runs init containers on
every start" into "Proxmox only extracts the template at create time".

### 2.1 Marker file contents

The marker should record what the rootfs was seeded from, so that upgrade policy can be expressed:

```json
{
  "seedImage": "docker.io/library/debian@sha256:...",
  "seededAt": "2026-08-29T14:03:11Z",
  "chartVersion": "0.1.0",
  "schemaVersion": 1
}
```

With that, three upgrade policies become expressible, and the chart should make the choice
explicit rather than picking silently:

| Policy | Behaviour on a changed seed image | Proxmox analogue |
| --- | --- | --- |
| `Never` (default) | Ignore. The rootfs is the source of truth forever. | `pct create` semantics |
| `Recreate` | Wipe the PVC and re-seed. Destroys all state. | destroy + recreate the CT |
| `Overlay` | Only meaningful in the overlay architecture (§3.2): swap the lower layer. | no analogue |

`Never` must be the default. Silently resetting a user's rootfs because a tag moved would be the
single worst failure mode this project can have.

## 3. Candidate architectures

### 3.1 Architecture A — copy-on-first-boot (Proxmox-faithful)

The PVC holds a full, ordinary root filesystem. Seeded once from a source, owned by the guest
thereafter.

```text
PVC (ext4, RWO)  ──►  /mnt/rootfs  ──►  pivot_root  ──►  /sbin/init
       ▲
   seeded once from an OCI image (an `image:` volume, or the init container's
   own rootfs) or from an LXC rootfs template fetched over HTTPS — see §3.4
```

The guest container's own image is the **shim**, never the seed. The machine's operating system
lives in the PVC; the container image only carries the program that mounts it and hands over to the
guest's init. This is obvious for an LXC template — a tarball cannot be a container image — and it
is equally true for an OCI source.

- **Pros.** Simplest mental model. Exactly matches Proxmox. `apt upgrade` inside the guest works
  and persists. No layered-filesystem edge cases. Snapshot/restore is trivially correct.
- **Cons.** Full copy of the image on first boot — a few seconds to a few minutes, and the PVC must
  be sized for the whole OS. No path to updating the base OS from outside. Image and state are
  permanently entangled, so a "rebuild from scratch" means destroying the volume.
- **Privileges.** `CAP_SYS_ADMIN` (ideally inside a user namespace) for the mounts and
  `pivot_root`.

The PVC is mounted at an ordinary path (`/mnt/rootfs`) and the switch to `/` is done by the
container's entrypoint. Declaring `volumeMounts: [{mountPath: /}]` instead is rejected by runc and
would shadow `/proc`, `/sys` and `/dev` even if it were not — see
[02-kubernetes-primitives.md](02-kubernetes-primitives.md) §4.0. The entrypoint therefore does the
work `lxc-start` does:

```sh
mount -t proc   proc   /mnt/rootfs/proc
mount -t sysfs  sysfs  /mnt/rootfs/sys        # ro for systemd guests, cf. sys:mixed
mount -t tmpfs  tmpfs  /mnt/rootfs/dev
for d in null zero full random urandom tty console; do   # see "device nodes" below
    : > /mnt/rootfs/dev/$d
    mount --bind /dev/$d /mnt/rootfs/dev/$d
done
mount -t devpts devpts /mnt/rootfs/dev/pts
mount -t tmpfs  tmpfs  /mnt/rootfs/dev/shm
mount -t tmpfs  tmpfs  /mnt/rootfs/run
mount -t cgroup2 none  /mnt/rootfs/sys/fs/cgroup   # writable; see 05-open-questions.md §4
export container=lxc                          # see 06-guest-provisioning.md §6
pivot_root /mnt/rootfs
exec /sbin/init
```

The mount set is **fixed, not per-guest**. A systemd guest needs the writable cgroup2; a runit
guest ignores it. Mounting it unconditionally is permitted inside a user namespace because
`cgroup2_fs_type` carries `FS_USERNS_MOUNT`, so this costs nothing and removes an entire
configuration axis — see [05](05-open-questions.md) §4.

Ordering is the whole point: kernel filesystems go into the new root *before* the pivot, which is
impossible to express declaratively.

**Device nodes must be bind-mounted, not created.** `mknod(2)` for character and block devices
checks the capability in the *initial* user namespace — `fs/namei.c`:

```c
if ((S_ISCHR(mode) || S_ISBLK(mode)) && !is_whiteout && !capable(CAP_MKNOD))
        return -EPERM;
```

and `capable()` is defined in `kernel/capability.c` as `ns_capable(&init_user_ns, cap)`. So in a
`hostUsers: false` pod the shim **cannot** create `/dev/null` at all, regardless of which
capabilities the pod requests, because it holds them only in its own user namespace. This is the
same reason rootless Podman cannot `mknod`, and why containerd notes that "in case of user
namespaces, the runtime simply bind mounts the devices from the host".

The workaround is the one Proxmox already uses in `lxc-pve-autodev-hook`: create a **regular file**
as a mount point and bind the real device over it.

```perl
PVE::Tools::mknod("$root/dev/$dev", S_IFREG, 0)
    or die("Could not mknod $root/dev/$dev: $!\n");
PVE::Tools::mount("/var/lib/lxc/$vmid/passthrough/dev/$dev", "$root/dev/$dev", 0, MS_BIND, 0)
```

The nodes to bind are the ones the runtime has already placed in the container's own `/dev`, so no
host access is needed. `devpts` and `tmpfs` can still be mounted fresh — both are permitted inside
a user namespace — so only the fixed device nodes need this treatment.

Note that this makes the shim's device handling *identical* in the privileged and user-namespaced
modes, which is a simplification: there is no reason to keep an `mknod` path at all.

### 3.2 Architecture B — overlayfs, image below, PVC above

```text
lower = `image:` volume (read-only, stable since 1.36)
upper = PVC/upper, work = PVC/work
merged = /mnt/rootfs  ──►  pivot_root  ──►  /sbin/init
```

- **Pros.** First boot is instant — no copy. The PVC only stores the delta, so it can be small.
  The base image **can** be upgraded by changing the lower layer, which recovers a large part of
  the Kubernetes value proposition (immutable, rebuildable base) while keeping state persistent.
- **Cons.** Upgrading the lower layer under a live upper layer is the classic overlay-upgrade
  problem: whiteouts and copy-ups made against the old base can produce a broken merge. Package
  managers copy up huge trees on the first `apt upgrade`, so the delta grows fast. Debugging is
  harder. Overlay-on-overlay works on modern kernels but is a compatibility cliff on older ones.
  NFS cannot be an upper layer.
- **Privileges.** Same as A. Unprivileged overlay mounts inside a user namespace work since
  Linux 5.11, which fits the userns target well.

### 3.3 Architecture C — selective mounts, no root pivot

No privileges. Mount PVC sub-paths over the stateful directories only:

```yaml
volumeMounts:
  - { name: state, mountPath: /etc,       subPath: etc }
  - { name: state, mountPath: /var,       subPath: var }
  - { name: state, mountPath: /home,      subPath: home }
  - { name: state, mountPath: /root,      subPath: root }
  - { name: state, mountPath: /opt,       subPath: opt }
  - { name: state, mountPath: /srv,       subPath: srv }
  - { name: state, mountPath: /usr/local, subPath: usr-local }
```

- **Pros.** Runs on a Restricted PodSecurity namespace with no capabilities at all. No feature
  gates. Works on any cluster, any runtime, any kernel. `kubectl exec`, probes and logs behave
  normally.
- **Cons.** Not a stateful rootfs. `/usr`, `/bin`, `/lib` come from the image and reset on every
  image change, so a package installed with `apt` puts files in `/usr/bin` (gone) and its state in
  `/var` (kept) — a broken half-state. `/etc` mounted from a PVC must still be seeded on first
  boot, or the guest starts with no `/etc/passwd`.
- **Verdict.** Useful as a documented "unprivileged" mode with honest limitations, not as the
  headline feature. Best paired with a guest whose packages are installed at image build time and
  whose runtime state genuinely lives in `/var` and `/home`.

### 3.4 Architecture D — a real VM (KubeVirt)

If what is actually wanted is "a pet machine on Kubernetes with a persistent disk", KubeVirt
already delivers it: a PVC-backed disk, a real kernel, live migration, snapshots, and none of the
tricks above.

- **Pros.** Mature, supported, correct. Live migration exists. Full isolation.
- **Cons.** Requires hardware virtualisation, a much heavier footprint per instance, slower boot,
  and a whole additional platform component.
- **Verdict.** This must be named in the README as the honest alternative. `stateful-pods` is for
  people who want the *feel* of a VM at the *cost* of a container.

### 3.5 Architecture E — nested LXC/Incus inside a privileged pod

Run `lxc-start` itself inside a privileged pod, with the container rootfs on the PVC.

- **Pros.** Maximum fidelity — it literally is LXC, including all the Proxmox setup logic if
  vendored.
- **Cons.** A fully privileged pod, a container-in-container supervision stack, two layers of
  cgroup and network plumbing, and Kubernetes has no visibility into the inner container at all
  (no logs, no exec, no probes, no resource accounting).
- **Verdict.** Rejected. It reimplements a node inside a pod.

### 3.6 Recommendation

Ship **A** as the default, **B** as an opt-in mode, **C** as the unprivileged fallback, and
document **D** honestly.

```text
rootfs.mode: Copy     # A — default, Proxmox-faithful
rootfs.mode: Overlay  # B — needs ImageVolume (1.36+) and a modern kernel
rootfs.mode: Subdirs  # C — unprivileged, partial statefulness
```

**Scope note.** The first chart version implements **A only**, and `rootfs.mode` is not yet an
input at all — see [05](05-open-questions.md) §2. B remains a documented future mode. C was
reconsidered and dropped as a chart mode: partial statefulness contradicts the project's premise,
so it stays here as the honest unprivileged alternative to describe, not to ship.

Run every mode inside `hostUsers: false` where the cluster supports it, with `CAP_SYS_ADMIN` added
inside the user namespace rather than `privileged: true`. Fall back to `privileged: true` only
when user namespaces are unavailable, and say so loudly in the values file.

## 4. Consequences that must be designed for

### 4.1 The image stops being the source of truth

This is the whole point of the project, and it is also the thing that will surprise every
Kubernetes user who touches it. After first boot:

- Changing `image:` in the values does nothing (with the default upgrade policy).
- GitOps drift detection is meaningless for anything inside the rootfs.
- A rebuild-from-clean requires deleting the PVC, which no reconciler will do for you.

The chart must state this in the values comments, in the README, and ideally in a `NOTES.txt`
printed on install.

### 4.2 Logging

Proxmox sends guest init stdout to `/dev/null` and expects users to read the guest's journal.
Kubernetes users expect `kubectl logs` to work. Options:

1. Let the guest init write to the container's stdout. For systemd this means
   `ForwardToConsole=yes` plus `TTYPath=/dev/console`, which produces very noisy, unstructured
   logs but does make `kubectl logs` show a boot sequence.
2. Run a sidecar that tails the guest's journal (`journalctl -D /mnt/rootfs/var/log/journal -f`)
   and reprints it to stdout. Cleaner, costs a container.
3. Discard, like Proxmox, and document `kubectl exec … journalctl`.

Option 1 as the default with option 2 as an opt-in seems right: a pod whose `kubectl logs` is
empty feels broken to a Kubernetes user.

### 4.3 `kubectl exec`, probes and `pivot_root`

With `pivot_root` (not `chroot`), the container's mount namespace root *is* the guest rootfs, so
`kubectl exec` and exec probes run guest binaries and see guest paths. This is a strong argument
for `pivot_root` over `chroot` and should be treated as a requirement, not a preference.

If `pivot_root` turns out to be unavailable in some environment and `chroot` is used instead, every
exec must be wrapped:

```bash
nsenter --target 1 --mount --uts --ipc --net --pid --root --wd -- "$@"
```

and probes must use that wrapper. Document it; do not let users discover it.

### 4.4 Shutdown

`SIGTERM` to systemd is "re-exec", not "shut down". Use a `preStop` hook sending `SIGRTMIN+3` and
waiting for PID 1 to exit, with `terminationGracePeriodSeconds` matching Proxmox's 120 s default.
Move to `lifecycle.stopSignal` when `ContainerStopSignals` graduates.

For non-systemd inits, `SIGTERM` is usually correct and the hook should be skipped.

### 4.5 Identity on clone

Restoring a `VolumeSnapshot` into a new PVC produces two machines with the same
`/etc/machine-id`, the same SSH host keys, and possibly the same static IP config. Proxmox handles
this in `post_clone_hook` (`clear_machine_id`). The chart needs the same: a "cloned" flag or a
detection heuristic (marker records the PVC UID; if the current PVC UID differs, treat it as a
clone) that triggers identity regeneration.

### 4.6 What must never be persisted

Mirror Proxmox exactly: exclude `./dev/*` from the seed copy, and mount `/proc`, `/sys`, `/dev`,
`/dev/pts`, `/dev/shm`, `/run` and `/tmp` fresh at every boot. If a previous boot left files in
`/run` on the PVC, systemd will behave unpredictably.

### 4.7 Storage sizing and the `fsGroup` trap

A full OS rootfs is 300 MB (Alpine) to several GB (a Debian with a desktop). The PVC must be sized
accordingly, and resizing later depends on the CSI driver supporting expansion.

Do **not** set `fsGroup` on the rootfs volume: it triggers a recursive `chown` of every inode on
every mount. If it is unavoidable, `fsGroupChangePolicy: OnRootMismatch` limits the damage.

### 4.8 Scheduling

`ReadWriteOnce` + a rootfs means one pod, one node, `Recreate` update strategy, and no rolling
updates. A `StatefulSet` with one replica per instance is the natural shape; the chart should make
"one release = one machine" the model rather than trying to support replicas.

## 5. What this design gets that Proxmox does not

Worth stating, because it is not purely a re-implementation:

1. **Better UID isolation.** Kubernetes user namespaces plus idmapped volume mounts give
   unshifted on-disk ownership *and* a non-root host identity. Proxmox unprivileged containers
   shift ownership on disk by 100000 unless idmapped mounts are configured per mountpoint.
2. **The overlay mode has no Proxmox equivalent.** Proxmox cannot upgrade a container's base
   template; architecture B can.
3. **Standard Kubernetes storage.** Any CSI driver, any snapshot/backup tooling, any storage
   vendor — instead of Proxmox's fixed storage plugin list.
4. **In-place resource resize is GA (1.35).** Changing memory or CPU without a restart is the same
   cgroup write Proxmox does, but expressed in the API and reconciled.
