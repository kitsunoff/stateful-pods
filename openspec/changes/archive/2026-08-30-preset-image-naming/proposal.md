## Why

A preset image is published today as one package per preset with a dated tag:
`ghcr.io/kitsunoff/stateful-pods-ubuntu-noble:noble-20260829_0742`. The release is written twice and
the build date is not optional, so there is no name a person can type. Someone who wants Ubuntu
Noble has to go and look up which build exists before they can pull anything, and the package list
reads as a list of releases rather than a list of distributions.

Every distribution names its own images the other way round — `ubuntu:noble`, `debian:trixie`,
`alpine:3.24` — because the package is the distribution and the tag is the release. This project
should read the same way: `ghcr.io/kitsunoff/stateful-pods-ubuntu:noble`.

The reason it does not already is recorded, and it is a good reason. `distro-presets` ruled out
rolling tags in its non-goals: a machine is a pet whose disk must be reproducible, and a reference
that comes to mean different content later would change a machine's origin without anything in its
values changing. That property is not being given up here. It is being kept where it actually lives
— in the chart's catalog, which pins a digest and will continue to. The rolling tag is a name for
people, not a reference a machine is ever seeded from.

## What Changes

- **BREAKING** for image references: a preset's package is named for its distribution rather than
  for the preset, so `stateful-pods-ubuntu-noble` becomes `stateful-pods-ubuntu`,
  `stateful-pods-debian-trixie` becomes `stateful-pods-debian`, `stateful-pods-alpine-3.24` becomes
  `stateful-pods-alpine` and `stateful-pods-void-current` becomes `stateful-pods-void`. The four
  packages under the old names are left in place, because the released chart still points at
  digests inside them.
- `images/presets/presets.list` gains a field naming the package a preset publishes into. It is
  stated rather than derived from the preset name, for the same reason the file already states the
  distribution and the release rather than deriving them.
- A rolling tag is published beside the dated one and moved to each new build: `:noble`, `:trixie`,
  `:3.24`, `:current`. This reverses a non-goal of `distro-presets`, deliberately and with the
  reproducibility property intact — see the design.
- The dated tag is unchanged, stays immutable, and remains the only thing retention orders by. The
  rolling tag is protected from retention unconditionally and is never what a build is counted by.
- Retention learns that one package can hold more than one release. It keeps five builds of each
  release rather than five builds of each package, so that adding a second release of a
  distribution cannot silently delete the first.
- The chart's catalog keeps pinning every preset to a digest, and `hack/check-presets.sh` keeps
  enforcing it. The preset names a user writes in `values.yaml` do not change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `distro-presets`: how a preset image is named and tagged. A published build is still identified
  immutably by a dated tag, and the requirement that no tag follows the newest build is replaced by
  one that publishes exactly such a tag and states what keeps a machine's source reproducible
  anyway. Retention gains the rolling tag as something it must preserve, and becomes per release
  rather than per package now that a package can hold several.

## Impact

- `images/presets/presets.list`: a new field, read by everything that reads the file.
- `hack/preset-build.sh`: composes the package name from the new field, and pushes the rolling tag.
- `hack/preset-retention.jq` and `hack/preset-retention.sh`: the rolling tag is protected and is not
  a build; planning is scoped to one release of a shared package.
- `hack/check-presets.sh`: the repository a catalog entry names is checked against the package, not
  against the preset name.
- `charts/stateful-pods/presets.yaml`: four references repointed at the new packages.
- `.github/workflows/preset-publish.yaml`: the visibility report names the package rather than the
  preset.
- `test/presets/retention.bats`, `test/presets/bump.bats`,
  `charts/stateful-pods/tests/values_preset_source_test.yaml`: fixtures and assertions.
- `README.md`, `charts/stateful-pods/README.md`, `docs/`: the published names.
- The four packages under the old names are orphaned but not deleted, and cannot be until a chart
  release points at the new ones.
