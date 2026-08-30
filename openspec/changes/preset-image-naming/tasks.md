## 1. The catalog of presets learns what package a preset publishes into

- [x] 1.1 Add a `package` field to `images/presets/presets.list` and say in its header why the
  package is stated rather than derived, naming the `voidlinux` / `void-current` /
  `stateful-pods-void` case that makes the point.
- [x] 1.2 Teach `hack/preset-build.sh`, `hack/preset-retention.sh` and `hack/check-presets.sh` to
  read the fifth field, and confirm each still rejects a malformed line rather than reading past it.

## 2. The build publishes into the new package and sets the rolling tag

- [x] 2.1 Test first: `hack/preset-build.sh --resolve-only` reports a reference in the new
  repository, and reports the dated tag unchanged.
- [x] 2.2 Compose the repository from the preset's package rather than from its name, so
  `--repository ghcr.io/<owner>/stateful-pods-` plus `ubuntu` is what a preset resolves to.
- [x] 2.3 Set the rolling tag on the index after the dated tag is pushed, and on the path where the
  dated tag was already published. Say in the comment why the order is that way round and why
  re-pointing on the already-published path cannot move the tag backwards.
- [x] 2.4 Confirm the build still refuses everything it refused before: a bad signature, a checksum
  mismatch, an unparsable index, an unknown preset, an incomplete upstream.

## 3. Retention keeps the rolling tag and counts per release

- [x] 3.1 Fixtures first, in `test/presets/retention.bats`, all failing before the planner changes:
  a rolling tag on the newest build is never deleted; a rolling tag left on a build outside the
  keep window is never deleted and neither are its children; a repository holding two releases
  retains each release's own five; a run for one release deletes nothing belonging to the other; a
  tag that is neither a rolling tag nor a dated build tag is still a hard stop.
- [x] 3.2 Extend `hack/preset-retention.jq` with `release` and `releases`, classify every tag as
  rolling, dated or unclassifiable, order and count only this release's builds, and protect
  everything a rolling tag or another release still points at.
- [x] 3.3 Pass the two new inputs from `hack/preset-retention.sh`, computing them from the catalog,
  and make `verify_retained` resolve the rolling tag for every platform after a run that acts.
- [x] 3.4 Run the whole retention suite and confirm the thirteen existing fixtures still pass
  unchanged in meaning.

## 4. The chart and its checks name the package

- [x] 4.1 Point `hack/check-presets.sh` at the package rather than the preset name when it asserts
  that a catalog entry's repository says what it is, and keep the digest-pinning assertion exactly
  as it is.
- [x] 4.2 Update `charts/stateful-pods/tests/values_preset_source_test.yaml` for the new repository
  name.
- [x] 4.3 Update `test/presets/bump.bats` fixtures, which name a preset repository.

## 5. Publish under the new names, then point the catalog at them

- [x] 5.1 Dispatch `preset-publish.yaml` against this branch and confirm all four presets publish
  rather than being left alone.
- [x] 5.2 Confirm each new package exists, is pullable, carries both the rolling and the dated tag,
  and resolves for both architectures; record what its visibility turned out to be.
- [x] 5.3 Write the four published digests into `charts/stateful-pods/presets.yaml` and run
  `hack/check-presets.sh`.

## 6. Documentation says what is published and what a machine is seeded from

- [x] 6.1 `charts/stateful-pods/presets.yaml` header: the rolling tag exists and this file
  deliberately does not name it.
- [x] 6.2 `charts/stateful-pods/README.md`: the guarantees table rows for tag immutability and for
  retention, the sentence about what the automatic publishing moves, and the claim about preset
  package visibility if the new packages turn out not to match it.
- [x] 6.3 `README.md`: the distributions section says what a person can pull and what the chart
  resolves.
- [x] 6.4 `.github/workflows/preset-publish.yaml`: the visibility report reads the package from the
  catalog rather than composing it from the preset name, and the header comment's claim that
  publishing changes nothing that already exists is corrected.

## 7. Verify

- [x] 7.1 `make all` green at the final commit.
- [x] 7.2 `make preset-test` green at the final commit.
- [x] 7.3 `hack/preset-retention.sh --dry-run` against the live packages produces a plan that
  deletes nothing, and names the rolling tag among what it protects.
