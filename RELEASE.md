# Releasing

A release is the tag build. Nothing here is published by hand: the chart, the shim image, the plugin
archive and its checksum all come out of the `ci` workflow, so that what is published is what a
recorded build produced from a recorded commit.

## Why the first release is two tags

The chart pins `shim.image` by **digest**, not by tag. That is deliberate — a machine is a pet whose
disk has to be reproducible, and a tag that quietly comes to mean different content makes the boot
path unreproducible without anything in the release changing. The scripts the chart's containers run
live inside that image, so the chart and the image are a matched pair.

A matched pair pinned by digest is **ordered**: the digest can only be written down after the image
it names exists. On a tag the workflow runs `chart`, `plugin`, `release`, `image` and
`integration`, and `chart` publishes on any tag — so on the *first* tag the chart is published no
matter what, and on the first tag no correct digest can exist yet, because the image that would
carry one is being built by that same run. No ordering of a single tag escapes this.

So the first tag mints the image and the second one is the release anybody should install:

| Tag | What it publishes | Installable? |
| --- | --- | --- |
| `v0.1.0` | The shim image, the plugin archive with its checksum and krew manifest, and a chart that still pins the old digest. | No — needs `--set shim.image=...`. |
| `v0.1.1` | The same, with the chart pinning the digest `v0.1.0` produced. | Yes, unaided. |

Say this in the `v0.1.0` release notes. A version number cannot carry it, and somebody will find that
tag before they find this file.

**What must never be done instead:** substituting the digest into the chart at package time. It would
make the published chart differ from the chart in git, so nobody could rebuild the artefact from the
source that claims to be it — which is the entire reason the value is a digest and not a tag.

Two better-shaped alternatives were considered and rejected for now, with reasons, under *Decisions*
in
[`openspec/changes/archive/2026-08-30-first-release/design.md`](openspec/changes/archive/2026-08-30-first-release/design.md)
— a prerelease bootstrap, and giving the shim image its own tag trigger. The second is the right
long-term answer and is filed as an issue; it is the mechanism
[`charts/stateful-pods/values.yaml`](charts/stateful-pods/values.yaml) already describes when it says
a script fix is "an image release plus the digest below".

## Before anything

GitHub Actions must actually start jobs. When the account is billing-blocked, runs complete in
three to five seconds having executed zero steps, and a tag pushed in that state produces no
artefacts and a red release. Check first:

```bash
gh run list --limit 5
gh api repos/kitsunoff/stateful-pods/actions/runs/<id>/jobs --jq '.jobs[].steps | length'
```

A job with zero steps did not run. **Do not push a tag until that number is non-zero.**

## Cutting `v0.1.0`

Everything must already agree on the version before any tag is pushed, this one included — the
workflow and [`hack/release-archives.sh`](hack/release-archives.sh) both refuse a tag that
disagrees with either the chart or the plugin. Both of these must print the tag without its `v`:

```bash
sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml   # the chart's version
sed -n 's/^SP_VERSION="\(.*\)"$/\1/p' cmd/kubectl-machine  # the plugin's own
```

```bash
git checkout main && git pull --ff-only
git tag --annotate v0.1.0 --message "v0.1.0"
git push origin v0.1.0
```

Then wait for the run and confirm all five jobs - `chart`, `plugin`, `release`, `image` and
`integration` - are green.

## Bumping the digest

Read the digest from the registry, never from a local build — the point is to pin what CI published:

```bash
crane digest ghcr.io/kitsunoff/stateful-pods-shim:0.1.0
```

That is the index digest, which is what to pin: it is the multi-architecture manifest list, so a node
resolves its own architecture underneath it.

A tag in a registry is a name and not a record of who wrote it, so confirm the version behind it is
the one this tag build produced before pinning it. A hand-pushed image that got there first carries
the same tag and reads out of `crane digest` exactly the same way. What distinguishes them is when
the version was created: it should be the minute the tag run's `image` job finished, which
`gh run view` reports. The query needs a token with `read:packages`.

```bash
gh api /user/packages/container/stateful-pods-shim/versions \
  --jq '.[] | select(.metadata.container.tags | index("0.1.0")) | "\(.name) \(.created_at)"'
```

Then, on a branch:

1. Set `shim.image` in [`charts/stateful-pods/values.yaml`](charts/stateful-pods/values.yaml) to
   `ghcr.io/kitsunoff/stateful-pods-shim@sha256:<that digest>`.
2. Remove the two `--set shim.image` caveats from
   [`charts/stateful-pods/README.md`](charts/stateful-pods/README.md) and the warning at the top of
   [`README.md`](README.md).
3. Move `version` and `appVersion` in `charts/stateful-pods/Chart.yaml`, and `SP_VERSION` in
   `cmd/kubectl-machine`, to `0.1.1`.
4. Move the version in both READMEs' install commands, and the release URLs the plugin's own
   install instructions carry, to `0.1.1` as well. The plugin defaults the chart reference to its
   own version, so the archive from the first tag installs the chart that still pins the old digest.
5. Run `make all` and `make image-test`, open a pull request, and merge it.

`charts/stateful-pods/tests/shim_image_test.yaml` asserts the *form* of the default reference rather
than its content, so it will not catch a stale-but-valid digest. Check the value by eye.

## Cutting `v0.1.1`

The same version check as before applies — it applies to every tag, not just the first:

```bash
git checkout main && git pull --ff-only
git tag --annotate v0.1.1 --message "v0.1.1"
git push origin v0.1.1
```

This is the first release that installs and boots with no extra flag. Verify it as a user would,
from the published artefacts rather than from the checkout:

```bash
helm install lab oci://ghcr.io/kitsunoff/charts/stateful-pods --version 0.1.1 --values my-machine.yaml
kubectl machine status web
```

## Afterwards, by hand

The repository is public. A package published from it is not public with it, and is not reachable by
a workflow just because the repository is — those are two separate settings, neither of which has an
API. Both are per package, in the GitHub UI, under
`https://github.com/users/<owner>/packages/container/<package>/settings`.

- **A package a workflow created is already right.** `GITHUB_TOKEN` owns what it creates: the chart
  package appeared during `v0.1.0`, linked to the repository and public, with nothing done to it by
  hand.
- **A package that was pushed by hand first is not, and it refuses the workflow.** Such a package is
  not linked to any repository, so `GITHUB_TOKEN` has no access to it at all — the push fails with
  `denied: permission_denied: read_package`, which reads like a missing `packages: write` and is not
  one. The fix is **Manage Actions access → Add repository → `<owner>/<repo>`, role Write**. This is
  what `v0.1.0` hit: the shim image had been pushed by hand during development, so the `image` job
  went red on a tag whose other four jobs were green.

  Recovering from that needs no new tag. Grant the access, then re-run the failed job in the same
  run — `gh run rerun <id> --job <job-id>` — so what is published still comes from the recorded build
  of the recorded commit. Deleting and re-pushing the tag is what would make the release
  unreproducible.
- **Visibility is separate again.** A linked, workflow-owned package can still be private. Each one
  that anybody else is meant to pull has to be set to public under **Change visibility**.
- **The krew index.** `dist/machine.yaml` from the release is the manifest to submit to
  [`kubernetes-sigs/krew-index`](https://github.com/kubernetes-sigs/krew-index). It needs the plugin
  archive to carry a licence, which it now does.

## Later releases

Ordinary ones are one tag, because the digest in `values.yaml` is already correct and only changes
when `images/shim` does. When a change *does* touch the image, the pair is ordered again: publish the
image on a tag, read its digest, commit it, and release the chart on the next one.
