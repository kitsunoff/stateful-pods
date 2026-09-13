## REMOVED Requirements

### Requirement: Exactly one machine per release, for now

**Reason**: a release may now hold as many machines as its values declare. The requirement existed
because per-machine rendering had not been proved for more than one, and it has been: every helper
takes an explicit machine context, every object is named from the machine's own name, and a release
with two machines renders two of everything with no name in common.

What it also required — that an empty or absent map fails, with a message showing the expected
shape — is kept, as a requirement of its own about the map rather than about the count.

## ADDED Requirements

### Requirement: A machines map with no entries is refused

The chart SHALL fail rendering when the machines map is absent or empty, with a message stating that
at least one machine must be declared and showing the shape one takes.

There is no reasonable default machine. Installing the chart with no values would otherwise create
something nobody described, on a volume that then becomes the machine.

#### Scenario: No machines declared

- **WHEN** the machines map is absent or empty
- **THEN** rendering fails, says that at least one machine must be declared, and shows the expected
  shape

#### Scenario: A map with entries is accepted whatever its size

- **WHEN** the machines map holds one entry, or several
- **THEN** the count alone is never a reason to refuse
