# stateful-pods

A Helm chart that runs a *machine* — a pet with a persistent root filesystem — inside a Kubernetes
pod. Each machine gets its own StatefulSet, its own rootfs PersistentVolume and its own headless
Service.

> **This version does not boot a machine.** It renders correct objects and nothing more. The guest
> container runs a placeholder command; the shim, rootfs seeding and guest provisioning arrive in
> later changes.

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
make lint    # helm lint --strict
make test    # helm unittest
make render  # helm template
```

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
