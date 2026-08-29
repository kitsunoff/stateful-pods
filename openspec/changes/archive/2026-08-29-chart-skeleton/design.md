## Context

See `proposal.md` — Why. The architectural decisions this change implements were settled in
`docs/research/`, in particular `05-open-questions.md` §0–§3 (the settled-decisions table),
§1.1 (fleet-shaped values) and §4 (no init-system input).

The constraint that shapes everything here is that object names are permanent. A machine's rootfs
is a PersistentVolumeClaim created from a StatefulSet's volume claim template; the claim's name is
derived from the StatefulSet's name, so renaming the StatefulSet orphans the volume and silently
recreates the machine empty. Every naming and structural decision below is made to avoid ever
having to rename.

The repository is empty of code, so there is no existing chart layout or convention to follow.

## Goals / Non-Goals

**Goals:**

- Establish the values shape, the naming scheme and the helper-calling convention that every later
  change builds on, such that adding the planned fleet form is a deletion rather than a rewrite.
- Make every invalid input fail at `helm template` time with a message that names the path and the
  fix.
- Be fully testable without a cluster, so CI stays cheap from the first commit.

**Non-Goals:**

- Booting a machine. The guest container is a placeholder in this change.
- Any `values.schema.json`. See Decisions.
- Deciding the remaining open questions in `docs/research/05-open-questions.md` (§6, §8, §9, §11,
  §12) — none of them affect the objects rendered here.

## Decisions

### Validation with `fail` helpers, not `values.schema.json`

`values-validation` requires every rejection to name the offending path *and* tell the user what to
do about it — for `security.mode`, that includes summarising what each mode requires of the
cluster. JSON Schema cannot produce that text; it would emit a terse enum violation and pre-empt
the useful message, because Helm validates the schema before templates run.

So: all validation lives in `_helpers.tpl`, invoked from a single entry point that every template
calls first, so the same errors appear regardless of which file renders first.

The checks **accumulate into a list and fail once with all of them**, rather than aborting on the
first. Fixing one misconfigured value only to discover the next one on the following run is a poor
experience, and the accumulation costs a few lines.

*Alternative considered:* a schema for types and shape plus `fail` for semantics. Rejected for this
change because two mechanisms means two places to look when a message is wrong, and the type errors
a schema catches are also catchable with `kindIs`. Worth revisiting once the values surface is
larger.

### Every template ranges over `machines` from day one

The single-machine restriction is enforced by exactly one `fail` on the map's length. Every
template already iterates the map and renders a full set of objects per entry.

This is the whole point of §1.1: if the templates were written for one machine and the `range` were
added later, lifting the restriction would be a rewrite touching every file, and it would be
tempting to change names along the way. Written this way, lifting it is deleting one guard.

### Helpers take an explicit machine context

Every helper takes a dict — `(dict "root" $ "name" $name "machine" $machine)` — rather than
reading `.Values` globals. No helper resolves "the machine" implicitly.

This is what actually makes the fleet form cheap. A helper that reaches for `.Values.machines` and
picks the only entry is correct today and wrong the moment there are two, and that class of bug is
invisible until then.

### StatefulSet, chosen for its termination ordering as much as for storage

`machine-topology` requires that an update never runs two instances of a machine at once, because
both would mount the same root filesystem.

A StatefulSet gives this for free: at one replica, a rolling update deletes the pod and waits for
it to fully terminate before creating its replacement. A Deployment with `Recreate` would also
work, but a Deployment cannot express volume claim templates, so the rootfs claim would have to be
a separate object with its own lifecycle and its own deletion hazard.

`updateStrategy` is left at `RollingUpdate`. `OnDelete` is arguably better suited to a pet — a
values change would not reboot the machine until the user chose — but a chart where `helm upgrade`
silently does nothing is a worse surprise than an expected restart. Worth revisiting as an opt-in.

### Volume retention is set explicitly, not inherited

`persistentVolumeClaimRetentionPolicy` is set to `Retain` for both `whenDeleted` and `whenScaled`,
even though `Retain` is already the default (the field is stable since Kubernetes 1.32).

Helm would not delete these claims in any case, because the StatefulSet controller creates them and
Helm never tracked them. The explicit policy defends against the other path — deleting the
StatefulSet itself — and, more importantly, states the intent in the manifest where a reader will
see it. Data retention should not depend on a default remaining a default.

### The guest container is an obvious placeholder

The pod template renders the machine's declared image with a placeholder command, and `NOTES.txt`
states plainly that the machine does not boot yet.

The alternative — running the image's own entrypoint so the release "works" — was rejected because
it would produce an ordinary stateless container that looks like a working machine and is not one.
A test asserts the placeholder is present, so the change that implements the shim has to remove it
deliberately rather than by accident.

### The concrete values shape

Written out here so that no part of it has to be inferred:

```yaml
# Image of the shim that mounts the rootfs and starts the guest's init.
# Not the machine's operating system — that lives in the PVC.
shim:
  image: ghcr.io/kitsunoff/stateful-pods-shim:<version>

machines:
  web:
    # Where the root filesystem is seeded from, once. Mandatory, no default.
    # Exactly one kind, named explicitly.
    source:
      kind: oci                                   # oci | lxc
      # kind: oci
      reference: docker.io/library/debian:13
      # kind: lxc
      # url: https://.../debian-13-standard_13.0-1_amd64.tar.zst
      # sha256: "<64 hex chars>"                  # mandatory for lxc

    # Guest hostname. Unset means the pod's own hostname is used, which is
    # what the kubelet already puts in /etc/hostname. Set to override.
    hostname: null

    security:
      # userns | privileged. Mandatory, no default, per machine.
      mode: userns

    rootfs:
      size: 8Gi
      # Optional: create the rootfs from an existing VolumeSnapshot instead of
      # seeding it from the source. Restoring into the same release keeps the
      # machine's identity; restoring into a new one regenerates it.
      dataSource:
        volumeSnapshotName: null
      # Unset (null) omits the field entirely, so the cluster's default
      # StorageClass applies. An explicit "" means "no class" and disables
      # dynamic provisioning — these are different things and the template
      # must preserve the difference.
      storageClassName: null
```

`machines` defaults to **empty**, and the block above lives in `values.yaml` as a commented
example. Installing with no values therefore fails on the "no machines declared" check rather than
silently creating a machine called `web`.

`rootfs.mode`, `guest.provisioning`, `resources`, and the usual scheduling inputs
(`nodeSelector`, `tolerations`, `affinity`) are **deliberately absent** from `values.yaml` in this
change. All of them are purely additive — adding any later renames nothing and invalidates no
existing values file — so declaring them now, unimplemented, would only mean either accepting a
value that does nothing or failing on a value the documentation advertises. An implementing agent
should not add them ad hoc.

The rootfs volume is mounted at **`/mnt/rootfs`** in the guest container. This path is fixed and
every later change refers to it.

### Two rootfs source kinds, with an explicit discriminator

Proxmox accepts both a conventional LXC template tarball (`pveam`, `vztmpl`) and — since PVE 9 — an
OCI image. Supporting both is therefore parity, not scope creep, and the template path is the
*older* and more familiar one for the audience.

The two are genuinely different, which is why the values carry an explicit `kind` rather than
inferring it from which fields are present:

| | `oci` | `lxc` |
| --- | --- | --- |
| Identifier | image reference | HTTPS URL |
| Integrity | digest, verified by the runtime | **explicit `sha256`, verified by us** |
| Credentials | image pull secrets, node credentials, ServiceAccount | none today |
| Retrieval | `image` volume source, or the init container's own rootfs | fetched by the init container |
| Tooling needed in the shim | `tar` | `tar`, plus `zstd`, `xz` and `gzip` |

Presence-based discrimination (`reference:` implies OCI, `url:` implies LXC) was considered and
rejected: a typo in a field name would silently change the machine's source kind, and the resulting
error message would be about the wrong thing. An explicit kind lets validation say "field `url` does
not belong to kind `oci`", which is what the user needs to read.

The checksum is mandatory for `lxc` and there is no opt-out. An OCI reference pinned by digest is
verified by the container runtime; a template is a tarball pulled over the network and unpacked into
what becomes a privileged machine's root filesystem. Proxmox verifies templates against a signed
index; we have no index, so the user supplies the hash. Making this optional would ship a one-line
path to booting an attacker's root filesystem.

Two consequences fall out for later changes and are recorded here so they are not rediscovered:

- The shim image needs `zstd`, `xz` and `gzip` alongside GNU `tar`. busybox provides gzip, bzip2,
  xz and lzma decompression but **no zstd whatsoever**, and Proxmox ships its templates as
  `.tar.zst` — so a busybox-only shim cannot open the most common template. busybox `tar` also has
  no extended-attribute support, which silently drops `security.capability`. Both are verified
  against the busybox source in `docs/research/05-open-questions.md` §10a.
- The seeding change should copy Proxmox's `check_tar_archive()` sanity checks — reject an archive
  with no `sbin` entry, with fewer than ten members, or containing a multi-volume member — because
  it is extracting an archive it did not build.

### The guest container runs the shim, not the machine

An earlier draft of this change rendered the machine's declared image as the guest container's
image. That was wrong, and adding LXC support is what made it obvious: a template source is a
tarball, so there is no image to run at all.

In the Copy architecture the container's own root filesystem is the shim; the machine's operating
system is in the PVC and is reached by `pivot_root`. The rootfs source is consumed once, by the
seeding init container, and is never a container image. Keeping them as one field would also have
made an OCI-sourced machine look like an ordinary stateless container, which is precisely the
confusion this project needs to avoid.

`shim.image` is a chart-level value with a default. Until the shim exists it points at a
placeholder, and a test asserts the placeholder so that the change implementing the shim has to
replace it deliberately.

### Security modes: exactly what each renders

`pod-security-posture` states the guarantees; this is the mapping the implementation uses.

| | `userns` | `privileged` |
| --- | --- | --- |
| `pod.spec.hostUsers` | `false` | not set |
| guest container `privileged` | not set | `true` |
| guest container `capabilities.add` | `["SYS_ADMIN"]` | not set |
| `allowPrivilegeEscalation` | not set to true | — |
| `runtimeClassName` | not set | not set |

`SYS_ADMIN` is what the shim will need for `mount(2)` and `pivot_root(2)`; inside the pod's own
user namespace it is void on the host. `CAP_SYS_CHROOT` and `CAP_MKNOD` are already in the
runtime's default set and are not requested.

A third mode using an administrator-installed runtime (sysbox) was excluded from this version.
Sysbox CE is open source, so this is not a licensing decision — it is that the project cannot
exercise the mode today, and its details (interaction with `hostUsers`, CRI-O annotations) are
exactly the kind that fail quietly when guessed. Adding it later is additive: a new accepted value
and a new branch, no change to anything that exists.

### Version checking: reject an impossible choice, never substitute one

The chart verifies the one prerequisite it can actually see — the cluster's Kubernetes version
against the requirement of the chosen mode — and fails when it is not met. It does not use that
information to pick a mode.

This looks like the autodetection the design rejected, and is not. Rejecting a choice the cluster
cannot honour turns a mysterious pod failure into a render error. Substituting a different mode
would change the machine's security posture without the user's consent. Only the first is done.

Prerequisites the chart cannot see — the node's kernel version, whether the storage backend
supports idmapped mounts — are documented, not guessed. `Chart.yaml`'s `kubeVersion` floor is
`>= 1.27.0-0`, driven by `persistentVolumeClaimRetentionPolicy` being honoured from 1.27; the
higher requirement of `userns` mode is enforced by the per-mode check, not by the chart-wide floor,
so a `privileged`-mode machine still installs on an older cluster.

### Labels: version labels on the object, never in the selector

A StatefulSet's `spec.selector` is immutable after creation. Putting `app.kubernetes.io/version` or
the chart version in it makes the first `helm upgrade` fail with `field is immutable`, recoverable
only by deleting and recreating the StatefulSet — that is, by destroying the machine.

So there are two helpers, and they are not interchangeable:

- **selector labels** — the machine's identity only: `app.kubernetes.io/name`,
  `app.kubernetes.io/instance`, and the machine name label. Never anything else.
- **object labels** — the selector labels plus `app.kubernetes.io/version`,
  `app.kubernetes.io/managed-by` and `helm.sh/chart`.

The pod template's labels must be a superset of the selector, and the selector must be a subset
that never changes. A test asserts the selector is byte-identical across two renders with different
chart and image versions, because a review will not catch this and the failure arrives only at the
first upgrade of a real machine.

### Values are documented against Proxmox expectations

`values.yaml` carries a comment for every input, and explicitly names the Proxmox options that have
no equivalent here — per-guest network and DNS configuration — with the reason. The audience arrives
with `ipconfig0` and `nameserver` in mind; silence about them reads as an omission rather than a
decision.

## Risks / Trade-offs

- **The fleet-shaped values are more verbose for the single-machine case.** → Accepted: a one-time
  readability cost against a migration that would destroy user data. `NOTES.txt` and the README
  show a complete minimal example so the shape is obvious by copying.
- **A mandatory `security.mode` means the chart cannot be installed with defaults.** → Accepted and
  intentional; the failure message doubles as the documentation of the three modes. Mitigated by
  keeping it the *only* mandatory choice — `rootfs.mode` and `guest.provisioning` both default.
- **Accumulated validation errors could become noisy** if a single root cause produces several
  messages. → Mitigated by ordering checks so structural problems short-circuit the semantic ones
  that depend on them.
- **`helm unittest` is an extra plugin dependency for contributors and CI.** → Accepted; it is the
  standard tool for this job and needs no cluster. Documented as a prerequisite.
- **This change ships a chart that cannot boot a machine.** → Accepted for one change; the risk is
  that someone installs it and is confused, mitigated by `NOTES.txt` saying so unambiguously.

## Migration Plan

Not applicable: this is the first change and there is no deployed state, no prior chart version and
nothing to roll back to. Rolling back is deleting the release.

Later changes inherit a constraint from here rather than a migration: the object naming scheme
introduced by this change is frozen, and no subsequent change may alter it.

## Open Questions

- Whether the machine name should default to being the guest's hostname
  (`docs/research/05-open-questions.md` §1). It does not affect any object rendered by this change,
  and can be answered when guest customization is implemented.
- Whether `updateStrategy: OnDelete` should be offered as an opt-in for users who want reboots to
  be deliberate. Additive, and safe to defer.
