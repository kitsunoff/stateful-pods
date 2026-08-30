## Purpose

Defines what happens between a filled root filesystem and a running operating system: which
filesystems the guest is entitled to find mounted, how the machine's root becomes the volume, what
the guest is told about where it is running, and what must be true of the result for the machine to
be a machine rather than a container.

## Requirements

### Requirement: The machine's root filesystem is the volume

The chart SHALL make the machine's root filesystem the seeded volume before the guest's init starts,
and SHALL do so by changing the root of the container's mount namespace rather than by confining a
process to a subtree.

The difference is not cosmetic. Only a real root change makes `kubectl exec`, exec probes and
`/proc/1/root` land in the machine; with a confinement they land in the chart's own image, and every
probe and every debugging session has to be wrapped in something that follows the machine's init
into its root. A machine a user cannot get a shell in is not usable.

#### Scenario: The guest's root is the volume

- **WHEN** a machine has booted
- **THEN** the operating system running in it is the one on the volume, and its root directory is
  the root of that volume

#### Scenario: A shell in the machine is the machine's shell

- **WHEN** a user opens a shell in a running machine
- **THEN** the commands and files they find are the machine's own, not the chart image's

#### Scenario: The volume is not offered to the runtime as the root

- **WHEN** a machine is rendered
- **THEN** the volume is mounted at an ordinary path and the root change is performed by the
  container itself, because a container runtime rejects being handed a volume as `/`

### Requirement: The guest finds the filesystems an init system needs

Before handing over, the chart SHALL mount into the machine's root the kernel filesystems an init
system expects to find, and SHALL make the device nodes the runtime already provided available
inside it.

#### Scenario: An init system finds what it expects

- **WHEN** a machine's init starts
- **THEN** the process, kernel, device, pseudo-terminal, shared-memory and runtime-state filesystems
  are present in its root

#### Scenario: A control-group hierarchy the guest can own

- **WHEN** a machine's init starts
- **THEN** a control-group filesystem it can write to is present, so that an init system which
  manages services through control groups can run

#### Scenario: Device nodes come from the runtime, not from creation

- **WHEN** the machine's devices are prepared
- **THEN** the nodes the runtime already placed in the pod are made available in the machine's root,
  rather than created, because creating a device node is impossible for a pod running in its own
  user namespace regardless of what it is granted

### Requirement: A machine can be entered with a terminal

A running machine SHALL be enterable with an interactive terminal, so that `kubectl exec --stdin
--tty` and every tool built on it open a shell on a pseudo-terminal inside the machine.

This is the promise the root change is made for. A machine whose shell can only be a pipe is not a
machine anyone can work in: no editor, no pager, no job control, no program that asks for a password.

Meeting it requires more than mounting the pseudo-terminal filesystem. A machine is given its own
private instance of that filesystem, so that the terminals it hands out belong to the machine and
not to the node. The multiplexer that allocates them therefore also belongs to the instance, and the
node's own multiplexer would allocate from the wrong one. So the path every program opens to ask for
a terminal SHALL resolve, inside the machine, to the multiplexer of the machine's own instance —
and SHALL be reachable by an unprivileged process, since a device node cannot be created by a pod
running in its own user namespace.

#### Scenario: A shell opened with a terminal gets one

- **WHEN** a user opens a shell in a running machine and asks for a terminal
- **THEN** the shell starts and is attached to a pseudo-terminal belonging to the machine

#### Scenario: The multiplexer is reachable at the path programs look for it at

- **WHEN** a machine has booted
- **THEN** the conventional path for the pseudo-terminal multiplexer resolves to the multiplexer of
  the machine's own instance of the pseudo-terminal filesystem, rather than being absent or naming
  the node's

### Requirement: The mount set is the same for every machine

The set of filesystems mounted for a machine SHALL be fixed. The chart SHALL NOT offer an input that
selects it, vary it by the machine's declared source, or vary it by the init system the guest turns
out to run.

An init that does not use a control-group hierarchy ignores the one that was mounted, at no cost.
Making it configurable would add an input whose wrong value produces a machine that fails to boot for
a reason no message could explain.

#### Scenario: Two machines get the same filesystems

- **WHEN** two machines running different operating systems boot
- **THEN** the same set of filesystems is mounted for both

#### Scenario: There is no input that changes it

- **WHEN** a user looks for a way to add, remove or alter a mount
- **THEN** no such input exists

### Requirement: The guest is told it is running in a container

The chart SHALL inform the guest's init that it is running inside a container, by the means that
init systems and provisioning tools actually consult.

Without it, an init system concludes it is running on hardware and starts doing what that implies:
loading kernel modules, checking filesystems, and taking over the control-group hierarchy. The pod
conventions other runtimes rely on are not written by Kubernetes, so the chart has to do it.

#### Scenario: The init system knows where it is

- **WHEN** a machine's init starts
- **THEN** it detects that it is running in a container, and does not attempt the work that only
  makes sense on hardware

### Requirement: Booting fails loudly and without a half-prepared machine

Every step of the boot SHALL be checked, and a failure SHALL stop the machine with a message naming
the step and the path it was working on. The chart SHALL NOT hand over to the guest's init after a
step has failed.

A boot that half-mounts and then starts an operating system anyway produces a machine that fails
later, somewhere else, for reasons nothing connects back to the mount that did not happen.

#### Scenario: A failed mount stops the boot

- **WHEN** any filesystem cannot be mounted
- **THEN** the guest's init is not started, and the failure names what was being mounted and where

#### Scenario: A machine with no init is reported as such

- **WHEN** the volume holds no init system to hand over to
- **THEN** the failure says so, rather than reporting a missing file

#### Scenario: An unseeded volume is never booted

- **WHEN** the volume has not been seeded
- **THEN** the machine does not boot, because there is no operating system to start
