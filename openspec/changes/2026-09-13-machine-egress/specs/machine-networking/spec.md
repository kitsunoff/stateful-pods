## ADDED Requirements

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

#### Scenario: Declaring nothing changes nothing

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
