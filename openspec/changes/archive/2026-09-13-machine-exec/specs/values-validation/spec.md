## MODIFIED Requirements

### Requirement: An input belonging to another backend is refused, not ignored

Rendering SHALL fail when a machine supplies a provisioning input that the backend it selected does
not use.

Silently ignoring it leaves the user believing the machine is configured to do something it is not.
Supplying user-data to a machine provisioned by its own script is a mistake worth catching while the
manifest is still text, and so is supplying a script to a machine provisioned by cloud-init.

#### Scenario: An input for an unselected backend is refused

- **WHEN** a machine selects the `exec` backend and supplies a cloud-init input
- **THEN** rendering fails, names the input, and says which backend it belongs to

#### Scenario: An input for the other unselected backend is refused too

- **WHEN** a machine selects the `cloud-init` backend and supplies an `exec` input
- **THEN** rendering fails, names the input, and says which backend it belongs to

#### Scenario: An unknown provisioning input is refused

- **WHEN** a machine supplies a provisioning input the chart does not recognise
- **THEN** rendering fails and lists the inputs the backend accepts

## ADDED Requirements

### Requirement: The exec backend's inputs are checked while the chart renders

The chart SHALL reject, while rendering and with a message naming the input, an `exec` block that is
not a map, a key under it that is not an input, a script or environment supplied neither inline nor
by reference, a script or environment supplied both ways at once, a retry count that is not a
non-negative whole number, a timeout that is not a positive whole number, and `exec` inputs on a
machine that selected another backend.

The chart SHALL also reject a machine whose object name leaves no room for the name of the object
that would run its script, naming the object, its length and the number of characters over the
limit — the same treatment the machine's own object name already gets.

An input belonging to a backend the machine did not select is an error rather than something
ignored, for the reason the `cloud-init` inputs are: silently dropping it leaves the user believing
the machine is configured to do something it is not.

#### Scenario: A script on a cloud-init machine is refused

- **WHEN** a machine selects `cloud-init` and supplies `exec` inputs
- **THEN** rendering fails, naming the inputs and the backend they belong to

#### Scenario: cloud-init inputs on an exec machine are refused

- **WHEN** a machine selects `exec` and supplies `cloudInit` inputs
- **THEN** rendering fails, naming the inputs and the backend they belong to

#### Scenario: A name too long for the object that would run the script is refused

- **WHEN** a machine supplies a script and its object name leaves fewer characters than the name of
  that object needs
- **THEN** rendering fails, naming the object, its length, and how many characters over the limit it
  is

#### Scenario: A retry count that is not a count is refused

- **WHEN** a machine names a number of retries that is negative or is not a whole number
- **THEN** rendering fails, naming the input
