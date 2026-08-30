## MODIFIED Requirements

### Requirement: The `privileged` mode is rendered plainly

In `privileged` mode the guest container SHALL be granted an explicit, enumerated set of
capabilities, without additionally opting into a user namespace. The chart SHALL NOT instruct the
runtime to suspend the policy it applies to containers.

The set SHALL include what the guest needs to mount the machine's filesystems and change its root,
and SHALL exclude the capabilities that let a container load kernel code, perform raw I/O, alter the
host's clock, or override the host's mandatory access control. Those exclusions are the ones the
reference implementation of this kind of container has always made, and none of them is needed to
start an operating system.

The blanket privileged flag is not a capability set. It also unmasks kernel interfaces, exposes the
node's devices, and causes the runtime to withhold the syscall filter and access-control profile a
container would otherwise run under — including a filter the machine's own values ask for. A machine
that needs privilege to mount its root filesystem does not need any of that, and this mode runs on
the clusters least able to absorb it.

The mode keeps its name because the name describes the relationship to the host, which is unchanged:
the machine's root is the node's root, and a capability the guest holds is a capability on the node.

#### Scenario: A privileged pod is rendered

- **WHEN** a machine's security mode is `privileged`
- **THEN** the guest container is granted the mode's named capability set, no container is marked as
  suspending the runtime's policy, and the pod does not opt out of the host user namespace

#### Scenario: The excluded capabilities are absent

- **WHEN** a machine is rendered in `privileged` mode
- **THEN** the capabilities that permit loading kernel code, raw I/O, changing the host's clock and
  overriding the host's mandatory access control are not among those granted

#### Scenario: The mode can still be confined

- **WHEN** a machine in `privileged` mode names a syscall filter
- **THEN** nothing in the rendered posture prevents the runtime from applying it

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
- **THEN** the guest container is the only container granted that mode's capability set

#### Scenario: The guest container alone is granted the mode's capability

- **WHEN** a machine is rendered in the user-namespace mode
- **THEN** the guest container is the only container granted the capability that mode names

#### Scenario: Preparation steps are ordinary containers

- **WHEN** a machine is rendered in either mode
- **THEN** no container that runs before the guest is marked privileged, adds a capability, or
  allows privilege escalation
