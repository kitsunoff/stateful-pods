## Purpose

Defines the files the chart maintains inside a running machine, why the machine cannot simply
inherit the pod's own, and how a machine takes one of them back.

## ADDED Requirements

### Requirement: The chart writes the pod's identity and resolver into the machine

On every boot the chart SHALL write the machine's host name, its host table and its resolver
configuration into the machine's own root filesystem, taking the values from what the pod itself was
given.

A pod receives these three files as mounts into the container image's filesystem. Once the machine's
root becomes the volume, those mounts are no longer in the machine's root, so a machine that does
nothing would boot with whatever its source image happened to ship — no resolver, and a host name
belonging to the image's build machine. Proxmox writes the same three files into a container's root
filesystem on every start, for the same reason.

#### Scenario: A machine knows its own name

- **WHEN** a machine boots
- **THEN** its host name inside the machine is the one the pod was given

#### Scenario: A machine can resolve names

- **WHEN** a machine boots
- **THEN** its resolver configuration is the cluster's, so that names resolve inside the machine as
  they do for any other workload

#### Scenario: The values are refreshed, not seeded once

- **WHEN** a machine is restarted and the pod's own values have changed
- **THEN** the machine's copies are updated to match, rather than keeping what the first boot wrote

### Requirement: A machine can take a managed file back

For each file the chart manages, the machine SHALL be able to declare that the chart must leave it
alone, and the chart SHALL then neither write nor remove it.

Some machines manage their own resolver, and a chart that overwrites it on every boot is a chart
that silently undoes the administrator's work. The opt-out is per file, so taking back the resolver
does not also mean taking back the host name.

#### Scenario: A file the machine claims is left alone

- **WHEN** a machine declares that one of the managed files is its own
- **THEN** that file is neither written nor removed on any subsequent boot

#### Scenario: Claiming one file does not claim the others

- **WHEN** a machine claims one managed file
- **THEN** the remaining managed files are still written

#### Scenario: The opt-out lives with the machine

- **WHEN** a machine's volume is restored elsewhere
- **THEN** the files it had claimed are still claimed, because the declaration travels with the
  machine rather than with the release
