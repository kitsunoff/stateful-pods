# Research: fully stateful pods

This directory contains the research that precedes the `stateful-pods` Helm chart.

## The idea in one paragraph

A normal Kubernetes Pod treats its root filesystem as disposable: the container image is the
source of truth, the writable layer is thrown away on every restart, and state is only allowed
to live in explicitly declared volumes. A Proxmox VE LXC container does the opposite: the
template tarball (or OCI image) is used **once**, at creation time, to seed a persistent root
volume, and from that moment on the root filesystem itself *is* the state. Everything the host
needs to inject on each boot — hostname, DNS, network configuration, TTYs — is written into
that persistent rootfs by a pre-start hook, not baked into an image.

This research asks: can the LXC model be reproduced on top of stock Kubernetes primitives, with
a PersistentVolumeClaim as the root filesystem, init containers as the pre-start hook, and the
main container as `lxc-start`?

Short answer: yes, with three viable architectures at different privilege levels, and a set of
consequences (exec, logging, shutdown signals, image upgrades) that must be designed for
explicitly rather than discovered later.

One result is worth stating up front, because it is the first thing anyone tries: a PVC **cannot**
be handed to the container as `volumeMounts: [{mountPath: /}]`. The API server accepts it, runc
rejects it at container start, and the mount ordering would hide `/proc`, `/sys` and `/dev` even if
runc did not. The switch to `/` has to be done by the container's own entrypoint. The reasoning,
with source references, is in
[02-kubernetes-primitives.md](02-kubernetes-primitives.md) §4.0.

## Documents

| # | Document | What it covers |
| --- | --- | --- |
| 01 | [Proxmox LXC boot path](01-proxmox-lxc-boot.md) | How PVE actually starts a container, read from the `pve-container` source |
| 02 | [Kubernetes primitives](02-kubernetes-primitives.md) | The building blocks and their current feature-gate status |
| 03 | [Mapping and architecture](03-mapping-and-architecture.md) | PVE → Kubernetes mapping, candidate architectures, recommendation |
| 04 | [Prior art](04-prior-art.md) | Projects that already solved parts of this |
| 05 | [Open questions](05-open-questions.md) | Decisions that must be made before writing the chart |
| 06 | [Guest provisioning](06-guest-provisioning.md) | cloud-init, systemd credentials, and who owns which file |
| 07 | [Provisioning inputs](07-provisioning-inputs.md) | The inline / secret-reference contract every input obeys |

## Scope and versions

All Kubernetes statements were verified against upstream sources on 2026-08-29. The current
stable release is **Kubernetes 1.37** (released 2026-08-26). Proxmox statements were verified
against the `master` branch of [`proxmox/pve-container`](https://github.com/proxmox/pve-container),
which corresponds to Proxmox VE 9.x.

Where a statement depends on a feature gate, the gate name and its graduation history are given,
because the chart will have to degrade gracefully on older clusters.
