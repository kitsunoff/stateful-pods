## ADDED Requirements

### Requirement: A machine's source is never a container image in its pod

The guest container SHALL run the chart's shim image. A machine's rootfs source SHALL NOT be used as
the image of any container in a machine's pod, at any stage, including the step that seeds the
volume from it.

The machine's operating system lives in the persistent volume, seeded once from the source. The
guest container's image only provides the small program that mounts that volume and hands control to
the guest's init. Conflating the two would make an OCI source look like a normal container image and
would leave an LXC template source — which is a tarball, not an image — with nothing to run.

Keeping the source out of the pod entirely is what makes the two source kinds symmetric: neither is
something the pod runs, both are something the chart reads. It also keeps a machine's ability to
start from depending on a reference that only has to resolve once, at seeding time.

#### Scenario: The guest container runs the shim

- **WHEN** a machine is rendered with either source kind
- **THEN** the guest container's image is the configured shim image

#### Scenario: An LXC template source renders without a container image of its own

- **WHEN** a machine declares an LXC template source
- **THEN** the rendered manifest contains no container whose image is derived from that source

#### Scenario: An OCI source is never a container image

- **WHEN** a machine declares an OCI source
- **THEN** no container in the rendered pod, at any stage, has that source as its image

## REMOVED Requirements

### Requirement: The guest container's image is the shim, not the machine's operating system

**Reason**: The requirement carved out one exception — the step that seeds a volume from an OCI
source ran that source as its image, because copying an image's filesystem faithfully needed a tool
from inside it. The chart now fetches and unpacks an OCI source from its own image, so the exception
has nothing left to describe. Everything else the requirement said is carried over unchanged by "A
machine's source is never a container image in its pod", which states the rule without it.

**Migration**: None. No values change, and no machine's volume is affected: a rendered pod simply
no longer refers to the machine's source anywhere.
