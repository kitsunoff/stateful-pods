<div align="center">

# stateful-pods

**Run a machine as a pet in a Kubernetes pod, with its root filesystem on a PersistentVolume.**

A machine here is a whole operating system — its own init, its own package manager, its own `/etc` —
living on a volume that survives the pod, reachable by the name you gave it. It is the Proxmox LXC
model on Kubernetes primitives, not a container wearing an operating system as a costume.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Helm chart](https://img.shields.io/badge/Helm-chart-0F1689?style=flat-square&logo=helm&logoColor=white)](charts/stateful-pods)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-%E2%89%A5%201.30-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](charts/stateful-pods/Chart.yaml)
[![kubectl plugin](https://img.shields.io/badge/kubectl-machine-326CE5?style=flat-square)](cmd/kubectl-machine)
[![Presets](https://img.shields.io/badge/presets-debian%20%C2%B7%20ubuntu%20%C2%B7%20alpine%20%C2%B7%20void-009688?style=flat-square)](#distributions-it-ships-a-name-for)

</div>

---

> [!CAUTION]
> **A machine's name is permanent.** Every object is named `<release>-<machine>`, and the root
> filesystem lives in a PersistentVolumeClaim derived from that name. Renaming a machine or its
> release does not move the volume — it orphans it and recreates the machine empty.

## Table of contents

- [What you get](#what-you-get)
- [How a machine starts](#how-a-machine-starts)
- [Declaring a machine](#declaring-a-machine)
- [The kubectl plugin](#the-kubectl-plugin)
- [Security modes](#security-modes)
- [Distributions it ships a name for](#distributions-it-ships-a-name-for)
- [Working on it](#working-on-it)
- [Known limitations](#known-limitations)
- [License](#license)

## What you get

| Piece | What it is |
| --- | --- |
| **The chart** | One StatefulSet, one rootfs PersistentVolumeClaim and one headless Service per machine. Exactly one machine per release, for now. |
| **The shim image** | The small program that fills the volume, writes the files the chart maintains inside the machine, mounts the filesystems and hands control to the guest's own init. It also carries the chart's logic, which is why the chart pins it by digest rather than by tag. |
| **The `kubectl machine` plugin** | Addresses a machine by the name you declared it under, and answers where it is in its life rather than reporting a container. One bash file, no build step. |
| **Four distribution presets** | A name instead of a URL and a checksum you found somewhere. Each was built from the upstream root filesystem after the upstream's signature over its own checksums verified against a pinned key. |

## How a machine starts

A machine takes minutes to become usable, and for most of that a pod-level view says `Init:1/3`.
That is not a stall; it is the volume being filled with an operating system.

```text
  source (oci · lxc · preset)
        │
        ▼
  ┌───────────┐   once per volume, ever
  │  seed     │   fill the rootfs from the source, then record what it holds
  └─────┬─────┘
        ▼
  ┌───────────┐
  │  prepare  │   the runtime directories the guest's init will mount over
  └─────┬─────┘
        ▼
  ┌───────────┐
  │ customize │   hostname, hosts, resolv.conf — the files the chart maintains
  └─────┬─────┘
        ▼
  ┌───────────┐
  │  guest    │   mount, pivot, exec /sbin/init — from here it is the machine's
  └───────────┘
```

**Seeding happens exactly once in the life of a volume.** From the moment it is filled, the volume
*is* the machine's operating system, so changing `source` afterwards changes nothing — re-applying a
source over a machine that has been running for a year would destroy it. To start from something
else, create another machine.

## Declaring a machine

```yaml
machines:
  web:
    source:
      kind: preset
      name: debian-trixie
    security:
      mode: userns
    rootfs:
      size: 8Gi
```

```bash
helm install lab oci://ghcr.io/kitsunoff/charts/stateful-pods --version 0.1.2 \
  --values my-machine.yaml
```

A source is one of three kinds, named explicitly rather than inferred from which fields are present,
so that a mistyped field name produces a message about the field and not about the kind:

| Kind | What it needs | Notes |
| --- | --- | --- |
| `preset` | `name` | A name this project pins and verified the provenance of. |
| `oci` | `reference` | Any image; flattened out of the registry, not run as a container. |
| `lxc` | `url`, `sha256` | A conventional template tarball. Verification cannot be skipped, and the checksum must be quoted — sixty-four digits with no letters is a YAML *number*. |

[`charts/stateful-pods/values.yaml`](charts/stateful-pods/values.yaml) is the full input contract,
with a comment on every input, and [`charts/stateful-pods/README.md`](charts/stateful-pods/README.md)
is the reference for the chart itself.

## The kubectl plugin

```bash
kubectl machine list                  # every machine here, and the stage each is in
kubectl machine status web            # where one machine is in its life
kubectl machine shell web             # a shell inside the machine
kubectl machine console web --follow  # the machine's own boot output
kubectl machine create web --preset debian-trixie --mode userns
kubectl machine delete web            # the release; the root filesystem is kept
```

**It validates nothing, and that is deliberate.** Every input goes to the chart, and what comes back
when one is wrong is the chart's own message, unchanged — so there is only ever one explanation of a
bad value, in one place.

**It removes no root filesystem.** `delete` uninstalls the release, says the volume survived, and
prints the separate command that would destroy it. There is no flag that does both.

Installation is one file on `PATH` named exactly `kubectl-machine`; from a checkout that is
`install -m 0755 cmd/kubectl-machine /usr/local/bin/`. Once a release exists it is also a krew
manifest — see [`krew/machine.yaml`](krew/machine.yaml). `shell`, `console`, `list` and `status`
need only `kubectl`; `create` and `delete` also need `helm`, because they install and uninstall a
release.

## Security modes

There is no default. An unset `security.mode` fails rendering with a message explaining the choice,
because the chart never silently escalates privileges and it cannot honestly guess: the API server
version says nothing about the node's kernel or the storage class's filesystem.

| Mode | What it renders | What it costs |
| --- | --- | --- |
| `userns` | `hostUsers: false` plus `CAP_SYS_ADMIN` inside the machine's own user namespace. | Kubernetes 1.33 or newer, a recent runtime and kernel, and an idmap-capable filesystem. |
| `privileged` | `drop: ALL` plus fifteen named capabilities. | Works on the 1.30 floor. Weaker isolation, but bounded and enumerated. |

**`privileged` does not mean `privileged: true`.** The chart has never rendered the blanket runtime
flag; the mode is a named capability list with `ALL` dropped first, so the list is the whole of it
rather than an addition to whatever a runtime currently calls a default.

**The syscall filter is always stated, never inherited.** The guest's `seccompProfile` is written
explicitly in every mode rather than left to the node — `Unconfined` by default, or a profile of
your own named through `security.seccompProfile`, with one shipped at
[`charts/stateful-pods/profiles/`](charts/stateful-pods/profiles). What the chart refuses is
`RuntimeDefault`, with the reason: it denies the mount the machine exists to perform, so a machine
under it fails to boot rather than running slightly confined.

## Distributions it ships a name for

`debian-trixie` · `ubuntu-noble` · `alpine-3.24` · `void-current`

A preset is a whole distribution rather than a base image, and each is pinned by digest. The point
is that you do not have to research a reference: a typo is refused and told which names exist,
instead of resolving to nothing or to somebody's default.

The images are published a package per distribution and a tag per release, so
`ghcr.io/kitsunoff/stateful-pods-ubuntu:noble` is a thing you can pull. That tag follows the newest
build, and beside it is an immutable one naming the upstream build it came from. The chart resolves
neither: it pins a digest, which is what keeps a machine's disk reproducible while the name in front
of it stays short.

## Working on it

Everything below runs without a cluster except the last two. `make image-test` needs only a
container engine.

```bash
make all            # lint, shell lint, docs, presets, unit tests, shell tests, preset tests, schemas
make lint           # helm lint --strict, against every example
make test           # helm unittest
make shell-test     # bats, inside a Linux container
make plugin-test    # the plugin's suite on this host's bash
make conform        # kubeconform, at 1.33 and at the chart's own floor
make image-test     # the shim image's archive and registry guarantees
make integration-test  # seed a machine end to end on kind
make seccomp-test   # the syscall filter, on a kubelet that filters by default
```

`make plugin-test MACHINE_BASH=/bin/bash` is the one that matters on macOS: the plugin targets
bash 3.2 because that is what macOS ships, and every construct that breaks that target — `mapfile`,
an associative array, `${var^^}` — runs perfectly in the Linux container the other suites use and
fails on somebody's Mac.

Changes go through [OpenSpec](openspec/): a proposal, a delta spec, a design and a task list before
the code, and the specs under [`openspec/specs/`](openspec/specs) are what the chart is held to.

## Known limitations

**One machine per release.** The map form is already in place so that lifting the restriction
renames nothing that exists.

**Windows is not supported and will not be.** The plugin is a bash program — one file, no build
step, no toolchain — and there is no bash on Windows worth targeting. Under WSL it is an ordinary
Linux install.

**The shim image's base is pinned to Alpine 3.22** — the image the chart runs, not the
`alpine-3.24` preset, which is a machine's operating system and unrelated. Alpine 3.24 ships crane
0.21, which drops go-containerregistry's rule
that a registry whose name ends in `.local` is spoken to over plain HTTP — and that rule is what
lets a machine seed from an in-cluster `<service>.<namespace>.svc.cluster.local` registry with no
insecure-registry input in the chart.

**Guest provisioning is not here.** Cloud-init, SSH host keys and accounts arrive in a later change,
so a machine starts with the identity and accounts its source shipped.

## License

MIT. See [LICENSE](LICENSE).
