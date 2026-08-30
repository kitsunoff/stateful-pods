## 1. Settle how a preset image is built

- [x] 1.1 Write `hack/preset-build.sh` far enough to fetch one build of `debian-trixie` for one
  architecture: resolve the path from `index-system`, download `rootfs.tar.xz`, `SHA256SUMS` and
  `SHA256SUMS.asc`; verify by hand for now, no packaging yet
- [x] 1.2 Obtain the linuxcontainers.org signing key fingerprint from what the project publishes,
  confirm it out of band, and commit it to the repository with a comment saying where it came from
  and that changing it is a decision; verify the fetched `SHA256SUMS.asc` validates against it
- [x] 1.3 Build the image with `images/presets/Containerfile` (`FROM scratch`, `ADD rootfs.tar.xz /`)
  and assert that the set of files carrying `security.capability` in the built image is identical to
  the set in the upstream tarball; verify by running the assertion and seeing both inventories match
  — done, and the narrow assertion passed: `ADD` preserves `security.capability`. Widening it to
  every extended attribute failed, because `ADD` drops the POSIX ACLs on `/var/log/journal`
- [x] 1.4 If the inventories differ, switch to `crane append` with the decompressed tarball as the
  single layer and record the change in `design.md` under Decisions; verify the same inventory
  assertion passes on the replacement path

## 2. The build, for all four presets on both architectures

- [x] 2.1 Finish `hack/preset-build.sh`: take distro, release and architecture, do the full
  verify-then-package sequence, and abort with a named failure on a bad signature, a checksum
  mismatch, or an index line it cannot parse; verify by running it against a deliberately corrupted
  checksum and seeing it refuse before packaging
- [x] 2.2 Record provenance in the image's OCI labels — the upstream path, the upstream build date,
  the verified checksum — and the standard `org.opencontainers.image.*` set the shim image already
  uses; verify by inspecting the built image's config
- [x] 2.3 Combine the per-architecture images into one multi-architecture index per preset, and
  refuse to publish a preset whose release the upstream does not offer for both architectures;
  verify that `crane manifest` on the index lists both platforms
- [x] 2.4 Add a `make preset-build` target mirroring the existing `image-build` and `image-test`
  conventions; verify a local run produces the four presets for the host architecture

## 3. Publishing

- [ ] 3.1 Add the build workflow: manual dispatch plus the matrix of the four presets, publishing to
  `ghcr.io/<owner>/stateful-pods-<distro>` under the `<release>-<upstream-date>` tag; verify a
  dispatch run publishes all four
- [ ] 3.2 Set each new package's visibility to public and assert it unauthenticated, because a GHCR
  package is private by default and the resulting failure looks like a typo in the reference; verify
  by resolving every published reference with no credentials
- [ ] 3.3 Assert in the workflow that a tag that already exists is never overwritten; verify by
  re-running a dispatch for an already-published build and seeing it skip rather than push

## 4. Keeping up, and cleaning up

- [ ] 4.1 Add the daily bump workflow: read `index-system`, compare each catalog entry's pinned
  upstream build with the newest, and for each preset that has fallen behind run the build and push
  the new dated tag; verify on a dry run that it identifies exactly the presets that are behind
- [ ] 4.2 Have it open one pull request per preset, on a branch named for that preset, updating the
  catalog entry to the reference it just published and force-updating an existing branch; verify the
  proposed reference resolves before the pull request is opened
- [ ] 4.3 Add the retention job: order a preset's tags by their build date, keep the newest five,
  and for each removed tag resolve the index's children, delete the index, then delete those
  children only when no retained index still references them; verify against a package seeded with
  seven builds
- [ ] 4.4 After a retention run, resolve every retained tag for both architectures and fail if any
  is incomplete — this is the failure mode a naive "delete untagged" step produces; verify the check
  fails when pointed at a deliberately broken index
- [ ] 4.5 Add `.github/dependabot.yml` for `github-actions` and `docker`, with a comment stating why
  the tarball upstream is not and cannot be covered by it; verify Dependabot's configuration is
  accepted by the repository

## 5. The chart learns the preset kind

- [x] 5.1 Write the helm-unittest suites first: a machine naming a known preset renders the pinned
  reference, an unknown name fails listing the available presets, a missing name fails, and a
  preset source carrying a `reference`, `url` or `sha256` fails naming the field; verify `make test`
  fails on the current chart for exactly those reasons
- [x] 5.2 Add `charts/stateful-pods/presets.yaml` with the four entries pinned by digest, and read
  it in `_helpers.tpl` with `.Files.Get` and `fromYaml`; verify a `helm package` followed by a
  render from the package resolves a preset, which is what a values file could not do
- [x] 5.3 Validate the new kind in `stateful-pods.validate.semantics`, generating the list of
  accepted names from the table rather than writing it twice; verify `make test` passes the suites
  from 5.1
- [x] 5.4 Resolve the preset in `stateful-pods.machine.seedEnv` to `SP_SOURCE_KIND=oci` with the
  resolved reference, plus `SP_SOURCE_PRESET` carrying the name; verify no seeding script gains a
  branch and `make shell-lint` is unchanged
- [x] 5.5 Record `SP_SOURCE_PRESET` in the provisioning marker written by `prepare.sh` as an
  additive field, leaving the record's schema version alone; verify the bats suite asserts the field
  is present when set and absent when not
- [x] 5.6 Add a `hack/check-presets.sh` asserting every catalog entry is pinned by digest and names
  a distribution the project publishes, wire it into `make`, and document the kind in `values.yaml`
  with a comment above every key; verify `make docs` and the new check both pass

## 6. Prove it end to end

- [x] 6.1 Add an example values file using a preset, and extend `make conform` and `make lint`
  coverage to it; verify both pass
- [ ] 6.2 Seed and boot a machine from each of the four presets in the integration test, asserting
  the machine's own init reaches a booted state — this is the first time Alpine and Void are
  exercised at all; verify with `make integration-test`
- [ ] 6.3 Assert that a preset machine's rootfs matches the node's architecture, using the same
  check the OCI path already has; verify on both architectures CI builds for
- [ ] 6.4 Assert the provisioning record names the preset the machine was made from; verify with
  `make integration-test`
