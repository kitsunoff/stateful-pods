## MODIFIED Requirements

### Requirement: A machine declares how it is provisioned

Each machine SHALL declare a provisioning backend. `cloud-init` and `exec` SHALL be accepted, and
`cloud-init` SHALL be the default when a machine declares none.

The default is the mechanism people actually want, and the one the images the audience reaches for
already carry. `exec` asks nothing of the image and is what a machine on an image without cloud-init
must name.

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

#### Scenario: An unimplemented backend says so

- **WHEN** a machine declares `systemd-credentials`
- **THEN** rendering fails, saying that it is described in the design and not implemented, rather
  than that the name is unknown

## ADDED Requirements

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

#### Scenario: An install waits for the script

- **WHEN** a release carrying such a machine is installed and waited on
- **THEN** the install does not report success until the machine has booted and its script has
  completed

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
