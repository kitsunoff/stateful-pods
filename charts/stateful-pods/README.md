# stateful-pods

A Helm chart that runs a *machine* — a pet with a persistent root filesystem — inside a Kubernetes
pod. Each machine gets its own StatefulSet, its own rootfs PersistentVolume and its own headless
Service.

> **The machine boots.** Its root filesystem is filled from the source it declares, mounted as a
> root, and handed to its own init system. Guest provisioning — cloud-init, SSH host keys, accounts —
> arrives in a later change, so a machine starts with the identity and accounts its source shipped.

## Prerequisites

Working on the chart needs two tools, both of which run without a cluster:

- **Helm 3.x** — <https://helm.sh/docs/intro/install/>
- **the `helm-unittest` plugin** — installed with:

  ```bash
  helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.0.3
  ```

Verify the plugin is available:

```bash
helm unittest --help
```

`kubeconform` is additionally used to validate rendered manifests against the Kubernetes API
schemas — <https://github.com/yannh/kubeconform>.

## Working on the chart

```bash
make lint         # helm lint --strict, against every example
make shell-lint   # shellcheck over every shell script
make docs         # the guarantees values.yaml makes about itself
make test         # helm unittest
make shell-test   # bats, inside a Linux container
make conform      # kubeconform against the Kubernetes API schemas
make image-test   # the toolbox image's archive and registry guarantees
make seccomp-test # the syscall filter, on a cluster whose kubelet filters by default
make render       # helm template
```

`make shell-test` and `make image-test` need a container engine: the scripts manipulate another
system's root filesystem, and ownership, extended attributes and file capabilities only exist on
Linux. `make image-test` additionally runs a throwaway registry on a container network of its own,
because an `oci` source is fetched from a registry rather than run.

`make integration-test` seeds a machine end to end on a throwaway `kind` cluster. It is the only
test that can tell whether a copy really preserved a file capability, or whether a second start
really does nothing. Its template case needs a tarball served over HTTPS, because that is what the
chart accepts:

```bash
TEMPLATE_URL='https://.../alpine/3.21/{arch}/default/<date>/rootfs.tar.xz' make integration-test
```

`{arch}` is replaced with the cluster node's own architecture, and the checksum is taken from the
publisher's `SHA256SUMS` beside the tarball. Both matter: a rootfs built for another architecture
seeds perfectly and then cannot be executed, so a fixed URL passes on the machine it was chosen on
and crash-loops everywhere else. Set `TEMPLATE_SHA256` to check against a digest of your own instead.

Without `TEMPLATE_URL` the template case is skipped rather than silently passed. In CI it comes from
the `INTEGRATION_TEMPLATE_URL` repository variable; distributors publish under dated paths, so it
needs refreshing when a build is retired upstream.

`make integration-test` then runs `make seccomp-test`, which builds a second cluster whose kubelet
applies a default syscall filter to every container that declares none. That is the configuration
under which a machine declaring no filter of its own does not boot, and it is the only place the
defect can be reproduced — so the suite reproduces it, on a real machine, before asserting that
declaring the filter starts the same machine on the same volume. Run it on its own with
`make seccomp-test`.

## Usage

A machine is declared under `machines`, keyed by its name. Exactly one machine per release is
supported for now.

```yaml
machines:
  web:
    source:
      kind: oci
      reference: docker.io/library/debian:13
    security:
      mode: userns
    rootfs:
      size: 8Gi
```

```bash
helm install lab charts/stateful-pods --values my-machine.yaml
```

> **Until the next release, name the shim image explicitly.** The default
> `shim.image` still points at an image published before the chart's scripts
> moved into it, so a default install renders containers whose command does not
> exist. Add `--set shim.image=<an image built from images/shim in this
> repository>` until the release that bumps the default lands.

Every object the release renders for that machine is named `<release>-<machine>` — `lab-web` for
the example above. **That name is permanent**: the machine's root filesystem lives in a
PersistentVolumeClaim derived from it, so renaming a machine or a release orphans its rootfs and
recreates the machine empty.

See `values.yaml` for the full input contract, with a comment on every input.

## Seeding

The first time a machine starts on an empty volume, an init container fills that volume from the
machine's `source`, and a second one records what it did. From then on both are no-ops: the volume
is the machine's operating system, and **changing `source` afterwards changes nothing**. Starting
from a different source means creating a new machine.

The record lives at `/.stateful-pods/provisioned` inside the machine. It is what makes seeding
happen once, so it survives everything the chart does not: deleting the release, moving the machine
to another node, upgrading the chart.

### What each source kind needs

| | `preset` | `oci` | `lxc` |
| --- | --- | --- | --- |
| You write | a name | an image reference | a URL and a checksum |
| Filled by | a step running the chart's own image | a step running the chart's own image | a step running the chart's own image |
| Obtained with | `crane`, after the name resolves to a reference | `crane`, which flattens the image's layers into a tar stream | `curl`, over HTTPS |
| The source must provide | nothing; it is never executed | nothing; it is never executed | nothing; it is a tarball |
| Integrity | the upstream's GPG signature over its published checksums, verified at build time against a key pinned in this repository | the registry, via the image's digest | the mandatory `sha256`, checked before anything is unpacked |
| Formats | not your problem | any image | `.tar.zst`, `.tar.xz`, `.tar.gz` |

### Naming a distribution instead of finding one

Declaring a source is the hardest part of installing this chart, and it is hard for a reason that
has nothing to do with machines: an `lxc` source needs a URL and a checksum found by hand from an
index that publishes a new dated build every day, and an `oci` source needs an image that happens to
be a whole operating system, which most published images are not.

A `preset` is a name for one this project publishes:

```yaml
machines:
  web:
    source:
      kind: preset
      name: debian-trixie
```

The names, and the digest-pinned reference each resolves to, are in `presets.yaml` beside this file.
Today they are `debian-trixie`, `ubuntu-noble`, `alpine-3.24` and `void-current`. An unknown name
fails rendering and lists the ones that exist.

A preset is stronger than an `lxc` source rather than merely shorter. Each one is an upstream
distribution's own root filesystem, packaged unmodified — the archive that was verified *is* the
image's layer, so there is no extraction for an extended attribute to be lost in — and it is
packaged only after the detached GPG signature the upstream publishes over its checksums verifies
against a key fingerprint pinned in this repository. A checksum you found yourself establishes that
the bytes did not change in transit from whoever served them, and nothing more.

What a name resolves to is decided while the chart renders and at no later point, so the manifest
you review carries the same source the pod will use. The catalog moves only through a reviewed
change, even though the builds behind it are published automatically: a newer upstream build is
almost certainly better, but what the chart points at is still a decision.

The presets carry a `pullSecretName` like any other source, because the registry serving them may
want credentials — a preset is a name for a reference, not a promise about who may fetch it.

Presets are not extensible through values. A user who wants their own image already has `kind: oci`,
which is the honest way to say "an image I chose".

**Any OCI image can be a source.** Nothing from it is executed, so an Alpine-, busybox- or
distroless-based image is an ordinary source — it needs no shell and no archiver of its own. What it
does need, to be a *machine*, is an init system for the boot to hand over to; an image with none is
refused at boot, naming that.

**An `oci` source only has to resolve once.** The volume's state is read before anything touches the
network, so a machine that has been seeded makes no registry request on any later start, and a
reference that stops resolving afterwards does not stop the machine. Pinning by digest is still the
safe form, because a machine's first start may happen long after its values were written.

**The seeded filesystem matches the node's architecture.** The chart resolves a multi-architecture
reference to the architecture of the node the machine runs on, rather than to a fixed default. A
source that offers no build for it fails at seeding, naming the architecture, instead of filling the
volume with an operating system that cannot execute its own init.

### A private source

A machine whose source needs authentication names a `kubernetes.io/dockerconfigjson` Secret in the
release's namespace:

```yaml
machines:
  web:
    source:
      kind: oci
      reference: registry.example.com/private/debian:13
      pullSecretName: registry-credentials
```

The Secret is mounted into the seeding step alone — the guest container a user execs into never sees
it — and no username, password or token is a chart input, because a value is stored in the release,
printed by `helm get values` and usually committed.

The ServiceAccount's `imagePullSecrets` are **not** consulted: the chart performs this fetch itself
rather than the kubelet, so the credentials the cluster would have supplied for an image it pulls are
not available to it. A docker configuration that delegates to a credential helper (`credsStore`,
`credHelpers`) is not supported; the Secret has to carry a static `auths` entry.

### Sizing the volume

`rootfs.size` must hold the unpacked operating system. For an `lxc` source, add the compressed size
of the template: it is downloaded onto the same volume, verified, unpacked, and then deleted.

### A volume the chart did not create

A volume that already holds content but carries no record is refused, and nothing is touched. That
state is ambiguous between a seeding that died half-way and content someone put there deliberately,
and the chart will not guess. An interrupted seeding is recognised separately and retried on its
own.

### Restoring a snapshot

Restoring a snapshot back into the machine it was taken from keeps that machine's identity.
Restoring it under a different namespace, release or machine name is a clone: the machine ID is
cleared so the guest generates a fresh one, and nothing else on the volume is touched. SSH host keys
are not yet handled and are inherited by a clone — that arrives with guest provisioning.

## Booting

Once the volume is seeded, the guest container mounts what an init system expects to find inside it,
changes the root to the volume, and hands over to the machine's own `/sbin/init`. From that moment
the container's process *is* the machine.

The root change is `pivot_root`, not `chroot`, and that is a requirement rather than a preference: it
makes the container's mount namespace root the machine, so `kubectl exec` and exec probes land in the
machine rather than in this chart's image.

```bash
kubectl exec --stdin --tty lab-web-0 -- /bin/sh   # a shell in the machine, not in the shim
kubectl logs lab-web-0 --follow                   # the machine's own boot sequence
```

### What a machine gets

The mount set is the same for every machine and is not configurable: `/proc`, a read-only `/sys`, a
`tmpfs` `/dev` with the runtime's own device nodes bound into it, `/dev/pts`, `/dev/shm`, `/run`,
`/tmp`, and a writable `cgroup2` hierarchy at `/sys/fs/cgroup`.

The control-group hierarchy is mounted for every machine, whatever it runs. A systemd guest needs one
it can own — Kubernetes mounts the pod's read-only — and a guest running a lighter init ignores it.
Making it an input would add a value whose wrong setting produces a machine that fails to boot for a
reason no message could explain.

Device nodes are bound from the ones the runtime already gave the pod, never created: `mknod` checks
the capability in the *initial* user namespace, so a pod running in its own user namespace cannot
create `/dev/null` at all, whatever it is granted. This is what Proxmox does, and it makes both
security modes take the identical path.

The machine is told it is running in a container. Without it systemd concludes it is on hardware and
starts loading kernel modules, checking filesystems and taking over the control-group hierarchy.

### Files the chart maintains inside the machine

A pod is given `/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` as mounts into the container
image's filesystem. After the root change those are no longer in the machine's root, so the chart
writes them into the machine itself, on every boot, from the pod's own copies. Without it a machine
boots with no resolver and a host name belonging to the image's build machine.

To keep one of them as the machine's own, create a marker beside it inside the machine:

```bash
touch /etc/.stateful-pods-ignore.resolv.conf
```

The marker is per file — claiming the resolver does not also claim the host name — and it lives on
the volume, so it travels with the machine rather than with the release.

### Readiness, shutdown and logs

The chart ships a **readiness probe and no liveness probe**. Readiness gates the Service endpoint
without touching the machine; a liveness probe would reboot a pet because something inside it was
briefly unresponsive, destroying the state that would have explained why.

The machine's headless Service publishes its address before it is ready, so its stable name resolves
while it is still booting and while it is unwell — which is exactly when someone is looking for it.

Deleting the pod asks the machine to shut down with the signal its own init understands. `SIGTERM`
means *re-execute* to systemd, not *stop*, so the default would leave every machine to be killed when
the grace period expired. The grace period is 120 seconds, copying Proxmox's own.

The machine's console goes to the pod's logs, so `kubectl logs` shows a boot sequence. It is noisy
and unstructured, and that is the accepted cost of not being empty. Per-service logs stay in the
machine's own journal.

### The syscall filter

Every container the chart renders names the filter it runs under, and none is left for the cluster
to choose. The steps that run before the guest declare the runtime's default profile: they unpack,
write and fetch, so nothing it withholds is in their way, and it needs no file on any node. The
guest declares `Unconfined`.

That declaration is not a preference, it is what keeps a machine bootable. A kubelet running with
`--seccomp-default=true` gives the runtime's default profile to every container that names none, and
containerd's default profile does not contain `pivot_root` — not in its base list, and not in the
block it unlocks for `CAP_SYS_ADMIN`, which does contain `mount`, `umount2`, `unshare` and `setns`.
A machine that inherited it would render, seed its volume over several minutes and then die at the
root change, on some clusters and not others.

To confine the machine itself, name a profile the cluster provides:

```yaml
machines:
  web:
    security:
      mode: userns
      seccompProfile:
        type: Localhost
        localhostProfile: profiles/stateful-pods-machine.json
```

`Localhost` is the only form that can carry a filter permitting the root change, so it is the only
alternative to `Unconfined` the chart accepts; `RuntimeDefault` is refused at render time with the
reason. The file it names lives on the node, which is outside anything a chart can create. A profile
suitable for a machine — LXC's own denylist, which every Proxmox container already runs under —
ships at `profiles/stateful-pods-machine.json`, and `profiles/README.md` documents the three ways to
get it onto nodes and what it is worth in each mode.

**Both modes run under the filter they name.** The `privileged` mode did not use to: it rendered a
container the runtime had been told to stop policing, and containerd drops the profile such a
container names before it builds it — measured rather than assumed, a profile denying an ordinary
system call stopped an unprivileged container and was absent from the privileged container's runtime
spec while the CRI request still carried the reference. That mode renders a capability set now, so
the reference is honoured and the machine reports a loaded filter.

### The access-control profile

The guest container also declares the AppArmor profile it runs under, `Unconfined`, in both modes,
for the same kind of reason and against the same kind of default. Containerd confines every container
it has not been told to stop policing with a default profile of its own, `cri-containerd.apparmor.d`,
on any node where AppArmor is supported — and that profile contains `deny mount,`. The guest exists
to mount. Left to the node, a machine would boot or not boot depending on whether that node has
`apparmor_parser` installed.

This is not a profile the chart ships. It is the field a real one would be named in, and a profile
that permits what a machine does is a later change.

**This field is why the chart requires Kubernetes 1.30.** `securityContext.appArmorProfile` does not
exist before then: on 1.27–1.29 it is either dropped, leaving the machine unable to start on any node
running AppArmor, or rejected outright — `kubeconform -strict` against the 1.29 schema calls it an
additional property that is not allowed. The chart's floor moved up rather than the field being made
conditional, because a posture that varies with the cluster it was rendered against is the thing this
chart most consistently refuses. Every release below 1.30 is long out of support, and none of them
could run `userns` in any case.

### What each mode grants

`userns` adds `CAP_SYS_ADMIN` to a pod running in its own user namespace, where it is void on the
node.

`privileged` grants the guest a named set, and every capability in it is real on the node:

```text
AUDIT_WRITE  CHOWN  DAC_OVERRIDE  FOWNER  FSETID  KILL  MKNOD  NET_BIND_SERVICE
NET_RAW      SETFCAP  SETGID  SETPCAP  SETUID  SYS_ADMIN  SYS_CHROOT
```

That is what a container gets by default, plus the `CAP_SYS_ADMIN` the mount and the root change
need. `ALL` is dropped first, so the list in the manifest is the whole of what the guest holds rather
than an addition to whatever a runtime currently calls a default.

It is deliberately narrower than the runtime's privileged flag, which is not a capability set at all.
A machine in this mode cannot load a kernel module, perform raw I/O, set the node's clock, override
the node's mandatory access control, or open a device the pod was not given — not even one it creates
the node for itself. `CAP_DAC_READ_SEARCH` and `CAP_SYS_BOOT` are absent permanently: they are what
`open_by_handle_at` and `kexec_load` need, and those are the two escape primitives the profile in
`profiles/` exists to close.

Capabilities outside the set are not refused on principle, merely not yet needed — `CAP_NET_ADMIN`
is the one to watch, since a machine wanting its own firewall or tunnel needs it. A capability added
here should name the machine that needed it and the failure that showed it; without that the set
drifts back towards the blanket flag one well-intentioned commit at a time.

### Prerequisites the chart cannot check

The `userns` mode is verified at render time against the cluster's Kubernetes version, and that is
the only part of it the chart can see. These it cannot, and a machine that renders may still fail to
boot on them:

- the node's kernel, which must support user namespaces for pods;
- the container runtime's configuration;
- whether the storage backend supports idmapped mounts — NFS does not.

When one of them is missing the boot fails on a mount, naming the path and the filesystem type. The
`privileged` mode has none of these prerequisites and asks nothing of the cluster beyond the chart's
own floor. Its capabilities are real on the node, which is what the name is about, but it is a named
set rather than an instruction to the runtime to stop applying policy — see *What each mode grants*
above.

**What `userns` looks like when the environment cannot support it.** The mode has been exercised by
hand on a `kind` cluster, where it does not work — a `kind` node is itself a container, so a pod's
user namespace nests inside one, and every volume in the pod would additionally have to support
idmapped mounts. The failure arrives before any of this chart's code runs, from the runtime:

```text
Error: failed to create containerd task: failed to create shim task: OCI runtime create failed:
runc create failed: unable to start container process: error during container init:
error running createContainer hook #0: ... permission denied
```

The pod never leaves `Init:RunContainerError`, and no chart message appears because nothing of the
chart has executed yet. A failure *inside* the chart looks different: the guest container starts, and
its log names the mount it could not make.

Because of this the project's own integration test boots `privileged` only. `userns` is supported and
rendered, and it is verified against the cluster version at render time, but it is not exercised by
this repository's CI.

## Upgrading

### `privileged` stops rendering the runtime's privileged flag

**Breaking.** A machine whose `security.mode` is `privileged` used to render `privileged: true`,
which is not a capability set but an instruction to the runtime to stop applying policy. It now
renders the named set documented under *What each mode grants*. Upgrading replaces the machine's pod
with a differently privileged one on its next start.

**The root filesystem is untouched.** Nothing about a machine's volume, its identity or its seeding
record changes, so a machine that breaks under the new set is recovered with a values change and a
pod replacement rather than a rebuild.

**The chart's minimum Kubernetes version moves from 1.27 to 1.30**, because the guest now names the
AppArmor profile it runs under and that field does not exist before 1.30. See *The access-control
profile* above for why the field is not optional. A cluster below 1.30 gets a clear refusal from Helm
rather than a machine that fails to mount.

What a machine in this mode no longer has:

| No longer granted | What breaks | What to do instead |
| --- | --- | --- |
| Any device the pod was not given | Opening one fails, including through a device node the machine creates itself | Ask for the device with a device plugin. Proxmox's own privileged container is allowed the same short list. |
| `CAP_SYS_MODULE` | `modprobe`, `insmod` and `rmmod` inside a machine | Load the module on the node. It is the node's kernel in either case. |
| `CAP_SYS_RAWIO` | Direct block-device access | A machine's disk is the volume it boots from. |
| `CAP_SYS_TIME` | A time daemon inside a machine trying to set the clock | Disable it. The node keeps the clock and the machine reads it. |
| `CAP_MAC_ADMIN`, `CAP_MAC_OVERRIDE` | Altering or overriding the node's mandatory access control | Nothing an operating system needs to start. |
| Everything else outside the set, `CAP_NET_ADMIN` included | A machine running its own firewall, or bringing up a tunnel | A pod's addressing belongs to the cluster's CNI. If a machine genuinely needs one of these, report the case — the set grows on evidence, not on convenience. |

What a machine in this mode gains: **the syscall filter its values name now reaches it.** A
`privileged` machine that named a profile was running unfiltered, because containerd drops the
profile a privileged container names before it builds one. It reports a loaded filter now, and
`profiles/stateful-pods-machine.json` is worth the same in this mode as in the other.

To go back, roll the release back one revision: the previous revision renders the privileged flag
again and the pod is replaced. No volume is affected in either direction.

## Specification coverage

Every scenario in the `chart-skeleton` change's specs maps to at least one test. Suite names
below are files under `tests/`.

### machine-topology

| Scenario | Covered by |
| --- | --- |
| A machine is declared by name | `naming_test.yaml`, `minimal_render_test.yaml` |
| Replica scaling is not offered | `values_rejected_inputs_test.yaml`, `hack/check-values-docs.sh` |
| Objects carry the machine name | `naming_test.yaml` |
| Adding a second machine renames nothing | `machine_iteration_test.yaml`, `naming_test.yaml` |
| A machine's objects are rendered | `minimal_render_test.yaml` |
| The rootfs volume is single-writer | `rootfs_volume_test.yaml` |
| The guest container runs the shim | `shim_image_test.yaml`, `statefulset_test.yaml` |
| An LXC template source renders without a container image of its own | `shim_image_test.yaml` |
| One instance per machine | `statefulset_test.yaml` |
| An update never doubles the instance | `statefulset_test.yaml` |
| A machine is created from a snapshot | `rootfs_snapshot_test.yaml` |
| No snapshot named means an empty volume | `rootfs_snapshot_test.yaml` |
| Default hostname | `hostname_test.yaml` |
| Explicit hostname | `hostname_test.yaml` |
| Uninstalling the release leaves the volume | `rootfs_retention_test.yaml` |
| The StatefulSet controller does not reclaim the volume | `rootfs_retention_test.yaml` |
| Upgrading does not change the selector | `selector_stability_test.yaml` |
| Version labels are present but not selected on | `selector_stability_test.yaml` |
| Stable name for a machine | `service_test.yaml`, `notes_test.yaml` |

### pod-security-posture

| Scenario | Covered by |
| --- | --- |
| Only the supported modes are accepted | `values_security_mode_test.yaml` |
| A user-namespaced pod is rendered | `security_posture_test.yaml` |
| Host namespaces are never shared in this mode | `security_negative_test.yaml` |
| A privileged pod is rendered | `security_posture_test.yaml` |
| The excluded capabilities are absent | `security_posture_test.yaml`, `hack/integration-test.sh` |
| The mode can still be confined | `seccomp_named_profile_test.yaml`, `hack/seccomp-test.sh` |
| The same values render the same posture everywhere | `security_cluster_independence_test.yaml` |
| No unnamed privilege is granted | `security_negative_test.yaml` |
| The mode is read from the machine | `values_security_mode_test.yaml`, `security_posture_test.yaml` |

### values-validation

| Scenario | Covered by |
| --- | --- |
| A rejection names the path and the fix | every `values_*_test.yaml` suite |
| Invalid input produces no manifest | `validation_entrypoint_test.yaml` |
| Unset security mode is rejected | `values_security_mode_test.yaml` |
| Unknown security mode is rejected | `values_security_mode_test.yaml` |
| No mode is chosen automatically | `security_cluster_independence_test.yaml` |
| A cluster too old for user namespaces is rejected | `security_version_check_test.yaml` |
| An unverifiable prerequisite does not block rendering | `security_version_check_test.yaml` |
| No machines declared | `values_machines_map_test.yaml` |
| More than one machine declared | `values_machines_map_test.yaml`, `machine_iteration_test.yaml` |
| Invalid machine name is rejected | `values_machine_name_test.yaml` |
| Overlong combined name is rejected | `values_machine_name_test.yaml` |
| Missing source is rejected | `values_rootfs_source_test.yaml` |
| Unknown source kind is rejected | `values_rootfs_source_test.yaml` |
| Fields belonging to the other kind are rejected | `values_rootfs_source_test.yaml` |
| OCI source without a reference is rejected | `values_rootfs_source_test.yaml` |
| LXC source without a URL is rejected | `values_rootfs_source_test.yaml` |
| Missing checksum is rejected | `values_rootfs_source_test.yaml` |
| There is no way to disable verification | `hack/check-values-docs.sh` |
| A credential value is not accepted | `hack/check-values-docs.sh` |
| A pull secret on a source kind that does not fetch an image is rejected | `values_rootfs_source_test.yaml` |
| An empty pull secret reference is rejected | `values_rootfs_source_test.yaml` |
| An input that was designed away is rejected | `values_rejected_inputs_test.yaml` |
| An omitted Proxmox-equivalent option is explained | `hack/check-values-docs.sh` |

Two further suites cover the mechanics rather than a single scenario:
`validation_ordering_test.yaml` (structural failures short-circuit the semantic ones) and
`validation_entrypoint_test.yaml` (every violation is reported in one message).

### rootfs-seeding

Suites named `.bats` are under `test/shell/`; the rest are chart unit tests under `tests/`.

| Scenario | Covered by |
| --- | --- |
| An empty volume is filled | `seed-driver.bats`, `hack/integration-test.sh` |
| The seeded filesystem is a root filesystem | `seed-oci-copy.bats`, `seed-lxc.bats` |
| A restart does not re-seed | `seed-driver.bats`, `prepare.bats`, `hack/integration-test.sh` |
| A changed source does not re-seed | `seed-driver.bats` |
| An interrupted seeding does not leave a half-filled volume in service | `seed-driver.bats`, `seed-oci-copy.bats` |
| The record identifies the source | `prepare.bats` |
| The record is readable by a later version | `prepare.bats` |
| An OCI-sourced volume is filled | `seed-oci-copy.bats`, `hack/integration-test.sh` |
| File capabilities survive the copy | `seed-oci-copy.bats`, `hack/image-test.sh`, `hack/integration-test.sh` |
| A source that carries no userland is still usable | `seed-oci-copy.bats`, `hack/integration-test.sh` |
| Layer removals are honoured | `hack/image-test.sh` |
| An unreachable image is a failure, not an empty machine | `seed-oci-copy.bats` |
| A multi-architecture source seeds the node's architecture | `seed-oci-copy.bats`, `hack/integration-test.sh` |
| A source with no build for the node is refused | `seed-oci-copy.bats` |
| A restart makes no request to the source | `hack/integration-test.sh` |
| A source that stops resolving does not stop the machine | `hack/integration-test.sh` |
| A named credential is used | `source_pull_secret_test.yaml` |
| No credential named means an anonymous fetch | `source_pull_secret_test.yaml` |
| The credentials reach only the seeding step | `source_pull_secret_test.yaml` |
| A rejected credential fails with a usable message | `seed-oci-copy.bats` |
| A matching checksum is unpacked | `seed-lxc.bats` |
| A mismatched checksum is refused | `seed-lxc.bats` |
| An unreachable template is a failure, not an empty machine | `seed-lxc.bats` |
| An archive that is not a root filesystem is rejected | `seed-lxc.bats` |
| A multi-part archive is rejected | `seed-lxc.bats` |
| Device nodes are not copied | `seed-oci-copy.bats` |
| Runtime directories are present but empty | `seed-driver.bats`, `hack/integration-test.sh` |
| A failed seeding does not start a guest | `seed-driver.bats`, `seed-oci-copy.bats` |
| The cause is visible where a user will look | `seed-driver.bats`, `seed-lxc.bats` |

### machine-identity

| Scenario | Covered by |
| --- | --- |
| A machine identifier from the image is not kept | `prepare.bats`, `hack/integration-test.sh` |
| Two machines seeded from the same source differ | `prepare.bats` |
| A machine restored under a new name gets its own identity | `prepare.bats` |
| A machine restored under its own name keeps its identity | `prepare.bats` |
| A clone keeps its data | `prepare.bats` |
| An ordinary restart is not a clone | `prepare.bats`, `hack/integration-test.sh` |

### shim-image

| Scenario | Covered by |
| --- | --- |
| A release refers to one chart-supplied image | `init_containers_test.yaml` |
| No container runs a machine's source | `shim_image_test.yaml`, `hack/integration-test.sh` |
| Every command is a path inside the image | `init_scripts_test.yaml` |
| No rendered object carries script content | `init_scripts_test.yaml` |
| The helpers that run inside the machine come from the image | `boot-handover.bats`, `hack/integration-test.sh` |
| The most common template format can be opened | `hack/image-test.sh`, `seed-lxc.bats` |
| Attributes survive unpacking | `hack/image-test.sh`, `seed-lxc.bats` |
| Attributes survive a flattened image | `hack/image-test.sh`, `hack/integration-test.sh` |
| The default reference is immutable | `shim_image_test.yaml` |
| The image is available for the architectures the audience runs | `.github/workflows/ci.yaml` (multi-architecture build) |
| Preparation is done by writing files | `prepare.bats`, `seed-oci-copy.bats` |
| Generated content comes from the chart's own tools | `prepare.bats` |

### machine-boot

| Scenario | Covered by |
| --- | --- |
| The guest's root is the volume | `hack/integration-test.sh` |
| A shell in the machine is the machine's shell | `hack/integration-test.sh` |
| The volume is not offered to the runtime as the root | `boot_test.yaml`, `rootfs_volume_test.yaml` |
| An init system finds what it expects | `boot-mounts.bats`, `hack/integration-test.sh` |
| A control-group hierarchy the guest can own | `boot-mounts.bats`, `hack/integration-test.sh` |
| Device nodes come from the runtime, not from creation | `boot-handover.bats`, `hack/integration-test.sh` |
| Two machines get the same filesystems | `boot-mounts.bats` |
| There is no input that changes it | `boot-mounts.bats`, `hack/check-values-docs.sh` |
| The init system knows where it is | `boot-handover.bats`, `hack/integration-test.sh` |
| A failed mount stops the boot | `boot-mounts.bats` |
| A machine with no init is reported as such | `boot-handover.bats` |
| An unseeded volume is never booted | `boot-handover.bats` |

### guest-managed-files

| Scenario | Covered by |
| --- | --- |
| A machine knows its own name | `customize.bats`, `hack/integration-test.sh` |
| A machine can resolve names | `customize.bats`, `hack/integration-test.sh` |
| The values are refreshed, not seeded once | `customize.bats`, `hack/integration-test.sh` |
| A file the machine claims is left alone | `customize.bats`, `hack/integration-test.sh` |
| Claiming one file does not claim the others | `customize.bats`, `hack/integration-test.sh` |
| The opt-out lives with the machine | `customize.bats` |

### machine-lifecycle

| Scenario | Covered by |
| --- | --- |
| A booting machine is not yet ready | `lifecycle-helpers.bats`, `hack/integration-test.sh` |
| A booted machine is ready | `lifecycle-helpers.bats`, `hack/integration-test.sh` |
| Readiness does not depend on knowing the guest | `lifecycle-helpers.bats` |
| No check can restart the machine | `boot_test.yaml` |
| A machine shuts down cleanly | `lifecycle-helpers.bats`, `hack/integration-test.sh` |
| The signal follows the machine, not a declaration | `lifecycle-helpers.bats` |
| Stopping waits for the machine to finish | `lifecycle-helpers.bats`, `boot_test.yaml` |
| The boot is visible from outside | `hack/integration-test.sh` |
| A machine that fails to boot says why | `boot-mounts.bats`, `boot-handover.bats` |

### machine-topology (added by machine-boot)

| Scenario | Covered by |
| --- | --- |
| A booting machine can be reached | `service_reachability_test.yaml` |
| The name does not disappear when the machine is unwell | `service_reachability_test.yaml` |

### machine-topology (modified) and pod-security-posture (added)

| Scenario | Covered by |
| --- | --- |
| The guest container runs the shim | `shim_image_test.yaml`, `statefulset_test.yaml` |
| An LXC template source renders without a container image of its own | `shim_image_test.yaml` |
| An OCI source is never a container image | `shim_image_test.yaml`, `init_containers_test.yaml`, `hack/integration-test.sh` |
| The guest container alone is privileged | `init_security_test.yaml` |
| The guest container alone is granted the mode's capability | `init_security_test.yaml` |
| Preparation steps are ordinary containers | `init_security_test.yaml` |

### pod-security-posture (added and modified by seccomp-posture)

| Scenario | Covered by |
| --- | --- |
| The preparation steps declare the runtime's default filter | `seccomp_posture_test.yaml` |
| The default filter does not depend on the machine's mode | `seccomp_posture_test.yaml` |
| A named filter is applied to the machine | `seccomp_named_profile_test.yaml` |
| The filter applies to the machine and to nothing else | `seccomp_named_profile_test.yaml` |
| The same values render the same posture everywhere | `security_cluster_independence_test.yaml` |
| The syscall filter is never left to the cluster | `seccomp_posture_test.yaml` |
| A cluster that filters by default does not change the machine | `hack/seccomp-test.sh` |

### pod-security-posture (added by bounded-privileged-mode)

| Scenario | Covered by |
| --- | --- |
| The guest declares the profile it runs under | `apparmor_posture_test.yaml` |
| The preparation steps are left to the node's default | `apparmor_posture_test.yaml` |

### values-validation (added by seccomp-posture)

| Scenario | Covered by |
| --- | --- |
| An unknown filter form is rejected | `values_seccomp_profile_test.yaml` |
| A filter form requiring a path is rejected without one | `values_seccomp_profile_test.yaml` |
| A path supplied to a form that takes none is rejected | `values_seccomp_profile_test.yaml` |
| The runtime default is rejected for the machine | `values_seccomp_profile_test.yaml` |
| The rejection does not apply to the preparation steps | `values_seccomp_profile_test.yaml` |

### distro-presets

| Scenario | Covered by |
| --- | --- |
| The contents are the upstream's | `hack/preset-build.sh` compares the published layer's `diff_id` against the checksum of the archive that was verified |
| A preset carries no configuration of ours | `crane mutate` sets a platform and labels and nothing else |
| An unsigned or wrongly signed checksum list stops the build | `test/presets/verification.bats` |
| A checksum mismatch stops the build | `test/presets/verification.bats` |
| What was verified is recorded | the `io.stateful-pods.preset.upstream.*` labels |
| One reference serves both architectures | `hack/preset-build.sh`, asserted in `preset-publish.yaml` |
| A preset with an incomplete upstream is not published | `test/presets/verification.bats` |
| A published tag keeps its content | the preset stage of `hack/integration-test.sh`, which builds twice and compares |
| No tag tracks the newest build | every tag names an upstream build date |
| A named preset renders as a pinned reference | `values_preset_source_test.yaml` |
| The table is part of the chart | `hack/check-presets.sh`, which packages the chart and renders a preset from the package |
| The five newest builds of a preset remain | `test/presets/retention.bats` |
| Retention is per preset | `hack/preset-retention.sh` runs per package |
| A kept build stays whole | `test/presets/retention.bats`, and asserted after every run |
| A newer upstream build is proposed | `preset-bump.yaml`, `test/presets/bump.bats` |
| An unchanged upstream proposes nothing | `test/presets/bump.bats` |
| A proposal names a reference that already exists | `preset-bump.yaml` publishes before it proposes |

### values-validation (added by distro-presets)

| Scenario | Covered by |
| --- | --- |
| A missing preset name is rejected | `values_preset_source_test.yaml` |
| An unknown preset name is rejected with the alternatives | `values_preset_source_test.yaml` |
| A preset name is never substituted | `values_preset_source_test.yaml` |
| A field belonging to another kind is rejected | `values_preset_source_test.yaml` |
