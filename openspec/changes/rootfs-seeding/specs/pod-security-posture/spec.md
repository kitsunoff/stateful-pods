## ADDED Requirements

### Requirement: Only the guest container receives the privilege the mode names

The privilege a machine's security mode names SHALL be granted to the guest container alone. Every
other container the chart runs for that machine SHALL receive no capability, no privileged flag and
no privilege escalation beyond what an ordinary container gets by default.

The mode exists because mounting a filesystem and changing the root require privilege. Preparing the
contents of a volume does not: writing files with their ownership and attributes intact is something
an ordinary container already does. Granting the preparation steps the same privilege as the guest
would widen the machine's exposure well past what its values say, and for no reason.

Running as the container's own root user is not privilege in this sense — it is what writing another
system's file ownership requires, and in the user-namespaced mode it is not root on the node at all.

#### Scenario: The guest container alone is privileged

- **WHEN** a machine is rendered in the privileged mode
- **THEN** the guest container is the only container marked privileged

#### Scenario: The guest container alone is granted the mode's capability

- **WHEN** a machine is rendered in the user-namespace mode
- **THEN** the guest container is the only container granted the capability that mode names

#### Scenario: Preparation steps are ordinary containers

- **WHEN** a machine is rendered in either mode
- **THEN** no container that runs before the guest is marked privileged, adds a capability, or
  allows privilege escalation
