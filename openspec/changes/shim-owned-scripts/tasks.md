## 1. Settle the fill tool before anything depends on it

- [x] 1.1 Give `hack/image-test.sh` a `registry:2` container beside its scratch volume, because a
  `crane` in a container cannot read a local image store; verify the registry is reachable from the
  shim image with `crane catalog`
- [x] 1.2 Build the fixture image with `crane append` from two layer tarballs made by the GNU tar
  already in the shim — the first carrying a file with `security.capability`, the second carrying a
  `.wh.` whiteout for a path the first added — and push it; verify `crane manifest` reports two
  layers, with no container builder involved
- [x] 1.3 Assert that `crane export` of that image preserves the capability and honours the
  whiteout; verify by running `make image-test` and seeing both new assertions pass
- [x] 1.4 Not needed: both assertions held against the real `crane`, so the fill stays `crane
  export` and `design.md` needs no correction. Verified by `make image-test`, which now carries
  those two assertions permanently

## 2. The image carries the scripts

- [x] 2.1 Move `charts/stateful-pods/scripts/` to `images/shim/scripts/` with `git mv`, leaving the
  file contents untouched; verify `git status` shows renames only and no deletions
- [x] 2.2 Add `crane` to `images/shim/Containerfile`, copy the scripts to
  `/usr/local/lib/stateful-pods/`, make them executable, and state in the file's header comment why
  the scripts are now part of the image; verify with `make image-build` followed by a container run
  that lists the directory and executes `crane version`
- [x] 2.3 Update every `# shellcheck source=` directive to the new path and add `images` to the
  search roots in `hack/shell-lint.sh`; verify `make shell-lint` passes and reports the same script
  count as before plus none missing

## 3. The OCI fill runs in the shim

- [x] 3.1 Rewrite `test/shell/seed-oci-copy.bats` against the new fill: a stub `crane` on `PATH`
  that emits a fixture tar, asserting the volume is filled, that a non-zero `crane` fails the seed
  rather than recording it, and that the requested platform is the node's; verify the suite fails
  for the right reason before the implementation lands
- [x] 3.2 Delete `test/shell/seed-oci-probe.bats` and the source-image archiver probe it covers,
  replacing it with a case asserting that a source providing no shell and no tar is seeded anyway;
  verify by pointing the suite's stub at a fixture built from a `scratch`-like tree
- [x] 3.3 Rewrite `lib-oci.sh` around `crane export` streamed into GNU tar, under `pipefail` with
  both pipe statuses checked, and map the kernel's machine architecture onto an OCI platform,
  failing by name on an unmapped one; verify `make shell-test` passes the suites from 3.1 and 3.2
- [x] 3.4 Hoist `SP_TAR_FLAGS` into `lib-seed.sh` as one definition for both source kinds, dropping
  the creation-only `--one-file-system`; verify `make shell-test` stays green and `grep` finds a
  single definition
- [x] 3.5 Convert `seed-oci.sh` to bash mirroring `seed-lxc.sh`, and update the header comments in
  `lib-oci.sh`, `lib-state.sh` and `lib-seed.sh` that explain the POSIX-sh constraint to say which
  parts it still applies to; verify `make shell-lint` passes with the new shebang dialect

## 4. The chart stops shipping scripts

- [x] 4.1 Rewrite the helm-unittest suites that pin the current delivery — `init_scripts_test.yaml`,
  `init_containers_test.yaml`, `boot_test.yaml`, and `shim_image_test.yaml`, whose first case still
  asserts that the seed container's image *is* the OCI source — to assert no ConfigMap is rendered,
  no `scripts` volume or mount exists, every command is an absolute path under
  `/usr/local/lib/stateful-pods`, and no container carries the source as its image; verify
  `make test` fails on the current templates for exactly those reasons
- [x] 4.2 Delete `templates/scripts-configmap.yaml`, remove the `scripts` volume and its four
  mounts from `templates/statefulset.yaml`, and point every command at its path in the image;
  verify `make test` passes the suites from 4.1
- [x] 4.3 Make the `seed` init container run the shim image for both source kinds, and update the
  comments in `statefulset.yaml` that explain why it used to run the source image; verify by
  rendering both examples and confirming no container refers to a machine's source
- [x] 4.4 Add `machines.<name>.source.pullSecretName`: a suite asserting it is mounted into the
  seed container alone, projected to `config.json`, with `DOCKER_CONFIG` set, and absent entirely
  when unset; the volume, mount and env belong to the seed container's own block, never to the
  shared `stateful-pods.machine.seedEnv` helper; verify `make test` covers both the set and unset
  renders and that no other container gains a mount
- [x] 4.5 Validate the new input in `_helpers.tpl` — accepted for `oci`, rejected for `lxc` with the
  cross-kind message, rejected when empty or not a valid object name; verify by extending
  `values_rejected_inputs_test.yaml` and `values_rootfs_source_test.yaml` and running `make test`
- [x] 4.6 Document the new input in `values.yaml` next to `source.reference`, including that
  `imagePullSecrets` on the ServiceAccount is not consulted and that credential helpers are not
  supported, and restate under `shim.image` that an override now supplies the chart's logic; the
  comment must sit on the line directly above the key, which is what `hack/check-values-docs.sh`
  enforces for every input; verify `make docs` passes and the render of both examples is unchanged
  apart from the intended diff

## 5. Suites and tooling follow the move

- [x] 5.1 Update the `SCRIPTS`, `LIB` and fixture paths in every bats suite under `test/shell/` to
  `images/shim/scripts`; verify `make shell-test` runs the same number of tests as before the move
- [x] 5.2 Point the boot-handover assertion that greps installed helpers for a `/scripts/` reference
  at the new path; `sp_install_runtime_helpers` already takes its source directory as an argument
  and `boot.sh` already derives it from `$0`, so neither should change — verify `make shell-test`
  passes with those two lines untouched
- [x] 5.3 Check `Makefile` and `.github/workflows/ci.yaml` for anything that assumed the scripts
  lived in the chart, including the image build context; verify a full `make all` and a CI run on
  the branch

## 6. Prove it on a cluster

- [x] 6.1 Replace the `kind load` of the source image with a registry the pod can reach: an
  in-cluster registry the test pushes to, referenced by a name that resolves from inside the
  cluster; `kind load` puts an image where containerd can see it and `crane` cannot, so the existing
  arrangement silently stops working — verify the oci machine seeds from the registry with
  `make integration-test`
- [x] 6.2 Confirm whether go-containerregistry speaks plain HTTP to a `.local` registry name before
  building on it, and fall back to a TLS test registry rather than adding an insecure-registry input
  to the chart; verify by seeding once against the chosen arrangement
- [x] 6.3 Add an Alpine-based source to `test/integration/` — a source that the old path rejected —
  and assert it seeds and boots; verify with `make integration-test`
- [x] 6.4 Assert that a restart of a seeded machine makes no request to the source, by stopping the
  test registry after the first boot and requiring the machine to come back up; verify with
  `make integration-test`
- [x] 6.5 Assert that the machine's rootfs matches the node's architecture, by checking the class of
  a binary taken from the seeded volume against the node's own; verify with `make integration-test`
  on both architectures CI builds for
- [x] 6.6 Confirm the release-owned ConfigMap disappears on upgrade without touching the volume:
  install with the previous chart revision, upgrade to this one, and assert the machine's own file
  written before the upgrade is still there; verify with `make integration-test`

## 7. Release sequencing

- [x] 7.1 Land the chart and image changes with `values.yaml` still pinning the previous digest, and
  state in the pull request that the chart is installable only with a `shim.image` override until
  the image is published; verify CI is green on the branch
- [ ] 7.2 After the tag build publishes the image, bump the default `shim.image` digest in
  `values.yaml` and the chart version; verify a `helm install` with no overrides on a fresh cluster
  seeds and boots a machine
