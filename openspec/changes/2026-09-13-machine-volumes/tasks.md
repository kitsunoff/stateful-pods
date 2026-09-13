## 1. The input contract and its refusals

- [ ] 1.1 Add `helm unittest` cases for every refusal in the `values-validation` delta, and verify
  each fails against the unmodified chart for the right reason
- [ ] 1.2 Add the resolution helper to `_helpers.tpl`: for one machine, emit the declared volumes
  normalised into what the pod spec needs - the claim templates, the pod volumes and the guest's
  mounts - deterministically ordered
- [ ] 1.3 Implement the validation, accumulating into the existing semantic stage; verify `make
  test` is green and every message names the machine and the volume

## 2. The objects

- [ ] 2.1 Add `helm unittest` cases asserting that a sized volume renders a claim template with its
  own class and data source, that an existing claim renders a pod volume and no template, that the
  rootfs template stays first, that the guest mounts each volume inside the root filesystem's mount
  point, and that no init container mounts one; verify they fail against the unmodified chart
- [ ] 2.2 Render the claim templates, the pod volumes and the guest's mounts in `statefulset.yaml`
- [ ] 2.3 Verify `make test` and `make conform` are green at both the development version and the
  chart's floor

## 3. Documentation

- [ ] 3.1 Document the block in `values.yaml` at the point of use - the permanence of the name, the
  immutability of the size, the paths the boot sequence owns, and what mounting over populated
  content does; run `make docs`
- [ ] 3.2 Add an example under `charts/stateful-pods/examples/`, and confirm `make lint` and
  `make conform` cover it
- [ ] 3.3 Extend `NOTES.txt` to report each declared volume, the claim behind it and the path it is
  mounted at
- [ ] 3.4 Update the chart README and the project README

## 4. On a cluster

- [ ] 4.1 Extend `hack/integration-test.sh`: a machine with a declared volume boots, the path inside
  the machine is a mount point on a different filesystem from the root, what is written there
  survives the pod being deleted, and the claim survives `helm uninstall`
- [ ] 4.2 Run `make all` and `make integration-test`; verify both are green
