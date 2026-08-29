## Purpose

Defines how a machine's root filesystem is filled from the source it declares: that it happens
exactly once in the life of the volume, what each source kind requires, what must never be copied
in, and which failures must stop the machine rather than leave it with a subtly broken disk.

## ADDED Requirements

### Requirement: A machine's root filesystem is seeded from its source

Before a machine's guest starts, the chart SHALL fill the machine's rootfs volume with the contents
of the source that machine declares.

Until this happens the volume is empty, and an empty volume is not a root filesystem. The source is
a seed, not a runtime dependency: once the volume holds a filesystem, the machine's operating system
is that filesystem and nothing else.

#### Scenario: An empty volume is filled

- **WHEN** a machine's rootfs volume has never been seeded
- **THEN** the contents of its declared source are written to the volume before the guest container
  starts

#### Scenario: The seeded filesystem is a root filesystem

- **WHEN** seeding completes
- **THEN** the volume holds the source's own directory tree at its top level, not an archive, an
  image layer, or a subdirectory

### Requirement: Seeding happens exactly once per volume

Seeding SHALL be performed at most once for a given volume. Every later start of the machine SHALL
leave the volume's contents untouched, whatever the machine's values then say.

The decision SHALL be made from a record kept on the volume itself, not from anything the chart, the
release or the cluster remembers, because the volume is the only thing that outlives them.

This is what makes the volume the source of truth: a machine that has been running for a year has
diverged from its source completely, and re-applying that source would destroy it.

#### Scenario: A restart does not re-seed

- **WHEN** a machine whose volume is already seeded is restarted, rescheduled to another node, or
  upgraded
- **THEN** the volume's contents are left exactly as the guest left them

#### Scenario: A changed source does not re-seed

- **WHEN** a machine's declared source is changed to a different image or template after its volume
  has been seeded
- **THEN** the volume is not re-seeded and the machine keeps the filesystem it has

#### Scenario: An interrupted seeding does not leave a half-filled volume in service

- **WHEN** seeding is interrupted before it completes
- **THEN** the volume is not recorded as seeded, and the next start seeds it again rather than
  starting a guest on a partial filesystem

### Requirement: The volume records what it was seeded from

Seeding SHALL write a record to the volume stating what the volume was filled from, when, by which
chart version, and which claim it was filled into. The record SHALL carry its own schema version.

Without it, "what is actually on this disk" is unanswerable the moment the values change, and no
later re-seeding policy can be offered at all.

#### Scenario: The record identifies the source

- **WHEN** a volume has been seeded
- **THEN** its record names the source it was seeded from precisely enough to distinguish it from a
  different source of the same kind

#### Scenario: The record is readable by a later version

- **WHEN** a record written by an earlier version of the chart is read
- **THEN** its schema version is available to decide how to interpret it

### Requirement: An OCI source is copied from the image itself

For a machine whose source is an OCI image, the chart SHALL fill the volume from that image's own
filesystem, preserving ownership, permissions, file capabilities, extended attributes and sparseness.

An ordinary recursive copy is not sufficient. A root filesystem whose `security.capability`
attributes were dropped looks correct and fails later in ways nothing explains — on a modern Debian,
an unprivileged `ping` fails with a permission error and no log says why.

#### Scenario: An OCI-sourced volume is filled

- **WHEN** a machine declares an OCI source and its volume is unseeded
- **THEN** the volume is filled from that image

#### Scenario: File capabilities survive the copy

- **WHEN** the source contains a file carrying a capability attribute
- **THEN** that file carries the same attribute on the seeded volume

#### Scenario: The image cannot copy itself faithfully

- **WHEN** the source image provides no tool able to preserve extended attributes
- **THEN** seeding fails with a message naming what is missing and what the user can use instead,
  and the volume is left unseeded

### Requirement: An LXC template is verified before it is unpacked

For a machine whose source is an LXC template, the chart SHALL fetch the tarball, verify it against
the checksum the machine declares, and unpack it only if the checksum matches.

#### Scenario: A matching checksum is unpacked

- **WHEN** the fetched tarball's checksum matches the declared one
- **THEN** it is unpacked into the volume

#### Scenario: A mismatched checksum is refused

- **WHEN** the fetched tarball's checksum does not match the declared one
- **THEN** nothing is unpacked, the volume is left unseeded, and the failure states that the
  downloaded bytes are not the ones the machine asked for

#### Scenario: An unreachable template is a failure, not an empty machine

- **WHEN** the tarball cannot be fetched
- **THEN** seeding fails with a message naming the URL and the transport error, and no guest is
  started on the empty volume

### Requirement: A template archive is sanity-checked before extraction

Before extracting a template, the chart SHALL reject an archive that does not look like a root
filesystem, and SHALL do so before writing anything to the volume.

The archive is built by someone else and extracted into what becomes a privileged machine's root
filesystem. A checksum establishes that the bytes are the ones the user named; it does not establish
that the user named a root filesystem.

#### Scenario: An archive that is not a root filesystem is rejected

- **WHEN** the archive contains no system directory a root filesystem must have, or contains too few
  entries to be one
- **THEN** extraction does not begin and the failure says what the archive looked like instead

#### Scenario: A multi-part archive is rejected

- **WHEN** the archive is one volume of a multi-volume set
- **THEN** extraction does not begin, because the result would be a truncated filesystem that
  extracts without error

### Requirement: Runtime state is never seeded

Seeding SHALL NOT populate the directories the kernel, the runtime and the init system own at boot.
Device nodes in particular SHALL NOT be copied from the source.

Anything left on the volume in those paths is stale by definition and reappears at every boot. A
device node copied into the volume is at best ignored and at worst wrong, and creating one is
impossible in a user-namespaced pod anyway.

#### Scenario: Device nodes are not copied

- **WHEN** the source contains device nodes
- **THEN** the seeded volume contains none of them

#### Scenario: Runtime directories are present but empty

- **WHEN** seeding completes
- **THEN** the directories the guest's init expects to mount over exist on the volume and are empty

### Requirement: Seeding failure stops the machine

Any failure during seeding SHALL prevent the guest from starting, and SHALL report the cause in a
form the user can act on.

A guest started on an empty or partial root filesystem produces a failure far away from its cause,
and the first thing a user does is look at the guest, which has nothing to tell them.

#### Scenario: A failed seeding does not start a guest

- **WHEN** seeding fails for any reason
- **THEN** the guest container does not start

#### Scenario: The cause is visible where a user will look

- **WHEN** seeding fails
- **THEN** the reason is in the logs of the step that failed, naming the source and what went wrong
