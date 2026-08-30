## ADDED Requirements

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

## MODIFIED Requirements

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
