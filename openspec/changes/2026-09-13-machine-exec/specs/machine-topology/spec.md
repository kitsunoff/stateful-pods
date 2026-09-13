## ADDED Requirements

### Requirement: A machine whose script is supplied renders a Job and an identity of its own

Where a machine on the `exec` backend supplies a script, the chart SHALL render exactly one Job, one
ServiceAccount, one Role and one RoleBinding for it, all named from the machine's own object name,
and the Job SHALL be named so that its name changes when and only when what it would run changes.

A Job's specification is immutable once it exists, so a Job whose name stayed the same while its
script changed would make `helm upgrade` fail with `field is immutable`. Putting a digest of the
material in the name is therefore not decoration: it is what makes an unchanged script a no-op, a
changed script a new run, and an uninstall a clean removal.

The machine's own pod SHALL NOT change when the script does: the script is applied from outside a
running machine, so nothing about the pod depends on it.

#### Scenario: The objects are rendered together

- **WHEN** release `lab` declares machine `web` on the `exec` backend with a script
- **THEN** a ServiceAccount, a Role and a RoleBinding named from `lab-web` are rendered, and one Job
  whose name carries a digest of what it would run

#### Scenario: Nothing is rendered without a script

- **WHEN** a machine on the `exec` backend supplies no script
- **THEN** no Job, ServiceAccount, Role or RoleBinding is rendered for it

#### Scenario: The Job's name follows the material

- **WHEN** the script changes and the release is rendered again
- **THEN** the Job's name differs from the one rendered before, and the machine's pod specification
  is unchanged

### Requirement: Provisioning material is mounted into the one container that consumes it

Where a machine supplies provisioning material, the chart SHALL mount it into the single container
that acts on it and into no other, whichever backend that container belongs to.

Under `cloud-init` that is the preparation step that writes the seed. Under `exec` it is the Job that
carries the script to the machine, and the preparation step is given nothing — it has nothing to do
with a script that runs after the machine has booted, and the guest container must never be able to
read it at all.

#### Scenario: The cloud-init material reaches the preparation step alone

- **WHEN** a machine on `cloud-init` supplies material
- **THEN** the preparation step that writes the seed mounts it, and no other container does

#### Scenario: The exec material reaches the Job alone

- **WHEN** a machine on `exec` supplies a script
- **THEN** the Job mounts it, no container of the machine's own pod does, and the machine's pod is
  given no ServiceAccount token
