## Purpose

Defines the input contract the chart enforces before it renders anything: which inputs are
mandatory, which values and combinations are rejected, and what each failure has to tell the user
so that a mistake is caught at render time rather than discovered as a broken machine.

## Requirements

### Requirement: Rendering fails rather than producing an unusable release

The chart SHALL reject invalid input by failing template rendering. It SHALL NOT render objects
that are known to be unusable, and it SHALL NOT silently substitute a value the user did not ask
for.

Every rejection message SHALL name the offending values path and state what the user must do to
fix it.

#### Scenario: A rejection names the path and the fix

- **WHEN** any input is rejected
- **THEN** the error message contains the values path that caused it and an instruction describing
  the accepted values or the required action

#### Scenario: Invalid input produces no manifest

- **WHEN** rendering is attempted with input that violates any requirement in this capability
- **THEN** no Kubernetes manifest is emitted

### Requirement: The security mode is mandatory and explicit

Each machine SHALL declare its security mode explicitly. The chart SHALL NOT default to any mode,
and it SHALL NOT infer one from the cluster version or any other property of the environment.

The modes differ in how much isolation they give up and have prerequisites the chart cannot fully
verify, so choosing one on the user's behalf would either break silently or weaken security without
consent.

#### Scenario: Unset security mode is rejected

- **WHEN** a machine does not declare a security mode
- **THEN** rendering fails with a message that names the machine, lists the accepted modes, and
  summarises what each one requires of the cluster

#### Scenario: Unknown security mode is rejected

- **WHEN** a machine declares a security mode outside the accepted set
- **THEN** rendering fails with a message naming the offending value and listing the accepted modes

#### Scenario: No mode is chosen automatically

- **WHEN** rendering succeeds
- **THEN** the security posture applied to the pod corresponds to the mode the user set, and to no
  other source of information

### Requirement: A chosen mode is checked against what the cluster can support

Where a declared security mode has a prerequisite the chart *can* observe, the chart SHALL verify
it and fail rendering when it is not met, naming the prerequisite and the alternative mode.

This does not contradict the previous requirement. Observing the environment in order to reject an
impossible choice is safe; observing it in order to silently pick a different mode is not, and the
chart SHALL never do the latter.

#### Scenario: A cluster too old for user namespaces is rejected

- **WHEN** a machine declares the user-namespace mode and the target cluster's Kubernetes version
  predates support for user-namespaced pods
- **THEN** rendering fails with a message stating the required version, the version found, and that
  the privileged mode is the alternative

#### Scenario: An unverifiable prerequisite does not block rendering

- **WHEN** a prerequisite cannot be observed from the chart, such as the node's kernel version or
  the storage backend's support for idmapped mounts
- **THEN** rendering succeeds and the prerequisite is documented rather than guessed at

### Requirement: Exactly one machine per release, for now

The chart SHALL accept exactly one entry in the machines map. Declaring none or more than one SHALL
fail rendering.

The map form exists so the restriction can be lifted without changing the values shape; the
restriction exists because per-machine rendering is not yet implemented for more than one machine.

#### Scenario: No machines declared

- **WHEN** the machines map is absent or empty
- **THEN** rendering fails with a message stating that exactly one machine must be declared, and
  showing the expected shape

#### Scenario: More than one machine declared

- **WHEN** the machines map contains two or more entries
- **THEN** rendering fails with a message stating that multiple machines per release are not
  implemented yet and that each machine should be its own release for now

### Requirement: Machine names must be usable in object names

A machine name SHALL be a valid DNS-1123 label, and the resulting `<release>-<machine>` object name
SHALL fit within the length limit Kubernetes imposes on the object kinds the chart renders.

Because the machine name becomes part of every object name, an invalid name would otherwise surface
as an obscure API server rejection at install time rather than as a render error.

#### Scenario: Invalid machine name is rejected

- **WHEN** a machine is declared under a name that is not a valid DNS-1123 label
- **THEN** rendering fails with a message naming the machine and stating the naming rule

#### Scenario: Overlong combined name is rejected

- **WHEN** the combination of release name and machine name would exceed the length limit for a
  rendered object's name
- **THEN** rendering fails with a message showing the combined name, the limit, and by how much it
  is over

### Requirement: A machine must declare where its root filesystem comes from

Each machine SHALL declare a rootfs source, and that source SHALL name its kind explicitly. The
chart SHALL NOT supply a default source and SHALL NOT infer the kind from which fields happen to be
present.

There is no reasonable default operating system for someone else's machine, and a wrong guess would
be seeded onto a persistent volume and then never revisited. An explicit kind is required so that a
typo in a field name produces a message about the missing field rather than a silent switch to the
other kind.

#### Scenario: Missing source is rejected

- **WHEN** a machine does not declare a rootfs source
- **THEN** rendering fails with a message naming the machine, the values path the source belongs
  at, and the accepted kinds

#### Scenario: Unknown source kind is rejected

- **WHEN** a machine declares a source kind outside the accepted set
- **THEN** rendering fails with a message naming the offending value and listing the accepted kinds

#### Scenario: Fields belonging to the other kind are rejected

- **WHEN** a machine declares one source kind but supplies a field that belongs only to the other
- **THEN** rendering fails with a message naming the field and the kind it belongs to, rather than
  ignoring it

### Requirement: Each source kind requires its own fields

For an OCI source the chart SHALL require an image reference. For an LXC template source the chart
SHALL require both a URL and a checksum.

#### Scenario: OCI source without a reference is rejected

- **WHEN** a machine declares an OCI source with no image reference
- **THEN** rendering fails with a message naming the machine and the missing values path

#### Scenario: LXC source without a URL is rejected

- **WHEN** a machine declares an LXC template source with no URL
- **THEN** rendering fails with a message naming the machine and the missing values path

### Requirement: An LXC template source must carry a checksum

The chart SHALL require a checksum for every LXC template source, and SHALL NOT offer a way to skip
verification.

A template is an ordinary tarball fetched over the network and extracted into what becomes the
machine's root filesystem. Unlike an OCI image referenced by digest, nothing about the transport
establishes that the bytes are the intended ones, and Proxmox's own equivalent verifies templates
against a signed index that this chart has no counterpart for. Making verification optional would
mean shipping an easy path to executing an attacker's root filesystem as a privileged machine.

#### Scenario: Missing checksum is rejected

- **WHEN** a machine declares an LXC template source without a checksum
- **THEN** rendering fails with a message stating that a checksum is mandatory and why

#### Scenario: There is no way to disable verification

- **WHEN** a user looks for an input that skips or relaxes template checksum verification
- **THEN** no such input exists

### Requirement: Deliberately rejected inputs fail loudly

Where the design has considered and rejected an input, supplying it SHALL fail rendering with a
message explaining why it does not exist and what replaces it. The chart SHALL NOT ignore such
inputs silently.

A user who sets an option that does nothing has been misled about what their machine is
configured to do, and will discover it only when the machine misbehaves.

#### Scenario: An input that was designed away is rejected

- **WHEN** values set an input that the design has explicitly rejected, such as a per-machine init
  system selector or a replica count
- **THEN** rendering fails with a message stating that the input is not supported and describing
  the behaviour that replaces it

### Requirement: Values are documented at the point of use

The chart's `values.yaml` SHALL carry comments for every input it accepts, and SHALL state
explicitly where the chart deviates from what a Proxmox user would expect — in particular that
network and DNS configuration are not chart inputs because they belong to the cluster's CNI and DNS
policy.

#### Scenario: An omitted Proxmox-equivalent option is explained

- **WHEN** a user looks in `values.yaml` for an equivalent of a familiar per-guest network or DNS
  option
- **THEN** they find a comment stating that the option does not exist and why, rather than silence
