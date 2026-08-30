## Context

See proposal.md — Why.

Five things constrain the shape of this change.

`distro-presets` requires that a preset is the upstream root filesystem, unmodified: "The image
SHALL carry no configuration, no package installation and no file this project authored." That
requirement is not being touched, and it decides the whole change. Getting cloud-init into a preset
is a question of which upstream build to take, never of what to add to one.

`images/presets/presets.list` is the single source of truth for what a preset is, and it already
carries the variant and the package as explicit fields whose values nothing derives. Both of the
things this change needs to say are therefore data rather than code, and every consumer — the build,
the daily bump, the retention job, `hack/check-presets.sh` — reads them already.

`hack/preset-build.sh` refuses to republish a dated tag that already exists, because a published
dated tag is immutable. That refusal is correct and it is also a trap for this change: it is what
turns a variant switch under an unchanged tag into a silent no-op.

`hack/preset-retention.jq` reads a release out of a tag with `^(?<release>[^-]+)-(?<date>...)$`. The
release segment cannot contain a dash.

`charts/stateful-pods/presets.yaml` pins every preset to a digest, and `hack/check-presets.sh` fails
the build unless the repository a catalog entry names matches the preset's package. The three
packages under the old names hold the digests chart 0.2.0 resolves to and cannot be deleted while
that release is the published one.

## Goals / Non-Goals

**Goals:**

- A preset carries cloud-init, so that the chart's settled default provisioning backend has
  something to talk to on the images the project itself ships.
- Establish per distribution what the upstream actually publishes, rather than assuming symmetry.
- Keep the preset names in `values.yaml` exactly as they are.
- Keep the signature verification, the checksum verification and their failure paths untouched.
- Reverse a recorded non-goal in a way the next person can read and check.

**Non-Goals:**

- Writing the seed, the backends or the provisioning inputs. That is a separate change, and this one
  deliberately lands first so that it finds cloud-init already present.
- Installing cloud-init into any image. See the first decision.
- Publishing both variants of a distribution as two presets. Nobody has asked for a preset that
  cannot be provisioned by the default backend, and doubling the build matrix and the retention load
  to offer one is a cost with no stated demand behind it.
- Deleting the three old packages. See Migration Plan.

## What was established by looking

Every claim below was checked against the upstream and against the archives themselves, because the
whole change rests on what the upstream actually publishes.

### Which distributions publish a cloud variant

Read from `https://images.linuxcontainers.org/meta/1.0/index-system`:

| Preset | Upstream variants for both architectures | Taken |
| --- | --- | --- |
| `debian-trixie` | `default`, `cloud` | `cloud` |
| `ubuntu-noble` | `default`, `cloud` (architectures disagree) | `default`, for now |
| `alpine-3.24` | `default`, `cloud`, `tinycloud` | `cloud` |
| `void-current` | `default`, `musl` | `default` |

Ubuntu's cloud variant exists but is not takeable yet: `20260829_07:42` on amd64 against
`20260829_08:43` on arm64. The rule that a preset covers every architecture or is not published
already decides this — there is no single build to name — so `ubuntu-noble` stays on `default` and
is documented as `native`-only until the upstream levels. It was left behind rather than holding the
rest of the change because the upstream event is outside this project's control and the wait is
unbounded; the two presets that are ready deliver the point of the change on their own. Nothing
switches it automatically: `hack/preset-bump.sh` says outright that it cannot write `presets.list`,
and the workflow only resolves and repins digests, so the variant field is only ever changed by a
person.

Void publishes no cloud variant at all. The three options for it were: keep it on `default` as a
`native`-only preset, install cloud-init into it at build time, or drop the preset. The second is
refused by the "unmodified" requirement, which exists so that a user choosing `void-current` is
choosing Void and not this project's opinion of Void — and it would also mean this project deciding
a Python runtime and a service manager integration into somebody's minimal system. The third throws
away a working preset to make a table look even. So Void keeps `default`, and what the user gets is
stated rather than implied: a Void machine provisions with `native` and a default install of it
fails loudly, which is the behaviour §5a asked for.

Alpine's `tinycloud` was not taken. It is tiny-cloud, an Alpine-native reimplementation, not
cloud-init; it answers a different and much smaller configuration surface, so a `cloud-init` backend
pointed at it would fail in a way that looks like cloud-init being broken.

### The cloud variant is not a drop-in, and the way it differs matters

The cloud rootfs is a different build, not the default one with a package added.

| Preset | `default` uncompressed | `cloud` uncompressed | Change |
| --- | --- | --- | --- |
| `debian-trixie` | 412 MiB | 557 MiB | +35% |
| `alpine-3.24` | 12 MiB | 76 MiB | +533% |

Debian's growth is unremarkable. Alpine's is not: the cloud variant is more than six times the size
of the default one, because cloud-init brings a Python runtime into a distribution whose whole
appeal is not having one. That is a real cost to state, and it is still the right trade, because an
`alpine-3.24` that cannot serve the chart's default backend is a preset most people would install
and then find broken.

### cloud-init arrives installed and disabled

Every cloud rootfs the upstream publishes contains an empty `/etc/cloud/cloud-init.disabled`, beside
service units that are otherwise fully enabled. This is deliberate and it is upstream's, from
distrobuilder's `generators/cloud-init.go`, whose LXC target exists to disable cloud-init:

```go
// RunLXC disables cloud-init.
func (g *cloudInit) RunLXC(img *image.LXCImage, target shared.DefinitionTargetLXC) error {
```

The Incus target instead writes the templates that populate `/var/lib/cloud/seed/nocloud-net/` at
instance creation. LXD and Incus therefore write a seed and enable cloud-init in one step, and the
plain LXC archive this project consumes is the half of that with the enabling left out.

This is the most consequential finding in the change, because it is invisible. A provisioning
backend that checks for cloud-init by looking for the program, the units or `/etc/cloud` finds all
three on a preset where cloud-init cannot run — which is exactly the "looks like a successful
install" failure §5a exists to prevent, arrived at from a direction §5a did not anticipate.

The marker is honoured cleanly rather than fatally, on both init systems. Alpine's OpenRC scripts
test for it and warn:

```sh
elif test -e /etc/cloud/cloud-init.disabled; then
  ewarn "$RC_SVCNAME is disabled via cloud-init.disabled file"
```

and cloud-init's systemd generator makes `cloud-init.target` a no-op the same way. So a machine
installed before the provisioning change boots as it always did.

### What a booted machine actually does, in both states

A `debian-trixie` machine was installed on kind from the published preset and inspected, because
none of the above is worth asserting from a file listing.

**As shipped, with the marker in place.** The machine reached readiness in under two minutes, most
of it seeding. Inside it: cloud-init 25.1.4, all nine units, `/etc/cloud`, and the marker.
`systemctl is-system-running` reports `running`, not `degraded`; no unit failed; no cloud-init unit
was even loaded, because the generator removed them from the transaction. Userspace start-up took
412ms. The generator recorded why:

```text
checking for datasource
ds-identify rc=2
cloud-init is disabled by kernel command line or etc_file
```

**With the marker removed and still no seed** — the state the provisioning change will pass through
if it removes the marker before it can write a seed. The machine came back ready in 20 seconds,
`is-system-running` reported `running`, and again no unit failed and no stage ran. `ds-identify`
recognised the environment correctly and declined:

```text
VIRT=lxc
is_container=true
No ds found [mode=search, notfound=disabled]. Disabled cloud-init [1]
```

So cloud-init gets out of the way rather than holding the boot up or leaving wreckage, in both
states. That is the answer the next change needed before it could be built on top of this one.

Three things it should take from the same run:

- **Both the marker and the seed are required.** With the marker present the generator stops before
  `ds-identify` runs at all, so writing a seed alone changes nothing; with the marker gone and no
  seed, `ds-identify` finds nothing and disables cloud-init. Neither half works on its own.
- **The seed goes where the upstream's own tooling puts it**, `/var/lib/cloud/seed/nocloud-net/`,
  which is what Incus's templates write and what `ds-identify`'s NoCloud check looks for. Neither
  image ships `/var/lib/cloud` at all, so its absence is also the cleanest evidence that no stage
  has run.
- **`datasource_list` is worth pinning.** `ds-identify` warned `no datasource_list found` and
  searched thirty-odd datasources, one of which — OpenStack — came back `maybe`. It did not matter
  here because the policy is `notfound=disabled` and `ON_MAYBE=none`, but a drop-in setting
  `datasource_list: [ NoCloud, None ]` would make detection deterministic instead of nearly so.
  That is a decision for the provisioning change, not this one.

## Decisions

### cloud-init gets into a preset by choosing an upstream build, never by adding to one

The user's preference and the project's own requirement agree here, which is convenient but not
why. A preset that had cloud-init installed into it would be a root filesystem nobody published and
nobody signed: the build verifies the upstream's signature over its checksums and then proves the
published layer is byte-for-byte the archive that signature covered. Installing a package breaks
that proof, and the proof is the entire reason a preset is worth more than a URL a user found.

Patching images stays available as a fallback if a distribution the project wants has no cloud
variant and a user asks for it. Void is that case today, and it is being answered by stating what
the preset can do rather than by reaching for the fallback.

### The variant goes in the package, and it has to go somewhere

A variant switch under an unchanged package and tag is not a rename — it is a correctness bug, and
the evidence is live. `stateful-pods-debian:trixie-20260830_0517` is already published and holds the
**default** rootfs. Debian's cloud build of the same day carries the same upstream serial,
`20260830_05:17`, so it would resolve to that same tag. `hack/preset-build.sh` would find the tag
present, take its "already published, leaving it alone" path, push nothing, re-point the rolling tag
at the default image and report its digest — and the catalog would then be bumped to a default
rootfs under a preset that claims to carry cloud-init. Every step of that succeeds.

So the variant has to be part of the published identity. It could have gone in the tag —
`trixie-cloud-20260830_0517` — but `hack/preset-retention.jq` reads the release as the text before
the first dash, so a release segment containing one is a rewrite of the planner and of the 528-line
suite that guards the only decision in this project that deletes published content. Putting the
variant in the package is a change to one field of one data file that no code reads specially,
because `presets.list` was written on the principle that none of its fields is derived from another.

The cost is that `stateful-pods-debian:trixie` stays behind pointing at a default build. That is the
same thing the file's header already describes happening when a release is removed, and it is
recorded in Migration Plan rather than tidied away.

### The preset names do not change

`debian-trixie` still means Debian trixie. The package and tag are where the images live; the preset
name is what a user writes, and the user asked for the cloud image *as* `debian-trixie` rather than
beside it. Nobody's `values.yaml` needs editing, and `charts/stateful-pods/tests/values_preset_source_test.yaml`,
which asserts the full sorted list of names, needs no editing either.

It is still a breaking change, and for a sharper reason than the package rename: `preset: debian-trixie`
resolves to a different and larger root filesystem than it did in 0.2.0. A machine already installed
is unaffected — it read its source once, when its volume was seeded — but a new install of the same
values gets different contents. The release that ships this needs a minor version bump. It is not
cut here.

### Enabling cloud-init belongs to whatever writes the seed

The disable marker cannot be removed by the build without modifying an upstream root filesystem, and
it must be removed by something or the default backend is a silent no-op. The only place left is the
step that writes the seed, which is the same step that already knows a machine is being provisioned
with cloud-init at all — and it is where the removal is honest, because it is a change to a
machine's own filesystem, visible to the user and reversible by them, rather than a change baked
into an image.

This change therefore states the obligation in the spec instead of implementing it, so that the
provisioning change inherits a written contract rather than a surprise. A presence check that looks
only for the program is explicitly not sufficient.

## Migration Plan

The three packages under the old names — `stateful-pods-debian`, `stateful-pods-ubuntu`,
`stateful-pods-alpine` — are orphaned by this change but must not be deleted. Chart 0.2.0 is the
published release and resolves three of its four presets to digests inside them, and
`RELEASE.md` already states the rule: retiring a preset package is bounded by the oldest chart that
names it. Nothing publishes into them after this change, so they simply stop moving.

`stateful-pods-void` is not orphaned; `void-current` keeps publishing into it.

The daily bump proposes catalog changes per preset and will find the three new packages already
pinned, so it has nothing to do differently.

## Risks

**The upstream can be mid-rebuild on a variant.** The two architectures of a variant are separate
upstream builds and can carry different serials for a while; `ubuntu-noble`'s cloud builds were
skewed by an hour while this change was written. The build already treats that as "upstream not
ready" and exits 3 rather than publishing a tag that names two different days, so the failure mode
is a build that does not happen rather than one that publishes something wrong. It does mean
publishing all four presets in one dispatch can be blocked by one of them, and they are dispatched
individually when that happens.

**Alpine's size.** Stated above and accepted. If it turns out to matter to someone, the answer is a
second Alpine preset on the default variant, which this design leaves open: it is a line in
`presets.list` with `default` in the variant field and `alpine` in the package field, and the
package it would publish into already exists.
