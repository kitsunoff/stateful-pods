## MODIFIED Requirements

### Requirement: Machines are declared as a keyed map

The chart SHALL accept machines as a map keyed by machine name, rather than as flat single-machine
values or as a list. The chart SHALL NOT expose a `replicas` input at any level.

A release SHALL be able to hold more than one machine. The count of entries SHALL never on its own
be a reason to refuse a map.

#### Scenario: A machine is declared by name

- **WHEN** values declare `machines.web` with the inputs a machine requires
- **THEN** the chart renders the objects for a machine identified as `web`

#### Scenario: Several machines are declared in one release

- **WHEN** values declare `machines.web` and `machines.db`
- **THEN** the chart renders the objects for both

#### Scenario: Replica scaling is not offered

- **WHEN** a user searches the chart's values for a way to run several copies of one machine
- **THEN** no `replicas` input exists at the release level or inside a machine entry

## ADDED Requirements

### Requirement: Machines in one release share nothing but the release

No object rendered for one machine SHALL be shared with, or named the same as, an object rendered
for another machine in the same release. A change to one machine's values SHALL NOT replace another
machine's pod.

This is what makes several machines in a release safe rather than merely possible. Every helper the
chart has takes an explicit machine context and reads no global for it, precisely so that a value
belonging to one machine can never reach another — and a helper that reached for "the only machine"
would be correct until the day a release had two.

A machine's declared volumes are the one place two machines meet by name: a volume claim template is
named for the volume rather than for the machine, so two machines may each declare `data`. They are
still two volumes, because the controller binds a claim per instance.

#### Scenario: No object name is shared

- **WHEN** a release declares two machines, each with ports, an ingress posture, an egress policy, a
  declared volume and a script
- **THEN** every object rendered carries a name no other object in that release has

#### Scenario: A machine's inputs reach only its own objects

- **WHEN** two machines in one release declare different volume sizes
- **THEN** each machine's claim templates request that machine's own sizes

#### Scenario: Two machines may declare a volume of the same name

- **WHEN** two machines in one release each declare a volume called `data`
- **THEN** each gets a volume of its own, bound to its own instance

#### Scenario: One machine's change does not disturb another

- **WHEN** one machine's values change and the release is upgraded
- **THEN** the other machines' pods are not replaced
