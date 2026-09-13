## Why

A machine has exactly one volume, and it is the machine. Everything a machine writes — the
operating system, the package cache, the database, the media library — goes on the same claim, at
the same size, in the same storage class, and is captured or restored as one thing.

That is wrong for the workloads a pet is actually run for. A database wants fast local storage for
its data and does not want its `/var/lib/postgresql` to be the same volume as its `/usr`. A media
box wants a large, slow, shared claim mounted at one path and an 8 GiB root everywhere else. And a
machine whose root filesystem has to be rebuilt — a new source, a different distribution — should
not lose its data with it, which today it does, because the data is on the root.

Proxmox has had this since the beginning: a container has a rootfs and up to two hundred and
fifty-six mount points, each its own volume with its own size. This is that, on the primitive
Kubernetes already offers.

## What Changes

- **A machine declares further volumes**, at `machines.<name>.volumes`, keyed by the name each is
  known by. Each names the `mountPath` it appears at inside the machine, and either a `size` — the
  chart provisions a claim for it, like the root filesystem — or an `existingClaim`, naming a
  PersistentVolumeClaim that is already there.
- **A provisioned volume is a claim template of its own**, so it is created with the machine, bound
  per instance, and retained when the release is uninstalled exactly as the root filesystem is. It
  takes its own `storageClassName` and its own `dataSource`, so a machine can restore one volume
  from a snapshot without touching another.
- **The mount is made where the machine will see it.** The guest container mounts the volume inside
  the root filesystem's own mount point, so that after the root change the volume is at the
  `mountPath` the values name and nothing in the machine has to know it was ever elsewhere.
- **Mount paths the shim owns are refused**, with a message naming the path and the reason: `/proc`,
  `/sys`, `/dev`, `/run`, `/tmp` and `/sys/fs/cgroup` are mounted over by the boot sequence, so a
  volume placed at or under one of them would be shadowed the instant the machine started — a
  volume that exists, binds and holds nothing.
- **`values.yaml`, the chart README, the project README and `NOTES.txt`** document the block, the
  names the claims get, and the fact that those names are as permanent as the root filesystem's.

Non-goals, named so they are not mistaken for omissions:

- **Changing a volume's size after it exists.** A StatefulSet's volume claim templates are immutable
  after creation, so raising `size` renders a manifest the API server refuses. That is a property of
  the primitive, and the chart says so where the input is rather than pretending to offer a resize.
- **`emptyDir`, `hostPath`, `configMap` and every other volume kind.** A machine already has a
  `tmpfs` `/tmp` and `/run`; a host path is the node's filesystem handed to a machine that is meant
  to be portable; and configuration belongs to the provisioning backends. What is offered is
  persistent storage, which is the thing a machine cannot get any other way.
- **Access modes.** A provisioned volume is `ReadWriteOnce`, for the same reason the root filesystem
  is: a machine is one instance. A claim that needs anything else is an `existingClaim`, where the
  mode is the claim's own business.
