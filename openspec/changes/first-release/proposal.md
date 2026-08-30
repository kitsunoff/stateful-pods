## Why

The chart, the shim image and the `kubectl machine` plugin are all written, tested and merged, and
none of them has ever been published. What stands between the repository and its first tag is not a
missing feature: it is a licence the krew index requires and the release script warns about on every
run, a repository with no README at its root, a package that carries thirty-six unit-test fixtures
into every install, a handful of defects the last five changes found and deliberately left, and one
ordering problem — the chart pins the shim image by digest, and that digest can only exist after a
build that a tag triggers.

The last of those decides what the first release actually is, so it is settled here in writing
rather than discovered at the tag.

## What Changes

- Add an MIT `LICENSE` at the repository root, copyright Maxim Belyy. This removes the warning
  `hack/release-archives.sh` emits on every build, puts a licence inside the plugin archive — which
  is what the upstream krew index requires before `krew/machine.yaml` can be submitted — and is
  recorded on the chart itself as an Artifact Hub annotation.
- Add a repository `README.md`. There is none today; `charts/stateful-pods/README.md` is the only
  one, and it is a chart reference rather than an introduction to the project.
- Add `charts/stateful-pods/.helmignore` so the packaged chart stops shipping `tests/`. Those
  thirty-six helm-unittest suites are roughly half the chart directory by size and no installing
  user can run them.
- Gate the `image` job in CI behind the jobs that hold the suites. On a tag it publishes the shim
  with no `needs`, so a red chart or plugin job does not stop the push — and the image is the half
  of a matched pair that the chart pins by digest.
- Make `make conform` fail when an example fails to render. Its per-example loop takes the exit
  status of `kubeconform`, which is content with the empty input a failed render hands it. The
  guard already exists four lines below, for the floor example only.
- Refuse an LXC checksum that is not a checksum, at render time. An all-digit `sha256` left unquoted
  is parsed by YAML as a float and reaches the guest as `1.23...e+61`, which fails after the whole
  template has been downloaded rather than before anything is fetched.
- Exclude the runtime directories when unpacking an LXC template, as the OCI path already does.
  Without it, a template carrying a device node under `./dev` cannot be seeded by a machine in
  `userns` mode at all, because `mknod` is checked against the initial user namespace.
- Point the two stale sections of `docs/research/` at the specs that superseded them, rather than
  rewriting them. They describe a privilege ladder whose bottom rung was `privileged: true`, which
  the chart has not rendered since `bounded-privileged-mode`.
- Add `RELEASE.md`: the order the two tags go in, and why the first one cannot be the installable
  one.

## Capabilities

### New Capabilities

None. Everything here either fixes code against a requirement that already exists, or changes no
behaviour at all.

### Modified Capabilities

- `values-validation`: an LXC source's checksum is checked for its form and not merely its
  presence, so a value YAML coerced into a float is refused at render time with the reason and the
  fix.

Two other behaviour changes in this proposal need no delta, and it is worth saying why. Excluding
runtime directories on the LXC path is a fix against `rootfs-seeding`'s existing requirement
*Runtime state is never seeded*, whose scenario *Device nodes are not copied* the LXC path does not
currently satisfy — the requirement is right and the code is wrong. Gating the `image` job, the
`.helmignore`, the licence, the READMEs and `make conform` are tooling, packaging and documentation,
which describe no guest-visible behaviour at all.

## Impact

- `LICENSE`, `README.md`, `RELEASE.md` — new at the repository root.
- `charts/stateful-pods/.helmignore` — new. Changes what `helm package` writes, not what renders.
- `charts/stateful-pods/Chart.yaml` — an `annotations` block naming the licence.
- `charts/stateful-pods/templates/_helpers.tpl` — one more refusal in the `lxc` branch of
  `stateful-pods.validate.semantics`, with a case in
  `charts/stateful-pods/tests/values_rootfs_source_test.yaml`.
- `images/shim/scripts/lib-lxc.sh` — the unpack grows the exclusion list `lib-oci.sh` already
  builds, with a case in `test/shell/seed-lxc.bats`. The file is `sh`, not `bash`, so the list
  cannot be an array.
- `.github/workflows/ci.yaml` — `needs` on the `image` job.
- `Makefile` — the `conform` recipe.
- `docs/research/03-mapping-and-architecture.md`, `docs/research/05-open-questions.md` — a
  superseded-by note at the head of the two stale sections.

Deliberately out of scope, each filed as an issue instead: dropping capabilities in
`initSecurityContext`, which contradicts the stated intent of assertions in two test files and is a
design question rather than a patch; bumping the default `shim.image` digest, which cannot happen
until a build publishes one; the preset retention workflow's missing token; and the visibility of
the published packages.
