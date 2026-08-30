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

GitHub Actions must actually start jobs. While the account is billing-blocked, runs complete in
three to five seconds having executed zero steps, and a tag pushed in that state produces no
artefacts and a red release. Check first:

```bash
gh run list --limit 5
gh api repos/kitsunoff/stateful-pods/actions/runs/<id>/jobs --jq '.jobs[].steps | length'
```

A job with zero steps did not run. **Do not push a tag until that number is non-zero.**

## Cutting `v0.1.0`

Everything must already agree on the version — the workflow and
[`hack/release-archives.sh`](hack/release-archives.sh) both refuse a tag that disagrees with either
the chart or the plugin:

```bash
sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml   # 0.1.0
sed -n 's/^SP_VERSION="\(.*\)"$/\1/p' cmd/kubectl-machine  # 0.1.0
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

Then, on a branch:

1. Set `shim.image` in [`charts/stateful-pods/values.yaml`](charts/stateful-pods/values.yaml) to
   `ghcr.io/kitsunoff/stateful-pods-shim@sha256:<that digest>`.
2. Remove the two `--set shim.image` caveats from
   [`charts/stateful-pods/README.md`](charts/stateful-pods/README.md) and the warning at the top of
   [`README.md`](README.md).
3. Move `version` and `appVersion` in `charts/stateful-pods/Chart.yaml`, and `SP_VERSION` in
   `cmd/kubectl-machine`, to `0.1.1`.
4. Run `make all` and `make image-test`, open a pull request, and merge it.

`charts/stateful-pods/tests/shim_image_test.yaml` asserts the *form* of the default reference rather
than its content, so it will not catch a stale-but-valid digest. Check the value by eye.

## Cutting `v0.1.1`

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

Neither of these has an API, and neither can be done by a workflow:

- **Package visibility.** The repository is private, so everything published from it is private too —
  the shim image, the chart and the four preset packages. If the release is meant to be usable by
  anyone else, each package's visibility has to be set to public in the GitHub UI.
- **The krew index.** `dist/machine.yaml` from the release is the manifest to submit to
  [`kubernetes-sigs/krew-index`](https://github.com/kubernetes-sigs/krew-index). It needs the plugin
  archive to carry a licence, which it now does.

## Later releases

Ordinary ones are one tag, because the digest in `values.yaml` is already correct and only changes
when `images/shim` does. When a change *does* touch the image, the pair is ordered again: publish the
image on a tag, read its digest, commit it, and release the chart on the next one.
