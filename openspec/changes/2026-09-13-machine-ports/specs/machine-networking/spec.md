## Purpose

Defines what a machine tells the cluster about its own network presence — which ports it serves,
under what names, and whether the cluster is asked to admit traffic to those ports and to nothing
else.

It is deliberately not about the machine's own interface. A pod's addressing belongs to the
cluster's CNI, and every input that would configure it from here is refused elsewhere in these
specs and stays refused.

## ADDED Requirements

### Requirement: A machine declares the ports it serves

A machine SHALL be able to declare the ports it serves, as a map keyed by the name each port is
known by. Each entry SHALL name a port number and MAY name a protocol of `TCP`, `UDP` or `SCTP`,
defaulting to `TCP` when none is named.

A machine that declares no ports SHALL render exactly what it rendered before this capability
existed, so that adding the input to the chart changes nothing for a machine that does not use it.

#### Scenario: A machine declares a named port

- **WHEN** a machine declares a port named `ssh` on number 22
- **THEN** the machine's rendered objects carry a port named `ssh` on number 22 with protocol `TCP`

#### Scenario: A protocol may be named

- **WHEN** a machine declares a port naming protocol `UDP`
- **THEN** the rendered port carries that protocol rather than the default

#### Scenario: Declaring nothing changes nothing

- **WHEN** a machine declares no ports
- **THEN** neither its guest container nor its Service carries a port list

### Requirement: A declared port is rendered on the guest container and on the Service

Each declared port SHALL appear as a port of the guest container, under the name it was declared
with, and as a port of the machine's headless Service, under the same name, targeting the same
number.

The container's port list is a declaration the cluster can read and is not access control: a pod's
network namespace is reachable on every port something inside it listens on, whatever that list
says. The Service's port list is what publishes an SRV record per named port, which is how a client
finds a machine's service without the number being written down a second time.

#### Scenario: The guest container carries the declaration

- **WHEN** a machine declares ports
- **THEN** the guest container's port list carries one entry per declared port, with its name,
  number and protocol

#### Scenario: The Service carries the declaration

- **WHEN** a machine declares ports
- **THEN** the headless Service carries one entry per declared port, with its name, number and
  protocol, and its target is the same number

#### Scenario: The preparation steps carry no ports

- **WHEN** a machine declares ports
- **THEN** no container other than the guest carries a port list

### Requirement: A machine may ask that only its declared ports be reachable

A machine SHALL be able to ask that the cluster admit traffic to its declared ports and to no
others. The chart SHALL NOT do this unless asked: the default SHALL leave a machine reachable
exactly as it was.

Restricting a running pet's traffic as a side effect of a chart upgrade would take a machine off the
network for a reason nothing in its values changed. This is the same class of decision as the
machine's security mode, which the chart has always refused to make on the user's behalf.

The restriction SHALL apply to inbound traffic only. A policy that also named egress would deny a
machine its resolver, its package mirror and everything else the moment it was applied.

#### Scenario: Restriction is not applied by default

- **WHEN** a machine declares ports and does not ask for them to be enforced
- **THEN** no policy object is rendered for it

#### Scenario: Restriction admits the declared ports

- **WHEN** a machine asks that only its declared ports be reachable
- **THEN** a policy is rendered selecting that machine's pod and admitting inbound traffic to each
  declared port

#### Scenario: Restriction does not touch outbound traffic

- **WHEN** a machine asks that only its declared ports be reachable
- **THEN** the rendered policy governs inbound traffic only, and the machine's outbound traffic is
  unaffected

#### Scenario: Asking for restriction with nothing declared admits nothing

- **WHEN** a machine asks that only its declared ports be reachable and declares no ports
- **THEN** the rendered policy admits no inbound traffic, and the release notes say so

### Requirement: What enforcement depends on is stated where it is chosen

The documentation SHALL state, at the input that asks for it, that the restriction is enforced by
the cluster's network plugin and has no effect on a cluster whose plugin does not implement one.

The chart cannot see which plugin a cluster runs, and an input whose effect silently depends on
something invisible from the values is the failure mode this project documents rather than hides: a
machine believed to be restricted and reachable on every port looks exactly like a machine that is
restricted.

#### Scenario: The dependency is documented at the point of use

- **WHEN** a user reads the input that asks for the restriction
- **THEN** it says that a network policy is enforced by the cluster's network plugin and does
  nothing where none implements it

### Requirement: The machine's readiness is never gated on the network

The signal that gates a machine's Service endpoint SHALL NOT depend on reaching the machine over
the network.

A probe that did would be denied by the machine's own ingress restriction, and the machine would
report itself unready forever for a reason its values describe as correct.

#### Scenario: A restricted machine still becomes ready

- **WHEN** a machine admits inbound traffic to no port at all
- **THEN** it still reports itself ready once its operating system has started
