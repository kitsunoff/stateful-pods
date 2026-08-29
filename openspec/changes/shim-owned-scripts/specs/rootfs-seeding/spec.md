## ADDED Requirements

### Requirement: An OCI source is fetched and unpacked by the chart's own image

For a machine whose source is an OCI image, the chart SHALL fetch that image from its registry and
unpack its flattened filesystem into the volume, using its own image and its own tools, preserving
ownership, permissions, file capabilities, extended attributes and sparseness. The chart SHALL NOT
execute anything from the source, and SHALL place no requirement on what the source image contains
beyond being an OCI image with a root filesystem.

An ordinary recursive copy is not sufficient. A root filesystem whose `security.capability`
attributes were dropped looks correct and fails later in ways nothing explains — on a modern Debian,
an unprivileged `ping` fails with a permission error and no log says why.

Doing the fetch from the chart's own image is what makes the source a seed rather than a runtime
dependency, and what makes an image with no shell and no archiver a usable source.

#### Scenario: An OCI-sourced volume is filled

- **WHEN** a machine declares an OCI source and its volume is unseeded
- **THEN** the volume is filled from that image

#### Scenario: File capabilities survive the copy

- **WHEN** the source contains a file carrying a capability attribute
- **THEN** that file carries the same attribute on the seeded volume

#### Scenario: A source that carries no userland is still usable

- **WHEN** a machine declares an OCI source that provides no shell and no archiver
- **THEN** its volume is seeded from that image all the same

#### Scenario: Layer removals are honoured

- **WHEN** the source image's layers delete or replace a path added by an earlier layer
- **THEN** the seeded volume reflects the image's final filesystem, not the union of its layers

#### Scenario: An unreachable image is a failure, not an empty machine

- **WHEN** the source image cannot be fetched
- **THEN** seeding fails with a message naming the reference and what went wrong, and no guest is
  started on the empty volume

### Requirement: A seeded filesystem matches the architecture it will run on

Seeding SHALL produce a root filesystem built for the architecture of the node the machine is
running on. Where a source can offer more than one, the chart SHALL select by the node's own
architecture rather than by a fixed default.

A rootfs for the wrong architecture is seeded without error and produces a machine that cannot
execute its own init. The failure appears at boot, far from its cause, and looks like a corrupt
guest.

#### Scenario: A multi-architecture source seeds the node's architecture

- **WHEN** a machine's source offers builds for several architectures
- **THEN** the volume is seeded with the build for the architecture of the node the machine runs on

#### Scenario: A source with no build for the node is refused

- **WHEN** a machine's source offers no build for the node's architecture
- **THEN** seeding fails with a message naming the architecture that was required and what the
  source offers, and the volume is left unseeded

### Requirement: The source is not contacted once the volume is seeded

Once a machine's volume has been seeded, no later start of that machine SHALL contact the source.
The record on the volume SHALL be read before any network request is made.

The volume is the machine's operating system from the moment it is filled. A machine that still
reached for its source on every start would depend, for its whole life, on a reference someone else
controls and on that reference continuing to resolve, and would pay for a full transfer of its
operating system every time it was rescheduled onto a node that had not seen it.

#### Scenario: A restart makes no request to the source

- **WHEN** a machine whose volume is already seeded is restarted or rescheduled
- **THEN** its source is not fetched, downloaded or otherwise contacted

#### Scenario: A source that stops resolving does not stop the machine

- **WHEN** a machine's declared source becomes unavailable after its volume was seeded
- **THEN** the machine continues to start normally

### Requirement: A private source is reached with credentials the machine names

A machine SHALL be able to name credentials for reaching a source that requires authentication, as a
reference to a Secret in the release's namespace. Those credentials SHALL be available only to the
step that seeds the volume, and SHALL NOT appear in any message that step produces.

Because the chart performs the fetch itself, the credentials the cluster would have supplied for an
image the kubelet pulls are not available to it, and the machine has to say which ones to use.

#### Scenario: A named credential is used

- **WHEN** a machine names a pull secret and its volume is unseeded
- **THEN** the source is fetched with those credentials

#### Scenario: No credential named means an anonymous fetch

- **WHEN** a machine names no pull secret
- **THEN** the source is fetched without credentials

#### Scenario: A rejected credential fails with a usable message

- **WHEN** the registry rejects the credentials
- **THEN** seeding fails naming the reference and the secret that was used, the message contains no
  part of the credentials themselves, and the volume is left unseeded

#### Scenario: The credentials reach only the seeding step

- **WHEN** a machine that names a pull secret is rendered
- **THEN** no container other than the one that seeds the volume is given access to that Secret

## REMOVED Requirements

### Requirement: An OCI source is copied from the image itself

**Reason**: The seeding step no longer runs inside the machine's source image, so the source is no
longer required to carry a shell and an archiver able to preserve extended attributes, and the
probe that refused such an image no longer has anything to refuse. The behaviour that mattered —
a faithful copy preserving ownership, permissions, capabilities, extended attributes and
sparseness — is carried over unchanged by "An OCI source is fetched and unpacked by the chart's own
image".

**Migration**: None for an existing machine: a volume that has already been seeded is never
re-seeded, and nothing on it changes. A machine whose source was rejected before for providing no
usable archiver — an Alpine- or distroless-based image, for example — is now accepted, so a values
file that worked around this by using an `lxc` source can be simplified when the machine is next
created from scratch.
