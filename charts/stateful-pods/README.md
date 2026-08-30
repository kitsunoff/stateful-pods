# stateful-pods

A Helm chart that runs a *machine* — a pet with a persistent root filesystem — inside a Kubernetes
pod. Each machine gets its own StatefulSet, its own rootfs PersistentVolume and its own headless
Service.

> **The machine boots, and it is provisioned.** Its root filesystem is filled from the source it
> declares, mounted as a root, and handed to its own init system — and cloud-init, by default, gives
> it the users, keys, packages and commands its values ask for. A machine on an image that cannot run
> cloud-init says so and stops, rather than booting with no way in — which today is two of the four
> presets, `ubuntu-noble` and `void-current`.

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
make plugin-test  # the kubectl plugin's suite, on this host's bash
make conform      # kubeconform against the Kubernetes API schemas
make image-test   # the toolbox image's archive and registry guarantees
make seccomp-test # the syscall filter, on a cluster whose kubelet filters by default
make render       # helm template
```

`make plugin-test` runs the plugin's suite directly on the host and needs `bats` there; it
is how the bash 3.2 constraint is checked locally (`make plugin-test MACHINE_BASH=/bin/bash`
on macOS). `make shell-test` runs the same suite in the container as well.

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
helm install lab oci://ghcr.io/kitsunoff/charts/stateful-pods --version 0.3.1 \
  --values my-machine.yaml
```

`helm install lab charts/stateful-pods --values my-machine.yaml` installs the chart in a
checkout instead, which is the same chart at whatever revision that checkout is on.

Every object the release renders for that machine is named `<release>-<machine>` — `lab-web` for
the example above. **That name is permanent**: the machine's root filesystem lives in a
PersistentVolumeClaim derived from it, so renaming a machine or a release orphans its rootfs and
recreates the machine empty.

See `values.yaml` for the full input contract, with a comment on every input.

## The kubectl plugin

`kubectl machine` addresses a machine by the name it was declared under, instead of by the
`<release>-<machine>-0` the chart derives from it:

```bash
kubectl machine list                      # every machine here, and the stage each is in
kubectl machine status web                # where one machine is in its life
kubectl machine shell web                 # a shell inside the machine
kubectl machine console web --follow      # the machine's own boot output
kubectl machine create web --preset debian-trixie --mode userns
kubectl machine delete web                # the release; the root filesystem is kept
```

A machine takes minutes to become usable, and for most of that time a pod-level view says
`Init:1/4`. The plugin answers the question that was actually asked: whether the machine is
being seeded, prepared or customized, booting, ready or stopped — and when it cannot be
entered, which stage it is in and the one command whose output explains the wait.

It validates nothing. Every input goes to the chart, and what comes back when one is wrong
is the chart's own message, unchanged. It removes no root filesystem: `delete` uninstalls
the release, says the volume survived and prints the separate command that would destroy
it. There is no flag that does both.

### Installing it

With krew, from a published release:

```bash
kubectl krew install --manifest-url https://github.com/kitsunoff/stateful-pods/releases/download/v0.3.1/machine.yaml
```

Or without krew, since it is one file:

```bash
curl --silent --show-error --location --fail --remote-name \
  https://github.com/kitsunoff/stateful-pods/releases/download/v0.3.1/kubectl-machine_v0.3.1.tar.gz
sha256sum --check <(curl --silent --location --fail \
  https://github.com/kitsunoff/stateful-pods/releases/download/v0.3.1/SHA256SUMS)
tar --extract --gzip --file kubectl-machine_v0.3.1.tar.gz
install -m 0755 kubectl-machine /usr/local/bin/kubectl-machine
```

The file has to be named exactly `kubectl-machine` and be on `PATH`; that is how `kubectl`
finds a plugin. From a checkout, `install -m 0755 cmd/kubectl-machine /usr/local/bin/` does
the same thing.

`shell`, `console`, `list` and `status` need only `kubectl`. `create` and `delete` also need
`helm`, because they install and uninstall a release.

### What it does not support

**Windows.** The plugin is a bash program, which is the trade taken when it was written in
bash rather than Go: it is one file with no build step and no toolchain, and there is no
bash on Windows worth targeting. Under WSL it is an ordinary Linux install. Run anywhere
else, it says which platform it found and stops, rather than failing part-way through an
action.

macOS is supported, and that is a real constraint rather than a hope: macOS ships bash 3.2,
so the plugin uses none of bash 4 — no associative arrays, no `mapfile`, no `${var^^}`. A
job in CI runs its suite and the shell lint against that bash on every push, because a
construct that breaks the target runs perfectly in the Linux container the other suites use
and fails on somebody's Mac.

### Creating a machine

`create` installs the chart by reference, and defaults that reference to the chart this
project publishes at the plugin's own version, so it needs no `--chart` of its own:

```bash
kubectl machine create web --preset debian-trixie --mode userns
```

`--chart` points it at a checkout instead, which is how a machine is created from a chart
that has not been released:

```bash
kubectl machine create web --chart ./charts/stateful-pods \
  --preset debian-trixie --mode userns
```

`--set` and `--values` reach `helm` unchanged, which is how anything the plugin has no flag
for is supplied — a seccomp profile, a volume snapshot to restore from. A private source
needs `--pull-secret <name>`, naming a `kubernetes.io/dockerconfigjson` secret in the
namespace. The preset images this project publishes are public, so a `--preset` machine
needs none.

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

The images themselves are a package per distribution and variant, and a tag per release —
`ghcr.io/kitsunoff/stateful-pods-debian-cloud:trixie`, `…-alpine-cloud:3.24`,
`…-ubuntu:noble`, `…-void:current` — beside an immutable tag naming the upstream build,
`noble-20260829_0742`. The release tag follows the newest build and is there for a person who
wants to pull one; `presets.yaml` names neither, because what a machine is seeded from is a digest.

The variant is in the package name rather than in the tag because two variants of one release carry
the same upstream serial. A tag naming only the release and that serial would name two different
root filesystems, and the build refuses to republish a dated tag it already published — so the
collision would not be reported, it would silently leave whichever variant arrived first in place.

#### Which presets carry cloud-init

The chart's provisioning backend will default to cloud-init, so a preset that cannot run it is a
preset that cannot serve a default install. Two of the four are therefore built from their upstream's
`cloud` variant, and nothing is installed into a preset to make up the difference.

Two are not, for different reasons. Void's upstream publishes no cloud variant — only `default` and
`musl` — so it stays on `default` permanently. Ubuntu's upstream does publish one, but its two
architectures are on different builds, and one tag cannot honestly name two of them; `ubuntu-noble`
stays on `default` until the upstream levels, and moving it is one line in
`images/presets/presets.list` plus a catalog entry. Nothing switches a variant on its own: the daily
bump reads that field and never writes it.

| Preset | Upstream variant | Provisioning it can serve | Uncompressed |
| --- | --- | --- | --- |
| `debian-trixie` | `cloud` | cloud-init, native | 557 MiB |
| `ubuntu-noble` | `default` (pending) | native only | 585 MiB |
| `alpine-3.24` | `cloud` | cloud-init, native | 76 MiB |
| `void-current` | `default` | native only | 361 MiB |

Alpine's cloud variant is six times the size of its default one, because cloud-init brings a Python
runtime with it.

**cloud-init is present, not enabled.** The upstream's own builder disables cloud-init in the LXC
images this project packages, by writing an empty `/etc/cloud/cloud-init.disabled` into them — its
LXD and Incus outputs write a seed and enable cloud-init in one step, and the plain LXC archive is
that with the enabling left out. A preset carries the marker unmodified, because a preset carries
everything unmodified. Removing it belongs to whatever writes the seed, and until that exists a
machine from a cloud preset boots exactly as one from a default preset did: cloud-init's units are
present, they check the marker, they warn and they stop.

A preset is stronger than an `lxc` source rather than merely shorter. Each one is an upstream
distribution's own root filesystem, packaged unmodified — the archive that was verified *is* the
image's layer, so there is no extraction for an extended attribute to be lost in — and it is
packaged only after the detached GPG signature the upstream publishes over its checksums verifies
against a key fingerprint pinned in this repository. What was published is then compared back
against what was verified: the layer's `diff_id` must equal the checksum of the decompressed
archive. A checksum you found yourself establishes that
the bytes did not change in transit from whoever served them, and nothing more.

What a name resolves to is decided while the chart renders and at no later point, so the manifest
you review carries the same source the pod will use. The catalog moves only through a reviewed
change, even though the builds behind it are published automatically, and even though the release
tag moves with them: a newer upstream build is almost certainly better, but what the chart points
at is still a decision.

The presets carry a `pullSecretName` like any other source, because the registry serving them may
want credentials — a preset is a name for a reference, not a promise about who may fetch it.

Presets are not extensible through values. A user who wants their own image already has `kind: oci`,
which is the honest way to say "an image I chose".

#### A preset is a whole distribution, and in `privileged` mode it behaves like one

A preset boots the distribution's own init, and that init does what it does on a real machine —
including applying the distribution's sysctl defaults. In `privileged` mode those writes reach the
**node's** kernel, because `kernel.*` sysctls are not namespaced and a privileged container is not
prevented from setting them. They outlive the machine, and they affect every other pod on that node.

This is not hypothetical, and it is not a defect. The Void preset ships
`/usr/lib/sysctl.d/10-void-user.conf`, which sets `kernel.kexec_load_disabled=1`. That switch only
goes one way: once a Void machine has booted on a node in `privileged` mode, nothing on that node
can load a kexec kernel again until it reboots. `kernel.dmesg_restrict` and
`kernel.yama.ptrace_scope` come from the same file.

`privileged` grants a named capability set on purpose, and this is what that grant is worth. A
machine in `userns` mode cannot do it: the sysctls in question are not namespaced, so the write is
refused rather than applied. If a machine does not need to be able to reconfigure its node's kernel,
that is the mode for it.

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

## Provisioning

A machine boots with the accounts its source image shipped, which for every preset this project
publishes means none at all. Provisioning is how a user, an SSH key, a package list or a first-boot
command gets into it.

```yaml
machines:
  web:
    guest:
      provisioning: cloud-init      # cloud-init | native. cloud-init is the default.
    cloudInit:
      user:
        value: maxim
      sshAuthorizedKeys:
        value: |
          ssh-ed25519 AAAAC3Nz... maxim@workstation
```

### The two backends

**`cloud-init`, the default.** The chart writes a NoCloud seed into the machine's own root
filesystem at `/var/lib/cloud/seed/nocloud/` — `meta-data`, `user-data`, and `network-config` and
`vendor-data` when they are supplied. A seed directory rather than the usual `cidata` image, because
attaching one would need a raw block volume and `volumeDevices` is forbidden outright in
user-namespaced pods. Four files and no privilege at all.

Beside it goes a drop-in the chart owns, at `/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg`, which
hands back what other layers already own:

```yaml
datasource_list: [NoCloud, None]
network:
  config: disabled          # the CNI configured eth0 before any container started
preserve_hostname: true     # the kubelet's, written into the machine on every boot
manage_etc_hosts: false
growpart:
  mode: "off"               # the rootfs is a mounted volume, not a partitioned disk
resize_rootfs: false
```

The network line is the important one. Proxmox's whole guest-customization layer exists to *write*
`/etc/network/interfaces`; here the job is the exact inverse, because a configuration applied on top
of what the CNI did takes away the address the pod was given.

**`native`.** The chart writes nothing into the machine beyond the three files it already maintains
on every boot. It asks nothing of the image, so it works with any of them, and it provisions no
users and no keys. Switching an already-provisioned machine to it does not undo what was done: the
volume is the machine, and a value change that silently edited a running machine's `/etc` would be a
chart that destroys state on a typo.

`systemd-credentials` is described in the design and is not implemented. Naming it fails rendering
and says so, rather than pretending the name is a typo.

### An image that cannot run cloud-init fails the machine

Before anything is written, the provisioning step checks that the machine's root filesystem can
actually run cloud-init — the program, and something an init system would start it with. If it
cannot, **the pod fails** with a message naming `guest.provisioning: native` as the fix.

This is deliberate and it is the point. On an image without cloud-init a seed would be written,
nothing would read it, and the machine would boot with no users, no keys and no way in, with nothing
in the logs to explain it — which looks exactly like a successful install. Auto-detection that fails
loudly is fine; auto-detection that silently switches backends is not.

Changing the value is not enough on its own: a StatefulSet does not replace a pod that never became
ready, so delete the pod after the change.

```bash
helm upgrade … --set machines.web.guest.provisioning=native
kubectl delete pod web-0
```

**Installing cloud-init is not enough either.** The distributions ship their LXC images with
cloud-init installed *and* disabled, by an empty `/etc/cloud/cloud-init.disabled`: every systemd
unit carries `ConditionPathExists=!` on it, and Alpine's OpenRC scripts test it by hand. Removing it
is therefore part of what writing a seed means, and the chart does it — after the check, so an image
that fails is left exactly as it was.

### Which presets can serve which backend

| Preset | Backends it can serve | Why |
| --- | --- | --- |
| `debian-trixie` | `cloud-init`, `native` | built from the upstream `cloud` variant |
| `alpine-3.24` | `cloud-init`, `native` | built from the upstream `cloud` variant |
| `ubuntu-noble` | **`native` only** | its upstream's cloud architectures are not yet on one build |
| `void-current` | **`native` only** | its upstream publishes no cloud variant at all |

Nothing is installed into a preset to close either gap, because a preset is the distribution's own
root filesystem or it is not a preset. Void's upstream publishes only `default` and `musl`; Ubuntu's
`cloud` variant exists but its two architectures are not on the same build, and one tag cannot
honestly name two root filesystems. **A machine on either must name `guest.provisioning: native`**
or it will not start.

**An `lxc` template source almost always needs `native` as well.** The templates
linuxcontainers.org and Proxmox distribute are `default` variant root filesystems and carry no
cloud-init — the cloud variants are not published in that form — so a machine on one that leaves the
backend unset is refused.

The column is what a preset can serve today, and it moves when an upstream does. `presets.yaml` and
the table above the preset section are the two places it is recorded; check them rather than
assuming a distribution that carries cloud-init everywhere else carries it here.

### Every input, inline or by reference

Each input takes one of exactly two forms, and they mix freely within one machine:

```yaml
cloudInit:
  user:
    value: maxim                    # not sensitive, inline is fine
  password:
    valueFrom:
      secretKeyRef:                 # sensitive, never in git
        name: machine-secrets
        key: root-password-hash
```

The shape is `EnvVarSource`'s, because everyone already knows it. `configMapKeyRef` is accepted
wherever `secretKeyRef` is: forcing a package list into a Secret is friction with no benefit.

Supplying both forms for one input, naming two sources under one `valueFrom`, or supplying an input
that belongs to a backend the machine did not select all fail while the manifest is still text.

The material is assembled by a projected volume into a single directory of fixed file names, mounted
into the provisioning step and **into no other container** — the guest a user execs into never sees
it.

> **Inline material is stored in the Helm release.** Helm keeps your values in a Secret that
> `helm get values` prints back, and they are usually committed as well. That is a property of Helm,
> not of this chart, and it is the reason the reference form exists.

The inputs are `userData`, `networkConfig` and `vendorData` — the raw files — and `user`,
`password`, `sshAuthorizedKeys`, `packages`, `runcmd` and `packageUpgrade`, which the chart composes
into user-data. `sshAuthorizedKeys`, `packages` and `runcmd` take one item per line, so that the
inline form and a Secret's bytes are the same shape. `values.yaml` documents each at the point of
use.

### Raw beats structured, per file

Supplying `userData` replaces the structured inputs for user-data entirely. They are not merged, and
the provisioning step's log says which ones were ignored. This is Proxmox's `cicustom` rule for the
same choice: a YAML merge of two cloud-configs is a misfeature waiting to happen, and per-file
replacement is the only rule anyone can predict. Shadowing is per file — raw `userData` does not
affect a `networkConfig` given separately.

### When provisioning is re-applied

The seed's `instance-id` is computed by the provisioning step at boot, as a hash of the files it
actually wrote plus the machine's namespace, release and name. cloud-init keys its per-instance
work on that identifier, so:

| What happened | What follows |
| --- | --- |
| The configuration changed | new identifier, so cloud-init re-applies on the next start |
| The machine restarted, unchanged | same identifier, so nothing re-runs |
| The volume was restored into the same machine | same identifier — it is the same machine |
| The volume was restored under another release or name | new identifier, so machine-id and host keys are regenerated |

It is computed at boot rather than while Helm renders because Helm cannot read a Secret it does not
own — and a `lookup` would break `helm template`, `--dry-run` and every GitOps diff.

Getting the restart to happen is a separate question from applying the change. Inline material is
rendered by Helm, so changing it changes a `checksum/provisioning` pod annotation and the machine
restarts. A referenced Secret that has rotated is invisible from here: use a controller that watches
it, `kubectl rollout restart`, or bump `machines.<name>.guest.provisioningRevision`.

### Where the material ends up

On the volume, and in its snapshots. cloud-init copies user-data there itself, into
`/var/lib/cloud/instances/<instance-id>/`, so hiding the seed would hide nothing — and this is how
every cloud VM already behaves. It is accepted rather than fought.

Put a **crypt(3) hash** in `password`, never a plaintext one: a hash on the volume is the same
exposure as `/etc/shadow`, which is unavoidable. Treat a machine's volume as holding credentials,
because it does, on every backend.

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

### Machines are provisioned by cloud-init unless they say otherwise

**Breaking**, and it is the kind of break that shows up as a machine that will not start rather than
as a machine that behaves differently.

Every machine now selects a provisioning backend, and one that declares none selects `cloud-init`.
On an image that cannot run cloud-init the pod fails, with a message naming
`guest.provisioning: native` as the fix. That is the settled design working as intended: the
alternative is a machine that installs cleanly, boots with no users and no keys, and gives nobody a
way in.

**What has to change, and where:**

| A machine on … | What to do |
| --- | --- |
| `debian-trixie`, `alpine-3.24` | nothing — cloud-init runs and provisions from an empty configuration |
| `ubuntu-noble` | set `guest.provisioning: native` — its upstream's cloud architectures are not yet on one build |
| `void-current` | set `guest.provisioning: native` — its upstream publishes no cloud variant |
| an `lxc` template source | set `guest.provisioning: native` — the published templates are `default` variants and carry no cloud-init |
| any other image without cloud-init | set `guest.provisioning: native` |

```yaml
machines:
  web:
    guest:
      provisioning: native
```

**A machine that already exists is not re-seeded**, and nothing on its volume is replaced. What
changes is that provisioning now runs on every start.

**On the two cloud presets, cloud-init will really run.** It was present and inert before, kept
that way by the `/etc/cloud/cloud-init.disabled` marker its upstream ships; the chart now removes
that marker, because a seed written while it is in place is read by nothing. A machine that supplies
no `cloudInit` inputs is provisioned from an empty cloud-config, which creates the distribution's
default user and generates SSH host keys, and is otherwise uneventful.

**After changing the backend on a machine that has already failed, delete its pod.** A StatefulSet
does not replace a pod that never became ready, so the new value would sit in the object while the
old pod went on failing.

### Two presets are now the upstream's cloud variant

**Breaking**, for what a preset resolves to and not for what a machine declares.
`source: {kind: preset, name: debian-trixie}` is unchanged, and so are the other three names.
`debian-trixie` and `alpine-3.24` are now built from their upstream's `cloud` variant, so they carry
cloud-init. `void-current` is unchanged because its upstream publishes no cloud variant, and
`ubuntu-noble` is unchanged because its upstream's cloud architectures are not yet on one build.

The package each moved preset resolves to moved with the variant:

| Was | Is now |
| --- | --- |
| `ghcr.io/kitsunoff/stateful-pods-debian` | `ghcr.io/kitsunoff/stateful-pods-debian-cloud` |
| `ghcr.io/kitsunoff/stateful-pods-alpine` | `ghcr.io/kitsunoff/stateful-pods-alpine-cloud` |
| `ghcr.io/kitsunoff/stateful-pods-ubuntu` | unchanged, for now |
| `ghcr.io/kitsunoff/stateful-pods-void` | unchanged |

**A machine that already exists is untouched**, for the same reason as below: seeding happens once
in the life of a volume.

**A machine created after the upgrade gets a different and larger root filesystem.** That is the
break, and it is a sharper one than a rename: the same values now seed a different operating system
image. Debian grows about a third; Alpine grows sixfold, because cloud-init brings a Python runtime
into a distribution whose appeal is not having one. Check `rootfs.size` before upgrading a values
file that was sized against an Alpine machine.

**What the variant is for** is above, under *Machines are provisioned by cloud-init unless they say
otherwise*. The upstream ships these images with an `/etc/cloud/cloud-init.disabled` marker and a
preset carries it unmodified, so cloud-init is inert until something removes the marker and writes a
seed — which is exactly what the provisioning step does. A machine from one of these two presets is
the only kind that can run the default backend.

The two packages under the old names are not deleted. Chart `0.2.0` resolves to digests inside
them, and they hold nothing else. `stateful-pods-ubuntu` is not orphaned at all — `ubuntu-noble`
still publishes into it, and the daily bump still moves it.

### A preset resolves into a package named for its distribution

**Breaking**, for where a preset is pulled from and not for what a machine declares.
`source: {kind: preset, name: debian-trixie}` is unchanged, and so are the other three names. What
changed is the package each one resolves to:

| Was | Is now |
| --- | --- |
| `ghcr.io/kitsunoff/stateful-pods-debian-trixie` | `ghcr.io/kitsunoff/stateful-pods-debian` |
| `ghcr.io/kitsunoff/stateful-pods-ubuntu-noble` | `ghcr.io/kitsunoff/stateful-pods-ubuntu` |
| `ghcr.io/kitsunoff/stateful-pods-alpine-3.24` | `ghcr.io/kitsunoff/stateful-pods-alpine` |
| `ghcr.io/kitsunoff/stateful-pods-void-current` | `ghcr.io/kitsunoff/stateful-pods-void` |

**A machine that already exists is untouched.** Seeding happens once in the life of a volume, so an
upgrade re-resolves nothing and pulls nothing: a running machine keeps the operating system it was
seeded with.

**A machine created after the upgrade is pulled from the new repository.** That is the break. If
this cluster reaches the registry through a mirror, an allowlist, or a `pullSecretName` scoped to a
repository rather than to a registry, the four new names have to be added there before a `preset`
machine will seed. A machine seeding from an `oci` or `lxc` source is unaffected.

**Each package also publishes a rolling tag** — `stateful-pods-debian:trixie`, and so on — that
follows the newest build. It is a name for a person who wants to pull one by hand. The chart still
resolves every preset to a digest, so what a machine is seeded from does not move.

The packages under the old names are being retired. Chart `0.1.1` and earlier resolve to digests
inside them, so a `--preset` install of one of those chart versions stops working once they go.

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
below are files under `tests/` **in the source repository**. They are not in the packaged chart —
`.helmignore` keeps them out of it, because an installed chart cannot run them and carries no
helm-unittest to try.

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
| The contents are the upstream's | `hack/preset-build.sh` compares the published layer's `diff_id` against the checksum of the decompressed verified archive |
| A preset carries no configuration of ours | `crane mutate` sets a platform and labels and nothing else |
| An unsigned or wrongly signed checksum list stops the build | `test/presets/verification.bats` |
| A checksum mismatch stops the build | `test/presets/verification.bats` |
| What was verified is recorded | the `io.stateful-pods.preset.upstream.*` labels |
| One reference serves both architectures | `hack/preset-build.sh`, asserted in `preset-publish.yaml` |
| A preset with an incomplete upstream is not published | `test/presets/verification.bats` |
| One repository holds a distribution | `test/presets/verification.bats`, which resolves a preset and checks the repository it names |
| The tag names the release | `hack/preset-build.sh` composes every tag from the release |
| A repository serves every release of its distribution | `test/presets/retention.bats`, which plans a package holding two releases; the package is a field in `images/presets/presets.list` rather than a rule about the preset's name, asserted in `test/presets/verification.bats` |
| A published dated tag keeps its content | the preset stage of `hack/integration-test.sh`, which builds twice and compares |
| A build is counted by its dated tag | `test/presets/retention.bats`: a rolling tag is not a build, and an unreadable tag stops the run |
| The rolling tag follows the newest build | `preset-publish.yaml` compares it against the digest just published |
| The rolling tag covers every architecture | `preset-publish.yaml` resolves it for each one |
| No machine is seeded from a rolling tag | `hack/check-presets.sh` fails the build if a catalog entry is not a digest |
| A named preset renders as a pinned reference | `values_preset_source_test.yaml` |
| The table is part of the chart | `hack/check-presets.sh`, which packages the chart and renders a preset from the package |
| The five newest builds of a preset remain | `test/presets/retention.bats` |
| Retention is per preset | `hack/preset-retention.sh` plans one release at a time, over a package its releases share |
| A kept build stays whole | `test/presets/retention.bats`, and asserted after every run |
| The rolling tag survives | `test/presets/retention.bats`, and resolved after every run that deletes |
| A newer upstream build is proposed | `preset-bump.yaml`, `test/presets/bump.bats` |
| An unchanged upstream proposes nothing | `test/presets/bump.bats` |
| A proposal names a reference that already exists | `preset-bump.yaml` publishes before it proposes |

### distro-presets (added and modified by cloud-init-presets)

| Scenario | Covered by |
| --- | --- |
| A preset built from a cloud variant carries cloud-init | the preset stage of `hack/integration-test.sh`, asserted inside the booted machine |
| A distribution with no cloud variant keeps the default one | `images/presets/presets.list` keeps `void-current` on `default`; the same stage asserts the Void machine carries no cloud-init |
| The variant is looked up, not assumed | `test/presets/verification.bats`: an index offering only the default build is refused as an upstream that is not ready |
| The disable marker is published as the upstream wrote it | the preset stage of `hack/integration-test.sh` |
| A machine boots unaffected while the marker is in place | the same stage: the machine reaches readiness and no cloud-init stage has run |
| One repository holds a distribution | `test/presets/verification.bats`, which resolves a preset and checks the repository it names, variant included |
| Two variants of one release do not collide | the variant is part of the package in `images/presets/presets.list`, and `test/presets/catalog.bats` refuses a catalog entry naming the variantless package |

### values-validation (added by distro-presets)

| Scenario | Covered by |
| --- | --- |
| A missing preset name is rejected | `values_preset_source_test.yaml` |
| An unknown preset name is rejected with the alternatives | `values_preset_source_test.yaml` |
| A preset name is never substituted | `values_preset_source_test.yaml` |
| A field belonging to another kind is rejected | `values_preset_source_test.yaml` |

### guest-provisioning (added by guest-provisioning)

| Scenario | Covered by |
| --- | --- |
| A machine that declares nothing is provisioned by cloud-init | `provisioning_volume_test.yaml` |
| A machine can ask for no guest cooperation | `provisioning_volume_test.yaml`, `provision.bats` |
| An unrecognised backend is refused | `values_provisioning_test.yaml` |
| A machine on an image with no cloud-init does not boot silently | `provision.bats`, `hack/integration-test.sh` |
| The check never switches backend on the machine's behalf | `provision.bats` |
| The message describes a fix that actually works | `provision.bats`, and `hack/integration-test.sh` follows the instruction rather than working around it |
| A failed check leaves nothing behind | `provision.bats`, `hack/integration-test.sh` |
| An image that ships the backend disabled is not treated as able to run it | `provision.bats`, `hack/integration-test.sh` |
| An input given inline reaches the machine | `provisioning_volume_test.yaml`, `hack/integration-test.sh` |
| An input given by reference reaches the machine | `provisioning_volume_test.yaml` |
| The two forms mix within one machine | `provisioning_volume_test.yaml` |
| The guest cannot read the material through the pod | `provisioning_volume_test.yaml` |
| A machine reads the configuration it was given | `hack/integration-test.sh`, which logs in over SSH as the provisioned user |
| Provisioning does not take the machine's address away | `provision.bats`, `hack/integration-test.sh` |
| Provisioning does not fight the files the chart maintains | `provision.bats`, `hack/integration-test.sh` |
| Which datasource a machine uses does not depend on its surroundings | `provision.bats` asserts the drop-in pins it; `hack/integration-test.sh` asserts the machine used it |
| The machine is provisioned whatever init system it runs | `provision.bats` for OpenRC and systemd; the Alpine preset stage of `hack/integration-test.sh` for a booted OpenRC machine |
| Changing the configuration re-applies it | `provision.bats` |
| Restarting with no change re-applies nothing | `provision.bats` |
| A clone into another release is a different instance | `provision.bats` |
| The identity does not depend on where the material came from | `provision.bats` |
| Raw user-data wins over the structured shortcuts | `provision.bats` |
| Shadowing is reported | `provision.bats`, `notes_test.yaml` |
| Shadowing is per file | `provision.bats` |
| A machine started again is provisioned again | `provision.bats`, `hack/integration-test.sh` |
| Provisioning does not re-seed the root filesystem | `hack/integration-test.sh` |

### values-validation (added by guest-provisioning)

| Scenario | Covered by |
| --- | --- |
| An input given both ways is refused | `values_provisioning_test.yaml` |
| A reference naming two sources is refused | `values_provisioning_test.yaml` |
| An incomplete reference is refused | `values_provisioning_test.yaml` |
| An input for an unselected backend is refused | `values_provisioning_test.yaml` |
| An unknown provisioning input is refused | `values_provisioning_test.yaml` |
| A designed but unimplemented backend says so | `values_provisioning_test.yaml` |

### machine-topology (added by guest-provisioning)

| Scenario | Covered by |
| --- | --- |
| The step that provisions reads fixed paths | `provisioning_volume_test.yaml`, `provision.bats` |
| The material is mounted nowhere else | `provisioning_volume_test.yaml`, `init_scripts_test.yaml` |
| A machine supplying nothing gets no volume | `provisioning_volume_test.yaml` |
| Changed inline material takes effect | `provisioning_volume_test.yaml`, which pins the digest rather than only requiring one |
| A referenced rotation can be applied deliberately | `provisioning_volume_test.yaml` |

### distro-presets (added by guest-provisioning)

| Scenario | Covered by |
| --- | --- |
| A preset that cannot serve the default backend is marked | the preset table above, the same table in the project README, and `values.yaml` beside the preset input |
| What a preset can serve is stated per preset | the same three places, a row per preset |
