## ADDED Requirements

### Requirement: A preset image is named for its distribution and tagged for its release

A preset SHALL be published into an image repository named for the distribution it comes from, and
every tag in that repository SHALL name the release. The repository name SHALL be stated in the
project's list of presets rather than derived from a preset's name.

A repository per preset writes the release into the repository name and then again into every tag,
so `stateful-pods-ubuntu-noble:noble-20260829_0742` says "noble" twice and says nothing a person
would type. Distributions name their own images the other way round — the repository is the
distribution and the tag is the release — and a project publishing root filesystems of those
distributions is read by people who already know that shape.

Deriving the repository from the preset name would work today and would be a rule two places had to
know: the preset `void-current` publishes into `stateful-pods-void` while its upstream calls the
distribution `voidlinux`, and none of those three names can be computed from another.

#### Scenario: One repository holds a distribution

- **WHEN** a preset of a given distribution is published
- **THEN** its image repository is named for that distribution and not for the release

#### Scenario: The tag names the release

- **WHEN** any tag a preset publishes is read
- **THEN** it begins with the release the preset names

#### Scenario: A repository serves every release of its distribution

- **WHEN** two presets of the same distribution and different releases are published
- **THEN** both publish into the same repository, distinguished by their tags

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

## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: A preset build is identified immutably and is never republished

**Reason**: Its first half is unchanged and is restated by "A preset build is identified immutably
by its dated tag". Its second half — "The project SHALL NOT publish a tag that follows the newest
build of a release" — is withdrawn, because the reproducibility it was protecting is enforced by the
catalog pinning a digest rather than by the absence of such a tag.

**Migration**: Nothing already published changes. Every dated tag keeps its content and keeps its
meaning, and the chart's catalog continues to resolve every preset to a digest. What a reader
looking for the newest build of a release used to be told did not exist is now published as a
rolling tag, and is documented as a name for people rather than a reference to pin.
