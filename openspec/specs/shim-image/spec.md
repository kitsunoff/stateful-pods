## Purpose

Defines the contract of the container image the chart runs its own containers from: what it must be
able to do, how a release refers to it, and the boundary between it and the machine's own operating
system.

## Requirements

### Requirement: One image serves every container the chart runs

The chart SHALL run all of its own containers from a single image. It SHALL NOT require the user to
supply a different image for seeding, for customization or for the guest container.

Splitting them duplicates most of the content for no benefit and multiplies what has to be built,
published, pinned and kept in step.

The one exception is the OCI seeding path, where the seeding step necessarily runs from the
machine's source image; that is a property of how an OCI source is copied, not a second image the
chart ships.

#### Scenario: A release refers to one chart-supplied image

- **WHEN** a machine is rendered
- **THEN** every container whose image the chart chooses refers to the same image

### Requirement: The image can open every source the chart accepts

The image SHALL be able to decompress and unpack every archive format the accepted rootfs sources are
distributed in, and SHALL preserve ownership, permissions, extended attributes, file capabilities and
sparseness while doing so.

The most widely distributed LXC templates use a compression format that the minimal userlands in
common use cannot read at all, and the archivers in those userlands silently discard extended
attributes. Either gap produces a machine that looks fine and is not.

#### Scenario: The most common template format can be opened

- **WHEN** a machine declares a template distributed in the format the reference distributor uses
- **THEN** the image can unpack it

#### Scenario: Attributes survive unpacking

- **WHEN** an archive containing files with capability attributes is unpacked
- **THEN** those attributes are present on the result

### Requirement: A release refers to the image by an immutable identifier

The chart SHALL refer to its image by an identifier that cannot come to mean different content
later, and SHALL NOT default to one that tracks a moving target.

A machine is a pet whose disk must be reproducible. An image reference that silently changes what it
resolves to makes a machine's own boot path unreproducible, and does it invisibly.

#### Scenario: The default reference is immutable

- **WHEN** the chart is installed without overriding the image
- **THEN** the reference it uses identifies exactly one set of contents

#### Scenario: The image is available for the architectures the audience runs

- **WHEN** a machine is scheduled to a node of any architecture the project supports
- **THEN** the image resolves to a build for that architecture without the user selecting one

### Requirement: The chart's containers never execute the guest's programs

The containers the chart runs SHALL only read, write and remove files inside the machine's root
filesystem. They SHALL NOT execute a program from it.

The chart's image and the machine's operating system are built against different system libraries.
A program taken from the machine's filesystem and run from the chart's container would resolve its
loader against the wrong root, and would fail in a way that looks like a corrupt guest. Where a
program is genuinely needed to produce a file, it is the chart image's own program that runs and its
output that is written in.

#### Scenario: Preparation is done by writing files

- **WHEN** the chart prepares a machine's root filesystem
- **THEN** it does so by writing files into it, never by running a program from it

#### Scenario: Generated content comes from the chart's own tools

- **WHEN** preparing a machine requires content that a program must generate
- **THEN** the program that runs is the chart image's own, and only its output is written into the
  machine's filesystem

### Requirement: The image carries a Kubernetes client

The shim image SHALL carry `kubectl`, because the chart runs every container it renders from this
one image and one of them reaches a machine through the cluster's API.

It is carried by every machine, including the ones that never use the backend that needs it. That is
accepted for the reason the image already carries `crane` and GNU `tar`: one image is what stops a
running machine having two versions of its own logic, and a second image for one Job would be a
second digest to pin, a second package to publish and a second thing to keep in step with the chart
— to save a layer a node pulls once and shares between every machine on it.

The client SHALL come from the base image's own package repository rather than being downloaded at
build time, so that the version it is at is a property of the base image the Containerfile pins.

#### Scenario: The client is present and executable

- **WHEN** the shim image is built
- **THEN** `kubectl` is on its path and reports a client version

#### Scenario: It is present for every architecture the image is published for

- **WHEN** the image is built for each supported architecture
- **THEN** each build carries the client

### Requirement: The image carries a packet-filter client

The shim image SHALL carry `iptables` and `ip6tables`, because the step that programs a machine's
network namespace runs this image like every other container the chart renders.

#### Scenario: Both clients are present and executable

- **WHEN** the shim image is built
- **THEN** `iptables` and `ip6tables` are on its path and report a version
