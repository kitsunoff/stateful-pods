## ADDED Requirements

### Requirement: A provisioning input is supplied one way, not two

Rendering SHALL fail when a provisioning input carries both a literal value and a reference, and
when a single reference names more than one source.

Both forms present is not a preference the chart can resolve. Picking one would mean the material
the user believed was in effect is the one that was discarded, and they would learn it from a
machine that behaves wrongly rather than from a message.

#### Scenario: An input given both ways is refused

- **WHEN** an input carries both a literal value and a reference
- **THEN** rendering fails and names the input

#### Scenario: A reference naming two sources is refused

- **WHEN** one reference names both a Secret key and a ConfigMap key
- **THEN** rendering fails and names the input

#### Scenario: An incomplete reference is refused

- **WHEN** a reference omits the name of the object or the key inside it
- **THEN** rendering fails and says which is missing

### Requirement: An input belonging to another backend is refused, not ignored

Rendering SHALL fail when a machine supplies a provisioning input that the backend it selected does
not use.

Silently ignoring it leaves the user believing the machine is configured to do something it is not.
Supplying user-data to a machine provisioned natively is a mistake worth catching while the manifest
is still text.

#### Scenario: An input for an unselected backend is refused

- **WHEN** a machine selects the `native` backend and supplies a cloud-init input
- **THEN** rendering fails, names the input, and says which backend it belongs to

#### Scenario: An unknown provisioning input is refused

- **WHEN** a machine supplies a provisioning input the chart does not recognise
- **THEN** rendering fails and lists the inputs the backend accepts

### Requirement: A backend that is designed but not implemented is refused with the reason

Rendering SHALL fail for a provisioning backend that the design names but the chart does not yet
implement, and the message SHALL say that it is not implemented rather than that it does not exist.

A user who read the design and asked for `systemd-credentials` did not make a typo. Telling them the
name is wrong would send them looking for the right spelling of something that is not there.

#### Scenario: A designed but unimplemented backend says so

- **WHEN** a machine names a backend the design describes and the chart has not implemented
- **THEN** rendering fails, says it is not implemented yet, and names the backends that are
