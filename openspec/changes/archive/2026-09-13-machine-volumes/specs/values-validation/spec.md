## ADDED Requirements

### Requirement: A machine's declared volumes are checked while the chart renders

The chart SHALL reject, while rendering and with a message naming the volume, a volumes block that
is not a map, a volume entry that is not a map, a volume name that is not a DNS-1123 label or that
collides with a volume the pod already has, a missing or non-absolute mount path, a mount path the
boot sequence mounts over, two volumes sharing one mount path, a volume naming both a size and an
existing claim, a volume naming neither, an existing claim name the API server would reject, and a
key under a volume entry that is not an input.

Each of these either renders a manifest the API server refuses on apply, or renders one it accepts
and that produces a machine whose volume is silently empty. The second kind is the reason the checks
are worth having: a volume mounted under a path the boot sequence covers works in every observable
way except the one it was created for.

#### Scenario: A mount path that is not absolute is refused

- **WHEN** a machine declares a volume whose mount path does not begin with `/`
- **THEN** rendering fails, naming the volume and the path

#### Scenario: A mount path the boot sequence covers is refused

- **WHEN** a machine declares a volume mounted at or under `/proc`, `/sys`, `/dev`, `/run` or `/tmp`
- **THEN** rendering fails, naming the path and saying that the boot sequence mounts over it, so the
  volume would be present and empty on every start

#### Scenario: A volume naming neither a size nor a claim is refused

- **WHEN** a machine declares a volume that names no size and no existing claim
- **THEN** rendering fails, explaining that one creates storage and the other consumes storage that
  exists

#### Scenario: An unknown key under a volume is refused rather than ignored

- **WHEN** a machine declares a key under a volume entry that the chart does not accept
- **THEN** rendering fails and lists the keys that are accepted

#### Scenario: A name the pod already uses is refused

- **WHEN** a machine declares a volume named after the machine's own object name, or after a volume
  the chart renders for its own purposes
- **THEN** rendering fails, naming what already holds that name
