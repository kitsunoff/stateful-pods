## Purpose

Defines the catalog of ready-made root filesystems the project publishes for the distributions it
supports: where a preset's contents come from, what establishes that they are what they claim to be,
how a preset is identified and for how long it remains available, and how the catalog keeps up with
the upstream that produces it.

## Requirements

### Requirement: A preset is an upstream root filesystem, unmodified

A preset SHALL contain the root filesystem an upstream distribution publishes, and nothing this
project added, removed or rewrote. The image SHALL carry no configuration, no package installation
and no file this project authored.

A user choosing `debian-trixie` is choosing Debian, not this project's opinion of Debian. Anything
the chart needs a machine to have, it writes at boot into the machine's own filesystem, where the
user can see it and take it back; anything baked into a preset would be invisible and permanent.

#### Scenario: The contents are the upstream's

- **WHEN** a preset image is compared against the upstream root filesystem it was built from
- **THEN** their contents are identical

#### Scenario: A preset carries no configuration of ours

- **WHEN** a preset image is inspected
- **THEN** it declares no command, no entrypoint and no environment beyond what the upstream root
  filesystem itself implies

### Requirement: A preset's provenance is verified before it is published

The build SHALL verify the upstream's cryptographic signature over its published checksums against a
key fingerprint pinned in this repository, and SHALL verify the root filesystem archive against
those checksums, before packaging anything. A failure of either check SHALL abort the build.

A checksum alone establishes only that the bytes did not change in transit from whoever served them.
The contents become a privileged machine's root filesystem, and the upstream publishes a signature
precisely so that its identity can be established rather than assumed. Pinning the fingerprint in
the repository is what makes the verification meaningful: a signature checked against whatever key
the server offers proves nothing.

#### Scenario: An unsigned or wrongly signed checksum list stops the build

- **WHEN** the upstream's checksum list cannot be verified against the pinned key
- **THEN** no image is built or published, and the failure names the key and what was received

#### Scenario: A checksum mismatch stops the build

- **WHEN** the downloaded root filesystem does not match the verified checksum
- **THEN** no image is built or published, and the failure names the archive and both checksums

#### Scenario: What was verified is recorded

- **WHEN** a preset image is published
- **THEN** it records the upstream location it was built from, the upstream build it corresponds to,
  and the checksum that was verified

### Requirement: A preset covers every architecture the project supports

Each preset SHALL be published as a multi-architecture image covering every architecture this
project builds for, so that a machine resolves its own architecture from the reference without the
user selecting one.

A root filesystem for the wrong architecture seeds without error and produces a machine that cannot
execute its own init. Publishing per-architecture references instead would move that choice into
every user's values file, where the mistake is silent.

#### Scenario: One reference serves both architectures

- **WHEN** a machine using a preset is scheduled onto a node of any architecture the project
  supports
- **THEN** the reference resolves to the build for that architecture

#### Scenario: A preset with an incomplete upstream is not published

- **WHEN** the upstream offers no build of a preset's release for one of the supported
  architectures
- **THEN** that preset is not published for the affected build rather than published covering only
  one architecture

### Requirement: A preset build is identified immutably and is never republished

Each published build of a preset SHALL be identified by a tag that names the release and the
upstream build it came from, and that tag SHALL NOT be moved to different content afterwards. The
project SHALL NOT publish a tag that follows the newest build of a release.

A machine is a pet whose disk must be reproducible. A reference that comes to mean different content
later makes a machine's origin unreproducible without anything in its values changing, and does it
invisibly.

#### Scenario: A published tag keeps its content

- **WHEN** a preset's newer build is published
- **THEN** the previously published tags continue to resolve to the content they already had

#### Scenario: No tag tracks the newest build

- **WHEN** a user looks for a reference that always resolves to the newest build of a release
- **THEN** no such tag is published

### Requirement: The catalog names a preset and pins what it resolves to

The chart SHALL ship a table mapping each preset name to a single image reference pinned by digest,
and a machine SHALL be able to name a preset instead of writing a reference. The chart SHALL resolve
the name at render time and SHALL NOT resolve it at any later point.

A name resolved after rendering would mean a machine's source could differ between the manifest the
user reviewed and the pod that ran, which is the property the whole seeding design exists to
prevent.

#### Scenario: A named preset renders as a pinned reference

- **WHEN** a machine names a preset
- **THEN** the rendered manifest carries the image reference that preset resolves to, pinned by
  digest

#### Scenario: The table is part of the chart

- **WHEN** the chart is installed from a package rather than from a checkout
- **THEN** every preset it documents still resolves

### Requirement: Five builds of each preset stay available

The project SHALL keep the five most recent published builds of each preset available, and SHALL
remove older ones. Removal SHALL NOT damage a build that is being kept.

Keeping every daily build forever is unbounded storage for content nobody references; keeping only
the newest leaves no way back when a build turns out to be broken. Five is a week of room to notice.

Removing a build is safe for machines because a machine reads its source once, when its volume is
seeded, and never again — a running machine seeded from a removed build is unaffected, and only a
new installation naming it would fail.

#### Scenario: The five newest builds of a preset remain

- **WHEN** a new build of a preset is published and more than five now exist
- **THEN** the five most recent remain available and the older ones are removed

#### Scenario: Retention is per preset

- **WHEN** one preset is rebuilt repeatedly while another is not
- **THEN** the second preset keeps its own five builds

#### Scenario: A kept build stays whole

- **WHEN** older builds are removed
- **THEN** every retained build still resolves for every architecture it was published for

### Requirement: The catalog keeps up with its upstream without a person watching it

The project SHALL check the upstream on a schedule, and where a preset's pinned build is no longer
the newest the upstream offers, SHALL publish the newer build and propose the corresponding change
to the catalog for review.

The upstreams rebuild daily, mostly to pick up security updates. A catalog that only moves when
someone remembers to look becomes, silently, a distributor of stale root filesystems.

A proposal is reviewed rather than applied: what content the chart points at is a decision, even
when the newer content is almost certainly better.

#### Scenario: A newer upstream build is proposed

- **WHEN** the upstream publishes a build newer than the one a preset is pinned to
- **THEN** that build is published and a change to the catalog entry is proposed for review

#### Scenario: An unchanged upstream proposes nothing

- **WHEN** every preset is already pinned to the newest upstream build
- **THEN** no change is proposed

#### Scenario: A proposal names a reference that already exists

- **WHEN** a catalog change is proposed
- **THEN** the reference it proposes is already published and resolvable
