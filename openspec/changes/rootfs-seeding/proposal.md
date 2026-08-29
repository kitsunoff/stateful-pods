## Why

The chart renders a machine's objects, but the volume it mounts is empty and the guest container
runs a placeholder that sleeps. Nothing turns a declared `source` into an operating system on the
volume, so every later change — the boot shim, guest customization, cloud-init — has nothing to
work on.

Seeding is also where this project's Proxmox-faithful semantics are actually decided. The source is
consumed exactly once, when the volume is first filled, and from that moment the volume is the
source of truth. Getting "once" wrong is the worst failure available here: seeding twice destroys a
user's machine, never seeding leaves them with an empty disk and no explanation.

## What Changes

- A **seeding init container** on every machine's pod. It fills the rootfs volume from the machine's
  `source` the first time it runs, and is a no-op on every start after that.
- A **marker file** on the volume that records what it was seeded from — the resolved source, the
  time, the chart version, the machine it was seeded for, and a schema version. The marker, not the
  chart, is what makes seeding happen once.
- **Two seeding paths, one per source kind.** For `oci`, the init container *is* the seed image and
  copies its own root filesystem into the volume. For `lxc`, the tarball is fetched over HTTPS,
  verified against the mandatory checksum, sanity-checked, and extracted.
- **BREAKING (spec-level):** an `oci`-sourced machine's pod now carries an init container whose
  image *is* the machine's source. `machine-topology` currently states that a rootfs source is never
  used as any container's image; that guarantee narrows to the guest container, which is where it
  was actually needed.
- A **toolbox image built and published from this repository** — busybox for the shell plus GNU
  `tar`, `xz`, `zstd` and `bash` — replacing the placeholder `shim.image` default. Built for amd64
  and arm64 and referenced by digest, because a machine that cannot be re-created byte-for-byte is
  not a pet.
- **Identity is not inherited.** `/etc/machine-id` is cleared after seeding, and the marker records
  the machine the volume was seeded for, so that a volume restored under a different name is
  recognised as a clone and has its identity regenerated instead of silently sharing one.
- **Every failure is loud.** A seed image with no capable archiver, a checksum mismatch, an archive
  that fails the sanity checks, a volume that cannot hold the source — each stops the pod with a
  message naming the cause, rather than producing a subtly broken root filesystem.

Non-goals, each deliberately left to a later change:

- **Booting.** The mounts, the device-node binds, `pivot_root` and `exec /sbin/init` are the next
  change. **Installing this chart still does not produce a running machine** — it produces a machine
  whose disk is correct.
- Guest customization: `/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`, the `.pve-ignore.<name>`
  markers, and the network-management units that need masking.
- cloud-init, systemd credentials, SSH host keys, root password and `authorized_keys`.
- Any re-seeding policy. `Never` is the only behaviour and there is no input for it; the marker
  records enough for a later change to add one.
- `rootfs.mode` and the overlay architecture.
- An `imagePullSecrets` input. A private `oci` source already works through pull secrets attached to
  the pod's ServiceAccount or through node credentials, so a chart input would only duplicate them.

## Capabilities

### New Capabilities

- `rootfs-seeding`: how a machine's root filesystem is filled from its source — that it happens
  exactly once, what makes it once, what each source kind requires, what must never be copied, and
  which failures must stop the pod rather than degrade the result.
- `machine-identity`: the identity a machine must not inherit — from the image it was seeded from,
  or from the machine a snapshot was taken of.
- `shim-image`: the contract of the image the chart runs its own containers from — that there is one
  of them, what it must be able to decompress, that it is pinned rather than tracked, and the
  boundary it must never cross into the guest.

### Modified Capabilities

- `machine-topology`: the requirement forbidding a rootfs source as any container's image narrows to
  the guest container, so that the OCI seeding path is permitted and bounded.
- `pod-security-posture`: the privilege a mode names is granted to the guest container only; the
  chart's own init containers receive nothing beyond a container's defaults.

## Impact

- **New files**: the toolbox image (`Containerfile`, its scripts, their `bats`/`shellcheck` tests),
  the seeding templates in `charts/stateful-pods/`, and the unit tests for both.
- **New tooling dependencies**: a container build (multi-arch), `shellcheck`, and a shell test
  runner. All run without a cluster except the image build itself.
- **Existing tests that must change deliberately**: `shim_image_test.yaml` asserts that no init
  container exists and that `shim.image` is a placeholder. Both assertions were written to force
  this change to remove them consciously, and both now do.
- **A machine's source image must stay pullable.** Because the seeding init container runs on every
  pod start — even to do nothing — an `oci` source that has been deleted upstream stops a machine
  from starting on a node that has not cached it. This is a consequence of the seeding mechanism
  the research settled on, and it is documented rather than worked around.
- **The research is the rationale**: `docs/research/03-mapping-and-architecture.md` §2 and §3.1
  (the lifecycle and the copy architecture), `05-open-questions.md` §6 (the OCI retrieval mechanism)
  and §10a (the image), and `02-kubernetes-primitives.md` §3.1 and §3.4 (the archive flags and the
  template path). They are not restated here.
