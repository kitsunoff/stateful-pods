## Why

The project has already decided that the default provisioning backend is cloud-init, and that its
absence from an image must fail the pod loudly rather than quietly produce a machine with no users
and no keys. `docs/research/05-open-questions.md` records both under "Already settled".

Every preset the project publishes today is built from the upstream's `default` variant, and none of
the four `default` variants contains cloud-init. A running Debian machine from `debian-trixie` has
no `cloud-init` program, no units and no `/etc/cloud`. So the moment the provisioning work lands as
designed, every default install fails on every preset — the chart would ship a default backend that
none of the images it ships can serve.

`distro-presets` ruled the cloud variants out in its non-goals, and the clause it rested on says
exactly what has changed:

> `cloud` and `tinycloud` variants. They carry cloud-init, which this chart does not drive; the
> `default` variant is what a machine wants.

"which this chart does not drive" is what stopped being true. The rest of that non-goal — that a
preset is the distribution's own tarball and not this project's opinion of it — is untouched, and is
what decides how cloud-init gets into a preset: by taking the variant the upstream already builds
with it, never by installing it into an image here.

## What Changes

- Presets are built from the upstream's `cloud` variant wherever the upstream publishes one, so a
  preset carries cloud-init as the distribution assembled it. This reverses a non-goal of
  `distro-presets`, deliberately, and the reversal is conditional: see Interim state below.
- **Void is the exception, established by looking rather than assumed.** The upstream publishes only
  `default` and `musl` for `voidlinux/current` — no `cloud` variant exists to take. `void-current`
  stays on `default`, carries no cloud-init, and serves the `native` backend only. Installing
  cloud-init into it here was rejected: it would modify an upstream root filesystem, which is a
  requirement of `distro-presets`, not a preference.
- **BREAKING** for image references: a preset's package names the variant as well as the
  distribution, so `stateful-pods-debian` becomes `stateful-pods-debian-cloud`,
  `stateful-pods-ubuntu` becomes `stateful-pods-ubuntu-cloud` and `stateful-pods-alpine` becomes
  `stateful-pods-alpine-cloud`. `stateful-pods-void` is unchanged. The three packages under the old
  names are left in place, because the released chart still points at digests inside them.
- The preset names a user writes in `values.yaml` do not change. `debian-trixie` still means Debian
  trixie; it now resolves to a root filesystem that can be provisioned.
- A preset is still the upstream's bytes, unmodified. That has a consequence worth stating rather
  than discovering: the upstream's LXC images ship cloud-init **installed and disabled**, by a
  `/etc/cloud/cloud-init.disabled` marker their builder writes on purpose. A preset carries that
  marker, and removing it belongs to whatever writes the seed.

## Interim state

Between this change and the provisioning change, the chart drives nothing. cloud-init is present in
three of the four presets and inert in all of them, because the upstream's disable marker is still
there and nothing has been written to remove it. A machine installed in that window boots exactly as
it does today, from a larger root filesystem. Nothing regresses and nothing new works yet, which is
the point of landing the images first: the provisioning change should find cloud-init already there
rather than ship a default backend into images that cannot serve it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `distro-presets`: which upstream variant a preset is built from, and what that obliges. A preset
  gains a stated guarantee that it carries cloud-init where the upstream publishes an image with it,
  and an equally stated non-guarantee that cloud-init is enabled. The repository a preset publishes
  into is named for its distribution and its variant rather than for its distribution alone.

## Impact

- `images/presets/presets.list`: three variants and three packages change; the header's account of
  why the variant is `default` everywhere is replaced by why it is not.
- `charts/stateful-pods/presets.yaml`: three references repointed at the new packages and at cloud
  builds. `void-current` is untouched.
- `test/presets/verification.bats`: the variant a preset names is the one looked up in the upstream
  index, and a preset resolves into the package its catalog line names including the variant.
- `README.md`, `charts/stateful-pods/README.md`: the published package names, the size a preset
  costs, and which preset can serve which provisioning backend.
- No workflow, no build script and no retention code changes. Every one of them reads the catalog.
- The three packages under the old names are orphaned but not deleted, and cannot be until a chart
  release points at the new ones.
