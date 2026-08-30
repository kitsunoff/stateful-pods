## ADDED Requirements

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
