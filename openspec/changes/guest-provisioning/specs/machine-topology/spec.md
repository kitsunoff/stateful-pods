## ADDED Requirements

### Requirement: Provisioning material is assembled into one directory of fixed paths

Where a machine supplies provisioning material, the chart SHALL assemble it into a single directory
of deterministic file names, mounted into the step that writes it into the machine and into no other
container.

Assembling it in the pod spec is what lets the step that consumes it read fixed paths and never
learn where a value came from: no API access, no ServiceAccount token, and one code path for inline
and referenced material alike. Two inputs resolving to the same file name is rejected by the kubelet
rather than by the chart, so the chart is responsible for the names being unique.

#### Scenario: The step that provisions reads fixed paths

- **WHEN** a machine supplies provisioning material inline and by reference
- **THEN** both arrive in the same directory, under the names that input is defined to use

#### Scenario: The material is mounted nowhere else

- **WHEN** a machine supplies provisioning material
- **THEN** no other container in the pod mounts it

#### Scenario: A machine supplying nothing gets no volume

- **WHEN** a machine supplies no provisioning material
- **THEN** no provisioning volume is rendered

### Requirement: A change to inline provisioning material restarts the machine

The chart SHALL restart a machine when provisioning material supplied inline changes, and SHALL
offer an explicit way to ask for the same restart when the material is supplied by reference.

Helm renders inline material itself, so it can see the change; it cannot see inside a Secret it does
not own, so a rotated referenced Secret produces no restart of its own. Pretending otherwise would
leave a machine running on material that no longer matches its values with nothing saying so.

#### Scenario: Changed inline material takes effect

- **WHEN** inline provisioning material changes and the release is upgraded
- **THEN** the machine restarts and is provisioned from the new material

#### Scenario: A referenced rotation can be applied deliberately

- **WHEN** referenced provisioning material has rotated
- **THEN** the machine can be restarted by changing an explicit revision input, without editing
  anything else
