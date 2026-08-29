## ADDED Requirements

### Requirement: The image carries the logic the chart runs

The shim image SHALL carry every script the chart's containers execute, at paths that are part of
the image's contract. The chart SHALL NOT deliver script content to a container through a
Kubernetes object or any other runtime mechanism.

A script and the tools it calls are one artifact. Delivering the script separately means the two can
be different versions of each other on a running machine, and it means the pod carries a copy of the
chart's logic that has to be mounted into every container that runs any of it.

This also makes a `shim.image` override a stronger statement than it was: the image supplies the
behaviour, not merely the userland it runs in.

#### Scenario: Every command is a path inside the image

- **WHEN** a machine is rendered with either source kind
- **THEN** every command the chart sets on a container is an absolute path inside the shim image

#### Scenario: No rendered object carries script content

- **WHEN** a release is rendered
- **THEN** the manifest contains no object whose data is the chart's own scripts

#### Scenario: The helpers that run inside the machine come from the image

- **WHEN** a machine boots and the helpers that run after the root change are installed onto its
  volume
- **THEN** they are taken from the shim image

## MODIFIED Requirements

### Requirement: One image serves every container the chart runs

The chart SHALL run all of its own containers from a single image. It SHALL NOT require the user to
supply a different image for seeding, for customization or for the guest container, and it SHALL NOT
run any container from an image it did not choose.

Splitting them duplicates most of the content for no benefit and multiplies what has to be built,
published, pinned and kept in step. Running one from an image the user named as a rootfs source
makes that image a runtime dependency of the machine and dictates what the image must contain.

#### Scenario: A release refers to one chart-supplied image

- **WHEN** a machine is rendered
- **THEN** every container whose image the chart chooses refers to the same image

#### Scenario: No container runs a machine's source

- **WHEN** a machine is rendered with either source kind
- **THEN** no container in its pod runs the machine's rootfs source as its image

### Requirement: The image can open every source the chart accepts

The image SHALL be able to obtain and unpack every rootfs source kind the chart accepts, and SHALL
preserve ownership, permissions, extended attributes, file capabilities and sparseness while doing
so. For an archive source this means decompressing every format those archives are distributed in;
for an image source it means fetching the image from a registry and flattening it, including
resolving a multi-architecture reference to a named architecture.

The most widely distributed LXC templates use a compression format that the minimal userlands in
common use cannot read at all, and the archivers in those userlands silently discard extended
attributes. Either gap produces a machine that looks fine and is not. The same is true of a flatten
that drops an attribute while applying image layers.

#### Scenario: The most common template format can be opened

- **WHEN** a machine declares a template distributed in the format the reference distributor uses
- **THEN** the image can unpack it

#### Scenario: Attributes survive unpacking

- **WHEN** an archive containing files with capability attributes is unpacked
- **THEN** those attributes are present on the result

#### Scenario: Attributes survive a flattened image

- **WHEN** an image containing files with capability attributes is fetched and flattened
- **THEN** those attributes are present on the result
