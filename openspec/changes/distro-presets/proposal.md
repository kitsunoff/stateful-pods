## Why

Declaring a machine's source is the hardest part of installing this chart, and it is hard for a
reason that has nothing to do with machines. An `lxc` source needs a URL and a SHA-256 the user has
to find by hand, from an index that publishes a new dated build every day; an `oci` source needs an
image that happens to be a whole operating system, which is not what most published images are.
Either way the user's first task is research.

Meanwhile the upstream that publishes exactly the right thing — a complete, per-architecture,
signed distribution root filesystem, rebuilt daily — publishes it as a tarball, in a format nothing
in Kubernetes can consume directly.

This change turns that upstream into a small catalog of images and gives the chart a name for each
one, so that declaring a Debian machine is one line and the reference behind it is pinned, signed
in provenance, and built for the architecture the machine lands on.

## What Changes

- **A new source kind**: `machines.<name>.source.kind: preset` with a `name` such as
  `debian-trixie`. The chart resolves it to an image reference pinned by digest, from a table it
  ships. An unknown name is rejected at render time with the available names listed, the way an
  unknown security mode already is.
- **Four presets in the first iteration**: `debian-trixie`, `ubuntu-noble`, `alpine-3.24` and
  `void-current`, each for `linux/amd64` and `linux/arm64`. Adding a release later is a line in a
  build matrix.
- **A build that wraps an upstream LXC root filesystem in an OCI image**, one preset per
  distribution release, published to GHCR under an immutable dated tag. Provenance — the upstream
  URL, the build date and the checksum the tarball was verified against — is recorded in the
  image's labels.
- **The upstream's signature is verified, not just its checksum.** linuxcontainers.org publishes a
  detached GPG signature beside every `SHA256SUMS`. The build verifies that signature against a key
  fingerprint pinned in this repository before it packages anything. This is strictly stronger than
  what the `lxc` source kind can offer, where the user supplies a checksum they found themselves.
- **A daily workflow proposes bumps.** It reads the upstream index, and where a preset's pinned
  build is no longer the newest, it builds and publishes the new one and opens a pull request
  updating the preset table to the reference it just published. Dependabot is configured alongside
  it for the two things it can actually track here — GitHub Actions and the base images in this
  repository's own Containerfiles — but it cannot track a daily dated build on a plain HTTPS index,
  so the tarball side is this workflow's job.
- **Five builds are kept per preset.** A scheduled job removes older versions from the registry,
  keeping the five newest of each preset.

Non-goals:

- Proxmox as an upstream. It has no Void at all, and two arm64 templates against fifty-four amd64
  ones, so it cannot serve the four distributions on the two architectures this project builds for.
- `cloud` and `tinycloud` variants. They carry cloud-init, which this chart does not drive; the
  `default` variant is what a machine wants. Void's `musl` variant is left out for the same reason
  of scope, not of preference.
- Rolling tags such as `debian:trixie` that follow the newest build. A machine's source must be
  reproducible, and the preset table pins a digest precisely so that nothing about a machine's
  origin can change under it.
- Any modification of the upstream root filesystem. A preset is the distribution's own tarball in
  an image, not this project's opinion of it.

## Capabilities

### New Capabilities

- `distro-presets`: what a preset is and what it guarantees — where its contents come from, how its
  provenance is established, which architectures it covers, how it is identified, how long it
  stays available, and how it keeps up with its upstream.

### Modified Capabilities

- `values-validation`: a third source kind is accepted, its own required field is enforced, an
  unknown preset name is rejected with the available names listed, and fields belonging to the
  other kinds are rejected on it as they are everywhere else.

## Impact

- **Depends on `shim-owned-scripts` having landed.** Two hard dependencies, not preferences.
  Alpine's and Void's root filesystems provide busybox tar, which the current OCI seeding path
  rejects outright, so two of the four presets are unusable before that change. And retention only
  becomes safe once a seeded machine stops fetching its source on every start — until then,
  deleting the sixth-oldest build would break a running machine that was seeded from it and is
  rescheduled.
- **New**: `images/presets/` with the pinned upstream signing key and the catalog of what is built,
  the build and its companions under `hack/`, `charts/stateful-pods/presets.yaml` as the shipped
  table, three workflows (build, daily bump, retention), and `.github/dependabot.yml`.
- **Chart**: a source kind in `_helpers.tpl`'s validation and in the seeding environment; the
  resolved reference feeds the existing OCI path unchanged, so no seeding logic changes.
- **Registry**: four new GHCR packages, at roughly 5 × 2 architectures × 4 presets stored at any
  time.
- **Verification risks to settle first**: whether a `FROM scratch` plus `ADD` build preserves
  `security.capability` through the builder's own extraction — if it does not, the layer must be the
  upstream tarball itself, which `crane append` can do without a builder. And whether the retention
  job can delete by tag without orphaning the per-architecture manifests that a multi-architecture
  index points at, which is the standard way these jobs break an image that still has a tag.
