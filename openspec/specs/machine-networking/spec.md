## Purpose

Defines what a machine tells the cluster about its own network presence — which ports it serves,
under what names, and whether the cluster is asked to admit traffic to those ports and to nothing
else.

It is deliberately not about the machine's own interface. A pod's addressing belongs to the
cluster's CNI, and every input that would configure it from here is refused elsewhere in these
specs and stays refused.

## Requirements

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

### Requirement: A machine declares what it may reach

A machine SHALL be able to declare an egress policy: an explicit default for traffic no rule allows,
and an ordered list of rules describing what it may reach.

The default SHALL be mandatory whenever a policy is declared at all. A policy whose unmatched traffic
nobody named means different things to its author and its reader, and the difference is only
discovered when something stops working or when something that should have been stopped does not.

A machine that declares no egress policy SHALL render exactly what it rendered before this
capability existed.

#### Scenario: A policy names its default explicitly

- **WHEN** a machine declares an egress policy without naming what happens to unmatched traffic
- **THEN** rendering fails, saying what each accepted default does

#### Scenario: Declaring no egress policy changes nothing

- **WHEN** a machine declares no egress policy
- **THEN** its pod carries no proxy, no packet-filter step and no policy

#### Scenario: The rules keep the order they were written in

- **WHEN** a machine declares several rules
- **THEN** the rendered policy presents them in the order the values declared them

### Requirement: A rule matches at one layer, and the documentation says which

Each rule SHALL match on exactly one of: the connection's destination address, the server name in a
TLS handshake, or the authority and path of a plaintext HTTP request. A rule naming more than one, or
none, SHALL be refused while the chart renders.

The forms see different things about the same connection, and a rule that combined two would be one
whose refusals nobody could predict.

The documentation SHALL state, for each form, what it can see and what it cannot — in particular that
a server-name rule is matched **without decrypting anything** and is therefore a claim the machine
makes about itself, which a process inside the machine can make falsely.

#### Scenario: A rule naming two matchers is refused

- **WHEN** a rule names both a destination range and a server name
- **THEN** rendering fails, naming both and saying that they see different layers

#### Scenario: What a server-name rule establishes is documented

- **WHEN** a user reads the input that matches on a server name
- **THEN** it says that the name is read from the handshake without decryption, that a process inside
  the machine can put any name there, and that an address-based rule is what bounds such a process

#### Scenario: A path rule is plaintext only

- **WHEN** a user reads the input that matches on an HTTP authority and path
- **THEN** it says that it applies to plaintext requests only, and why matching a path on an
  encrypted connection is not offered

### Requirement: A default of deny denies what the proxy cannot see

Where the default is to refuse, the chart SHALL also refuse traffic the proxy does not decide:
traffic that is not TCP and that no rule allows, and traffic over IPv6.

A proxy is given TCP. A policy that stopped there would be one a machine could step around with a
UDP socket, and a policy that covers half of what its name claims is worse than one that says which
half.

The pod's own resolver SHALL be permitted automatically under either default, and SHALL NOT be
something a rule has to name. A machine that cannot resolve a name cannot reach a host however many
rules name it, so a policy that dropped its resolver would be one whose every name-based rule
silently failed.

#### Scenario: Unmatched UDP is refused under a default of deny

- **WHEN** a machine's default is to refuse and no rule allows a UDP destination
- **THEN** traffic to it is dropped

#### Scenario: An allowed UDP destination is permitted

- **WHEN** a machine declares a rule allowing a UDP destination and port
- **THEN** traffic to it is permitted

#### Scenario: The resolver works without a rule

- **WHEN** a machine's default is to refuse and it declares no rule about DNS
- **THEN** the machine can still resolve names through the resolver the pod was given

#### Scenario: What is not proxied is documented

- **WHEN** a user reads the egress inputs
- **THEN** they say that IPv6 is dropped under a default of deny and untouched under allow, and that
  it is not proxied either way

### Requirement: Every decision the policy makes is legible without being turned on

The proxy SHALL write a log line for every connection it allows and every connection it refuses, to
its own standard output, by default and without an input to enable it.

"Why can this machine not reach X" has to be answerable with `kubectl logs`. A policy whose refusals
are silent is one that gets disabled rather than debugged.

#### Scenario: A refused connection says so

- **WHEN** a machine attempts a connection no rule allows and the default is to refuse
- **THEN** a line naming the destination appears on the proxy's output

#### Scenario: An allowed connection names the rule that allowed it

- **WHEN** a machine attempts a connection a rule allows
- **THEN** a line naming that rule appears on the proxy's output

### Requirement: The policy is in place before the machine starts and after it is built

The step that programs the machine's network namespace SHALL run after the steps that seed and
prepare the machine's root filesystem, after the proxy is listening, and before the machine's own
init is started.

Each of the three is load-bearing. Seeding fetches a root filesystem from a registry, so a policy
applied before it would need a rule for the chart's own source. Traffic redirected to a port nothing
is listening on is traffic refused. And a machine whose first connections escaped the policy would be
a policy that depends on timing.

#### Scenario: Seeding is not subject to the policy

- **WHEN** a machine with an egress policy is seeded from a registry no rule allows
- **THEN** seeding succeeds, and the policy applies to the machine rather than to its construction

#### Scenario: The machine does not start before the policy is in place

- **WHEN** a machine with an egress policy starts
- **THEN** the redirect exists before the machine's init is executed

#### Scenario: A proxy that will not start stops the machine

- **WHEN** the proxy cannot start
- **THEN** the machine is not started either, and the failure names where the proxy's own output is

### Requirement: The capability a machine is not given is held by a step that exits

The privilege needed to program the pod's network namespace SHALL be granted to the step that does
it and to no other container. The machine's own container SHALL NOT be granted it.

A machine that could edit its own packet filter would be a machine whose policy it enforces on
itself, which is not a policy.

#### Scenario: The guest holds no network administration capability

- **WHEN** a machine with an egress policy is rendered
- **THEN** the guest container's capability set does not include the one required to change the
  namespace's packet filter

#### Scenario: The step that programs the namespace exits

- **WHEN** a machine with an egress policy has started
- **THEN** the container that programmed its namespace is no longer running
