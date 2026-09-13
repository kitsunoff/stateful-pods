## ADDED Requirements

### Requirement: A command that acts on a release says which machines that is

Where a plugin command acts on a Helm release rather than on one machine, and the release holds more
than the machine named, the command SHALL name the other machines before it acts.

The commands that remove and that install act on releases: a release may hold several machines, and
each of them is somebody's pet. Finding out that one had stopped by noticing it had stopped is the
failure this exists to prevent.

#### Scenario: Removal names what else goes

- **WHEN** a machine is removed and its release holds other machines
- **THEN** the output names them before anything is removed

#### Scenario: Removal of a lone machine is unchanged

- **WHEN** a machine is removed and its release holds only that machine
- **THEN** the output describes the release exactly as it did before

### Requirement: A confirmation asks for the name of what is actually removed

Where a removal takes more than the machine named, the confirmation SHALL ask for the release's name
rather than the machine's.

A confirmation exists to make an act deliberate. Typing one machine's name to stop several is a
confirmation of the wrong thing: the question answered was about a machine and the price paid is a
release.

#### Scenario: The release's name is what confirms a removal that takes several

- **WHEN** a removal would stop machines other than the one named
- **THEN** typing the machine's name does not confirm it, and typing the release's name does

#### Scenario: The machine's name still confirms a removal that takes one

- **WHEN** a removal would stop only the machine named
- **THEN** typing the machine's name confirms it

### Requirement: Installing one machine never removes another

The creation command SHALL refuse to install into a release that already holds a machine other than
the one being created, and SHALL say what it would have removed and what to run instead.

The command composes one machine's values and hands them to Helm, which replaces a release's values
with what it is given. A release holding another machine would come back holding only this one, and
the other machine's objects would be deleted.

It SHALL NOT avoid this by asking Helm to reuse the release's existing values. That pins a release to
the values it already has, so the chart's own new defaults stop reaching it — a decision about a
machine the user did not mention, made by a command that does not otherwise decide anything.

#### Scenario: A release holding another machine is refused

- **WHEN** a machine is created into a release that already holds a different machine
- **THEN** nothing is installed, and the message names the machine that would have been removed

#### Scenario: The refusal says what does work

- **WHEN** such a creation is refused
- **THEN** the message shows the command that adds a machine to a release properly

#### Scenario: Updating the same machine is unaffected

- **WHEN** a machine is created into a release that holds only that machine
- **THEN** it is installed as an update, as before
