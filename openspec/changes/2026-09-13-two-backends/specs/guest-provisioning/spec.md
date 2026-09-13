## MODIFIED Requirements

### Requirement: A machine declares how it is provisioned

Each machine SHALL declare a provisioning backend. `cloud-init` and `exec` SHALL be accepted, and
`cloud-init` SHALL be the default when a machine declares none. No other backend SHALL be accepted,
and none SHALL be named in the documentation as forthcoming.

The two are chosen for what they do not ask for. `cloud-init` needs cloud-init in the image and says
so loudly when it is absent, but asks nothing of the init system: a systemd unit and an OpenRC script
are both recognised. `exec` asks for a shell and nothing else. Between them they serve every image
this project ships a name for, and neither is tied to one init system — which is the property a third
backend built on `/run/host/credentials` could not have had, because that mechanism is systemd's.

`native` SHALL be refused, with a message saying that it was renamed to `exec` and that `exec` with
no script supplied behaves exactly as `native` did. The name changed because the behaviour did: the
backend is no longer defined by writing nothing.

#### Scenario: A machine declaring no backend gets cloud-init

- **WHEN** a machine declares no provisioning backend
- **THEN** it is provisioned by cloud-init

#### Scenario: A machine names the exec backend

- **WHEN** a machine declares the `exec` backend
- **THEN** nothing is written into its root filesystem before it starts, and its script, if it has
  one, is run inside it after it has booted

#### Scenario: The former name is refused, not translated

- **WHEN** a machine declares `native`
- **THEN** rendering fails, saying that the backend is now called `exec` and that `exec` with no
  script behaves as `native` did

#### Scenario: Any other name is refused as unknown

- **WHEN** a machine declares a backend that is neither `cloud-init` nor `exec` nor the former name
- **THEN** rendering fails, naming the two backends that exist, with no third described as planned

## REMOVED Requirements

### Requirement: A backend that is designed but not implemented is refused with the reason

**Reason**: it described one value, `systemd-credentials`, which is no longer a name the chart knows.
The gap it was filed against — a machine that cannot run cloud-init — is served by `exec`, and the
mechanism it named is systemd's, which a chart whose backends are chosen for being agnostic should
not carry. What remains is the general form, already required: an unknown backend is refused and the
accepted ones are listed.
