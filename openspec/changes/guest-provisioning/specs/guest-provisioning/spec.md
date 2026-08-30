## Purpose

Defines how a machine is given the users, keys, packages and commands it needs to be usable —
which mechanism carries them into the guest, how the material is supplied without putting it in a
values file, when a change to it is re-applied, and why an image that cannot run the chosen
mechanism must stop the machine rather than boot one nobody can reach.

## ADDED Requirements

### Requirement: A machine declares how it is provisioned

Each machine SHALL declare a provisioning backend. `cloud-init` and `native` SHALL be accepted, and
`cloud-init` SHALL be the default when a machine declares none.

The default is the mechanism people actually want, and the one the images the audience reaches for
already carry. `native` asks nothing of the image and is what a machine on an image without
cloud-init must name.

The backend SHALL never be chosen for the machine by inspecting the image. Behaviour that depends
on what an image happens to contain is behaviour nobody can predict from the values file.

#### Scenario: A machine that declares nothing is provisioned by cloud-init

- **WHEN** a machine declares no provisioning backend
- **THEN** it is provisioned by cloud-init, exactly as if it had named it

#### Scenario: A machine can ask for no guest cooperation

- **WHEN** a machine declares the `native` backend
- **THEN** nothing is written into the guest beyond the files the chart already maintains, and the
  machine boots on any image

#### Scenario: An unrecognised backend is refused

- **WHEN** a machine names a backend the chart does not implement
- **THEN** rendering fails and names the backends that exist

### Requirement: An image that cannot run the chosen backend fails the machine

Before a machine boots, the chart SHALL establish that the machine's own root filesystem can
actually run the backend the machine named, and SHALL fail the pod with an explicit message naming
the `native` backend as the fix when it cannot.

This is the most important requirement in this capability. On an image without cloud-init a seed is
written, nothing reads it, and the machine boots with no users, no keys and no way in, with nothing
in the logs to explain it. That failure looks exactly like a successful install, which makes it the
worst outcome available to this chart.

Establishing that the backend can run means more than finding the program. A distribution may ship
cloud-init installed and switched off, in which case a seed alone changes nothing.

#### Scenario: A machine on an image with no cloud-init does not boot silently

- **WHEN** a machine selects the cloud-init backend and its root filesystem cannot run cloud-init
- **THEN** the pod fails before the machine starts, and the message says what was looked for and
  that `guest.provisioning: native` is the fix

#### Scenario: The check never switches backend on the machine's behalf

- **WHEN** the chosen backend cannot run
- **THEN** the chart fails rather than provisioning by some other means

#### Scenario: The message describes a fix that actually works

- **WHEN** the message tells a user how to recover
- **THEN** it names every step required, including replacing the machine's pod — changing the value
  alone leaves the failing pod in place, because a StatefulSet does not replace a pod that never
  became ready

#### Scenario: A failed check leaves nothing behind

- **WHEN** the check refuses an image
- **THEN** nothing has been written into the machine, so a later start on a backend that can run
  finds the root filesystem as its source left it

#### Scenario: An image that ships the backend disabled is not treated as able to run it

- **WHEN** a root filesystem carries cloud-init together with the marker its distribution uses to
  keep it from running
- **THEN** provisioning either makes cloud-init able to run or fails, and never leaves a seed that
  nothing will read

### Requirement: Every provisioning input can be supplied inline or by reference

Every provisioning input SHALL accept either a literal value or a reference to a key in a Secret or
a ConfigMap in the release's namespace. No input SHALL be available in only one of the two forms,
and the two forms SHALL be selectable per input rather than per machine.

Inline keeps a lab machine to one readable file. A reference is what makes the chart usable in a
repository, where a password or a private key must never appear in a values file or in the Helm
release. ConfigMap is accepted wherever Secret is, because forcing a list of packages into a Secret
is friction with no benefit.

#### Scenario: An input given inline reaches the machine

- **WHEN** an input is given as a literal value
- **THEN** its content reaches the machine unchanged

#### Scenario: An input given by reference reaches the machine

- **WHEN** an input names a key in a Secret or ConfigMap
- **THEN** its content reaches the machine unchanged, and the value never appears in the release

#### Scenario: The two forms mix within one machine

- **WHEN** one machine supplies some inputs inline and others by reference
- **THEN** both are honoured

### Requirement: Provisioning material never reaches the guest container

Provisioning material SHALL be made available only to the step that writes it into the machine, and
SHALL NOT be mounted into the container a user execs into.

The guest container is the machine. Material mounted there would be readable from inside the
machine for its whole life through a path the machine never asked for, and would survive in the
pod's own filesystem rather than in the machine's.

#### Scenario: The guest cannot read the material through the pod

- **WHEN** a machine is provisioned from a referenced Secret
- **THEN** no mount of that Secret exists in the guest container

### Requirement: The cloud-init backend seeds the machine and gives its files back

The cloud-init backend SHALL place a NoCloud seed inside the machine's own root filesystem, and
SHALL configure cloud-init so that it does not manage the machine's host name, host table, resolver
or network interfaces.

A pod's addressing belongs to the cluster's CNI, and its host name and resolver belong to the
kubelet. cloud-init writing an interface configuration would take away the address the pod was
given. The other three files are already maintained on every boot by the chart, and two owners of
one file means whichever ran last wins.

#### Scenario: A machine reads the configuration it was given

- **WHEN** a machine selects the cloud-init backend and is given user-data
- **THEN** cloud-init inside the machine applies it on the next boot

#### Scenario: Provisioning does not take the machine's address away

- **WHEN** a machine is provisioned by cloud-init
- **THEN** its network interface is still the one the cluster configured, and it is still reachable

#### Scenario: Provisioning does not fight the files the chart maintains

- **WHEN** a machine is provisioned by cloud-init
- **THEN** its host name, host table and resolver are the ones the chart writes on every boot

#### Scenario: Which datasource a machine uses does not depend on its surroundings

- **WHEN** a machine is provisioned by cloud-init
- **THEN** the datasource it uses is the seed the chart wrote, and is not chosen by probing what
  happens to be reachable from the node at that moment

#### Scenario: The machine is provisioned whatever init system it runs

- **WHEN** a machine's root filesystem starts cloud-init through something other than systemd
- **THEN** it is provisioned in the same way and from the same seed

### Requirement: A changed configuration is re-applied and an unchanged one is not

The identity cloud-init keys its per-instance work on SHALL be derived from the provisioning
material that was actually placed in the machine, together with the machine's own identity of
namespace, release and machine name.

Deriving it from the material makes a configuration change re-apply on the next start, with no agent
and no annotation. Deriving it also from the machine's identity means a volume restored under
another name is a different machine and regenerates what must not be shared, while a volume restored
into the machine it came from is the same machine and keeps it.

#### Scenario: Changing the configuration re-applies it

- **WHEN** a machine's provisioning material changes and the machine restarts
- **THEN** cloud-init applies the new configuration

#### Scenario: Restarting with no change re-applies nothing

- **WHEN** a machine restarts with its provisioning material unchanged
- **THEN** cloud-init does not repeat the work it already did

#### Scenario: A clone into another release is a different instance

- **WHEN** a machine's volume is restored under a different namespace, release or machine name
- **THEN** it is a new instance to cloud-init, so per-instance work is done again for it

#### Scenario: The identity does not depend on where the material came from

- **WHEN** the same content is supplied inline by one machine and by reference by another
- **THEN** both machines derive the same identity from it

### Requirement: A raw provisioning file replaces the structured values for that file

Where both a raw file and structured shortcuts for the same file are supplied, the raw file SHALL be
used and the structured shortcuts for that file SHALL be ignored entirely. The two SHALL NOT be
merged, and the release SHALL say that the shadowing happened.

This is the reference implementation's own rule for the same choice. Merging two configuration
documents is a misfeature waiting to happen, and per-file replacement is the only rule a user can
predict. Silently discarding half a values file is a bad surprise, which is why it is reported.

#### Scenario: Raw user-data wins over the structured shortcuts

- **WHEN** a machine supplies both raw user-data and structured shortcuts for user-data
- **THEN** the machine is configured from the raw user-data alone

#### Scenario: Shadowing is reported

- **WHEN** a raw file shadows structured values
- **THEN** the release says which values were ignored and why

#### Scenario: Shadowing is per file

- **WHEN** a machine supplies raw user-data and a structured value belonging to another file
- **THEN** the other file is still generated from its structured value

### Requirement: Provisioning is applied on every start, from what the values now say

Provisioning SHALL be applied on every pod start rather than once at seeding, and SHALL reflect what
the machine's values say at that start.

The root filesystem is seeded once and never again; provisioning is not the same lifecycle. A
machine whose key rotated must be able to take the new one by restarting, and the two must not share
a marker.

#### Scenario: A machine started again is provisioned again

- **WHEN** a machine is restarted
- **THEN** its provisioning material is written again from the current values

#### Scenario: Provisioning does not re-seed the root filesystem

- **WHEN** a machine is provisioned on a start after its first
- **THEN** nothing on the volume outside what provisioning owns is replaced
