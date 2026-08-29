## Why

The research in `docs/research/` has settled the architecture for stateful pods, but no chart
exists yet. Before any of the interesting work — the shim, rootfs seeding, cloud-init provisioning
— there has to be a chart that turns values into Kubernetes objects, and the shape of those values
and those object names has to be right on the first commit.

The names in particular cannot be changed later. A machine's rootfs lives in a PVC bound to a
StatefulSet; renaming that StatefulSet orphans the PVC and recreates the machine empty. That is the
one migration this project can never offer its users, so the naming scheme has to accommodate the
planned fleet form (several machines per release, each its own StatefulSet) from the start, even
while only one machine per release is supported.

## What Changes

- New Helm chart `stateful-pods` — `Chart.yaml`, `values.yaml`, `_helpers.tpl`, `NOTES.txt`.
- A **`machines` map keyed by machine name** as the top-level workload input, rather than flat
  single-machine values. Exactly one entry is accepted for now; more than one fails rendering with
  a message saying the fleet form is not implemented yet.
- Every rendered object is named `<release>-<machine>`, so adding a second machine later renames
  nothing that already exists.
- Rendering of the per-machine objects: a `StatefulSet` (one replica, `OnDelete`-style pet
  semantics), a rootfs `PersistentVolumeClaim` via `volumeClaimTemplates`, and a headless
  `Service`.
- A **rootfs source** input that accepts two kinds: an **OCI image** and a conventional **LXC
  rootfs template** — the compressed tarballs distributed by Proxmox's `pveam` and by
  linuxcontainers.org. Both are seeds for the persistent root filesystem, and which one a machine
  uses is a per-machine choice. This mirrors Proxmox itself, which accepts both.
- A **shim image** as the guest container's image, distinct from the machine's rootfs source. The
  machine's operating system lives in the PVC, not in the container image, so the two are never the
  same reference.
- A **mandatory per-machine `security.mode`** input (`userns` / `privileged`) that selects the
  pod-level security posture. Unset fails rendering with a message explaining the ladder; there is
  no default and no autodetection.
- Values validation with explicit, actionable failure messages for every rejected input.
- Test scaffolding: `helm unittest` suites and a `helm lint` / `helm template` check that CI can
  run without a cluster.

Non-goals, each deliberately left to a later change:

- The shim image and its bash scripts — the guest container's command is a placeholder here.
- Rootfs seeding from an image, and the provisioning init containers.
- cloud-init, systemd credentials, guest customization, lifecycle hooks and probes.
- **Installing this chart does not yet produce a booting machine.** It produces correct objects.

## Capabilities

### New Capabilities

- `machine-topology`: how a release maps to machines and Kubernetes objects — the `machines` map,
  the `<release>-<machine>` naming scheme, which objects exist per machine, their pet-oriented
  update and storage semantics, and the temporary single-machine restriction.
- `values-validation`: the input contract the chart enforces at render time — which inputs are
  mandatory, which combinations are rejected, and what each failure message must tell the user.
- `pod-security-posture`: what each security mode actually renders onto the pod, and the guarantee
  that a mode never grants more than it names.

### Modified Capabilities

None. This is the first change in the repository; `openspec/specs/` is empty.

## Impact

- **New files**: the chart tree under `charts/stateful-pods/`, plus its test suites.
- **New tooling dependencies**: `helm` (3.x) and the `helm-unittest` plugin for template tests;
  both run without a cluster, which keeps CI cheap.
- **No existing code affected** — the repository currently contains only `docs/` and `openspec/`.
- **Downstream changes constrained**: every later change edits this chart rather than creating its
  own. The helper signatures introduced here (each taking the machine as an explicit argument
  rather than reading `.Values` globals) are what make the planned fleet form a small change rather
  than a rewrite.
- **Research documents** `docs/research/05-open-questions.md` §0-§3 record the decisions this
  change implements; they are the source of truth for the rationale and are not restated here.
