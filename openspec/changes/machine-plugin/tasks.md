## 1. Publish the chart, because create has nothing to install without it

- [ ] 1.1 Add `helm package` and `helm push` to `oci://ghcr.io/<owner>/charts` to the existing tag
  build in `.github/workflows/ci.yaml`, beside the shim image publication; verify a dry run packages
  the chart and reports the reference it would push
- [ ] 1.2 Publish once and install from the published reference into a throwaway namespace; verify
  `helm upgrade --install` against the OCI reference renders and installs with no checkout present

## 2. The plugin itself

- [ ] 2.1 Create `cmd/kubectl-machine` with subcommand dispatch, full-form long flags, `--help` for
  every subcommand, and a startup check that names a missing `kubectl` or `helm` rather than failing
  inside a pipeline; verify `kubectl machine --help` works once the file is on `PATH`
- [ ] 2.2 Add the platform check that refuses to run where bash is not the shell the plugin targets,
  naming the platform; verify it exits with the message rather than partway through an action
- [ ] 2.3 Resolve a machine by the `stateful-pods.io/machine` label, reporting every match with its
  release when a name is ambiguous and doing nothing, and listing the machines that do exist when a
  name is not found; verify with a stubbed `kubectl` returning zero, one and two matches
- [ ] 2.4 Implement the stage derivation exactly as the table in `design.md` states, reading only
  from the pod's own status with `--output jsonpath` and no `jq`; verify with a bats suite feeding
  canned pod status for every row of that table
- [ ] 2.5 Implement `list` and `status` on top of it; verify each machine appears under its own name
  with its stage, for one machine and for a namespace with several

## 3. Getting in, and looking at it

- [ ] 3.1 Implement `shell`: exec with a TTY into the `guest` container, choosing `bash` or `sh`
  inside the machine in one round trip, with a trailing `--` passing a command through instead;
  verify the composed command against a stubbed `kubectl` and confirm no shell is assumed to exist
- [ ] 3.2 Make a failure to enter report the machine's stage and the command that shows the relevant
  output, instead of the container error; verify with stubbed status for a seeding machine, a
  booting machine and a machine whose seed step failed
- [ ] 3.3 Implement `console` as the guest container's logs, with a follow mode; verify the composed
  command and that it works while the machine is still booting

## 4. Making one, and removing one

- [ ] 4.1 Implement `create`: map the flags to values paths, compose `helm upgrade --install` with
  `--chart` defaulting to the published reference and `--version` to the plugin's own, print the
  context, namespace and resulting object name first, then run it; verify the composed command with
  a stubbed `helm` for an oci source and an lxc source
- [ ] 4.1a Add `--preset` and its test only once `distro-presets` has landed, since it composes a
  source kind the chart does not yet accept; verify the composed command against a stubbed `helm`,
  and until then verify that `--preset` reports the flag as not yet available
- [ ] 4.2 Assert that the plugin adds no default and no validation of its own: a create missing a
  required input must surface the chart's message unchanged; verify with a stub that returns the
  chart's rejection and an assertion that the plugin's output contains it verbatim
- [ ] 4.3 Make `create` fail usefully when the chart reference cannot be resolved, telling the user
  to pass `--chart` a local path; verify with a stubbed `helm` that fails to pull
- [ ] 4.4 Implement `delete`: print context, namespace, machine and object name, require typing the
  machine's name to confirm, accept `--yes` for non-interactive use, and do nothing when
  non-interactive without it; verify that no `helm uninstall` is composed in the unconfirmed case
- [ ] 4.5 After removal, state that the root filesystem survives and print the
  `kubectl delete persistentvolumeclaim` command that would destroy it; verify no flag anywhere in
  the plugin performs both actions

## 5. Tests, lint and the macOS constraint

- [ ] 5.1 Add `test/shell/plugin*.bats` with stubbed `kubectl` and `helm` recording their arguments,
  following the stub pattern the existing suites use; verify `make shell-test` runs them
- [ ] 5.2 Pass `cmd/kubectl-machine` to `hack/shell-lint.sh` explicitly, since it has no `.sh`
  extension and the current `find` would skip it in silence, and assert the number of files linted so
  that a skipped file fails the lint; verify by temporarily renaming the plugin and seeing the count
  assertion fail
- [ ] 5.3 Add a CI job on a macOS runner that runs the plugin's suite against the system bash 3.2;
  verify it fails on a deliberately introduced bash 4 construct such as `declare -A`
- [ ] 5.4 Check the plugin's own bash for 3.2 compatibility — no associative arrays, no `mapfile`, no
  `${var^^}`; verify the macOS job from 5.3 is green

## 6. Shipping it

- [ ] 6.1 Add release archives to the tag build: the plugin and the licence in a `.tar.gz` per
  supported platform, with a published `sha256` for each; verify the checksums match a downloaded
  archive
- [ ] 6.2 Add the krew manifest to the repository, listing each supported platform, and verify it
  with `kubectl krew install --manifest` against a published release
- [ ] 6.3 Document installation in the README, including that Windows is not supported and why;
  verify the documented commands work from a clean machine
- [ ] 6.4 Point `NOTES.txt` at the plugin for the operations it now covers, keeping the raw
  `kubectl` form for anyone without it; verify `make test` still passes the notes suite
