## Purpose

Defines what each security mode renders onto a machine's pod, so that the privilege a machine runs
with is fully determined by the mode its values name and by nothing else.

## Requirements

### Requirement: The chart offers exactly two security modes

The chart SHALL support the modes `userns` and `privileged` and no others.

A third mode based on a container runtime installed by the cluster administrator was considered and
excluded from this version: its behaviour cannot be verified by the project today, and a mode that
is documented as working but never exercised is worse than a mode that does not exist.

#### Scenario: Only the supported modes are accepted

- **WHEN** a machine names a security mode
- **THEN** rendering succeeds only for `userns` or `privileged`

### Requirement: The `userns` mode runs the machine in a user namespace

In `userns` mode the pod SHALL run in its own user namespace, and the guest container SHALL be
granted the single capability it needs to build the machine's root filesystem, and no more.

The capability is scoped to the pod's own user namespace and is void on the host, which is what
makes this mode meaningfully different from running privileged.

#### Scenario: A user-namespaced pod is rendered

- **WHEN** a machine's security mode is `userns`
- **THEN** the pod opts out of the host user namespace, the guest container is granted only the
  capability required to mount filesystems and change the root, and no container is marked
  privileged

#### Scenario: Host namespaces are never shared in this mode

- **WHEN** a machine's security mode is `userns`
- **THEN** the pod does not share the host's network, IPC or PID namespaces

### Requirement: The `privileged` mode is rendered plainly

In `privileged` mode the guest container SHALL be marked privileged, without additionally opting
into a user namespace.

#### Scenario: A privileged pod is rendered

- **WHEN** a machine's security mode is `privileged`
- **THEN** the guest container is marked privileged and the pod does not opt out of the host user
  namespace

### Requirement: A mode grants nothing beyond what it names

The rendered security posture SHALL be a function of the named mode alone. No capability,
privilege escalation, host namespace or runtime class SHALL be added by any other input, and the
posture SHALL NOT vary with the cluster it is rendered against.

Someone reviewing a machine's values must be able to tell exactly what privilege it runs with,
without also knowing which cluster it will land on.

#### Scenario: The same values render the same posture everywhere

- **WHEN** the same machine values are rendered against two different clusters
- **THEN** the resulting pod security fields are identical

#### Scenario: No unnamed privilege is granted

- **WHEN** any machine is rendered in `userns` mode
- **THEN** the manifest contains no privileged container, no allowed privilege escalation, and no
  capability beyond the one the mode requires

### Requirement: Each machine chooses its own mode

The security mode SHALL be an input on the machine, not on the release, so that machines in a
future multi-machine release can differ.

A machine whose guest needs a full init system may require a different posture from a machine
running a single lightweight process, and that difference belongs to the machine.

#### Scenario: The mode is read from the machine

- **WHEN** a machine declares a security mode
- **THEN** that mode determines the posture of that machine's pod, and the values path that carries
  it is part of the machine's own configuration

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
