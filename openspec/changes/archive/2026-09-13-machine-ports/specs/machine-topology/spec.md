## ADDED Requirements

### Requirement: A machine that asks for its ports to be enforced renders one policy object

Where a machine asks that only its declared ports be reachable, the chart SHALL render exactly one
NetworkPolicy for it, named with the machine's own object name and selecting the machine's pod on
the same labels its StatefulSet selects on.

One object per machine, named like every other object a machine gets, so that a release with two
machines has two policies that can be read, diffed and deleted independently. Selecting on the
machine's own selector labels rather than on anything broader keeps a policy from reaching a
neighbour that happens to share a release.

#### Scenario: The policy is named like the machine's other objects

- **WHEN** release `lab` declares machine `web` and asks for its ports to be enforced
- **THEN** a NetworkPolicy named `lab-web` is rendered, selecting the same labels the StatefulSet
  selects on

#### Scenario: No policy without the request

- **WHEN** a machine does not ask for its ports to be enforced
- **THEN** no NetworkPolicy is rendered, whether or not it declares ports
