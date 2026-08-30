## Purpose

Defines the command-line surface for working with machines: how a machine is addressed, what
entering one guarantees, what the tool is allowed to decide on a user's behalf, and how it reaches
someone's machine in the first place.

## ADDED Requirements

### Requirement: A machine is addressed by its own name

The plugin SHALL accept the name a machine was declared under, and SHALL resolve it to the objects
that represent it. It SHALL NOT require the user to know the pod name, the container name, or the
naming rule that produces them.

The chart already gives every machine a label carrying its name; the derived object name is an
implementation detail of the chart's naming rule, and a user who has to know it has been handed the
chart's internals as an interface.

#### Scenario: A machine is reached by the name it was declared under

- **WHEN** a user names a machine that exists in the namespace being acted on
- **THEN** the plugin acts on that machine's objects

#### Scenario: An unknown name lists what does exist

- **WHEN** a user names a machine that is not in the namespace
- **THEN** the plugin reports that it was not found and lists the machines that are there

#### Scenario: An ambiguous name is never guessed

- **WHEN** a name matches more than one machine
- **THEN** the plugin reports every match and does nothing, rather than choosing one

### Requirement: Entering a machine either lands inside it or explains why not

The command that enters a machine SHALL place the user inside the machine's own operating system.
When that is not possible, it SHALL report which stage the machine is in and where the explanation
is, and SHALL NOT surface only the underlying container error.

"Cannot exec into container guest" is a true statement about a machine whose root filesystem is
still being unpacked, and a useless one. The stages a machine passes through are already visible in
the objects the chart renders; a user should not have to reconstruct them.

#### Scenario: A running machine is entered

- **WHEN** a machine has booted and is running
- **THEN** the user is placed in a shell inside that machine

#### Scenario: A shell is chosen, not assumed

- **WHEN** the machine's operating system provides no `bash`
- **THEN** a shell that does exist is used, rather than failing on the absence of one

#### Scenario: A machine that is still being made says so

- **WHEN** a machine's volume is still being seeded or prepared
- **THEN** the plugin reports that stage, and names the step whose output explains the wait

#### Scenario: A machine that failed says where to look

- **WHEN** a machine is not running because a step failed
- **THEN** the plugin names the step that failed and how to read its output

### Requirement: The plugin is never a second source of truth for the chart's inputs

The plugin SHALL pass the values a user supplies to the chart and SHALL surface the chart's own
rejection unchanged. It SHALL NOT validate a machine's inputs itself, SHALL NOT supply a default the
chart does not supply, and SHALL NOT rewrite a value on the user's behalf.

The chart deliberately refuses to guess a security mode or a source, and its rejections name the
values path and the accepted set. A second validator in the plugin would drift from it, and a
default invented here would be a machine configured by a tool rather than by its owner.

#### Scenario: A rejected input reads as the chart wrote it

- **WHEN** the chart rejects the values a create produces
- **THEN** the chart's message is what the user sees

#### Scenario: No input is invented

- **WHEN** a user does not supply an input the chart requires
- **THEN** the chart's own error about that input is what appears, rather than a value chosen by the
  plugin

### Requirement: An action that changes the cluster names its target before acting

Before performing an action that changes cluster state, the plugin SHALL state the cluster context,
the namespace and the machine it will act on, and SHALL state the underlying command it will run.

A tool that acts on "the current context" is one mistaken shell away from acting on the wrong
cluster, and a pet is exactly the workload where that is unrecoverable.

#### Scenario: The target is stated before a change

- **WHEN** a command that changes cluster state is run
- **THEN** the context, namespace and machine it will act on are shown first

#### Scenario: Read-only commands do not require confirmation

- **WHEN** a command only reads state
- **THEN** it runs without a confirmation step

#### Scenario: A destructive action is confirmed

- **WHEN** a machine is to be removed
- **THEN** the plugin requires an explicit confirmation naming that machine, and a non-interactive
  run without a supplied confirmation does nothing

### Requirement: Removing a machine does not remove its root filesystem

The removal command SHALL leave the machine's root filesystem in place, SHALL say that it did, and
SHALL show the separate command that would destroy it. The plugin SHALL NOT offer an option that
removes a machine and its root filesystem in one action.

This is the chart's own rule, and the plugin is where it would be easiest to break: a convenience
flag that cleaned everything up would make an irreversible act as cheap as a reversible one.

#### Scenario: The volume survives a removal

- **WHEN** a machine is removed
- **THEN** its root filesystem still exists afterwards

#### Scenario: The user is told where the state still is

- **WHEN** a machine is removed
- **THEN** the output names the volume that remains and the command that would delete it

#### Scenario: No single action does both

- **WHEN** a user looks for an option that removes a machine together with its root filesystem
- **THEN** no such option exists

### Requirement: The plugin reports where a machine is in its life

The plugin SHALL report a machine's stage — being seeded, being prepared, booting, ready, or
stopped — derived from the state the chart already produces, and SHALL do so for a single machine
and for every machine in a namespace.

A machine takes minutes to become usable, and for most of that time a pod-level view says
`Init:1/3`, which answers a question about containers rather than about the machine.

#### Scenario: A machine's stage is reported

- **WHEN** a user asks for a machine's state
- **THEN** the stage it is in is named

#### Scenario: Every machine in a namespace is listed with its stage

- **WHEN** a user lists machines
- **THEN** each machine appears under its own name with the stage it is in

#### Scenario: The stage comes from the cluster, not from a guess

- **WHEN** a machine's stage is reported
- **THEN** it is derived from that machine's own objects, and no stage is inferred from elapsed time

### Requirement: The plugin installs without a build step

The plugin SHALL be published as a downloadable archive carrying a checksum, for every platform it
supports, and SHALL be installable by the standard plugin manager without the user compiling or
cloning anything.

#### Scenario: A published release can be installed directly

- **WHEN** a user installs the plugin from a published release
- **THEN** no toolchain, checkout or build is required

#### Scenario: A download can be verified

- **WHEN** an archive is published
- **THEN** a checksum is published with it

#### Scenario: An unsupported platform is stated, not attempted

- **WHEN** the plugin is run on a platform it does not support
- **THEN** it says so, rather than failing partway through an action
