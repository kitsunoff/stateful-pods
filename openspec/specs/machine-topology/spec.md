## Purpose

Defines how a Helm release maps onto machines and the Kubernetes objects that represent them: how
machines are declared, how their objects are named, which objects each machine gets, and the
pet-oriented storage and update semantics those objects must have.

## Requirements

### Requirement: Machines are declared as a keyed map

The chart SHALL accept machines as a map keyed by machine name, rather than as flat single-machine
values or as a list. The chart SHALL NOT expose a `replicas` input at any level.

A release SHALL be able to hold more than one machine. The count of entries SHALL never on its own
be a reason to refuse a map.

#### Scenario: A machine is declared by name

- **WHEN** values declare `machines.web` with the inputs a machine requires
- **THEN** the chart renders the objects for a machine identified as `web`

#### Scenario: Several machines are declared in one release

- **WHEN** values declare `machines.web` and `machines.db`
- **THEN** the chart renders the objects for both

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

### Requirement: A machine that asks for its ports to be enforced renders one policy object

Where a machine asks that only its declared ports be reachable, the chart SHALL render exactly one
NetworkPolicy for it, named with the machine's own object name and selecting the machine's pod on
the same labels its StatefulSet selects on.

One object per machine, named like every other object a machine gets, so that a release with two
machines has two policies that can be read, diffed and deleted independently. Selecting on the
machine's own selector labels rather than on anything broader keeps a policy from reaching a
neighbour that happens to share a release.

#### Scenario: The policy is named like the machine's other objects

- **WHEN** release `lab` declares machine `web` and asks for its ports to be enforced
- **THEN** a NetworkPolicy named `lab-web` is rendered, selecting the same labels the StatefulSet
  selects on

#### Scenario: No policy without the request

- **WHEN** a machine does not ask for its ports to be enforced
- **THEN** no NetworkPolicy is rendered, whether or not it declares ports

### Requirement: A machine whose script is supplied renders a Job and an identity of its own

Where a machine on the `exec` backend supplies a script, the chart SHALL render exactly one Job, one
ServiceAccount, one Role and one RoleBinding for it, all named from the machine's own object name,
and the Job SHALL be named so that its name changes when and only when what it would run changes.

A Job's specification is immutable once it exists, so a Job whose name stayed the same while its
script changed would make `helm upgrade` fail with `field is immutable`. Putting a digest of the
material in the name is therefore not decoration: it is what makes an unchanged script a no-op, a
changed script a new run, and an uninstall a clean removal.

The machine's own pod SHALL NOT change when the script does: the script is applied from outside a
running machine, so nothing about the pod depends on it.

#### Scenario: The objects are rendered together

- **WHEN** release `lab` declares machine `web` on the `exec` backend with a script
- **THEN** a ServiceAccount, a Role and a RoleBinding named from `lab-web` are rendered, and one Job
  whose name carries a digest of what it would run

#### Scenario: Nothing is rendered without a script

- **WHEN** a machine on the `exec` backend supplies no script
- **THEN** no Job, ServiceAccount, Role or RoleBinding is rendered for it

#### Scenario: The Job's name follows the material

- **WHEN** the script changes and the release is rendered again
- **THEN** the Job's name differs from the one rendered before, and the machine's pod specification
  is unchanged

### Requirement: Provisioning material is mounted into the one container that consumes it

Where a machine supplies provisioning material, the chart SHALL mount it into the single container
that acts on it and into no other, whichever backend that container belongs to.

Under `cloud-init` that is the preparation step that writes the seed. Under `exec` it is the Job that
carries the script to the machine, and the preparation step is given nothing — it has nothing to do
with a script that runs after the machine has booted, and the guest container must never be able to
read it at all.

#### Scenario: The cloud-init material reaches the preparation step alone

- **WHEN** a machine on `cloud-init` supplies material
- **THEN** the preparation step that writes the seed mounts it, and no other container does

#### Scenario: The exec material reaches the Job alone

- **WHEN** a machine on `exec` supplies a script
- **THEN** the Job mounts it, no container of the machine's own pod does, and the machine's pod is
  given no ServiceAccount token

### Requirement: A machine with an egress policy carries a proxy and the step that programs its namespace

Where a machine declares an egress policy, the chart SHALL render one ConfigMap holding the proxy's
configuration, one long-running proxy container in the machine's own pod, and one preparation step
that programs the pod's network namespace and exits.

The proxy is in the machine's pod and not beside it because it must share the machine's network
namespace: a redirect is a rule in that namespace, and a proxy in another pod would be a proxy the
redirect could not reach.

#### Scenario: The proxy and its step are rendered together

- **WHEN** a machine declares an egress policy
- **THEN** a ConfigMap named for the machine, a proxy container that keeps running, and a
  preparation step that programs the namespace are all rendered

#### Scenario: Nothing is rendered without a policy

- **WHEN** a machine declares no egress policy
- **THEN** none of them is rendered, and the pod is what it was

### Requirement: A change to an egress policy replaces the machine

The chart SHALL replace a machine's pod when its egress policy changes.

The policy is a ConfigMap, and a ConfigMap whose content changes restarts nothing on its own: the
proxy would go on enforcing the policy it was started with, and the values would describe something
the machine is not doing. Unlike provisioning material, the whole of an egress policy is visible to
the chart, so the digest that triggers the replacement is exact.

#### Scenario: A changed policy takes effect

- **WHEN** a machine's egress policy changes and the release is upgraded
- **THEN** the machine's pod is replaced and the proxy starts with the new policy

#### Scenario: An unrelated change does not replace the machine

- **WHEN** a release is upgraded and the machine's egress policy is unchanged
- **THEN** the digest that governs the replacement is unchanged

### Requirement: Machines in one release share nothing but the release

No object rendered for one machine SHALL be shared with, or named the same as, an object rendered
for another machine in the same release. A change to one machine's values SHALL NOT replace another
machine's pod.

This is what makes several machines in a release safe rather than merely possible. Every helper the
chart has takes an explicit machine context and reads no global for it, precisely so that a value
belonging to one machine can never reach another — and a helper that reached for "the only machine"
would be correct until the day a release had two.

A machine's declared volumes are the one place two machines meet by name: a volume claim template is
named for the volume rather than for the machine, so two machines may each declare `data`. They are
still two volumes, because the controller binds a claim per instance.

#### Scenario: No object name is shared

- **WHEN** a release declares two machines, each with ports, an ingress posture, an egress policy, a
  declared volume and a script
- **THEN** every object rendered carries a name no other object in that release has

#### Scenario: A machine's inputs reach only its own objects

- **WHEN** two machines in one release declare different volume sizes
- **THEN** each machine's claim templates request that machine's own sizes

#### Scenario: Two machines may declare a volume of the same name

- **WHEN** two machines in one release each declare a volume called `data`
- **THEN** each gets a volume of its own, bound to its own instance

#### Scenario: One machine's change does not disturb another

- **WHEN** one machine's values change and the release is upgraded
- **THEN** the other machines' pods are not replaced
