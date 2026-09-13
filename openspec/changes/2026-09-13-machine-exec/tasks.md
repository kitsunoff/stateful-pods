## 1. The rename, and what it costs

- [x] 1.1 Add `helm unittest` cases for the refusal of `native`, naming `exec` and saying that
  `exec` with no script behaves as `native` did; verify they fail against the unmodified chart
- [x] 1.2 Rename the backend in `_helpers.tpl` and in `lib-provision.sh`, and make `native` a
  refusal of its own rather than an unknown value
- [x] 1.3 Update every existing suite, example and fixture that names `native`; verify `make test`
  and `make shell-test` are green

## 2. The input contract and its refusals

- [x] 2.1 Add `helm unittest` cases for every refusal in the `values-validation` delta - an `exec`
  block that is not a map, an unknown key under it, a script supplied both ways or neither, an
  environment likewise, a retry count and a timeout that are not counts, `exec` inputs on a
  cloud-init machine, `cloudInit` inputs on an exec machine, and an object name that leaves no room
  for the Job's; verify each fails for the right reason
- [x] 2.2 Extend the provisioning resolution helper with the `exec` catalog, so that a script and an
  environment are materialized under fixed names by the same machinery the cloud-init inputs use
- [x] 2.3 Implement the validation, accumulating into the existing semantic stage

## 3. The image

- [x] 3.1 Add `kubectl` to `images/shim/Containerfile` from the base image's own repository, and
  extend `hack/image-test.sh` to assert it is present and reports a client version
- [x] 3.2 Add `images/shim/scripts/lib-exec.sh` and `exec-provision.sh`, and make the entry point
  executable in the image
- [x] 3.3 Add a `bats` suite for the library: that it refuses to run with no script mounted, that it
  waits for readiness before it execs, that it confirms the boot marker, that it places the script
  through a shell rather than an archiver, that the environment is sourced from a file and never
  passed as an argument, and that a non-zero script fails the run; verify `make shell-test` is green
- [x] 3.4 Run `make image-test`; verify it is green

## 4. The objects

- [x] 4.1 Add `helm unittest` cases asserting that a machine with a script renders a Job, a
  ServiceAccount, a Role and a RoleBinding, that the Role names the machine's own pod and nothing
  else, that the Job's name carries a digest that moves with the material and not otherwise, that
  the machine's pod is unchanged by a script change, that no `checksum/provisioning` annotation is
  applied under this backend, and that a machine with no script renders none of it
- [x] 4.2 Add `templates/exec-job.yaml` and `templates/exec-rbac.yaml`; mount the provisioning
  material into the Job rather than into the preparation step under this backend
- [x] 4.3 Give the machine's own pod no ServiceAccount token, and assert it
- [x] 4.4 Verify `make test` and `make conform` are green at both the development version and the
  chart's floor

## 5. Documentation

- [x] 5.1 Document the backend in `values.yaml` at the point of use, including the access the Job is
  given in plain words, the re-run policy, and what removing a script does and does not undo; run
  `make docs`
- [x] 5.2 Add an example under `charts/stateful-pods/examples/`; confirm `make lint` and
  `make conform` cover it
- [x] 5.3 Extend `NOTES.txt` to name the Job, say how to read its logs, and say which command runs
  the script again
- [x] 5.4 Update the chart README, the project README and the preset tables that say `native`

## 6. On a cluster

- [x] 6.1 Extend `hack/integration-test.sh`: a machine on a source with no cloud-init is configured
  by its own script, the script's effect is visible inside the machine, an unchanged release does
  not run it again, a changed script does, the machine's pod is not replaced by either, and a
  failing script fails the Job with its own output in the logs
- [x] 6.2 Run `make all`, `make image-test` and `make integration-test`; verify all are green
