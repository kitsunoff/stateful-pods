# Prior art

Projects that already solved part of this problem, and what is worth taking from each.

## Proxmox VE `pve-container`

<https://github.com/proxmox/pve-container>

The reference design, covered in [01-proxmox-lxc-boot.md](01-proxmox-lxc-boot.md). Take: the
two-phase create/start split, the `.pve-ignore.<name>` opt-out, chroot-confined customization, the
per-distro plugin structure, the "never persist `/dev`" rule, and the OCI-config-to-container-config
translation table.

Proxmox VE 9 accepting OCI images as container templates
(`PVE::LXC::Create::restore_oci_archive()`) is direct confirmation that "OCI image as a seed for a
persistent rootfs" is a mainstream idea and not a hack.

## Incus / LXD

<https://linuxcontainers.org/incus/>

The upstream lineage of what Proxmox wraps. Incus 6.x can also run OCI images as system
containers, and has a first-class distinction between "image" (immutable, cached, content-addressed)
and "instance" (a persistent volume derived from an image). Its `lxd-agent` and instance-config
model are a good reference for how to express VM-like configuration declaratively.

Take: the image/instance split as an explicit concept, and the vocabulary.

## Coder `envbuilder`

<https://github.com/coder/envbuilder>

The closest existing thing to "provision a rootfs from an image and then become PID 1 in it",
running as an ordinary container.

How it works (from the source):

- It builds or fetches an image and **extracts it into the running container's own root
  filesystem**, rather than into a sub-path.
- It records completion with a marker file at `/.envbuilder/built`
  (`internal/workingdir/workingdir.go`), so a restart skips the destructive build step. The
  `SkipRebuild` option is exactly the `provisioned` marker idea.
- It then hands off with `syscall.Exec(args.InitCommand, ...)` — the process is replaced, so the
  init command becomes the container's PID 1 lineage. The docs explicitly mention execing systemd
  as the init command.

Take: the marker-file idempotency pattern, and `exec` rather than fork/supervise so that the guest
init genuinely owns PID 1 semantics.

## Gitpod `workspacekit`

<https://github.com/gitpod-io/gitpod> (PR #2048, "User Namespaced Workspaces")

A production system that gives every workspace its own root filesystem inside a Kubernetes pod,
unprivileged, via user namespaces. The architecture is a three-ring hand-off:

- **ring0** creates a new user namespace and mount namespace.
- **ring1** talks to a node daemon over a socket to trigger the UID/GID map writes and to get the
  container's rootfs marked (originally via `shiftfs`, before idmapped mounts existed).
- **ring2** mounts the marked rootfs, adds a set of rbind mounts, and `chroot`s into the shifted
  rootfs.

Take: the proof that a full custom rootfs inside a pod is viable at scale, and the reminder that
the hardest part is not the pivot but the ownership shifting — a problem that idmapped mounts and
Kubernetes user namespaces (stable 1.36) have since solved much more cleanly than shiftfs did.

## Sysbox

<https://github.com/nestybox/sysbox> (Nestybox, acquired by Docker in 2022)

An OCI runtime that makes containers able to run systemd, Docker, containerd and even Kubernetes
inside, without privileged mode. It does this by combining user namespaces with syscall trapping
and procfs/sysfs virtualisation, so the container sees a plausible `/proc` and `/sys` and gets a
writable, delegated `/sys/fs/cgroup`.

Status: actively maintained; officially supports CRI-O (which had native user-namespace support
first), with containerd 2.0+ support arriving as containerd's own user-namespace support matured.
K3s published integration documentation in 2025.

Take: if a cluster can install a RuntimeClass, sysbox removes most of the privilege problem
outright. The chart should support `runtimeClassName` as a value and document sysbox as the
recommended way to run a systemd guest without `CAP_SYS_ADMIN`. This is a genuine alternative to
architecture A's privilege requirements, not a competitor to the project.

## Kata Containers

<https://katacontainers.io/>

A VM-backed OCI runtime: each pod gets a lightweight VM. Solves isolation, not statefulness — the
rootfs is still image-derived and disposable. Relevant as a `runtimeClassName` option for people
who want stronger isolation around a stateful pod, and as a data point that "pods can be much more
VM-like than the default" is an accepted direction.

## KubeVirt

<https://kubevirt.io/>

Real VMs as Kubernetes objects, with PVC-backed disks (`DataVolume`), `containerDisk` for
image-seeded ephemeral disks, snapshots, and live migration. The Containerized Data Importer (CDI)
solves precisely the "populate a PVC from a registry artifact" problem, using volume populators.

Take: CDI is the reference implementation of the volume-populator approach described in
[02-kubernetes-primitives.md](02-kubernetes-primitives.md) §3.3, and its `DataVolume` API is worth
studying before designing the seeding CRD, if one is ever added. Also: KubeVirt is the honest
alternative that the README must name.

## warm-metal `csi-driver-image`

<https://github.com/warm-metal/csi-driver-image-populator>

A CSI driver that mounts a container image as a volume, predating the in-tree `image` volume
source. Now largely superseded by `ImageVolume` being stable in 1.36, but useful as a reference for
how image-as-volume behaves on older clusters, and as a fallback for clusters below 1.36.

## Kubernetes `image` volume source (KEP-4639)

<https://github.com/kubernetes/enhancements/issues/4639>

Not a project but the upstream feature this design leans on. Stable since 1.36. The KEP discussion
also covers the "writable, container-isolated volume content" follow-up, which is essentially
architecture B (overlay on top of an image volume) being considered for the platform itself. Worth
tracking: if upstream ships writable image volumes, part of this chart becomes unnecessary — which
would be a good outcome.

## systemd `nspawn` and portable services

<https://systemd.io/CONTAINER_INTERFACE/>

Not a Kubernetes thing, but the container interface document is the authoritative statement of what
systemd expects from its container environment: which mounts, which capabilities, cgroup
delegation, `container=` environment variable, `SIGRTMIN+3` for shutdown. Every requirement in
[02-kubernetes-primitives.md](02-kubernetes-primitives.md) §6 and §7 traces back to this document,
and the chart's systemd support should be validated against it point by point.
