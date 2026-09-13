## ADDED Requirements

### Requirement: The image carries a packet-filter client

The shim image SHALL carry `iptables` and `ip6tables`, because the step that programs a machine's
network namespace runs this image like every other container the chart renders.

#### Scenario: Both clients are present and executable

- **WHEN** the shim image is built
- **THEN** `iptables` and `ip6tables` are on its path and report a version
