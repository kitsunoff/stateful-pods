## ADDED Requirements

### Requirement: A machine's network inputs are checked while the chart renders

The chart SHALL reject, while rendering and with a message naming the input, a network block that
is not a map, a port collection that is not a map, a port entry that is not a map, a port name the
Kubernetes API would reject, a missing or non-integer port number, a port number outside 1–65535, a
protocol that is not `TCP`, `UDP` or `SCTP`, a key under a port entry that is not an input, a key
under the network block that is not an input, and two entries declaring the same number and
protocol.

Every one of these renders a manifest the API server rejects on apply, or — in the case of the
duplicate — one it rejects with a message about a field index rather than about a machine. The
chart's own refusals name the machine, the input and the rule, and they accumulate with the rest of
the semantic stage so that fixing one does not merely reveal the next.

#### Scenario: A port name the API would reject is refused

- **WHEN** a machine declares a port whose name is longer than fifteen characters, or contains a
  character outside lowercase alphanumerics and hyphens, or contains no letter at all
- **THEN** rendering fails, naming the port and stating the rule

#### Scenario: A port number outside the valid range is refused

- **WHEN** a machine declares a port number that is not an integer between 1 and 65535
- **THEN** rendering fails, naming the port

#### Scenario: An unknown protocol is refused

- **WHEN** a machine declares a protocol other than `TCP`, `UDP` or `SCTP`
- **THEN** rendering fails, listing the protocols that are accepted

#### Scenario: A duplicate port and protocol is refused

- **WHEN** two entries declare the same number with the same protocol
- **THEN** rendering fails, naming both entries

#### Scenario: The same number on two protocols is accepted

- **WHEN** two entries declare the same number with different protocols
- **THEN** both are rendered

#### Scenario: An unknown key is refused rather than ignored

- **WHEN** a machine declares a key under the network block, or under one port entry, that the
  chart does not accept
- **THEN** rendering fails and lists the keys that are accepted

#### Scenario: An unknown ingress posture is refused

- **WHEN** a machine names an ingress posture other than `any` or `declared`
- **THEN** rendering fails, listing the postures that are accepted and what each one renders
