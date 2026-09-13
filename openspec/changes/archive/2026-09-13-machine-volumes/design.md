## Context

A machine's root filesystem is a volume claim template on its StatefulSet, mounted into every
preparation step at `/mnt/rootfs` and into the guest container at the same path, where the boot
script turns it into the machine's root with `pivot_root`. That is the whole of the chart's storage
today.

Proxmox's model, which this project follows deliberately, separates the two: a container has a
`rootfs` and up to 256 `mp<N>` mount points, each with its own storage, its own size and its own
backup flag. The distinction is not cosmetic — it is what lets a container's operating system be
rebuilt without its data, and its data be placed on different storage from its operating system.

## Goals

- A machine declares further volumes beside its root filesystem, each with its own size, class and
  restore source, at a path of its own choosing inside the machine.
- A machine can mount a claim somebody else made, which is how a machine reaches shared storage the
  chart has no business provisioning.
- The volumes are as durable as the root filesystem: created with the machine, retained when the
  release is uninstalled, and never removed as a side effect of anything.

## Non-goals

See the proposal. In short: no resize, no non-persistent volume kinds, no access modes.

## Decisions

### The mount is a nested volume mount, not a bind performed by the shim

The guest container already mounts the root filesystem at `/mnt/rootfs`. A declared volume is
mounted at `/mnt/rootfs<mountPath>` in the same container, so that when `pivot_root` makes
`/mnt/rootfs` the machine's root, the volume is already at the path the values named and the boot
script does not have to know it exists.

The alternative was to mount each volume somewhere neutral and have `boot.sh` bind it into the root
before the pivot, next to the device binds it already performs. That was rejected, because it is
more machinery for the same result and because it would put the feature inside the shim image —
making it a matched-pair release, and making a machine's storage layout depend on which shim it was
running rather than on which chart rendered it.

Two things make the simpler form correct rather than merely shorter:

- **The order is the declared order.** The kubelet passes a container's `volumeMounts` to the
  runtime in the order they appear, and the root filesystem is first in that list for every
  machine. CRI-O additionally sorts mounts by path depth, which produces the same order. A mount
  point that does not exist yet is created by the runtime, inside the root filesystem's own volume,
  where it persists.
- **A sub-mount under the new root is exactly what `pivot_root` is specified to carry.** The call
  requires the new root to be a mount point; mounts underneath it move with it. This is what LXC
  does for its own mount points.

The integration suite asserts the result from inside a booted machine rather than trusting either
claim: that the path is a mount, that it is a different filesystem from `/`, and that what is
written to it survives the pod being deleted.

### A provisioned volume is a claim template; an existing claim is a pod volume

`size` renders another entry in `volumeClaimTemplates`, which is what makes it behave like the root
filesystem in every way that matters: the StatefulSet controller creates it, binds it to this
instance, and the retention policy the chart already declares — `Retain` on delete and on scale —
covers it without a second decision.

`existingClaim` renders an ordinary pod volume naming that claim. The chart creates nothing, so the
claim's size, class, access mode and lifetime are its owner's business. This is how a machine
reaches a ReadWriteMany share, which a claim template of this chart's could not offer: a machine is
one instance and its own claims say `ReadWriteOnce`.

Exactly one of the two, and naming both is refused. They are not a fallback for each other: one
creates storage and one consumes somebody else's, and guessing which was meant would either
provision a volume nobody asked for or silently ignore a size the user believed was in effect.

### The claim template is named for the volume, not for the machine

The root filesystem's claim template is named `<release>-<machine>`, which produces a claim called
`<release>-<machine>-<release>-<machine>-0`. A declared volume's template is named for the volume
alone — `data` — producing `data-<release>-<machine>-0`.

Not for symmetry's sake but because the alternative does not fit. A volume name in a pod
specification is a DNS-1123 label, at most 63 characters; the chart already allows an object name of
up to 61, so `<release>-<machine>-<volume>` would leave two characters for the volume's own name.
The pod-scoped name is unique as it stands, and the claim it produces still carries the machine's
name, because the StatefulSet controller appends the pod's.

The consequence is the same one the root filesystem carries, and it is stated in the same words:
**the name is permanent**. Renaming a volume does not move it — it orphans the old claim and
provisions a new empty one. Three names are refused outright because the pod already uses them:
the machine's own object name, `source-credentials` and `provisioning`.

### Mount paths the shim owns are refused

`boot.sh` mounts `/proc`, a read-only `/sys`, a `tmpfs` `/dev`, `/dev/pts`, `/dev/shm`, a `tmpfs`
`/run`, a `tmpfs` `/tmp` and a `cgroup2` hierarchy at `/sys/fs/cgroup` — over the root filesystem,
after the volumes are mounted. A declared volume at or under any of those would be shadowed the
instant the machine started: it would exist, it would bind, it would be empty every time, and
nothing would say why.

So the chart refuses those paths while it renders, naming the path and saying the boot sequence
mounts over it. `/` is refused separately, because a volume there is the root filesystem, which is
declared under `rootfs` and seeded — an entirely different thing from an empty claim mounted over
the operating system.

`/.stateful-pods` is refused too: it is where the chart keeps the record that says the volume has
been seeded, and a volume mounted over it would make every start look like a first one.

### What is not checked, and why

The chart does not refuse a path the machine's own source has content at. `/var/lib/postgresql`
holding a distribution's empty skeleton is the normal case, and mounting a volume over a populated
directory is ordinary Unix behaviour that the person who wrote the path intended. Refusing it would
mean the chart reading the machine's filesystem at render time, which it cannot do, or at boot,
where the refusal would arrive after the volume had been provisioned.

It is documented instead, at the input: what was at the path is hidden, not deleted, and it comes
back if the volume is removed.
