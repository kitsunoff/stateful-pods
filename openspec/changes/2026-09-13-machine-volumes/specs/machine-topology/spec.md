## MODIFIED Requirements

### Requirement: Each machine renders a StatefulSet, a rootfs volume and a headless Service

For each declared machine the chart SHALL render exactly one StatefulSet, exactly one rootfs
PersistentVolumeClaim declared through the StatefulSet's volume claim templates, and exactly one
headless Service.

The rootfs claim SHALL request the `ReadWriteOnce` access mode, because a root filesystem can only
be mounted by one instance at a time.

A machine MAY declare further volumes, each of which adds one more volume claim template or one more
pod volume, depending on whether the chart provisions it. The root filesystem's claim template SHALL
remain the first, so that the guest container mounts it before anything mounted inside it.

#### Scenario: A machine's objects are rendered

- **WHEN** a release declares one machine
- **THEN** the rendered manifest contains one StatefulSet, one headless Service, and a volume claim
  template for the rootfs

#### Scenario: The rootfs volume is single-writer

- **WHEN** the rootfs volume claim template is rendered
- **THEN** its access modes are exactly `["ReadWriteOnce"]`

#### Scenario: Declared volumes follow the root filesystem

- **WHEN** a machine declares volumes the chart provisions
- **THEN** the rootfs claim template is the first, and one further claim template is rendered per
  declared volume
