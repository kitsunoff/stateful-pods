## Purpose

Defines how a machine is given the users, keys, packages and commands it needs to be usable —
which mechanism carries them into the guest, how the material is supplied without putting it in a
values file, when a change to it is re-applied, and why an image that cannot run the chosen
mechanism must stop the machine rather than boot one nobody can reach.

## Requirements

### Requirement: A machine declares how it is provisioned

Each machine SHALL declare a provisioning backend. `cloud-init` and `exec` SHALL be accepted, and
`cloud-init` SHALL be the default when a machine declares none. No other backend SHALL be accepted,
and none SHALL be named in the documentation as forthcoming.

The two are chosen for what they do not ask for. `cloud-init` needs cloud-init in the image and says
so loudly when it is absent, but asks nothing of the init system: a systemd unit and an OpenRC script
are both recognised. `exec` asks for a shell and nothing else. Between them they serve every image
this project ships a name for, and neither is tied to one init system — which is the property a third
backend built on `/run/host/credentials` could not have had, because that mechanism is systemd's.

`native` SHALL be refused, with a message saying that it was renamed to `exec` and that `exec` with
no script supplied behaves exactly as `native` did. The name changed because the behaviour did: the
backend is no longer defined by writing nothing.

#### Scenario: A machine declaring no backend gets cloud-init

- **WHEN** a machine declares no provisioning backend
- **THEN** it is provisioned by cloud-init

#### Scenario: A machine names the exec backend

- **WHEN** a machine declares the `exec` backend
- **THEN** nothing is written into its root filesystem before it starts, and its script, if it has
  one, is run inside it after it has booted

#### Scenario: The former name is refused, not translated

- **WHEN** a machine declares `native`
- **THEN** rendering fails, saying that the backend is now called `exec` and that `exec` with no
  script behaves as `native` did

#### Scenario: Any other name is refused as unknown

- **WHEN** a machine declares a backend that is neither `cloud-init` nor `exec` nor the former name
- **THEN** rendering fails, naming the two backends that exist, with no third described as planned

### Requirement: An image that cannot run the chosen backend fails the machine

Before a machine boots, the chart SHALL establish that the machine's own root filesystem can
actually run the backend the machine named, and SHALL fail the pod with an explicit message naming
the `exec` backend as the fix when it cannot.

This is the most important requirement in this capability. On an image without cloud-init a seed is
written, nothing reads it, and the machine boots with no users, no keys and no way in, with nothing
in the logs to explain it. That failure looks exactly like a successful install, which makes it the
worst outcome available to this chart.

Establishing that the backend can run means more than finding the program. A distribution may ship
cloud-init installed and switched off, in which case a seed alone changes nothing.

The `exec` backend asks nothing of the image and therefore has nothing to establish: its script runs
inside the machine after the machine has started, with whatever the machine turns out to have.

#### Scenario: A machine on an image with no cloud-init does not boot silently

- **WHEN** a machine selects the cloud-init backend and its root filesystem cannot run cloud-init
- **THEN** the pod fails before the machine starts, and the message says what was looked for and
  that `guest.provisioning: exec` is the fix

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

### Requirement: The exec backend runs a machine's own commands inside it

A machine on the `exec` backend SHALL be able to supply a script, which SHALL be run inside the
machine, after the machine has completed its root change and reported itself ready, as the machine's
own root.

Nothing that runs before the root change can do this. At that moment the machine does not exist:
there is a directory holding another system's binaries, which the chart must never execute, and no
init, no package manager and no network stack of the machine's own. A backend that writes files into
that directory can create a user; it cannot install a package, enable a service, or ask the machine
anything.

A machine that supplies no script SHALL have nothing run and nothing rendered on its behalf, so that
the backend with no script is exactly what the backend it replaced always was.

#### Scenario: A script runs inside the booted machine

- **WHEN** a machine on the `exec` backend supplies a script
- **THEN** the script runs inside that machine, after it has booted, with the machine's own shell and
  as its own root

#### Scenario: The script does not run before the machine exists

- **WHEN** a machine on the `exec` backend supplies a script
- **THEN** nothing is written into its root filesystem before it starts, and no step that runs before
  the machine executes anything belonging to it

#### Scenario: No script means no mechanism

- **WHEN** a machine on the `exec` backend supplies no script
- **THEN** no further object is rendered for it, and the machine is provisioned exactly as a machine
  that asked for nothing

### Requirement: The script is carried by a Job beside the machine

The mechanism that runs a machine's script SHALL be an object beside the machine rather than a
container inside its pod, and SHALL reach the machine through the cluster's API.

A container in the machine's own pod cannot enter the machine's mount namespace without the pod
sharing its process namespace, and a pod that shares its process namespace does not give its
workload PID 1 — which the machine's init requires and systemd refuses to run without. The chart
exists to run a machine's own init; a mechanism that takes PID 1 away from it is disqualified by its
own purpose.

#### Scenario: The machine's pod is unchanged

- **WHEN** a machine on the `exec` backend supplies a script
- **THEN** its pod carries the same containers it would carry without one, and none of them is given
  access to the cluster's API

#### Scenario: An install can be waited on

- **WHEN** a release carrying such a machine is installed and waited on, including waiting for Jobs
- **THEN** the install does not report success until the machine has booted and its script has
  completed, and the documentation says which flags that takes

#### Scenario: A failing script fails visibly

- **WHEN** a machine's script exits non-zero
- **THEN** the mechanism fails, its logs carry the script's own output, and the failure is not
  retried unless the machine asked for retries

### Requirement: A script is run once per change of what it is

The chart SHALL run a machine's script when the script, the environment supplied with it, or the
machine's provisioning revision changes, and SHALL NOT run it again while none of those has changed.

Running it on every pod start would make a non-idempotent script a liability every time a node is
drained. Running it on every upgrade would make it one every time an unrelated value moved.

Changing a machine's script SHALL NOT restart the machine. The script is applied to a running
machine from outside it, so nothing about the machine's pod depends on its content, and replacing a
pet's pod to change something it never reads at boot would destroy state for no effect.

#### Scenario: A changed script runs again

- **WHEN** a machine's script changes and the release is upgraded
- **THEN** the script runs again inside the machine

#### Scenario: An unchanged script does not

- **WHEN** a release is upgraded and the machine's script, environment and revision are unchanged
- **THEN** the script does not run again

#### Scenario: A referenced rotation can be applied deliberately

- **WHEN** material the script is composed from has rotated in a Secret the chart cannot see
- **THEN** the script can be re-run by changing the machine's provisioning revision

#### Scenario: Changing the script does not restart the machine

- **WHEN** a machine's script changes and the release is upgraded
- **THEN** the machine's pod is not replaced

### Requirement: The mechanism is given the narrowest access that can work

The object that runs a machine's script SHALL run under an identity of its own, whose permissions
name the machine's own pod and extend to nothing else in the namespace.

The permission it needs is the right to run a command as root inside one machine, and that is what a
mechanism that runs a script as root inside a machine is. It cannot be given less. It SHALL be given
no more: it SHALL NOT be able to list pods, read Secrets, or reach any other workload.

The documentation SHALL state this grant in plain words at the input that causes it, because it is a
real escalation and an operator choosing the backend is the person who should weigh it.

#### Scenario: The identity reaches one pod

- **WHEN** a machine's script mechanism is rendered
- **THEN** its permissions name that machine's pod and no other object

#### Scenario: The machine keeps no credentials of its own

- **WHEN** a machine on the `exec` backend is rendered
- **THEN** the machine's own pod is given no cluster credentials

#### Scenario: The grant is documented where it is chosen

- **WHEN** a user reads the input that supplies a script
- **THEN** it says that running it requires the right to execute a command as root inside that
  machine, and that the chart creates an identity holding exactly that

### Requirement: Material carried to the machine does not reach its volume

The script and any environment supplied with it SHALL be placed on a filesystem inside the machine
that does not survive a restart, and the environment SHALL NOT be passed as command arguments.

An environment is where a secret would be. A file on the machine's volume is in every snapshot of
that machine for the rest of its life, and an argument is in the mechanism's own logs, in the
machine's process table, and in the cluster's audit log.

#### Scenario: The script does not persist

- **WHEN** a machine's script has been run and the machine is restarted
- **THEN** neither the script nor its environment is present inside the machine

#### Scenario: The environment is never an argument

- **WHEN** a machine supplies an environment with its script
- **THEN** it is written to a file inside the machine and read from there, and it appears in no
  command line
