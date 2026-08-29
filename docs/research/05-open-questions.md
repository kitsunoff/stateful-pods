# Open questions

Decisions that must be made before the chart is written. Each one changes the shape of the
templates, so they are worth settling first.

## 0. Already settled

Recorded here so the rest of the list is read as genuinely open.

| Decision | Where |
| --- | --- |
| The PVC cannot be given to the container as `mountPath: /`; the entrypoint does the mounts and `pivot_root` | [02](02-kubernetes-primitives.md) §4.0 |
| Device nodes are bind-mounted, never `mknod`-ed — `mknod` is impossible in a user namespace | [03](03-mapping-and-architecture.md) §3.1 |
| `container=lxc` in PID 1's environment is mandatory, not optional | [06](06-guest-provisioning.md) §6 |
| cloud-init is supported, via a NoCloud seed directory — no ISO, no block device | [06](06-guest-provisioning.md) §3 |
| Every provisioning input is expressible inline **or** as a Secret/ConfigMap reference | [07](07-provisioning-inputs.md) §1 |
| `instance-id` is computed by the init container at boot, seeded with namespace + release + machine name | [07](07-provisioning-inputs.md) §5 |
| cloud-init user-data persists to the volume and appears in snapshots — accepted, not mitigated | [07](07-provisioning-inputs.md) §6 |
| Raw provisioning files shadow structured values per file, no merging (Proxmox `cicustom` semantics) | [07](07-provisioning-inputs.md) §4.2 |
| The shim is **bash scripts**, not a compiled binary | §10a |
| The shim and init containers **manipulate files** in the guest rootfs and never execute guest binaries | §10a |
| **One machine per release** for now; a fleet form is planned, one StatefulSet per machine | §1 |
| Default rootfs architecture is **Copy**; Overlay stays an opt-in `rootfs.mode` | §2 |
| `security.mode` is **mandatory** — no default, no autodetect, render fails if unset | §3 |
| **No `guest.init` value** — the shim always `exec`s `/sbin/init` and detects the rest at boot | §4 |
| Default provisioning backend is **cloud-init**, and its absence in the image must fail loudly | §5a |
| A rootfs source is **either an OCI image or an LXC template tarball**, with an explicit kind | [02](02-kubernetes-primitives.md) §3.4 |
| An LXC template **must** carry a checksum; there is no opt-out | [02](02-kubernetes-primitives.md) §3.4 |
| The guest container's image is the **shim**, never the machine's rootfs source | [03](03-mapping-and-architecture.md) §3.1 |
| Guest hostname follows the **pod's hostname**, with an explicit per-machine override | §1 |
| OCI seeding **copies from the init container's own rootfs**; `ImageVolume` deferred | §6 |
| The guest console is **forwarded to stdout** so `kubectl logs` is not empty | §8 |
| The chart ships a **readiness probe only** — no liveness probe for a pet | §9 |
| Backup is **`VolumeSnapshot` only**, plus an optional snapshot data source on the rootfs volume | §10 |
| The shim image is **Alpine + busybox** plus `tar`, `xz`, `zstd`, `bash`; one image for everything | §10a |
| The project is framed as an **experiment**, not a KubeVirt alternative | §11 |
| Integration tests run on **kind** | §12 |

One pleasant consequence of the network decision in §5 below: because the chart does **not** write
network configuration, Proxmox's ten per-distro `Setup` plugins have no counterpart here.
`/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` are distro-agnostic. The only distro-specific
work left is knowing which network-management unit to mask, which is a short table rather than a
plugin architecture.

## 1. Scope: what is a "release"?

**Decided.** One machine per release for now. `replicas` is never exposed — a machine is a pet, and
a `StatefulSet` with `replicas: 3` sharing one seed image would have to derive hostname, SSH keys
and identity from the ordinal, which makes pet semantics incoherent.

**Planned.** A fleet form where a release declares several machines, each rendered as its own
StatefulSet with its own PVC and its own identity. Not `replicas` on one StatefulSet — genuinely
separate objects, because each machine diverges after first boot.

### 1.1 Consequence: shape the values for the fleet form today

The fleet form is known to be coming, so the templates should be written for it now. Retrofitting
it later is a breaking change that renames every object, and renaming a StatefulSet means its PVC
is orphaned and the machine is recreated empty. That is the one migration this project cannot
offer its users.

The cheap way to avoid it is to make the values fleet-shaped from the first commit and simply
refuse more than one entry:

```yaml
machines:
  web:
    image: ...
    rootfs:
      size: 20Gi
```

- A **map keyed by machine name**, not a list. `--set machines.web.image=...` works;
  `--set machines[0].image=...` is misery.
- Every object is named `<release>-<machine>` from day one, so adding a second machine renames
  nothing.
- Every helper template takes the machine as an explicit argument rather than reading `.Values`
  globals, which is what actually makes the later change a one-line removal.
- A `fail` in `_helpers.tpl` when `len(.Values.machines) > 1`, with a message saying the fleet form
  is not implemented yet. Lifting the restriction later touches exactly that one line.

The cost is that the single-machine case reads slightly more verbosely than a flat values file
would. That is a small, one-time readability tax against a guaranteed breaking change.

**Decided: hostname follows the pod, with an explicit override.** By default the guest's hostname is
whatever the pod's hostname already is; a machine may set `hostname` to override it.

This is cheaper than it looks. The kubelet already sets the pod's UTS hostname, and containerd
already bind-mounts `/etc/hostname` with that value ([02](02-kubernetes-primitives.md) §8). Layer 0
copies that file into the guest rootfs, so the default costs nothing beyond the copy that has to
happen anyway. The override is `pod.spec.hostname`, which flows through the exact same path — one
mechanism, not two.

## 2. Default architecture

**Decided.** Copy (A) — see [03](03-mapping-and-architecture.md) §3.1. It matches the project's
stated idea, has the fewest failure modes, and is the easiest to explain.

Overlay (B) stays a documented future `rootfs.mode`; its base-upgrade story needs validation before
it could ever be a default. Subdirs (C) is **not planned as a chart mode at all** — it delivers
partial statefulness (`/usr` and `/bin` still reset on an image change) which contradicts the
project's premise, so it stays in the research as the honest unprivileged alternative rather than
as something the chart offers.

The first chart version therefore implements Copy only, and `rootfs.mode` does not yet exist as an
input — adding it later is additive and renames nothing.

## 3. Privilege model

**Decided.** Explicit choice, no default. An unset `security.mode` fails template rendering with a
message explaining the ladder. The chart never silently escalates privileges, and it never guesses
from `.Capabilities.KubeVersion` — the API server version says nothing about the node's kernel or
the storage class's filesystem, so any autodetect would be confidently wrong some of the time.

The ladder, as a design space:

1. `userns` — `hostUsers: false` + `CAP_SYS_ADMIN`. Requires Kubernetes 1.36 (or 1.33+ with the
   gate), containerd 2.0+/CRI-O, Linux 6.3+, idmap-capable filesystems, and no NFS.
2. `sysbox` — `runtimeClassName: sysbox-runc`. Requires a cluster admin to install sysbox.
3. `privileged` — works everywhere, gives up almost all isolation.

**The first chart version implements rungs 1 and 3 only.** Sysbox is excluded not for licensing
reasons — Sysbox CE is open source — but because the project cannot exercise it today, and its
details (interaction with `hostUsers`, CRI-O annotations) are the kind that fail quietly when
guessed. Adding it later is additive: one accepted value and one branch. Recorded in the
`chart-skeleton` change's `pod-security-posture` spec.

Every implemented rung grants `CAP_SYS_ADMIN` in some form, which is what lets §4 treat the shim's
mount set as fixed rather than mode-dependent.

## 4. Init system: no values field, detect at boot

**Decided.** There is **no `guest.init` value.** The shim runs `exec /sbin/init` for every guest and
works out the rest at runtime. An earlier draft proposed an explicit enum; the argument for it does
not survive scrutiny.

The proposed field existed to drive two things. Both turn out not to need it.

**Writable cgroup2 for systemd.** systemd wants to own its cgroup subtree, which Kubernetes does
not give it — `/sys/fs/cgroup` is mounted read-only by default. But the shim controls the mount
table of the new root, and mounting a fresh cgroup2 there is permitted inside a user namespace,
because the filesystem carries `FS_USERNS_MOUNT` (`kernel/cgroup/cgroup.c`):

```c
static struct file_system_type cgroup2_fs_type = {
        .name                   = "cgroup2",
        .init_fs_context        = cgroup_init_fs_context,
        .parameters             = cgroup2_fs_parameters,
        .kill_sb                = cgroup_kill_sb,
        .fs_flags               = FS_USERNS_MOUNT,
};
```

With `CAP_SYS_ADMIN` in the pod's own user namespace — which every value of `security.mode` already
grants — and the private cgroup namespace containerd gives containers on cgroup v2 hosts, the shim
can simply mount it, unconditionally. A guest running runit ignores it; nothing is lost. So this is
not a per-guest decision at all, it is a fixed part of the shim.

**The shutdown signal.** This is the one that looked like it had to be declarative, because
`lifecycle.preStop` lives in the pod spec, which Helm renders before the rootfs exists. But
`preStop` is a *script*, so it can branch at runtime on systemd's own canonical check — the
existence of `/run/systemd/system`, which is what `sd_booted(3)` tests:

```sh
if [ -d /run/systemd/system ]; then kill -s RTMIN+3 1; else kill -s TERM 1; fi
```

That removes the last reason for the field.

**What is left that is genuinely systemd-specific** — masking network-management units, getty
units, and warning about a systemd older than 232 in a pure cgroup v2 environment — is guest
*customization*, not init *selection*. All of it is detectable by looking at the seeded rootfs from
the init container, which is exactly what Proxmox does rather than asking the user:

```perl
my $systemd = $self->ct_readlink('/sbin/init');
if (defined($systemd) && $systemd =~ m@/systemd$@) { ... }
```

Detecting rather than declaring is both simpler and more faithful to the reference design.

**Deferred to experiment.** Proxmox warns when the guest's systemd is too old for cgroup v2,
inspecting the init binary with `objdump`. Whether that warning is worth carrying depends on
whether anything actually misbehaves in our arrangement, which is a question for the integration
tests of §12 rather than for reading. Same disposition as §5.

## 5. How much guest customization to implement

Proxmox has ten distribution plugins, most of the code being network configuration. Reimplementing
that is a large, thankless surface.

**Question.** Which of these does the chart manage?

| File | Manage? | Note |
| --- | --- | --- |
| `/etc/hostname` | almost certainly yes | trivial, and the guest needs it |
| `/etc/hosts` | yes | copy the pod's, which already has hostAliases applied |
| `/etc/resolv.conf` | yes | copy the pod's, which already has the cluster DNS policy applied |
| `/etc/localtime` | probably | cheap |
| `/etc/machine-id` | yes, at provision and on clone detection | identity correctness |
| SSH host keys | yes, at provision | identity correctness |
| Root password / `authorized_keys` | yes, at provision, from a Secret | how else does anyone get in |
| `container=` marker + `/run/host/*` | **yes, mandatory** | see [06](06-guest-provisioning.md) §6 |
| Network interface config | **no — disable it** | see below |
| TTY / getty | **?** | there is no console to attach to in a pod |

**Deferred to experiment.** Which units need masking on which distributions is not answerable by
reading; it needs a real pod on a real cluster. This is the one item that gates the
`guest-customization` change, and the first thing the §12 integration environment should be pointed
at.

**Network configuration is not just unnecessary, it is actively harmful.** The CNI configures
`eth0` in the pod's network namespace before any container starts. If the guest's network manager
then applies a chart-written config, the pod loses the address it was given. This inverts Proxmox's
approach: instead of writing `/etc/network/interfaces`, the job is to *stop*
`systemd-networkd`/`NetworkManager`/`ifupdown` from touching the interface, and — with the
cloud-init backend — to set `network: {config: disabled}` in the drop-in. Which per-distro units
need masking is still untested and remains the biggest unknown in the design.

The `container=` row is a hard requirement discovered in [06](06-guest-provisioning.md) §6: a
Kubernetes pod has neither `/.dockerenv` nor `/run/.containerenv`, so without an explicit
`container=lxc` in PID 1's environment, systemd and cloud-init both conclude they are on bare metal.

Getty setup is likely pointless: nothing will ever attach to `/dev/tty1`. Masking the getty units is
probably more useful than configuring them.

## 5a. Provisioning backend and `instance-id` composition

[06](06-guest-provisioning.md) proposes three backends (`native`, `cloud-init`,
`systemd-credentials`) over a mandatory layer 0. Two decisions follow from it.

**Which backend is the default? Decided: `cloud-init`.** It is what people actually want, and the
Debian and Ubuntu cloud images the audience will reach for already ship it.

This carries an obligation. `native` degrades gracefully on any image; `cloud-init` does not — on an
image without cloud-init installed, the seed is written, nothing reads it, and the machine boots
with no users, no keys and no way in, with nothing in the logs explaining why. **The provisioning
init container must therefore verify that cloud-init is actually present in the seeded rootfs and
fail the pod with an explicit message if it is not**, naming `guest.provisioning: native` as the
fix. A silent no-op here is the worst failure mode available to this chart, because it looks like
a successful install.

Auto-detection was rejected for the same reason it was rejected for `security.mode`: behaviour that
depends on image contents is behaviour nobody can reason about from the values file. Detecting in
order to *fail loudly* is fine; detecting in order to *silently switch backends* is not.

**What goes into `instance-id`?** Settled in [07](07-provisioning-inputs.md) §5: the init container
hashes the materialized files plus an identity seed of namespace + release + machine name, at boot.
What remains open is that re-apply-on-change and regenerate-on-clone are **coupled** — a user cannot get
one without the other. If someone wants a byte-identical clone, they would have to pin the value.
Is an escape hatch (`cloudInit.instanceId`, itself following the §2 inline/ref contract) worth
exposing?

**Does the `native` backend need its own clone detection?** Yes — the instance-id trick only helps
when cloud-init is running. The `native` backend still needs the hand-written "PVC uid changed →
regenerate machine-id and SSH host keys" path from [03](03-mapping-and-architecture.md) §4.5. That
is duplicated logic; worth checking whether the marker file can serve both backends.

## 6. Seed source

`image:` volume source (needs 1.36 for stable) versus "the init container's own rootfs is the
seed" (works everywhere, but couples the seed OS to the provisioning tooling).

**Decided: copy from the init container's own rootfs.** The seed image *is* an init container, and
it copies its own `/` into the PVC. No dependency on `ImageVolume`, so it works on any cluster, and
it is the simplest thing that can possibly work.

One consequence has to be handled rather than assumed: the copy has to come from a tool **inside
the seed image**, because a musl-linked archiver from the shim cannot run there (§10a). Any
glibc-based distribution image has GNU `tar` and GNU `cp --preserve=all`; a busybox-based one
(Alpine) has neither with xattr support, and would silently drop file capabilities. The seeding
change must therefore probe for a capable archiver and **fail with a clear message** rather than
producing a subtly broken rootfs — the same "fail loudly, never silently degrade" rule as §5a.

`ImageVolume` remains the cleaner mechanism and is worth revisiting once 1.36 is a safe floor; it
sidesteps the archiver problem entirely by letting the shim's own GNU tar do the copy.

**Related, and already decided:** this question is only about the *OCI* retrieval mechanism. An
LXC template source ([02](02-kubernetes-primitives.md) §3.4) is always fetched by the init
container over HTTPS, so it has no equivalent choice — and it needs `zstd`, `xz` and `gzip` in the
shim image on top of the GNU `tar` that §10a already requires.

## 7. Upgrade policy default

Confirmed by the design, but worth restating as a decision: the default for a changed seed image
must be **do nothing**. Any policy that can destroy a user's rootfs must be opt-in, and probably
should require a second confirmation value (e.g. `rootfs.reprovision.confirm: "yes-destroy-my-data"`).

## 8. Logging

Empty `kubectl logs` versus a noisy console dump versus a journal-tailing sidecar. See
[03-mapping-and-architecture.md](03-mapping-and-architecture.md) §4.2.

**Decided: forward the guest's console to the container's stdout**, so `kubectl logs` shows a boot
sequence rather than nothing. For a systemd guest that means `ForwardToConsole=yes` with the console
pointed at the container's output.

The output is unstructured and noisy, and that is accepted. A pod whose logs are empty reads as
broken to every Kubernetes user, and the first thing anyone does when a machine does not come up is
`kubectl logs`. Noise that answers the question beats silence that does not. This is a deliberate
divergence from Proxmox, whose unit sends guest init output to `/dev/null`
([01](01-proxmox-lxc-boot.md) §3.1).

## 9. Health checking

**Decided: the chart ships a readiness probe; no liveness probe by default.**

A liveness probe on a pet is dangerous — restarting a machine because a service was briefly
unresponsive is worse than leaving it degraded and visible. Readiness is the right signal: it gates
the Service endpoint without touching the machine.

The probe has to adapt to whichever init the guest runs, which the shim already detects
(§4): `systemctl is-system-running` for systemd, and a simpler check otherwise. It ships as a script
in the shim so the pod spec does not need to know which guest it is running.

## 10. Backup and clone

**Decided: `VolumeSnapshot` and nothing else — plus the ability to restore from one.** The chart
does not ship backup tooling, schedules or restore procedures; it exposes an optional data source on
the rootfs volume so a machine can be created from an existing `VolumeSnapshot`.

That single input is what makes snapshots useful without building anything: restoring is creating a
release whose rootfs starts from a snapshot. Everything else — taking snapshots, retention,
off-cluster copies — belongs to the cluster's snapshot tooling, which already exists and is better
at it.

Clone-identity regeneration is not optional and is already handled: a restored volume in a new
release gets a different identity seed, so `machine-id` and SSH host keys are regenerated
([07](07-provisioning-inputs.md) §5.1). Restoring into the *same* release keeps the identity, which
is what disaster recovery wants.

## 10a. The shim image

Every document treats "the shim" as if it exists. It does not yet — and it is the only piece of
this project that is not a Helm template, so it needs its own decisions.

**Decided: bash scripts, not a compiled binary.** Debuggability wins. This project will generate a
lot of "why did my machine not boot", and a user who can `cat` the script and read exactly which
mounts were attempted is in a far better position than one holding an opaque binary. It also keeps
the barrier to contribution low.

The shim must provide:

- `mount`, `pivot_root`, and the device-node bind loop from
  [03](03-mapping-and-architecture.md) §3.1
- the provisioning logic per backend — reading `/provisioning/*`, writing into `/mnt/rootfs`,
  honouring `.pve-ignore.<name>` markers
- `sha1sum` for the `instance-id` computation of [07](07-provisioning-inputs.md) §5
- the seed copy for architecture A

### Consequences of the bash decision

- **busybox alone is not sufficient — verified against the busybox source, not assumed.** It covers
  more than expected and falls short in exactly two places:

  | Need | busybox | Evidence |
  | --- | --- | --- |
  | `tar` | yes | `archival/tar.c` |
  | gzip / bzip2 / xz / lzma decompression | yes | `FEATURE_SEAMLESS_GZ`, `_BZ2`, `_XZ`, `_LZMA` in `archival/Config.src` |
  | `mount`, `pivot_root`, `mknod`, `sha1sum` | yes | standard applets |
  | SELinux context restore in tar | yes | `FEATURE_TAR_SELINUX` |
  | **zstd decompression** | **no** | `grep -rn zstd` over the whole tree returns nothing; the tar autodetect list is `Z \|\| GZ \|\| BZ2 \|\| LZMA \|\| XZ` |
  | **extended attributes in tar** | **no** | zero `xattr` references anywhere under `archival/` |

  The zstd gap is disqualifying on its own: Proxmox distributes its templates as `.tar.zst`
  (`debian-13-standard_13.0-1_amd64.tar.zst`), and `PVE::LXC::Create` maps `.zst` to `--zstd`. A
  busybox-only shim cannot open the single most common LXC template. linuxcontainers.org's
  `rootfs.tar.xz` would work, which is what makes this easy to miss in testing.

  The xattr gap is quieter and worse: extraction succeeds and the rootfs looks fine, but
  `security.capability` is dropped, so on a modern Debian `ping` fails for any non-root user with
  `socket: Operation not permitted`. Nothing in the logs explains it.

  So: **Alpine base, busybox for the shell and the mount work, plus `tar`, `xz`, `zstd` and `bash`
  from packages** — on the order of a megabyte on top of the base image. GNU tar is used only for
  seeding, with flags equivalent to Proxmox's `@PVE::Storage::Plugin::COMMON_TAR_FLAGS` (see
  [02](02-kubernetes-primitives.md) §3.1). `rsync -aHAX` is an alternative for the OCI copy path
  but does not help the tarball path.

  If the scripts were written for POSIX `sh` rather than bash, the `bash` package could be dropped
  too — busybox `ash` covers the rest. Not proposed, just noted as available.

- **An Alpine/musl shim does not affect a glibc guest.** The concern is reasonable and the answer is
  structural: `exec` replaces the process image. After `pivot_root`, the shim `exec`s `/sbin/init`,
  and the new program's ELF `PT_INTERP` — `/lib64/ld-linux-x86-64.so.2` for a Debian binary — is
  resolved against the *new* root, so systemd loads the guest's own glibc from the PVC. The musl
  userland belonged to a process that no longer exists. Nothing is shared but the kernel, whose
  syscall ABI is stable by design.

  The proof is Proxmox itself, running the same arrangement in mirror image: a Debian/glibc host
  starting Alpine/musl containers, which is what `PVE::LXC::Setup::Alpine` exists for.

  **The invariant this rests on: the shim and the init containers manipulate files in the guest
  rootfs, and never execute guest binaries.** A glibc binary from the PVC launched from the
  musl-linked container rootfs would fail to find its loader. Proxmox observes the same rule — its
  per-distro plugins only read, write and symlink files (`ct_file_set_contents`, `ct_symlink`), and
  where it genuinely needs a program it runs the *host's* copy and writes the result in:

  ```perl
  my sub generate_ssh_key { # create temporary key in hosts' /run, then read and unlink
      PVE::Tools::run_command(['ssh-keygen', '-f', $file, '-t', $type, ...]);
  ```

  We do the same: Alpine's `ssh-keygen` produces the host keys, and the resulting text files are
  written into the PVC. If some step ever does need to run a guest binary, it must `chroot` into
  the rootfs first, at which point the guest's own loader applies and musl is again irrelevant.

  One small consequence worth knowing rather than discovering: musl's `crypt(3)` supports SHA-crypt
  (`$5$`, `$6$`) but not yescrypt (`$y$`), which is libxcrypt's default on Debian 12 and later. A
  password hashed in the shim will be `$6$`. Every current guest verifies `$6$` fine, so this
  affects the format written, not whether login works.
- **`set -euo pipefail` and explicit error messages are not optional.** A shell script that
  half-mounts and then execs init produces a guest that fails in a way nobody can diagnose. Every
  mount should be checked and every failure should say which path and which mount type.
- **Shell injection surface.** Values flow into the script (hostname, paths, credential names).
  Everything must be passed through the environment or files and quoted, never interpolated into
  the script text by Helm. A ConfigMap-mounted script plus an env-var interface is the safe shape.
- **Testable with `bats` or `shellspec`**, plus `shellcheck` in CI. That satisfies the project's
  TDD requirement for the non-Helm half without needing a cluster.

**Decided: Alpine plus busybox, with the packages above.** One image, used by every init container
and by the guest container. Splitting it would duplicate layers for no benefit, and one image means
one thing to build, sign and pin.

The exception is the seed copy: it runs in the *source image*, not the shim, because a musl-linked
archiver cannot execute there (§6).

**Still open (mechanical, not design).** Where it is built and published, and how the chart pins it
— a `:latest` reference is not reproducible, so a digest plus a release process is needed.
Multi-arch (`amd64` + `arm64`) is table stakes for the homelab audience.

## 11. Naming and positioning

**Decided: this is an experiment, and the README says so first.** The framing is "what if pods were
fully stateful?" — a project exploring whether the Proxmox LXC model can be reproduced on stock
Kubernetes primitives, not a product competing with KubeVirt.

That is a much easier position to hold honestly than "lighter alternative to KubeVirt", and it sets
the right expectations for every rough edge the design already knows about: no live migration, a
shared kernel, an image that stops being the source of truth after first boot, and a privilege
requirement that a hardened cluster will refuse.

The technical comparison still belongs in the README, but underneath the framing rather than as the
opening pitch: no hardware virtualisation, container-speed boot, container-level overhead, and it
stays a Pod so every Kubernetes tool still works. KubeVirt is named as the answer for anyone who
needs this in production.

## 12. Testing strategy

TDD is required by the project's conventions, and Helm charts are testable at two levels:

- **Template tests** (`helm template` + assertions, or `helm unittest`) — rendering logic, the
  privilege ladder, the values validation. These can be written first.
- **Integration tests** (kind/k3s + a real PVC) — does a Debian rootfs actually boot, does state
  survive a pod delete, does clone detection fire. These need a cluster with a suitable kernel and
  storage class, which constrains CI.

**Decided: kind.** Integration tests run against a kind cluster in CI, and kind is also the
environment that answers the deferred experiments of §4 and §5.

Two caveats to establish early rather than trip over:

- **The `userns` mode may not be testable on kind.** A kind "node" is itself a container, so pods
  run nested, and user namespaces additionally require every filesystem in the pod's volumes to
  support idmapped mounts. A GitHub runner's kernel is new enough (6.x, well past the 6.3 floor),
  but the node filesystem is overlayfs inside a container, and that combination needs verifying
  before it is relied on. If it does not work, CI covers `privileged` only and the `userns` path is
  exercised manually — which must then be stated, not glossed over.
- **A storage class with real `ReadWriteOnce` PVCs is required.** kind's default local-path
  provisioner is sufficient for a single-node test, and snapshot-restore (§10) needs a CSI driver
  that supports `VolumeSnapshot`, which local-path does not — so that path is either tested with a
  different provisioner or left to manual verification.
