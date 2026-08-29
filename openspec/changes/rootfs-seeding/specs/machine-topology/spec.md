## MODIFIED Requirements

### Requirement: The guest container's image is the shim, not the machine's operating system

The guest container SHALL run the chart's shim image. A machine's rootfs source SHALL NOT be used as
the image of any container in which the machine itself runs.

The one place a source may be a container image is the step that seeds the volume from it, and only
for an OCI source: copying an image's filesystem faithfully requires a tool from inside that image,
so the seeding step necessarily runs there. That step exits before the machine starts and never
becomes the machine.

The machine's operating system lives in the persistent volume, seeded once from the source. The
guest container's image only provides the small program that mounts that volume and hands control to
the guest's init. Conflating the two would make an OCI source look like a normal container image and
would leave an LXC template source — which is a tarball, not an image — with nothing to run.

#### Scenario: The guest container runs the shim

- **WHEN** a machine is rendered with either source kind
- **THEN** the guest container's image is the configured shim image

#### Scenario: An LXC template source renders without a container image of its own

- **WHEN** a machine declares an LXC template source
- **THEN** the rendered manifest contains no container whose image is derived from that source

#### Scenario: An OCI source is a container image only where it is copied

- **WHEN** a machine declares an OCI source
- **THEN** the only container whose image is that source is the step that seeds the volume, and the
  machine's own container is not it
