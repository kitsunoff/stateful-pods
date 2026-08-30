## ADDED Requirements

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
  machine on that preset must select the `native` backend

#### Scenario: What a preset can serve is stated per preset

- **WHEN** the presets are documented
- **THEN** each one names the backends it can serve, rather than the set being described in general
  or stated only for the presets that differ from the majority

#### Scenario: A preset waiting on its upstream is marked like any other

- **WHEN** a preset's upstream publishes a variant carrying cloud-init but the preset is not yet
  built from it
- **THEN** that preset is documented as serving `native` only, for as long as that holds, rather
  than as carrying cloud-init because its distribution does elsewhere
