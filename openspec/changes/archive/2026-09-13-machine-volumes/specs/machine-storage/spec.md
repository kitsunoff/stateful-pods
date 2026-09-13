## Purpose

Defines the storage a machine has beside its root filesystem: how further volumes are declared,
where they appear inside the machine, which of them the chart provisions and which it merely
mounts, and what a machine's storage layout guarantees about the names and the lifetimes of the
claims behind it.

The root filesystem itself is not described here. It is the machine, it is seeded, and it is
specified under `rootfs-seeding` and `machine-topology`.

## ADDED Requirements

### Requirement: A machine declares further volumes

A machine SHALL be able to declare volumes beside its root filesystem, as a map keyed by the name
each volume is known by. Each entry SHALL name the path it is mounted at inside the machine.

A machine that declares no volumes SHALL render exactly what it rendered before this capability
existed.

#### Scenario: A volume is declared

- **WHEN** a machine declares a volume named `data` mounted at `/var/lib/data`
- **THEN** the machine's guest container mounts that volume so that it appears at `/var/lib/data`
  inside the machine

#### Scenario: Declaring nothing changes nothing

- **WHEN** a machine declares no volumes
- **THEN** its pod carries exactly the volumes and mounts it carried without the input

### Requirement: A volume is either provisioned by the chart or already exists

Each declared volume SHALL name exactly one of a size, which the chart provisions a claim for, or
an existing PersistentVolumeClaim, which the chart mounts and does not create. Naming both, or
neither, SHALL be refused while the chart renders.

They are not alternatives to one another: one creates storage and one consumes somebody else's.
Choosing between them on the user's behalf would either provision a volume nobody asked for or
silently ignore a size the user believed was in effect.

#### Scenario: A sized volume is provisioned

- **WHEN** a machine declares a volume with a size
- **THEN** the chart renders a volume claim template for it on the machine's StatefulSet

#### Scenario: An existing claim is mounted and not created

- **WHEN** a machine declares a volume naming an existing claim
- **THEN** the chart renders a pod volume referring to that claim and no claim template for it

#### Scenario: Naming both is refused

- **WHEN** a machine declares a volume naming both a size and an existing claim
- **THEN** rendering fails, naming the volume and both inputs

### Requirement: A provisioned volume has the same durability as the root filesystem

A volume the chart provisions SHALL be a volume claim template on the machine's StatefulSet, single
writer, and SHALL be retained when the release is uninstalled and when the StatefulSet is deleted or
scaled.

A machine's data is the reason the machine is a pet. Deleting it as a side effect of uninstalling a
release would make an ordinary mistake unrecoverable, and that argument does not weaken for a volume
that is not the root filesystem.

#### Scenario: A declared volume is single-writer

- **WHEN** the chart provisions a volume for a machine
- **THEN** its access modes are exactly `["ReadWriteOnce"]`

#### Scenario: Uninstalling the release leaves the volume

- **WHEN** a release running a machine with declared volumes is uninstalled
- **THEN** the claims for those volumes still exist afterwards

### Requirement: A provisioned volume takes its own class and its own restore source

Each provisioned volume SHALL accept its own storage class and its own volume snapshot to be
restored from, independently of the root filesystem and of every other volume.

Placing a database's data on fast storage while its operating system stays on the default class is
the reason to have a second volume at all, and restoring one volume from a snapshot without
disturbing another is the reason to keep them apart.

#### Scenario: A volume names its own class

- **WHEN** a machine declares one volume with a storage class and another without
- **THEN** each claim template carries the class its own entry named, and the one that named none
  omits the field entirely

#### Scenario: A volume is restored on its own

- **WHEN** a machine declares a volume naming a snapshot to restore from
- **THEN** that claim template requests the snapshot as its data source, and no other claim template
  is affected

### Requirement: A volume's name is permanent

The name a volume is declared under SHALL determine the name of the claim behind it. Renaming a
volume SHALL NOT move its data.

This is the same guarantee, and the same trap, as the machine's own name. It is stated because the
consequence is invisible at the moment it is chosen and irreversible afterwards: the old claim is
orphaned and a new empty one is provisioned in its place.

The chart SHALL refuse a volume name that would collide with a volume the pod already has.

#### Scenario: The claim is named for the volume

- **WHEN** release `lab` declares machine `web` with a volume named `data`
- **THEN** the claim bound to the machine is named from `data` and the machine's instance, and does
  not change when anything else about the machine does

#### Scenario: A colliding name is refused

- **WHEN** a machine declares a volume under a name the pod already uses for a volume of its own
- **THEN** rendering fails, naming the volume and what already holds the name

### Requirement: A volume may not be mounted where the boot sequence mounts

The chart SHALL refuse a mount path that is, or is under, a path the boot sequence mounts over
inside the machine, and SHALL refuse the machine's root and the directory the chart keeps its own
state in.

The boot sequence mounts the kernel filesystems and the machine's temporary filesystems after the
pod's volumes are in place. A volume underneath one of them would be provisioned, bound, mounted and
then covered: present, empty on every start, and with nothing anywhere to say why.

#### Scenario: A kernel filesystem path is refused

- **WHEN** a machine declares a volume mounted at or under a path the boot sequence mounts over
- **THEN** rendering fails, naming the path and saying that the boot sequence mounts over it

#### Scenario: The machine's root is refused

- **WHEN** a machine declares a volume mounted at `/`
- **THEN** rendering fails, and the message points at the root filesystem inputs instead

#### Scenario: Two volumes at one path are refused

- **WHEN** two declared volumes name the same mount path
- **THEN** rendering fails, naming both

### Requirement: A declared volume reaches the machine and nothing else

Declared volumes SHALL be mounted into the guest container only. No step that runs before the
machine starts SHALL mount one.

The preparation steps fill and configure a root filesystem. A machine's data volume is not theirs to
see, and mounting it into the step that seeds would put it inside the directory that step is
entitled to wipe when a previous attempt was interrupted.

#### Scenario: The preparation steps do not mount a declared volume

- **WHEN** a machine declares volumes
- **THEN** no init container mounts any of them

#### Scenario: The machine sees the volume at the declared path

- **WHEN** a machine with a declared volume has booted
- **THEN** the declared path inside the machine is a mount point on a different filesystem from the
  machine's root
