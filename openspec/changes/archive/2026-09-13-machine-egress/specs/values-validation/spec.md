## ADDED Requirements

### Requirement: A machine's egress policy is checked while the chart renders

The chart SHALL reject, while rendering and with a message naming the rule, an egress block that is
not a map, a key under it that is not an input, a missing or unknown default, a rules list that is
not a list, a rule that is not a map, a rule with no name or a duplicate name, a rule naming more
than one or fewer than one matcher, a missing or empty port list, a port outside 1–65535, a port the
proxy itself holds, a malformed host name, address range or path prefix, a UDP rule matching on
anything a proxy would be needed for, and two rules that would render the same match.

The last of those is not tidiness. The proxy validates its configuration on startup and exits when
it cannot reconcile it, and two filter chains with the same match are the commonest way to get
there — which surfaces as a sidecar that crash-loops behind a machine whose own containers are all
healthy.

The chart SHALL also reject a machine that declares a served port the proxy holds inside the same
pod, because nothing outside would reach the machine there.

#### Scenario: A policy with no default is refused

- **WHEN** a machine declares an egress policy and names no default
- **THEN** rendering fails, saying what each accepted default does

#### Scenario: A rule matching on two layers is refused

- **WHEN** a rule names both a server name and an address range
- **THEN** rendering fails, naming both

#### Scenario: A UDP rule matching above layer 4 is refused

- **WHEN** a rule names `UDP` and matches on a server name
- **THEN** rendering fails, saying that UDP is not proxied and that such a rule would never match

#### Scenario: Two rules rendering one match are refused

- **WHEN** two rules would allow the same server name on the same port
- **THEN** rendering fails, naming both rules and saying that the proxy refuses a duplicate

#### Scenario: A served port the proxy holds is refused

- **WHEN** a machine declares an egress policy and a served port that the proxy occupies
- **THEN** rendering fails, naming the port and both inputs
