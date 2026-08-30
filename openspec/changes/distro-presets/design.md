## Context

See `proposal.md` — Why. The facts this design is built on, all checked against the live upstream:

- `https://images.linuxcontainers.org/meta/1.0/index-system` is a plain-text index, one line per
  build: `distro;release;arch;variant;date;path`. It covers all four distributions on both
  architectures — `debian` (bullseye, bookworm, trixie, forky), `ubuntu` (jammy, noble, resolute),
  `alpine` (3.21–3.24, edge) and `voidlinux` (current, in `default` and `musl` variants).
- Each build directory holds `rootfs.tar.xz`, `SHA256SUMS`, and a detached `.asc` signature for
  every file including `SHA256SUMS` itself.
- Proxmox was evaluated and rejected: no Void at all, and two arm64 templates against fifty-four
  amd64 ones.
- The chart today accepts `oci` and `lxc` source kinds, validates them in
  `stateful-pods.validate.semantics`, and passes the source to the scripts through
  `stateful-pods.machine.seedEnv` as `SP_SOURCE_*`.
- `hack/check-values-docs.sh` requires a comment on the line above every key in `values.yaml`.

## Goals / Non-Goals

**Goals:**

- Declaring a supported distribution is one line, and what it resolves to is pinned and reviewable.
- The bytes that become a machine's root filesystem are traceable to a signature, not to a URL.
- The catalog moves on its own but changes only through review.
- The seeding scripts never learn that presets exist.

**Non-Goals:**

- Letting a user extend the catalog through values. A user who wants their own image already has
  `kind: oci`, which is the honest way to say "an image I chose".
- Building anything into a preset, including this project's own scripts. Those live in the shim.
- Supporting an architecture the project does not otherwise build for.

## Decisions

### `preset` is a third source kind that resolves at render time

The chart ships `charts/stateful-pods/presets.yaml` — a flat map from preset name to a
digest-pinned reference — and reads it with `.Files.Get` and `fromYaml`. `kind: preset` with a
`name` resolves through that map during rendering.

Not in `values.yaml`, for two reasons. It is data maintained by a bot rather than configuration a
user sets, and every key there would need its own comment to satisfy `hack/check-values-docs.sh`,
which is noise on a generated table. `.Files` includes chart-root files in a packaged chart, so the
table travels with the chart however it is installed — which a `presets/*.yaml` values file, usable
only from a checkout, would not.

The validation follows the shape the chart already uses for `security.mode`: an unknown name fails
with the accepted set listed, and the listing is generated from the table rather than written twice.

### The scripts never see a preset

`stateful-pods.machine.seedEnv` resolves the preset and emits `SP_SOURCE_KIND=oci` with the
resolved reference. The seeding path is the OCI path, unchanged, and no script gains a branch.

One addition: an optional `SP_SOURCE_PRESET` carrying the name, recorded by `prepare.sh` in the
volume's provisioning record. Without it the volume would record only a digest, and "which preset
was this machine made from" would be unanswerable a year later, when the answer matters most. It is
an additive field on the existing record, so the record's schema version does not change and an
older reader is unaffected.

### The image is the upstream tarball, byte for byte

The layer of a preset image is the upstream `rootfs.tar.xz`, decompressed and otherwise untouched,
appended with `crane append`. There is no builder and no Containerfile, because there is nothing to
build: a preset is the distribution's own archive with an OCI manifest wrapped around it.

The idiomatic `FROM scratch` plus `ADD rootfs.tar.xz /` was tried first and measured, because it is
the more readable form and worth having if it is faithful. It is not. Every extended attribute in
all four upstream tarballs was enumerated and compared against the same enumeration of the layer
buildkit produced:

- `security.capability` survives. Buildkit preserves it byte for byte, so the narrow assertion this
  design originally proposed would have passed.
- `system.posix_acl_access` and `system.posix_acl_default` do not. Debian and Ubuntu both carry them
  on `/var/log/journal`, where they are what grants `systemd-journal` read access to the journal,
  and buildkit's extract-and-retar drops both without a word.

So the concern was right and the specific test for it was wrong. `crane append` round-trips all
three attributes identically, because the tarball is never extracted: the archive that was verified
is the archive that becomes the layer, which is the only form in which "their contents are
identical" is a claim rather than a hope.

Making the layer the archive also makes the assertion better than the inventory this design first
proposed. The published layer's `diff_id` is the SHA-256 of its uncompressed content, so comparing
it against the checksum of the archive that was verified proves the two are the same bytes - every
extended attribute, every mode, every ordering decision included. An inventory can only assert the
properties someone thought to enumerate, which is exactly how the ACLs were nearly missed. The
check reads the config back from the registry, so what it compares is what was published rather
than an intermediate nobody serves.

Dropping the builder drops the QEMU and buildx machinery with it. Packaging a foreign
architecture's root filesystem never executes it, so there was never anything for emulation to do.
`crane mutate` sets the platform and the provenance labels afterwards, and sets nothing else: a
preset declares no command, no entrypoint and no environment.

Either way the per-architecture images are combined into one multi-architecture index, because a
preset that resolved to one architecture would push that choice into every user's values file.

### Provenance is verified against a fingerprint pinned in the repository

The build fetches `SHA256SUMS` and `SHA256SUMS.asc`, verifies the signature against a key
fingerprint committed to this repository, then verifies `rootfs.tar.xz` against the verified
checksum list. Only then does it package.

Pinning the fingerprint in the repository is the whole point. A signature verified against whatever
key the same server offers establishes that the server is consistent with itself, which is not a
security property. The fingerprint is a value a human confirms once, out of band, against what
linuxcontainers.org publishes, and changing it is a reviewed commit.

Key rotation upstream therefore breaks the build rather than silently accepting a new key. That is
the correct failure: it is a person's decision, and a loud stop is cheap.

The verified checksum, the upstream path and the upstream build date go into the image's OCI labels,
so an image found later can be traced without this repository.

### The daily workflow publishes first and proposes second

Once a day: read the index, compare each preset's pinned upstream build against the newest, and for
each preset that has fallen behind, run the full build — verify, package, push under the new dated
tag — and then open a pull request that points the catalog entry at what was just published.

The other order, proposing a bump and building after merge, would put a reference in the catalog
that does not exist yet and leave the digest to be filled in by a second commit. Publishing first
means every proposed entry is already resolvable, which is also what the reviewer needs in order to
review it.

Publishing without review is safe here in a way that changing the catalog is not: a dated tag is
immutable and new, so nothing that exists changes, and nothing uses it until the catalog says so.

One pull request per preset, on a branch named for it, force-updated when the upstream moves again
before the previous one is merged. A single combined pull request would make a problem with one
distribution block the other three.

### Retention deletes indexes and their children deliberately

The obvious implementation — a retention action set to remove untagged versions — is exactly the way
these jobs break a multi-architecture image. A multi-architecture image is a tagged index whose
per-architecture manifests are themselves untagged package versions. "Delete untagged" deletes the
architectures out from under every retained tag.

So the job works from the tags: list them, order by the build date in the tag, keep the newest five,
and for each tag being removed, resolve its index's children first, delete the index, then delete
those children only if no retained index still references them. A child shared with a retained index
is left alone.

The order matters too — children after their index, never before — so that an interrupted run leaves
a resolvable image rather than an index pointing at manifests that are gone.

### Dependabot covers what it can, which is not the tarballs

`.github/dependabot.yml` is added for `github-actions` and `docker`, which keeps the workflow actions
and the shim's `alpine` base current. It cannot track the upstream here: a daily dated build on an
HTTPS index is not a package registry in any ecosystem Dependabot implements, and the preset
Containerfile's `FROM scratch` gives it nothing to look at. The daily workflow above is what covers
the tarballs, and the two do not overlap.

## Risks / Trade-offs

- **An extraction-based build drops extended attributes** → Measured, not assumed: `ADD` keeps
  `security.capability` but loses the POSIX ACLs on `/var/log/journal`. Settled by making the layer
  the upstream archive itself, and asserted after publication by requiring the published layer's
  `diff_id` to equal the checksum of the archive that was verified.
- **A retention job can break a retained multi-architecture image** → Addressed by the algorithm
  above rather than by an off-the-shelf "delete untagged" step. Verified by resolving every retained
  tag for both architectures after a retention run.
- **New GHCR packages are private by default** → A preset nobody can pull is a preset that does not
  work, and the failure looks like a typo in the reference. Each package's visibility is set to
  public as part of first publication, and the check that a published reference resolves is run
  unauthenticated.
- **The upstream index is a scrape, not an API** → A format change breaks parsing. The workflow
  fails loudly on a line it cannot parse rather than proposing whatever it managed to read.
- **Alpine and Void are unusable until `shim-owned-scripts` lands** → Their root filesystems provide
  busybox tar, which today's OCI seeding path rejects. Sequenced in the migration plan; do not start
  this change before that one is merged.
- **Retention is only safe after `shim-owned-scripts`** → Until a seeded machine stops fetching its
  source on every start, deleting an old build breaks a running machine that was seeded from it and
  is then rescheduled. Same sequencing.
- **Four distributions, one build path** → Void and Alpine differ from Debian and Ubuntu in almost
  everything except the shape of a root filesystem tarball, which is the only thing this build
  touches. If that stops being true, it stops being true loudly, at the capability assertion.

## Migration Plan

1. `shim-owned-scripts` must be merged first. Both the Alpine and Void presets and the retention
   policy depend on it.
2. Land the build and the workflows with the catalog empty, and publish the four presets by running
   the build workflow by hand. Nothing in the chart refers to them yet.
3. Confirm every published reference resolves unauthenticated, on both architectures.
4. Land the chart change — the source kind, its validation, the catalog file populated with the
   four digests — and the documentation.
5. Enable the daily workflow and the retention job. Retention does nothing until a preset has six
   builds, which is the first week it can be observed doing the right thing.

Rollback at any point before step 4 is deleting the packages; nothing in the chart depends on them.
After step 4 it is a chart revision, and a machine already seeded from a preset is unaffected either
way, because its volume is its operating system.

### Implementation order

Group 1 is a gate: it settles how the image is built. Group 2 (the build) and group 5 (the chart)
touch disjoint trees — `images/presets/` against `charts/stateful-pods/` — and can proceed in
parallel once group 1 is settled. Groups 3 and 4, the workflows, need group 2. Group 6 needs
everything.

## Open Questions

- Whether to add Void's `musl` variant and the `cloud` variants later. Deferrable: each is a row in
  a matrix and a name in the catalog, and adding one changes nothing about how any of this works.
- Whether five is the right number once there is a month of data on how often a bump turns out to be
  bad. Deferrable: it is one constant in one job.
- Whether the catalog should eventually be generated into the chart's README as a table. Deferrable
  and cosmetic.
