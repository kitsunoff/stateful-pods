## Context

See `proposal.md` — Why. The decisions this change implements were settled in `docs/research/`:
`03-mapping-and-architecture.md` §2 (the two-phase lifecycle and the marker) and §3.1 (the copy
architecture and the tar flags), `05-open-questions.md` §6 (OCI is copied from the init container's
own rootfs, not from an `image:` volume) and §10a (one image, busybox plus GNU tools, bash scripts),
and `02-kubernetes-primitives.md` §3.1 and §3.4 (the archive flags and the template path).

What the chart already fixes and this change must not move: the rootfs volume is mounted at
`/mnt/rootfs`, every object for a machine is named `<release>-<machine>`, the guest container's image
is `shim.image`, and a machine declares exactly one `source` with an explicit `kind`.

Two constraints do most of the shaping here.

**Kubernetes has no conditional init container.** Every init container in a pod runs on every start,
in order. "Seed once" therefore cannot be expressed in the pod spec at all — it has to be a decision
the container makes at runtime, from state on the volume.

**An image's filesystem can only be copied faithfully by a tool from inside that image.** The chart's
own image is built against a different libc, and a binary from it cannot execute in the source image.
So the OCI seeding step runs *in the machine's source image*, which is why the spec requirement
forbidding a source as a container image had to be narrowed rather than kept.

## Goals / Non-Goals

**Goals:**

- Make "seeded exactly once" a property of the volume, so that it survives everything else being
  recreated.
- Make an interrupted seeding recoverable automatically, and make a volume the chart did not create
  refuse to be overwritten.
- Keep every failure mode a message that names the source and the cause, at the step that failed.
- Keep the shell logic in the chart rather than in the image, so a fix ships without a new image.

**Non-Goals:**

- Booting the machine. The guest container keeps its placeholder command, and `NOTES.txt` keeps
  saying the machine does not boot.
- Any input that can cause a second seeding. See `proposal.md`.
- Making a source image optional after first boot. See Risks.

## Decisions

### Two init containers, split by which image they must run in

`seed` runs the copy or the extraction. `prepare` writes the marker and does the identity work.

They are separate because they cannot share an image. For an `oci` source, `seed` must run in the
machine's source image; `prepare` must not, because a busybox-based source image cannot be relied on
for anything, and the machine's identity handling would then differ per source image. `prepare`
always runs in the chart's image, so its behaviour is identical for both source kinds.

The split also gives the ordering the "interrupted seeding" requirement needs for free: the marker is
written by a *later* container than the one that fills the volume, so a copy that dies half-way
cannot leave a marker behind.

*Alternative considered:* one init container doing both, with the LXC path in the chart image and the
OCI path in the source image. Rejected — the identity logic would exist twice, in two languages of
shell, and only one copy would ever be tested.

### The scripts live in the chart as a ConfigMap, not in the image

The image is a toolbox: a shell, the archivers, and nothing project-specific. Every script this
change adds is rendered into a ConfigMap and mounted into the containers that run it.

Three reasons. The OCI path needs it regardless — the script has to reach a container running an
image the project does not build. Keeping the rest in the same place removes the chart-to-image
version skew that would otherwise exist for every fix, so a bad `sed` is a `helm upgrade` rather than
an image release. And it is what `05-open-questions.md` §10a asks for on the injection surface:
values reach the scripts through the environment and through mounted files, never by Helm
interpolating text into a script.

*Alternative considered:* baking the scripts into the image. Rejected for the skew: the chart would
have to pin an image version per chart version, and a user pinning an older image would silently run
older logic against newer values.

### The OCI seed script is POSIX `sh`; everything else is `bash`

The OCI seed script executes inside the machine's source image, so it may only assume what every
distribution image has: `/bin/sh` and GNU `tar`. Every other script runs in the chart's image, where
`bash` is present, and uses it.

This is also the boundary of what the chart can promise about an OCI source. A source image with no
shell — distroless, scratch — cannot be seeded, and the failure is the runtime's, not one this chart
can improve on. That is acceptable: an image with no shell has no init either, so it was never going
to be a machine.

### The copy uses Proxmox's archive flags, through a tar pipe

`seed` copies with `tar -C / <flags> --exclude=./dev/* -cf - . | tar -C /mnt/rootfs -xpf -`, with the
flags of `@PVE::Storage::Plugin::COMMON_TAR_FLAGS` — `--one-file-system -p --sparse --numeric-owner
--acls --xattrs --xattrs-include=user.* --xattrs-include=security.capability`.

`--one-file-system` is what keeps `/proc`, `/sys` and the mounted volume itself out of the copy
without enumerating them, and `--xattrs-include=security.capability` is the flag whose absence
produces the failure nobody can diagnose: extraction succeeds, and an unprivileged `ping` fails
forever after with a permission error.

Before copying, the script probes its own `tar` for GNU provenance and extended-attribute support and
**fails with a message naming the `lxc` source kind as the alternative** if either is missing. This
is the §6 "fail loudly, never silently degrade" rule, and it is the whole reason an Alpine OCI source
is rejected rather than seeded badly.

### A template is verified, then inspected, then unpacked — in that order

The tarball is downloaded to `.stateful-pods/download/` on the rootfs volume itself, checksummed
against the machine's mandatory `sha256`, listed and inspected, unpacked, and deleted.

Downloading onto the volume avoids adding an `emptyDir` the user would have to size, and the volume
is already required to be large enough for the unpacked result. The transient cost is the compressed
size on top.

The inspection is Proxmox's `check_tar_archive()`, for the reason Proxmox has it: a checksum proves
the bytes are the ones the user named, not that the user named a root filesystem. An archive with no
`sbin` entry, with fewer than ten members, or carrying a multi-volume member is rejected before
anything is written.

### Seeding state is three states on the volume, not two

`.stateful-pods/` on the volume holds:

- `seeding` — written before the first byte is copied, removed when the marker is written.
- `provisioned` — the marker, written last, by `prepare`.

That yields four distinguishable situations, and each has exactly one safe action:

| `provisioned` | `seeding` | Volume | Action |
| --- | --- | --- | --- |
| present | — | — | Nothing. Check for a clone, then start. |
| absent | present | any | A previous attempt died. Wipe everything but `.stateful-pods/` and seed again. |
| absent | absent | empty | Seed. |
| absent | absent | not empty | **Fail.** Contents the chart did not create. |

The last row is the one worth the extra file. Without `seeding`, "unmarked but not empty" is
ambiguous between "we crashed half-way" and "the user put something here", and the chart would have
to choose between destroying a user's data and getting permanently stuck. With it, neither.

*Alternative considered:* seeding into a staging directory and making completion a single atomic
`rename`. Rejected because it makes the volume's top level not be the root filesystem, which breaks
the property that a restored snapshot is directly usable and that the volume can be inspected by
mounting it anywhere.

### A clone is detected by the machine's name, not by the volume's identity

The marker records the namespace, the release and the machine name. On every start, `prepare`
compares them with the machine it is running as. Different means clone: clear the inherited identity,
rewrite the marker, touch nothing else.

`03-mapping-and-architecture.md` §4.5 suggests recording the PVC's UID instead. That is not available
to a container — the downward API exposes the pod, not the claim — and it would also give the wrong
answer for the ordinary case: restoring a backup into the same machine creates a *new* claim with a
new UID, and the machine would wrongly regenerate its identity every time it was restored.

The name triple gives exactly the semantics `values.yaml` already documents: restoring into the same
release keeps the machine's identity, restoring into a new one regenerates it.

### Identity means the machine ID, and nothing else yet

`prepare` truncates `/etc/machine-id` to empty and removes a stale `/var/lib/dbus/machine-id`. Empty
rather than absent, because that is the state systemd documents as "first boot" and the state
Proxmox's `clear_machine_id` leaves behind.

SSH host keys, the root password and `authorized_keys` are identity too, and they are deliberately
not here: they need the provisioning input contract of `docs/research/07-provisioning-inputs.md`,
which is a change of its own. A machine cloned before that change has a fresh machine ID and the
original's host keys, which is documented rather than half-solved.

### The image is pinned by digest, and the chart's default is a digest

`shim.image` stops being a placeholder and becomes `ghcr.io/kitsunoff/stateful-pods-shim@sha256:…`
for `linux/amd64` and `linux/arm64`.

A tag would make a machine's own boot path change under it without anything in the release changing,
which is precisely what this project promises not to do to a pet. The cost is a bootstrap order: the
image must be published before the chart default can name it, so the first build is tagged, and the
chart is updated with the digest that build produced.

### Only the guest container gets the mode's privilege

The init containers add no capability, are never privileged and never allow privilege escalation.
They do run as the container's root user, which is what writing another system's file ownership
requires, and which in `userns` mode is not root on the node at all.

This is not a weakening of `pod-security-posture` — it is the reading that requirement always
implied, now stated because there are containers other than the guest for the first time.

## Risks / Trade-offs

- **An `oci` source must stay pullable for the life of the machine.** The seeding init container runs
  on every pod start even to do nothing, so its image must be resolvable — a machine whose upstream
  tag was deleted will not start on a node that has not cached it. → Documented, and the default
  advice is to pin the source by digest. Removing it entirely means seeding at claim-creation time
  through a volume populator, which needs a controller; recorded as the reason to revisit.
- **An Alpine or other busybox-based OCI source cannot be seeded.** Its `tar` has no extended
  attribute support, so the copy would silently drop file capabilities. → The probe fails the pod
  with a message naming the `lxc` kind as the way to run Alpine.
- **A source image with no shell fails opaquely.** The chart cannot print a better message than the
  runtime's "no such file". → Documented as a prerequisite; such an image has no init and is not a
  machine.
- **The tarball transiently occupies the rootfs volume.** A volume sized exactly for the unpacked
  filesystem will run out of space. → The failure is reported as what it is, and the sizing note in
  the README says to add the compressed size.
- **`.stateful-pods/` is visible inside the guest as `/.stateful-pods`.** → Accepted; Proxmox does
  the same with its `/.pve-ignore.*` markers, and hiding it would mean a directory the guest can
  neither see nor be told about.
- **An integration test needs a real cluster.** Rendering tests cannot tell whether a copy preserved
  a capability bit. → One kind job seeds a small image and a small template and asserts the result,
  in `privileged` mode only, because `userns` on kind is nested and unreliable
  (`05-open-questions.md` §12).

## Migration Plan

Existing releases have an empty rootfs volume and a guest that sleeps. Upgrading adds the init
containers; the next pod start seeds the volume for the first time.

Rolling back to the previous chart version removes the init containers and leaves the volume seeded
and marked. Rolling forward again finds the marker and does nothing. No state is lost in either
direction, because nothing in this change ever removes a marked volume's contents.

## Open Questions

- Whether to expose `imagePullSecrets` as a chart input for a private `oci` source. Attaching them to
  the pod's ServiceAccount already works, so this is convenience, and it is additive.
- Whether seeding should eventually move to a volume populator so that it happens when the claim is
  created rather than when the pod starts. It would remove the pullability risk above, at the cost of
  shipping a controller; it changes nothing about what a seeded volume must contain.
