## 1. Settle what the images actually contain, before building on it

- [x] 1.1 Read the published `debian-trixie`, `alpine-3.24` and `void-current` preset root
  filesystems and record, for each, the path of the cloud-init program, the init-system integration
  it ships, and whether `/etc/cloud/cloud-init.disabled` is present; verify by exporting each image
  and listing the paths rather than by reasoning from the distribution's packaging
- [x] 1.2 Read the unit files and the OpenRC scripts those images ship and confirm that the disabled
  marker is the single gate on both init systems; verify by finding the condition in each
- [x] 1.3 Record the result in `design.md` as the table the fail-loud check is built on, and state
  which enablement questions are deliberately not checked and why

## 2. The value-source contract, in the templates

- [x] 2.1 Add `helm unittest` cases for the refusals in the `values-validation` delta — an input
  given both inline and by reference, a `valueFrom` naming two sources, a reference missing its name
  or its key, an input belonging to an unselected backend, an unknown key under `cloudInit`, an
  unrecognised backend, and `systemd-credentials` saying it is not implemented; verify every one
  fails against the unmodified chart for the right reason
- [x] 2.2 Implement the resolution helper in `_helpers.tpl`: for one machine, walk the declared
  provisioning inputs and emit what the pod spec needs — the inline entries for the chart-owned
  Secret, and one projected source per reference — with the file name each input is defined to use;
  verify with `helm template` that a mixed inline-and-referenced machine renders both
- [x] 2.3 Implement the validation the cases from 2.1 demand, accumulating into the existing
  semantic stage so that fixing one input does not merely reveal the next; verify `make test` is
  green and every message names the input
- [x] 2.4 Run `make docs`; verify `values.yaml` still satisfies the documentation checks after the
  new inputs are added

## 3. The pod: the Secret, the volume and the step

- [x] 3.1 Add `helm unittest` cases asserting that a machine supplying material renders a
  chart-owned Secret and a projected volume mounted only into the `provision` container, that a
  machine supplying nothing renders neither, that the guest container mounts neither, and that the
  pod annotation changes when inline material changes and when the revision input changes; verify
  they fail against the unmodified chart
- [x] 3.2 Add `templates/provisioning-secret.yaml` rendering the inline material, and extend
  `statefulset.yaml` with the projected volume, the `provision` init container and the
  `checksum/provisioning` annotation; verify `make test` and `make conform` are green
- [x] 3.3 Update the existing suites the fourth init container changes — the init-container,
  init-security and script-path suites — and `assert_default_filter` in `hack/integration-test.sh`,
  which asserts the filter of exactly three steps; verify `make test` is green and the integration
  helper counts four

## 4. The provisioning step, in the shim image

- [ ] 4.1 Write `test/shell/provision.bats` for the `native` backend: the step writes nothing into
  a fixture root filesystem, removes nothing, and says what it did; verify it fails with no script
  present
- [ ] 4.2 Write the cases for the fail-loud check against three fixture root filesystems — one with
  no cloud-init at all, one with the program but no init integration, and one with both — asserting
  that the first two fail with a message naming `guest.provisioning: native` and that neither leaves
  a seed behind; verify they fail before the script exists
- [ ] 4.3 Write the cases for what the cloud-init backend writes: the four seed paths, the drop-in
  with the six settings, the removal of `/etc/cloud/cloud-init.disabled`, and that a root filesystem
  with no `/etc/cloud` at all still ends up with a usable drop-in
- [ ] 4.4 Write the cases for composition and shadowing: structured inputs compose a cloud-config
  that is valid JSON, list-valued inputs become arrays one item per line, a supplied `userData`
  is used verbatim and the structured inputs for it are ignored, and shadowing does not affect
  `network-config`
- [ ] 4.5 Write the cases for the instance identity: the same material yields the same identity
  across two runs, changed material changes it, a changed machine name changes it, and the same
  content supplied by two different forms yields the same identity
- [ ] 4.6 Implement `images/shim/scripts/lib-provision.sh` and `provision.sh` until the suites in
  4.1–4.5 pass; verify `make shell-test` is green
- [ ] 4.7 Mark `provision.sh` executable in `images/shim/Containerfile` and add an assertion to
  `hack/image-test.sh` that it is; verify `make image-test` is green — a container whose command is
  not executable fails at start, which is the failure this line prevents
- [ ] 4.8 Run `make shell-lint`; verify shellcheck reports nothing

## 5. Prove both halves on a cluster, as a user

- [ ] 5.1 Add the positive assertion to `hack/integration-test.sh`: a machine whose `userData`
  creates a user with an SSH public key, asserting inside the booted machine that the user exists,
  that the key is in its `authorized_keys`, and that cloud-init reports the run as successful rather
  than merely having started
- [ ] 5.2 Add the negative assertion: a machine on a root filesystem that cannot run cloud-init and
  declares no backend must fail, and the assertion must match the message the design demands rather
  than merely observing that the pod is unhealthy; verify it fails if the message changes
- [ ] 5.3 Add the assertion that the same machine boots once it names `guest.provisioning: native`,
  so the fix the message offers is the fix that works
- [ ] 5.4 Run the whole suite on kind against a machine seeded from a preset carrying cloud-init;
  verify the user it created can be logged into over SSH from inside the cluster, using the key that
  was supplied

## 6. Documentation, at the point of use

- [ ] 6.1 Document every new input in `values.yaml` beside where it is used, including that inline
  material is stored in the Helm release, that a crypt(3) hash belongs in `password`, and that raw
  files shadow structured values per file; verify `make docs` is green
- [ ] 6.2 Add the backend to the preset table in `README.md` and `charts/stateful-pods/README.md`,
  stating for each preset which backends it can serve and that `void-current` must name `native`;
  verify by reading the table against `images/presets/presets.list`
- [ ] 6.3 Add the upgrade note naming the changed default as the break, with the one-line fix
- [ ] 6.4 Extend `NOTES.txt` to report the backend a machine selected and to warn when a raw file
  shadowed structured values; verify with the notes suite
- [ ] 6.5 Add an example under `charts/stateful-pods/examples/` showing both input forms in one
  machine; verify `make lint` and `make conform` cover it

## 7. Green at the final commit

- [ ] 7.1 Run `make all`; verify green
- [ ] 7.2 Run `make image-test`, `make seccomp-test` and `make integration-test`; verify green, and
  state in the report which targets ran, at which commit, and what could not run
