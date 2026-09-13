## ADDED Requirements

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
