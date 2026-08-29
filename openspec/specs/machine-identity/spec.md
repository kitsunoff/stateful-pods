## Purpose

Defines the identity a machine must not inherit — neither from the image it was seeded from nor from
the machine whose snapshot it was restored from — so that two machines are never the same machine.

## Requirements

### Requirement: A seeded machine does not inherit the image's identity

A machine SHALL NOT take its identity from the source it was seeded from. Any identity the source
carries SHALL be cleared when the volume is seeded, so that the machine's init system generates a
fresh one at first boot.

An image is a template used by everyone who pulls it. An identifier baked into it is shared by every
machine seeded from it, and things that key on it — logging backends, DHCP leases, cluster
memberships — will treat those machines as one.

#### Scenario: A machine identifier from the image is not kept

- **WHEN** a volume is seeded from a source that carries a machine identifier
- **THEN** the seeded volume carries no identifier inherited from that source

#### Scenario: Two machines seeded from the same source differ

- **WHEN** two machines are seeded from the same source
- **THEN** neither takes an identity from it, so nothing about the source makes them the same machine

### Requirement: A machine restored from a snapshot is recognised as a clone

The chart SHALL detect that a volume's contents were seeded for a different machine than the one
they now serve, and SHALL treat such a volume as a clone: its inherited identity is cleared, while
everything else on the volume is left untouched.

A machine here is identified by the namespace, release and machine name it is declared under — the
same triple its objects are named from. Restoring a snapshot back into the machine it was taken from
is a restore and keeps that machine's identity; restoring it under a different name is a clone and
must not.

Restoring a snapshot is how this project offers backup, and it is also how a second machine gets
made. Without detection the clone silently shares the original's identity; with it, the clone keeps
its data and loses only what must not be shared.

#### Scenario: A machine restored under a new name gets its own identity

- **WHEN** a machine's volume was created from a snapshot taken of a machine declared under a
  different namespace, release or machine name
- **THEN** the identity inherited from that machine is cleared before the guest starts

#### Scenario: A machine restored under its own name keeps its identity

- **WHEN** a machine's volume was created from a snapshot taken of that same machine
- **THEN** it is not treated as a clone and its identity is left alone

#### Scenario: A clone keeps its data

- **WHEN** a volume is detected as a clone
- **THEN** it is not re-seeded and nothing on it is removed beyond the inherited identity

#### Scenario: An ordinary restart is not a clone

- **WHEN** a machine restarts on the volume it was seeded into
- **THEN** it is not treated as a clone and nothing on the volume is touched
