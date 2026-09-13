## MODIFIED Requirements

### Requirement: A preset carries cloud-init where its upstream publishes an image that has it

A preset SHALL be built from the upstream variant that carries cloud-init, for every distribution
and release whose upstream publishes one as a single build covering every architecture this project
supports. Where the upstream publishes no such variant, or publishes one its architectures do not
agree on, the preset SHALL be built from the `default` variant, and the project SHALL state that the
preset serves the `exec` provisioning backend only and why.

The chart's default provisioning backend is cloud-init, and an image without it is required to fail
the pod loudly. A project that ships both a default backend and a catalog of images that cannot
serve it has shipped a default that does not work, so the catalog moves where it can and says where
it cannot.

#### Scenario: A distribution whose upstream publishes a cloud variant

- **WHEN** an upstream publishes a `cloud` variant for a distribution and release, as one build
  covering every architecture this project supports
- **THEN** the preset for it is built from that variant

#### Scenario: A distribution whose upstream publishes none

- **WHEN** an upstream publishes no variant carrying cloud-init
- **THEN** the preset is built from the `default` variant, and the documentation says that a machine
  on it must select the `exec` backend

#### Scenario: A distribution whose architectures disagree

- **WHEN** an upstream publishes a cloud variant whose architectures are not on the same build
- **THEN** the preset stays on the `default` variant until they are, because one tag cannot honestly
  name two root filesystems

### Requirement: Which backends a preset can serve is documented where a preset is chosen

For each preset the project publishes, the documentation SHALL state which provisioning backends its
root filesystem can serve, per preset rather than in general, and a preset that cannot serve the
default backend SHALL say so at every place a preset is named as an input.

A preset is the short way to say "a Debian machine" without researching a reference, so it is also
where someone learns what that machine can do. The default backend is cloud-init, and a preset that
does not carry it cannot serve one: naming that preset with no backend of its own produces a machine
that refuses to start. Meeting that in a crash loop, having read nothing that warned of it, is the
failure this requirement exists to prevent.

Per preset and not in general, because the presets disagree and will go on disagreeing. One
distribution's upstream publishes no cloud variant at all; another publishes one whose architectures
are not yet on the same build, which is a state that resolves later. A reader who is told "most
presets carry cloud-init" learns nothing about the one they chose, and a reader whose Debian machine
works while their Ubuntu machine does not will conclude the chart is broken rather than that the
image lacks cloud-init.

Nothing is installed into a preset to close the gap. A preset is an upstream distribution's own root
filesystem or it is not a preset.

#### Scenario: A preset that cannot serve the default backend is marked

- **WHEN** a preset's root filesystem does not carry cloud-init, for any reason
- **THEN** the values file, the chart documentation and the project documentation each say that a
  machine on that preset must select the `exec` backend

#### Scenario: What a preset can serve is stated per preset

- **WHEN** the presets are documented
- **THEN** each one names the backends it can serve, rather than the set being described in general
  or stated only for the presets that differ from the majority

#### Scenario: A preset waiting on its upstream is marked like any other

- **WHEN** a preset's upstream publishes a variant carrying cloud-init but the preset is not yet
  built from it
- **THEN** that preset is documented as serving `exec` only, for as long as that holds, rather
  than as carrying cloud-init because its distribution does elsewhere
