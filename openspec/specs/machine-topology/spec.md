## Purpose

Defines how a Helm release maps onto machines and the Kubernetes objects that represent them: how
machines are declared, how their objects are named, which objects each machine gets, and the
pet-oriented storage and update semantics those objects must have.

## Requirements

### Requirement: Machines are declared as a keyed map

The chart SHALL accept machines as a map keyed by machine name, rather than as flat single-machine
values or as a list. The chart SHALL NOT expose a `replicas` input at any level.

The map form is required even while only one machine per release is supported, so that adding
further machines later does not change the shape of existing values files.

#### Scenario: A machine is declared by name

- **WHEN** values declare `machines.web` with the inputs a machine requires
- **THEN** the chart renders the objects for a machine identified as `web`

#### Scenario: Replica scaling is not offered

- **WHEN** a user searches the chart's values for a way to run several copies of one machine
- **THEN** no `replicas` input exists at the release level or inside a machine entry

### Requirement: Object names derive from release and machine name

Every object rendered for a machine SHALL be named `<release>-<machine>`. The machine name SHALL be
part of the object name even when the release declares only one machine.

This naming is permanent: a machine's rootfs lives in a PersistentVolumeClaim bound to its
StatefulSet, so a later rename would orphan the volume and recreate the machine empty.

#### Scenario: Objects carry the machine name

- **WHEN** release `lab` declares machine `web`
- **THEN** the StatefulSet, Service and rootfs PersistentVolumeClaim for that machine are all named
  `lab-web`

#### Scenario: Adding a second machine renames nothing

- **WHEN** release `lab` already runs machine `web` and a machine `db` is added to the same release
- **THEN** the objects for `web` keep the names they had, and the objects for `db` are named
  `lab-db`

### Requirement: Each machine renders a StatefulSet, a rootfs volume and a headless Service

For each declared machine the chart SHALL render exactly one StatefulSet, exactly one rootfs
PersistentVolumeClaim declared through the StatefulSet's volume claim templates, and exactly one
headless Service.

The rootfs claim SHALL request the `ReadWriteOnce` access mode, because a root filesystem can only
be mounted by one instance at a time.

#### Scenario: A machine's objects are rendered

- **WHEN** a release declares one machine
- **THEN** the rendered manifest contains one StatefulSet, one headless Service, and a volume claim
  template for the rootfs

#### Scenario: The rootfs volume is single-writer

- **WHEN** the rootfs volume claim template is rendered
- **THEN** its access modes are exactly `["ReadWriteOnce"]`

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

### Requirement: A machine is a single instance with pet update semantics

A machine's StatefulSet SHALL declare exactly one replica. The chart SHALL NOT perform a rolling
update that would run two instances of the same machine at once, because both would attempt to
mount the same root filesystem.

#### Scenario: One instance per machine

- **WHEN** a machine's StatefulSet is rendered
- **THEN** its replica count is 1

#### Scenario: An update never doubles the instance

- **WHEN** a change to a machine's values requires its pod to be replaced
- **THEN** the existing pod is terminated before its replacement is started

### Requirement: A machine's rootfs may be restored from a snapshot

The rootfs volume claim SHALL accept an optional reference to an existing volume snapshot, so that
a machine can be created from a previously captured root filesystem instead of from its source.

This is the whole of the chart's backup story. Taking snapshots, retaining them and copying them
off-cluster belong to the cluster's snapshot tooling; being able to start from one is the part that
cannot be done from outside.

#### Scenario: A machine is created from a snapshot

- **WHEN** a machine names an existing volume snapshot as its rootfs data source
- **THEN** its volume claim template requests that snapshot as the claim's data source

#### Scenario: No snapshot named means an empty volume

- **WHEN** a machine names no snapshot
- **THEN** its volume claim template carries no data source and the volume is provisioned empty

### Requirement: The guest's hostname follows the pod unless overridden

A machine SHALL be able to declare a hostname. When it does not, the machine's hostname SHALL be
the pod's own hostname, which the kubelet already sets.

#### Scenario: Default hostname

- **WHEN** a machine declares no hostname
- **THEN** the pod specification sets no explicit hostname and the machine takes the one the
  kubelet assigns

#### Scenario: Explicit hostname

- **WHEN** a machine declares a hostname
- **THEN** the pod specification carries that hostname

### Requirement: The rootfs volume survives release deletion

A machine's root filesystem SHALL NOT be deleted as a side effect of deleting the Helm release or
of scaling operations performed by the StatefulSet controller. Destroying a machine's state SHALL
require a deliberate, separate action by the user.

The rootfs holds everything that makes the machine a pet. Deleting it on `helm uninstall` would
make an ordinary mistake unrecoverable.

#### Scenario: Uninstalling the release leaves the volume

- **WHEN** a release running a machine is uninstalled
- **THEN** the machine's rootfs PersistentVolumeClaim still exists afterwards

#### Scenario: The StatefulSet controller does not reclaim the volume

- **WHEN** a machine's StatefulSet is deleted or scaled down
- **THEN** the retention policy in effect keeps the rootfs PersistentVolumeClaim

### Requirement: A machine's pod selector never changes

The label selector of a machine's StatefulSet SHALL contain only labels that are stable for the
life of the machine. It SHALL NOT contain the chart version, the application version, the release
revision, or any other value that changes between upgrades.

A StatefulSet's selector is immutable after creation. A selector containing a version label makes
the first `helm upgrade` fail, and the only way out is to delete and recreate the StatefulSet —
which is exactly the operation this chart exists to make unnecessary.

#### Scenario: Upgrading does not change the selector

- **WHEN** a machine is rendered, then rendered again after the chart version and the machine's
  image have both changed
- **THEN** the StatefulSet's selector is byte-for-byte identical in both renders

#### Scenario: Version labels are present but not selected on

- **WHEN** a machine's StatefulSet is rendered
- **THEN** version-bearing labels may appear in the object's metadata, and none of them appear in
  the selector

### Requirement: A machine is reachable by a stable DNS name

Each machine SHALL be addressable through its headless Service at a name derived from the machine's
object name and namespace, so that other workloads can reach a machine without depending on its pod
IP.

#### Scenario: Stable name for a machine

- **WHEN** machine `web` in release `lab` is running in namespace `homelab`
- **THEN** it is reachable in-cluster at a name derived from `lab-web` and `homelab`, and that name
  does not change when the pod is recreated

### Requirement: A machine's name resolves while it is still booting

A machine SHALL be reachable at its stable name from the moment its pod exists, including while its
operating system is still starting and before it reports itself ready.

An operating system takes time to boot, and the readiness signal that gates a Service endpoint would
otherwise make the machine unresolvable for exactly the period in which someone is most likely to be
looking for it. A machine is a pet with an address, not a member of a load-balanced pool whose
traffic must be withheld until it is healthy.

#### Scenario: A booting machine can be reached

- **WHEN** a machine's operating system is still starting
- **THEN** its stable in-cluster name still resolves to it

#### Scenario: The name does not disappear when the machine is unwell

- **WHEN** a machine stops reporting itself ready
- **THEN** its stable name continues to resolve, so that it can be reached and inspected

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
