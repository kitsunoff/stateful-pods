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
make lint        # helm lint --strict, against every example
make shell-lint  # shellcheck over every shell script
make docs        # the guarantees values.yaml makes about itself
make test        # helm unittest
make shell-test  # bats, inside a Linux container
make conform     # kubeconform against the Kubernetes API schemas
make image-test  # the toolbox image's archive guarantees
make render      # helm template
```

`make shell-test` and `make image-test` need a container engine: the scripts manipulate another
system's root filesystem, and ownership, extended attributes and file capabilities only exist on
Linux.

`make integration-test` seeds a machine end to end on a throwaway `kind` cluster. It is the only
test that can tell whether a copy really preserved a file capability, or whether a second start
really does nothing. Its template case needs a tarball served over HTTPS, because that is what the
chart accepts:

```bash
TEMPLATE_URL=https://.../rootfs.tar.xz \
TEMPLATE_SHA256=<the digest from the publisher's SHA256SUMS> \
  make integration-test
```

Without those two the template case is skipped rather than silently passed. In CI they come from
the `INTEGRATION_TEMPLATE_URL` and `INTEGRATION_TEMPLATE_SHA256` repository variables; distributors
publish under dated paths, so those values need refreshing when a build is retired upstream.

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

| | `oci` | `lxc` |
| --- | --- | --- |
| Filled by | a step running the source image itself | a step running the chart's own image |
| The source must provide | a shell and GNU `tar` with extended-attribute support | nothing; it is a tarball |
| Integrity | the container runtime, via the image's digest | the mandatory `sha256`, checked before anything is unpacked |
| Formats | any image | `.tar.zst`, `.tar.xz`, `.tar.gz` |

**An Alpine or other busybox-based image cannot be an `oci` source.** Its `tar` has no
extended-attribute support, so the copy would silently drop `security.capability` and an
unprivileged `ping` inside the machine would fail forever after with nothing in the logs to explain
it. The chart probes for this and refuses to seed rather than seeding badly; use a `lxc` source for
those distributions. An image with no shell at all — distroless, scratch — cannot be a source
either, and has no init system to be a machine with.

**An `oci` source must stay pullable for the life of the machine.** The seeding step runs on every
pod start, even once it has nothing left to do, so a machine whose upstream tag was deleted will not
start on a node that has not cached the image. Pin the source by digest.

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

### Prerequisites the chart cannot check

The `userns` mode is verified at render time against the cluster's Kubernetes version, and that is
the only part of it the chart can see. These it cannot, and a machine that renders may still fail to
boot on them:

- the node's kernel, which must support user namespaces for pods;
- the container runtime's configuration;
- whether the storage backend supports idmapped mounts — NFS does not.

When one of them is missing the boot fails on a mount, naming the path and the filesystem type. The
`privileged` mode has none of these prerequisites and works on any cluster, at the cost of almost all
isolation from the node.

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
| File capabilities survive the copy | `seed-oci-copy.bats`, `hack/integration-test.sh` |
| The image cannot copy itself faithfully | `seed-oci-probe.bats` |
| A matching checksum is unpacked | `seed-lxc.bats` |
| A mismatched checksum is refused | `seed-lxc.bats` |
| An unreachable template is a failure, not an empty machine | `seed-lxc.bats` |
| An archive that is not a root filesystem is rejected | `seed-lxc.bats` |
| A multi-part archive is rejected | `seed-lxc.bats` |
| Device nodes are not copied | `seed-oci-copy.bats`, `hack/integration-test.sh` |
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
| The most common template format can be opened | `hack/image-test.sh`, `seed-lxc.bats` |
| Attributes survive unpacking | `hack/image-test.sh`, `seed-lxc.bats` |
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
| An OCI source is a container image only where it is copied | `shim_image_test.yaml`, `init_containers_test.yaml` |
| The guest container alone is privileged | `init_security_test.yaml` |
| The guest container alone is granted the mode's capability | `init_security_test.yaml` |
| Preparation steps are ordinary containers | `init_security_test.yaml` |
