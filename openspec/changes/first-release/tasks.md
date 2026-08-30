## 1. Licence

- [x] 1.1 Add an MIT `LICENSE` at the repository root, copyright Maxim Belyy, and verify
  `./hack/release-archives.sh --version 0.1.0` no longer prints either "no LICENSE" warning
- [x] 1.2 Verify the licence reaches the plugin archive: run the release script and confirm
  `tar --list` on the archive it writes shows `LICENSE`, which is what the krew index requires
- [x] 1.3 Record the licence on the chart as an `annotations` block in
  `charts/stateful-pods/Chart.yaml`, and verify `make lint` still passes
- [x] 1.4 Confirm `krew/machine.yaml` needs no edit — its `files: [{from: "*"}]` glob already picks
  up whatever the archive holds — and verify by rendering the manifest with the release script

## 2. Packaging

- [x] 2.1 Add `charts/stateful-pods/.helmignore` excluding `tests/`, and verify
  `helm package` writes an archive whose `tar --list` contains no `tests/` entry
- [x] 2.2 Verify `make test` still passes, since `helm unittest` reads `tests/` from the chart
  directory rather than from the package

## 3. Release-quality defects

- [x] 3.1 Write a failing unit test in `charts/stateful-pods/tests/values_rootfs_source_test.yaml`
  for an unquoted all-digit `sha256`, for a wrong-length one, and for one carrying a character
  outside `0-9a-f`; verify each fails before the rule exists
- [x] 3.2 Add the form check to the `lxc` branch of `stateful-pods.validate.semantics` in
  `charts/stateful-pods/templates/_helpers.tpl`, naming quoting as the fix, and verify the tests
  from 3.1 now pass and a well-formed checksum still renders
- [x] 3.3 Write a failing case in `test/shell/seed-lxc.bats` for a template carrying a device node
  under `./dev`, and verify it fails before the exclusions exist
- [x] 3.4 Build the runtime-directory exclusions from `SP_RUNTIME_DIRS` in `lib-lxc.sh` as a
  space-separated word list, not an array, since the file is `sh`; verify 3.3 passes and
  `make shell-lint` reports nothing
- [x] 3.5 Make the `conform` recipe render each example on its own before piping it, mirroring the
  guard the floor example already has, and verify a deliberately broken example makes
  `make conform` exit non-zero
- [x] 3.6 Add `needs: [chart, plugin]` to the `image` job in `.github/workflows/ci.yaml` and verify
  the file still parses and that no other tag-triggered publishing job is left ungated

## 4. Documentation

- [ ] 4.1 Add a repository `README.md` in the style of the author's other repositories, and verify
  every claim in it is true of the tree it ships with — in particular what it says about
  `shim.image` and about which release is installable
- [ ] 4.2 Add a superseded-by line to `docs/research/05-open-questions.md` §3 and
  `docs/research/03-mapping-and-architecture.md` §3.6 pointing at the spec that now governs, leaving
  the text below each untouched
- [ ] 4.3 Add `RELEASE.md` giving the two-tag order as named commands, and verify the version
  strings it names agree with `Chart.yaml`, the plugin's `SP_VERSION` and the tag check in CI
- [ ] 4.4 Verify every Markdown file added or changed satisfies `.markdownlint.yaml`

## 5. Housekeeping

- [ ] 5.1 Review the six open Dependabot pull requests on their merits, merging those whose inputs
  the workflows do not use and which change only the runtime; verify each diff touches nothing else
- [ ] 5.2 Reproduce the Alpine 3.24 regression against both bases before deciding that pull request,
  and close it with the reproduction rather than merging it
- [ ] 5.3 Remove the stale `openspec/changes/machine-plugin/` line from `.git/info/exclude`, leaving
  the `.claude/` line, and verify `git status` is unaffected
- [ ] 5.4 File one issue per defect left unfixed, each with a reproduction, and verify none of them
  duplicates something this change fixed

## 6. Verification

- [ ] 6.1 Confirm `helm`, `shellcheck`, `bats`, `kubeconform` and `crane` resolve on `PATH` at the
  versions CI pins, and record where each came from — a suite that passes because a tool is missing
  proves nothing
- [ ] 6.2 Run `make all` at the final commit and verify it exits zero
- [ ] 6.3 Run `make image-test` at the final commit and verify it exits zero
- [ ] 6.4 Run the kind-based suites this change can affect and report exactly which ran, which were
  skipped and why
- [ ] 6.5 Re-check whether GitHub Actions starts jobs immediately before the release step; if it
  does not, stop at the tag and report what is prepared
