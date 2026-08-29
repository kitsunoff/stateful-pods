## Purpose

Defines the pod-facing behaviour of a running machine: how it reports that it has finished booting,
how it is asked to stop, and what its logs show while either happens.

## Requirements

### Requirement: A machine reports when it has finished booting

The chart SHALL provide a readiness signal that becomes positive when the machine's operating system
has finished starting, and SHALL derive it from whatever init system the machine turns out to run
rather than from an input describing it.

Without one, a machine counts as ready the moment its process exists, which is minutes before
anything inside it works.

#### Scenario: A booting machine is not yet ready

- **WHEN** a machine's operating system is still starting
- **THEN** the machine does not report itself ready

#### Scenario: A booted machine is ready

- **WHEN** a machine's operating system has finished starting
- **THEN** the machine reports itself ready

#### Scenario: Readiness does not depend on knowing the guest

- **WHEN** machines running different init systems boot
- **THEN** each reports readiness correctly, without any input having declared which init it runs

### Requirement: A machine is never restarted for being unwell

The chart SHALL NOT ship a health check whose failure restarts the machine.

A machine is a pet. Restarting one because a service inside it was briefly unresponsive replaces a
degraded machine a user can inspect with a reboot loop they cannot, and the state that would explain
it is destroyed by the first restart.

#### Scenario: No check can restart the machine

- **WHEN** a machine becomes unresponsive
- **THEN** nothing the chart ships restarts it, and it remains available for inspection

### Requirement: A machine is asked to shut down, in a way its init understands

When a machine's pod is stopped, the chart SHALL ask the machine's operating system to shut down
using the signal that operating system actually treats as a shutdown request, and SHALL wait for it
to finish.

The signal is not the same for every init system, and the one Kubernetes sends by default means
something else entirely to the most common of them — it is a request to re-execute, not to stop. A
machine that is signalled wrongly is killed outright when the grace period runs out, which is an
unclean shutdown of a pet on every ordinary operation.

The grace period SHALL be long enough for an operating system to stop its services.

#### Scenario: A machine shuts down cleanly

- **WHEN** a machine's pod is deleted
- **THEN** the machine's operating system is asked to shut down and is given time to do so, rather
  than being killed where it stands

#### Scenario: The signal follows the machine, not a declaration

- **WHEN** machines running different init systems are stopped
- **THEN** each receives the signal its own init understands, without any input having declared
  which init it runs

#### Scenario: Stopping waits for the machine to finish

- **WHEN** a machine has been asked to shut down
- **THEN** the pod is not considered stopped until the machine's init has exited or the grace period
  has run out

### Requirement: A machine's logs show it booting

The output of a machine's operating system SHALL reach the pod's logs, so that the boot can be
watched from outside the machine.

This is a deliberate divergence from Proxmox, which discards it. The first thing anyone does when a
machine does not come up is read its logs, and a pod whose logs are empty reads as broken to every
Kubernetes user. The output is unstructured and noisy, and that is accepted: noise that answers the
question beats silence that does not.

#### Scenario: The boot is visible from outside

- **WHEN** a machine is booting
- **THEN** its operating system's own output appears in the pod's logs

#### Scenario: A machine that fails to boot says why

- **WHEN** a machine's operating system fails during boot
- **THEN** what it printed is in the pod's logs, rather than being discarded
