## ADDED Requirements

### Requirement: A machine's name resolves while it is still booting

A machine SHALL be reachable at its stable name from the moment its pod exists, including while its
operating system is still starting and before it reports itself ready.

An operating system takes time to boot, and the readiness signal that gates a Service endpoint would
otherwise make the machine unresolvable for exactly the period in which someone is most likely to be
looking for it. A machine is a pet with an address, not a member of a load-balanced pool whose
traffic must be withheld until it is healthy.

#### Scenario: A booting machine can be reached

- **WHEN** a machine's operating system is still starting
- **THEN** its stable in-cluster name still resolves to it

#### Scenario: The name does not disappear when the machine is unwell

- **WHEN** a machine stops reporting itself ready
- **THEN** its stable name continues to resolve, so that it can be reached and inspected
