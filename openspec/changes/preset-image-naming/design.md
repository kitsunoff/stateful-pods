## Context

See proposal.md — Why.

Four things constrain the shape of this change.

`images/presets/presets.list` is the single source of truth for what a preset is: the build matrix,
the daily bump, the retention job and `hack/check-presets.sh` all read it, and its own header says
that the preset name is stated rather than derived because "nothing should have to know that rule
twice". A package name is a fifth thing about a preset, and it belongs there under the same rule.

`hack/preset-retention.jq` is a pure function with thirteen fixtures behind it, and it exists
because the obvious retention step — remove untagged versions — destroys the per-architecture
manifests of every tag being kept. It is the one decision in the project that can delete something
already published, and its failures are silent until somebody installs a machine. Anything added
here is added to that function, with fixtures, and not around it.

`charts/stateful-pods/presets.yaml` pins every preset to a digest, and `hack/check-presets.sh`
fails the build if one is pinned to a tag. That check also asserts that the repository a catalog
entry names matches the preset, which is the assertion this change has to move rather than remove.

The four packages under the old names hold the digests chart 0.1.1 resolves to. They cannot be
deleted while that release is the published one.

## Goals / Non-Goals

**Goals:**

- Publish into a repository per distribution, with the release as the tag.
- Publish a rolling release tag that follows the newest build, without the chart ever resolving one.
- Keep retention correct once a repository can hold more than one release, and once a tag exists
  that must never be deleted or moved.
- Reverse a recorded non-goal in a way the next person can read and check, rather than one they
  have to reconstruct.

**Non-Goals:**

- Changing the preset names a user writes in `values.yaml`. `debian-trixie` stays `debian-trixie`.
- Adding a second release of any distribution. The design has to survive one being added; adding
  one is a separate decision and a separate line in the catalog.
- A `latest` tag, or any tag that does not name a release. There is no sense in which one
  distribution's newest build is the project's newest anything.
- Deleting the four old packages. See Migration Plan.

## Decisions

### The repository name is a field, not a rule

`presets.list` gains a fifth field: `preset;distro;release;variant;package`. The first four are
unchanged and still match the upstream index's own field order, which is why they are in that order.

The alternative is to derive the package by stripping the release from the preset name —
`void-current` minus `current` is `void`. It works for all four presets today, and it is exactly the
kind of rule the file's header already refuses: the preset is `void-current`, the upstream calls the
distribution `voidlinux`, and the package is `stateful-pods-void`. Three names, none computable from
another, and a derivation would put the fourth relationship in the reader's head instead of on the
line.

### The rolling tag is a second tag on the same version, pushed after the dated one

The build already pushes per-architecture manifests, tags each of them, and combines them into an
index under the dated tag. The rolling tag is applied to that index afterwards with `crane tag`,
which writes a manifest reference and uploads nothing.

Two consequences worth stating. The rolling tag and the dated tag name identical content, so on GHCR
they are the same package version carrying two tags — which is what makes retention's "protect the
version carrying the rolling tag" rule sufficient, and what makes "delete the version and orphan the
tag" impossible to do accidentally rather than merely unlikely. And the order matters: dated first,
rolling second, so that a run interrupted between them leaves a complete immutable build and a
rolling tag one build behind, rather than a rolling tag pointing at content nothing else names.

A run that finds the dated tag already published still sets the rolling tag. That path exists so a
re-run cannot change what a reference already means, and setting the rolling tag does not — it is
how the interrupted run above is repaired, and it can only ever move the tag forward, because the
build resolves whatever the upstream index currently offers and the upstream index offers the newest
build. There is no code path that publishes an older build.

### The dated tag format does not change

`noble-20260829_0742` is what it was. The retention planner orders builds by parsing that date out
of the tag, and the whole of its fixture suite is written against that shape. Changing the tag and
the repository in one step would mean the planner's tests no longer tell you whether the planner
still works.

It also gives the rolling tag a free property: `noble` does not match the pattern a build tag
matches, so the two can never be confused for one another by accident. The planner still refuses to
proceed on a tag it cannot classify — that refusal is the thing standing between an unreadable tag
and a deleted operating system — so the rolling tags are named to it explicitly rather than
recognised by shape.

### Retention is scoped to one release, and is told which tags are rolling

The planner gains two inputs: `release`, the release this run is retaining, and `releases`, every
release published into this repository. A tag is then one of three things: exactly a member of
`releases`, and therefore a rolling tag; a dated build tag of some release; or unclassifiable, which
is still a hard stop.

From there:

- Only builds of `release` are ordered and counted. Five is five builds of Noble, not five builds of
  Ubuntu. Without this, adding `ubuntu-jammy` beside `ubuntu-noble` would make the next retention run
  delete every Jammy build the day six Noble builds existed — silently, and the way this project's
  retention hazards always fail, invisibly until an installation.
- Every version belonging to another release is protected, along with everything its indexes point
  at. Retention runs once per preset, so a repository with two releases is planned twice, and each
  run has to leave the other's work alone.
- Every version carrying a rolling tag is protected, along with everything it points at,
  unconditionally and regardless of which build it names. Normally it names the newest build and is
  retained anyway; the case this exists for is a rolling tag left behind by an interrupted run,
  pointing at a build old enough to fall out of the five.

The alternative — protecting the rolling tag by teaching the shell to skip its digest — was
rejected for the reason the planner exists at all: a decision that can destroy a published image
belongs where fixtures can be put in front of it.

### `verify_retained` checks the rolling tag too

The check that runs after every deletion resolves each retained build for every platform, because a
retained tag that lost an architecture is invisible damage. The rolling tag is a reference people use
directly, so it is checked the same way and by the same code path.

### Why the reversal is defensible, written where it will be found

`distro-presets` listed rolling tags in its non-goals, and gave a reason: a machine's source must be
reproducible, and the preset table pins a digest precisely so that nothing about a machine's origin
can change under it.

That reason is correct and this change does not weaken it. The property lives in
`charts/stateful-pods/presets.yaml`, which pins a digest for every preset, and in
`hack/check-presets.sh`, which fails the build if any entry is a tag instead. Both are unchanged.
A machine is seeded from a digest before this change and after it, so no existing machine's origin
can move, and no new machine can be installed from a reference that means something different
tomorrow.

What the non-goal actually protected against is a chart that resolves a preset to `debian:trixie`.
That is still forbidden, and now forbidden by a requirement that says so directly rather than by the
absence of the tag. The rolling tag is a name for a person at a terminal, and the reproducibility
argument was never an argument about those.

## Risks / Trade-offs

- **Retention deletes by digest, and a rolling tag shares a digest with a dated tag.** Deleting the
  version deletes both tags. → The planner protects any version carrying a rolling tag before it
  computes what is doomed, fixtures cover a rolling tag on a build inside the window and on one
  outside it, and `verify_retained` resolves the rolling tag after every run.
- **One repository, several releases, one retention pass per preset.** A pass for one release sees
  the other's versions and could plan them away. → Builds of other releases are protected, not
  merely excluded from the ordering, and there is a fixture for a repository holding two releases.
- **A rolling tag makes a stale pull easy.** Someone can pull `stateful-pods-ubuntu:noble` today and
  get different bytes tomorrow. → That is the point of it, and it is why the chart resolves digests
  instead. The dated tag remains published and immutable for anyone who needs to name a build.
- **The old packages are orphaned.** Nothing publishes into them again, and they keep the digests
  chart 0.1.1 resolves to. → They are left in place, and deleting them is a decision for after a
  chart release that names the new packages. A `GITHUB_TOKEN` cannot delete them in any case.
- **The daily bump opens a pull request the first night after this lands.** Each preset's catalog
  entry will be compared against a newly published build, and the newest upstream build will often
  be newer than the one published here. → That is the bump working, and the proposal it opens is
  reviewed like any other.

## Migration Plan

The publishing has to happen before the catalog can name it, which is the order
`.github/workflows/preset-bump.yaml` already argues for at length: a proposed reference that does
not resolve yet is not a reviewable proposal.

1. Land the build, retention and check changes on the branch, with the catalog still naming the old
   references. `hack/check-presets.sh` will fail on the branch at this point, by design — it asserts
   that a catalog entry names its preset's package.
2. Dispatch `preset-publish.yaml` against the branch. Nothing exists under the new names, so all
   four presets publish rather than being left alone.
3. Read the four digests back from the registry and write them into
   `charts/stateful-pods/presets.yaml`. `hack/check-presets.sh` passes from here.
4. Merge. The rolling tags are live from step 2 and are what a person is told to pull.

Rollback is the catalog file: the old packages still hold the digests 0.1.1 names, so reverting the
four lines restores the previous resolution exactly. Nothing published in step 2 has to be
withdrawn, because nothing that already existed was changed.
