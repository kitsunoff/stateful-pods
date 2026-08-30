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

### Requirement: A preset carries cloud-init where its upstream publishes an image that has it

A preset SHALL be built from the upstream variant that carries cloud-init, for every distribution
and release whose upstream publishes one as a single build covering every architecture this project
supports. Where the upstream publishes no such variant, or publishes one its architectures do not
agree on, the preset SHALL be built from the `default` variant, and the project SHALL state that the
preset serves the `native` provisioning backend only and why.

The chart's default provisioning backend is cloud-init, and an image without it is required to fail
the pod loudly. A project that ships both a default backend and a catalog of images that cannot
serve it would fail every default install of its own presets.

Which variant to take is settled by reading the upstream's index rather than by assuming the
distributions are symmetric. They are not: at the time of writing, Debian, Ubuntu and Alpine publish
a `cloud` variant and Void publishes only `default` and `musl`.

The single-build condition is not a loophole; it is the same rule that already governs publishing.
A preset covers every architecture or it is not published, because a root filesystem for the wrong
architecture seeds without error. A variant whose architectures are on different upstream builds
offers nothing one tag can honestly name, so there is nothing to take from it yet — and taking the
`default` variant meanwhile is the honest state rather than a downgrade, provided it is stated.

A variant that carries some other provisioning implementation does not satisfy this requirement.
Alpine's `tinycloud` is tiny-cloud rather than cloud-init, and answers a different configuration
surface, so a cloud-init backend pointed at it would fail in a way that reads as cloud-init being
broken.

#### Scenario: A preset built from a cloud variant carries cloud-init

- **WHEN** the root filesystem of a preset built from a cloud variant is inspected
- **THEN** it contains the cloud-init program, cloud-init's service units for the init system the
  image uses, and `/etc/cloud`

#### Scenario: A distribution with no cloud variant keeps the default one

- **WHEN** the upstream publishes no variant carrying cloud-init for a preset's distribution and
  release
- **THEN** that preset is built from the `default` variant rather than having cloud-init installed
  into it, and what it can be provisioned with is stated

#### Scenario: A variant its architectures disagree on is not taken yet

- **WHEN** the upstream publishes a variant carrying cloud-init but its architectures are on
  different upstream builds
- **THEN** the preset stays on the variant that resolves as one build, and the project records that
  it is waiting on the upstream rather than presenting the preset as one that carries cloud-init

#### Scenario: The variant is looked up, not assumed

- **WHEN** a preset is resolved against the upstream index
- **THEN** the build named in the project's list of presets is the one looked up, and a variant the
  upstream does not offer for every supported architecture stops the build rather than falling back
  to another

### Requirement: A preset carries cloud-init installed, not enabled

A preset SHALL carry the upstream's cloud-init state exactly as published, including the
`/etc/cloud/cloud-init.disabled` marker the upstream's builder writes. Whatever provisions a machine
with cloud-init SHALL remove that marker from the seeded root filesystem, and SHALL NOT treat the
presence of the cloud-init program, its units or `/etc/cloud` as sufficient evidence that cloud-init
will run.

The upstream's builder disables cloud-init in the LXC images this project consumes, on purpose: its
LXD and Incus outputs write a seed and enable cloud-init in one step, and the plain LXC archive is
that with the enabling left out. A preset cannot remove the marker itself without modifying an
upstream root filesystem, which this capability forbids.

Stating it as an obligation rather than leaving it to be discovered is the point. A backend that
checks for cloud-init by looking for the program finds it on an image where cloud-init cannot run,
writes a seed nothing reads, and produces a machine with no users and no keys — the failure that
requiring a loud check was meant to prevent, reached from a direction that check does not cover.

#### Scenario: The disable marker is published as the upstream wrote it

- **WHEN** a preset built from a cloud variant is inspected
- **THEN** it carries the upstream's `/etc/cloud/cloud-init.disabled`, unmodified and not removed

#### Scenario: A machine boots unaffected while the marker is in place

- **WHEN** a machine is seeded from such a preset and nothing has removed the marker
- **THEN** the machine boots, cloud-init does not run, and it leaves no failed service behind

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

### Requirement: A preset image is named for its distribution and tagged for its release

A preset SHALL be published into an image repository named for the distribution it comes from and
the upstream variant it is built from, and every tag in that repository SHALL name the release. The
repository name SHALL be stated in the project's list of presets rather than derived from a preset's
name.

A repository per preset writes the release into the repository name and then again into every tag,
so `stateful-pods-ubuntu-noble:noble-20260829_0742` says "noble" twice and says nothing a person
would type. Distributions name their own images the other way round — the repository is the
distribution and the tag is the release — and a project publishing root filesystems of those
distributions is read by people who already know that shape.

The variant belongs in the repository name because two variants of one release share an upstream
serial, and a tag naming only the release and the serial would name two different root filesystems.
The build refuses to republish a dated tag that already exists, so such a collision would not be
reported: it would leave whichever variant was published first in place and report its digest as the
preset's. Putting the variant in the tag instead would put a dash inside the release segment that
retention parses, which is a different and larger change.

Deriving the repository from the preset name would work today and would be a rule two places had to
know: the preset `void-current` publishes into `stateful-pods-void` while its upstream calls the
distribution `voidlinux`, and none of those three names can be computed from another.

#### Scenario: One repository holds a distribution

- **WHEN** a preset of a given distribution is published
- **THEN** its image repository is named for that distribution and the variant it is built from, and
  not for the release

#### Scenario: The tag names the release

- **WHEN** any tag a preset publishes is read
- **THEN** it begins with the release the preset names

#### Scenario: A repository serves every release of its distribution

- **WHEN** two presets of the same distribution and variant and different releases are published
- **THEN** both publish into the same repository, distinguished by their tags

#### Scenario: Two variants of one release do not collide

- **WHEN** two presets name the same distribution and release and different variants
- **THEN** they publish into different repositories, and neither can resolve to a dated tag the
  other already published

### Requirement: A preset build is identified immutably by its dated tag

Each published build of a preset SHALL be identified by a tag that names the release and the
upstream build it came from, and that tag SHALL NOT be moved to different content afterwards. Every
decision the project makes about which builds of a release exist, and in what order, SHALL be made
from those tags alone.

A machine is a pet whose disk must be reproducible. A reference that comes to mean different content
later makes a machine's origin unreproducible without anything in its values changing, and does it
invisibly.

A tag that follows the newest build is published beside this one and does not weaken it: the two are
distinguishable by their names, and nothing a machine is seeded from is a tag at all.

#### Scenario: A published dated tag keeps its content

- **WHEN** a preset's newer build is published
- **THEN** the previously published dated tags continue to resolve to the content they already had

#### Scenario: A build is counted by its dated tag

- **WHEN** the project decides which builds of a release exist and in what order
- **THEN** the decision is made from the dated tags alone, and a tag that is neither a dated tag nor
  a known rolling tag stops the decision rather than being guessed at

### Requirement: The newest build of a release is reachable by a rolling tag

The project SHALL publish, for each preset, a tag equal to the release name that resolves to the
most recently published build of that release, and SHALL move it to each newer build as it is
published. The catalog the chart ships SHALL NOT resolve a preset to that tag or to any other tag.

This reverses an earlier decision, and the reason it is safe is specific. A machine is a pet whose
disk must be reproducible, and the property that makes it so is that the catalog pins a digest —
which it still does, and which is still enforced. A machine is never seeded from a rolling tag, so
no machine's origin can change under it. What the rolling tag buys is a name a person can type, a
pull that works without first looking up which build exists, and a repository whose newest content
is discoverable from the registry alone.

#### Scenario: The rolling tag follows the newest build

- **WHEN** a newer build of a release is published
- **THEN** the release's rolling tag resolves to it

#### Scenario: The rolling tag covers every architecture

- **WHEN** the rolling tag is resolved on any architecture the project supports
- **THEN** it resolves to the build for that architecture

#### Scenario: No machine is seeded from a rolling tag

- **WHEN** the catalog the chart ships is read
- **THEN** every preset in it resolves to a reference pinned by digest

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
remove older ones. Removal SHALL NOT damage a build that is being kept, SHALL NOT remove or move the
rolling tag of any release, and SHALL NOT remove content another release published into the same
repository still needs.

Keeping every daily build forever is unbounded storage for content nobody references; keeping only
the newest leaves no way back when a build turns out to be broken. Five is a week of room to notice.

Removing a build is safe for machines because a machine reads its source once, when its volume is
seeded, and never again — a running machine seeded from a removed build is unaffected, and only a
new installation naming it would fail. That is not true of the rolling tag, which is a name people
use directly, so it is preserved whatever build it points at.

#### Scenario: The five newest builds of a preset remain

- **WHEN** a new build of a preset is published and more than five now exist
- **THEN** the five most recent remain available and the older ones are removed

#### Scenario: Retention is per preset

- **WHEN** one preset is rebuilt repeatedly while another is not
- **THEN** the second preset keeps its own five builds, including where both publish into the same
  repository

#### Scenario: A kept build stays whole

- **WHEN** older builds are removed
- **THEN** every retained build still resolves for every architecture it was published for

#### Scenario: The rolling tag survives

- **WHEN** older builds are removed
- **THEN** the rolling tag of every release still resolves for every architecture, including where
  it points at a build that would otherwise have been removed

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
