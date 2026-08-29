## ADDED Requirements

### Requirement: The steps that run before the guest are confined by default

Every container the chart runs before the guest SHALL declare the container runtime's default
syscall filter.

Those containers unpack an archive, write files and record what they wrote. They mount nothing and
change no root, so nothing the default filter withholds is in their way. They also need no file to
be present on the node, which makes this the one part of the posture that can be tightened for
everybody without an operator doing anything first.

#### Scenario: The preparation steps declare the runtime's default filter

- **WHEN** a machine is rendered in either mode
- **THEN** every container that runs before the guest declares the runtime's default syscall filter

#### Scenario: The default filter does not depend on the machine's mode

- **WHEN** the same machine is rendered in each mode
- **THEN** the filter those containers declare is the same in both

### Requirement: A machine may be confined by a filter the cluster provides

A machine SHALL be able to name a syscall filter that the cluster makes available on its nodes, and
the chart SHALL apply it to the guest container. The chart SHALL NOT require such a filter, and
SHALL NOT ship one into the cluster itself.

The filter that would confine a machine has to permit an entire distribution's userland, including
the root change the guest container performs, so it is a denylist of the operations that would let a
machine leave its node — which is what the reference implementation of this kind of container has
always used. Such a file lives on the node, outside anything a chart can create, so naming one is
the most the chart can do.

#### Scenario: A named filter is applied to the machine

- **WHEN** a machine names a syscall filter the cluster provides
- **THEN** the guest container declares that filter

#### Scenario: The filter applies to the machine and to nothing else

- **WHEN** a machine names a syscall filter
- **THEN** no container other than the guest declares it

## MODIFIED Requirements

### Requirement: A mode grants nothing beyond what it names

The rendered security posture SHALL be a function of the named mode and of the machine's own inputs
alone. No capability, privilege escalation, host namespace or runtime class SHALL be added by any
other input, and the posture SHALL NOT vary with the cluster it is rendered against.

The posture includes the syscall filter each container runs under. The chart SHALL declare that
filter explicitly rather than leaving it to be supplied by the cluster, because a filter chosen by
the node's configuration is a posture the machine's values do not describe — and one such default
withholds the root change the guest performs, so the machine would not merely be confined
differently, it would not start.

Someone reviewing a machine's values must be able to tell exactly what privilege it runs with,
without also knowing which cluster it will land on.

#### Scenario: The same values render the same posture everywhere

- **WHEN** the same machine values are rendered against two different clusters
- **THEN** the resulting pod security fields are identical

#### Scenario: No unnamed privilege is granted

- **WHEN** any machine is rendered in `userns` mode
- **THEN** the manifest contains no privileged container, no allowed privilege escalation, and no
  capability beyond the one the mode requires

#### Scenario: The syscall filter is never left to the cluster

- **WHEN** any machine is rendered
- **THEN** every container it renders declares which syscall filter it runs under

#### Scenario: A cluster that filters by default does not change the machine

- **WHEN** a machine is run on a cluster whose nodes apply a default syscall filter to pods that
  declare none
- **THEN** the machine runs under the filter its own values name, and it starts
