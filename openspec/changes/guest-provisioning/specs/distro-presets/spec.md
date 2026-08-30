## ADDED Requirements

### Requirement: Which backends a preset can serve is documented where a preset is chosen

For each preset the project publishes, the documentation SHALL state which provisioning backends its
root filesystem can serve, and a preset that cannot serve the default backend SHALL say so at every
place a preset is named as an input.

A preset is the short way to say "a Debian machine" without researching a reference, so it is also
where someone learns what that machine can do. The default backend is cloud-init, and a preset whose
upstream publishes no cloud variant cannot serve it: naming that preset with no backend of its own
produces a machine that refuses to start. Meeting that in a crash loop, having read nothing that
warned of it, is the failure this requirement exists to prevent.

Nothing is installed into a preset to close the gap. A preset is an upstream distribution's own root
filesystem or it is not a preset.

#### Scenario: A preset that cannot serve the default backend is marked

- **WHEN** a preset's upstream publishes no variant carrying cloud-init
- **THEN** the values file, the chart documentation and the project documentation each say that a
  machine on that preset must select the `native` backend

#### Scenario: What a preset can serve is stated per preset

- **WHEN** the presets are documented
- **THEN** each one names the backends it can serve, rather than the set being described in general
