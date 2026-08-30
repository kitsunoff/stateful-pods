## ADDED Requirements

### Requirement: A preset source names a preset the chart knows

A machine declaring a source of kind `preset` SHALL name one, and the chart SHALL reject a name that
is not in the table it ships, listing the names that are.

The whole value of a preset is that the user does not have to research a reference. A typo that
rendered anyway — resolving to nothing, or to a default — would hand back exactly the debugging
session the preset exists to avoid.

#### Scenario: A missing preset name is rejected

- **WHEN** a machine declares a source of kind `preset` without naming one
- **THEN** rendering fails with a message naming the machine, the values path, and the available
  presets

#### Scenario: An unknown preset name is rejected with the alternatives

- **WHEN** a machine names a preset the chart's table does not contain
- **THEN** rendering fails with a message naming the offending value and listing every preset the
  chart knows

#### Scenario: A preset name is never substituted

- **WHEN** rendering succeeds for a machine that names a preset
- **THEN** the reference in the manifest is the one that preset maps to, and no other source of
  information contributed to it

### Requirement: A preset source takes no fields of the other kinds

A machine declaring a source of kind `preset` SHALL NOT supply a reference, a URL or a checksum, and
supplying one SHALL fail rendering rather than be ignored.

A preset is a name for a reference this project pins and verified provenance for. A user who also
supplies a reference has expressed two intentions, one of which would be silently discarded, and the
discarded one may be the one they believed was in effect.

#### Scenario: A field belonging to another kind is rejected

- **WHEN** a machine declares a source of kind `preset` and also supplies a field belonging to the
  `oci` or `lxc` kind
- **THEN** rendering fails with a message naming the field and the kind it belongs to
