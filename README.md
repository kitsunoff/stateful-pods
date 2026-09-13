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

## Table of contents

- [What you get](#what-you-get)
- [How a machine starts](#how-a-machine-starts)
- [Declaring a machine](#declaring-a-machine)
- [Getting into a machine](#getting-into-a-machine)
- [The ports a machine serves](#the-ports-a-machine-serves)
- [What a machine may reach](#what-a-machine-may-reach)
- [Storage beside the root filesystem](#storage-beside-the-root-filesystem)
- [The kubectl plugin](#the-kubectl-plugin)
- [Security modes](#security-modes)
- [Distributions it ships a name for](#distributions-it-ships-a-name-for)
- [Working on it](#working-on-it)
- [Known limitations](#known-limitations)
- [License](#license)

## What you get

| Piece | What it is |
| --- | --- |
| **The chart** | One StatefulSet, one rootfs PersistentVolumeClaim and one headless Service per machine. As many machines per release as you like. |
| **The shim image** | The small program that fills the volume, writes the files the chart maintains inside the machine, mounts the filesystems and hands control to the guest's own init. It also carries the chart's logic, which is why the chart pins it by digest rather than by tag. |
| **An egress proxy, when asked for** | A machine that declares what it may reach runs Envoy beside itself, with its outbound TCP redirected into it. The only container this project runs from an image it did not build, and nothing renders it unless a machine asks. |
| **The `kubectl machine` plugin** | Addresses a machine by the name you declared it under, and answers where it is in its life rather than reporting a container. One bash file, no build step. |
| **Four distribution presets** | A name instead of a URL and a checksum you found somewhere. Each was built from the upstream root filesystem after the upstream's signature over its own checksums verified against a pinned key. |

## How a machine starts

A machine takes minutes to become usable, and for most of that a pod-level view says `Init:1/4`.
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
  │ provision │   users, keys, packages — a cloud-init seed, or nothing at all
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
helm install lab oci://ghcr.io/kitsunoff/charts/stateful-pods --version 0.3.1 \
  --values my-machine.yaml
```

> [!IMPORTANT]
> **The name is permanent.** Every object is named `<release>-<machine>` — `lab-web` above — and the
> root filesystem lives in a PersistentVolumeClaim derived from that name. Renaming a machine or its
> release later does not move the volume: it orphans it and recreates the machine empty. This is the
> moment to choose a name you will keep.

A source is one of three kinds, named explicitly rather than inferred from which fields are present,
so that a mistyped field name produces a message about the field and not about the kind:

| Kind | What it needs | Notes |
| --- | --- | --- |
| `preset` | `name` | A name this project pins and verified the provenance of. |
| `oci` | `reference` | Any image; flattened out of the registry, not run as a container. |
| `lxc` | `url`, `sha256` | A conventional template tarball. Verification cannot be skipped, and the checksum must be quoted — sixty-four digits with no letters is a YAML *number*. |

## Getting into a machine

A machine is provisioned by **cloud-init** unless it says otherwise. The chart writes a NoCloud seed
into the machine's own root filesystem, hands the host name, host table, resolver and network
configuration back to the layers that already own them, and removes the
`/etc/cloud/cloud-init.disabled` marker the distributions ship in their LXC images — without which a
seed is read by nothing at all.

```yaml
machines:
  web:
    cloudInit:
      user:
        value: maxim
      sshAuthorizedKeys:
        value: |
          ssh-ed25519 AAAAC3Nz... maxim@workstation
      password:
        valueFrom:                  # sensitive material is named, never spelled out
          secretKeyRef:
            name: machine-secrets
            key: root-password-hash
```

Every input takes either form, per input, and the two mix freely in one machine. Referenced material
appears neither in the values file nor in the Helm release. `userData` is the escape hatch: supply it
and the structured inputs for user-data are replaced rather than merged, which is Proxmox's
`cicustom` rule for the same choice.

**An image that cannot run cloud-init fails the pod**, with a message naming
`guest.provisioning: exec` as the fix. That is the whole point of the default: the alternative is a
machine that installs cleanly, boots with no users and no keys, and gives nobody a way in — a failure
indistinguishable from success.

| Preset | Backends it can serve | Why |
| --- | --- | --- |
| `debian-trixie` | `cloud-init`, `exec` | built from the upstream `cloud` variant |
| `alpine-3.24` | `cloud-init`, `exec` | built from the upstream `cloud` variant |
| `ubuntu-noble` | **`exec` only** | its upstream's cloud architectures are not yet on one build |
| `void-current` | **`exec` only** | its upstream publishes no cloud variant at all |

### A machine that cannot run cloud-init runs its own script

The other half of the presets has no cloud-init and never will, so it is configured by its own
commands instead — inside the machine, after it has booted, as its own root:

```yaml
machines:
  os:
    guest:
      provisioning: exec
    exec:
      script:
        value: |
          set -eu
          xbps-install -Sy openssh
          ln -sf /etc/sv/sshd /var/service/
      environment:               # sourced from the machine's tmpfs, never an argument
        valueFrom:
          secretKeyRef:
            name: machine-secrets
            key: exec-environment
```

Nothing that runs before the guest could do this. At every earlier moment there is a directory of
another system's binaries and no machine — no init, no package manager, no network — which is why a
backend that writes files can create a user and never install a package.

The script is carried by a **Job beside the machine**, which waits for it to boot and then execs into
it. That Job holds a ServiceAccount whose Role may get one pod and exec into that same pod, and
reach nothing else: it is root inside that one machine, which is exactly what running a script as
root inside a machine requires and is stated in those words where the input is. Supply no script and
none of it is rendered — which is what the `native` backend, now renamed to `exec`, always was.

The Job's name carries a digest of what it runs, so an unchanged script is a no-op, a changed one
runs again, and neither restarts the machine.

[`charts/stateful-pods/values.yaml`](charts/stateful-pods/values.yaml) is the full input contract,
with a comment on every input, and [`charts/stateful-pods/README.md`](charts/stateful-pods/README.md)
is the reference for the chart itself.

## The ports a machine serves

A machine declares the ports it serves, and may ask that the cluster admit traffic to those and to
nothing else.

```yaml
machines:
  web:
    network:
      ingress: declared      # `any` by default, which restricts nothing
      ports:
        ssh:
          port: 22
        http:
          port: 80
```

The name each port is declared under is what its SRV record is published as, so a client finds
`_ssh._tcp.lab-web.homelab.svc.cluster.local` rather than being told the number twice.

**The declaration alone restricts nothing.** A pod is reachable on every port something inside it is
listening on, whatever its container declares; `ingress: declared` is the input that renders a
NetworkPolicy, and a NetworkPolicy is enforced by the cluster's network plugin and by nothing else.
On a cluster whose plugin implements none, it is accepted and does nothing at all — which the chart
cannot detect and therefore says out loud.

The restriction is inbound only. A machine that asked for it keeps its resolver, its package mirror
and everything else it reaches out to.

## What a machine may reach

A machine is an operating system with a package manager, a shell and somebody's script on it, and it
reaches everything the pod reaches. `network.egress` is where it says what it may reach instead.

```yaml
machines:
  web:
    network:
      egress:
        default: deny
        rules:
          - name: debian-mirror
            ports: [443]
            serverNames: [deb.debian.org, security.debian.org]
          - name: our-database
            ports: [5432]
            cidrs: ["10.0.5.7/32"]
```

The rule people actually write is a **name**, and a name is not something a packet filter or a
NetworkPolicy can match — it resolves to a rotating set of addresses. What can match it is the name
the machine itself puts in the TLS handshake, so declaring a policy puts an **Envoy in the machine's
own pod** with its outbound TCP redirected into it. Nothing is decrypted.

A rule matches on exactly one of: an address range (layer 4), a TLS server name, or the authority and
path of a plaintext HTTP request. `deny` covers what the proxy cannot see too — unmatched UDP and
IPv6 are dropped — and the pod's own resolver is always allowed, because a policy written in names
needs one.

Every decision is a line on the proxy's output, allowed and refused alike:

```bash
kubectl logs lab-web-0 --container envoy
```

**A server-name rule is a claim the machine makes about itself**: a process inside it can put any
name in a handshake, and the proxy believes it. An address rule is stronger, because an address is
not something the machine gets to assert — but the policy governs the machine's software and not its
root, and both READMEs say where that line is.

## Storage beside the root filesystem

The root filesystem is the machine. A machine may declare volumes next to it, for the data that
should outlive a rebuild of the operating system rather than be rebuilt with it — which is the
Proxmox distinction between a container's `rootfs` and its mount points.

```yaml
machines:
  db:
    rootfs:
      size: 8Gi
    volumes:
      data:
        mountPath: /var/lib/postgresql
        size: 200Gi
        storageClassName: fast
      archive:
        mountPath: /srv/archive
        existingClaim: archive-share
        readOnly: true
```

A volume names `size`, and the chart provisions a claim for it with the machine — its own class, its
own snapshot to restore from, retained on uninstall exactly as the root filesystem is. Or it names
`existingClaim`, and the chart mounts a claim somebody else made and creates nothing, which is how a
machine reaches a share that a single-writer claim of this chart's could never be.

**The name of a volume is as permanent as the machine's own**, and its size cannot be changed
afterwards: a StatefulSet's volume claim templates are immutable once it exists.

`/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/.stateful-pods` and `/` are refused as mount paths. The
boot sequence mounts over those after the pod's volumes are in place, so a volume there would be
present, empty on every start, and with nothing to say why.

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

Two of the four are built from their upstream's **cloud** variant, so they carry cloud-init as the
distribution assembled it. Nothing is installed into a preset to make up the difference: a preset is
the distribution's own root filesystem or it is not a preset.

Void has no cloud variant upstream at all — only `default` and `musl` — so it never gets one.
Ubuntu does have one, but its two architectures are currently on different upstream builds, and a
preset covers every architecture or it is not published; it moves to `cloud` once the upstream
levels.

| Preset | Upstream variant | Provisioning it can serve | Uncompressed |
| --- | --- | --- | --- |
| `debian-trixie` | `cloud` | cloud-init, exec | 557 MiB |
| `ubuntu-noble` | `default` (pending) | exec only | 585 MiB |
| `alpine-3.24` | `cloud` | cloud-init, exec | 76 MiB |
| `void-current` | `default` | exec only | 361 MiB |

Alpine's cloud variant is six times the size of its default one, because cloud-init brings a Python
runtime with it. That is the cost of an Alpine that can be provisioned the same way the others are.

The images are published a package per distribution and variant, and a tag per release, so
`ghcr.io/kitsunoff/stateful-pods-debian-cloud:trixie` is a thing you can pull. That tag follows the
newest build, and beside it is an immutable one naming the upstream build it came from. The chart
resolves neither: it pins a digest, which is what keeps a machine's disk reproducible while the name
in front of it stays short.

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

**Windows is not supported and will not be.** The plugin is a bash program — one file, no build
step, no toolchain — and there is no bash on Windows worth targeting. Under WSL it is an ordinary
Linux install.

**The shim image's base is pinned to Alpine 3.22** — the image the chart runs, not the
`alpine-3.24` preset, which is a machine's operating system and unrelated. Alpine 3.24 ships crane
0.21, which drops go-containerregistry's rule
that a registry whose name ends in `.local` is spoken to over plain HTTP — and that rule is what
lets a machine seed from an in-cluster `<service>.<namespace>.svc.cluster.local` registry with no
insecure-registry input in the chart.

**A machine's script does not re-run when its volume is destroyed and re-seeded.** The Job that ran
it is named for what it ran, so an unchanged script is a Job that already completed. Deleting that
Job and upgrading runs it again, and `NOTES.txt` prints the command.

**There are two provisioning backends and no third is planned.** `cloud-init` asks the image for
cloud-init; `exec` asks it for a shell; neither asks anything of the machine's init system, which is
why those two and not others. An earlier design named a third built on systemd's
`/run/host/credentials`, and it is not built: it would have been the only one tied to one init
system, and two of the four presets do not run systemd.

## License

MIT. See [LICENSE](LICENSE).
