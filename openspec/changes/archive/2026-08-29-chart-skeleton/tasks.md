## 1. Scaffolding and tooling

- [x] 1.1 Create the chart tree at `charts/stateful-pods/` with `Chart.yaml` (apiVersion v2, name, initial version 0.1.0, description, kubeVersion floor) and an empty `templates/` directory; verify `helm lint charts/stateful-pods` exits 0
- [x] 1.2 Add a `Makefile` with `lint`, `test` and `render` targets wrapping `helm lint --strict`, `helm unittest` and `helm template`; verify `make lint` succeeds and `make test` runs the (still empty) suite without error
- [x] 1.3 Add a CI workflow running `make lint` and `make test` on push and pull request; verify the workflow file parses and the job succeeds on a branch push
- [x] 1.4 Document `helm` 3.x and the `helm-unittest` plugin as contributor prerequisites in the chart's README; verify the documented install command produces a working `helm unittest`

## 2. Values contract and validation

Tests come first in every pair below — write the failing test, then make it pass.

- [x] 2.1 Write the unittest suite for the per-machine security mode, covering unset, unknown value, and each of `userns` and `privileged`; verify the suite fails for the right reason before any helper exists
- [x] 2.2 Write the unittest suite for the machines map, covering absent, empty, one entry, and two entries; verify it fails before implementation
- [x] 2.3 Write the unittest suite for machine-name validity and for the combined `<release>-<machine>` length limit, including a name that is one character over; verify it fails before implementation
- [x] 2.4 Write the unittest suite for the deliberately rejected inputs (a per-machine init selector, a replica count); verify it fails before implementation
- [x] 2.4a Write the unittest suite for the rootfs source: missing source, unknown kind, `oci` without a reference, `lxc` without a URL, `lxc` without a checksum, and a field belonging to the other kind; verify it fails before implementation and that each case names the offending field
- [x] 2.5 Implement the validation helper in `_helpers.tpl`, accumulating all violations and failing once with the complete list, each entry naming the values path and the required action; verify the suites from 2.1–2.4 all pass
- [x] 2.5a Write and satisfy the unittest suite for the per-mode cluster version check: `userns` on a cluster below the required version fails naming the required version, the found version and the `privileged` alternative, while `privileged` renders on the same cluster; verify both cases with `--kube-version`
- [x] 2.6 Implement the single validation entry point invoked first by every template; verify the same error set is produced regardless of which template renders first by asserting on `helm template --show-only` for two different files
- [x] 2.7 Order the checks so structural failures short-circuit the semantic ones that depend on them; verify a values file with a malformed machines map reports only the structural error, not a cascade
- [x] 2.8 Write `values.yaml` with a comment on every input and an explicit note that per-guest network and DNS options have no equivalent, with the reason; verify by review that every key in `values.yaml` has an adjacent comment

## 3. Naming and helper conventions

- [x] 3.1 Write the unittest suite asserting that the StatefulSet, Service and volume claim template for machine `web` in release `lab` are all named `lab-web`; verify it fails before implementation
- [x] 3.2 Implement the name helper and two separate label helpers — selector labels (machine identity only) and object labels (selector labels plus version, managed-by and chart) — each taking an explicit `(dict "root" $ "name" $name "machine" $machine)` context and reading no `.Values` globals; verify 3.1 passes
- [x] 3.2a Write and satisfy the test that renders a machine twice with different chart versions and different images and asserts the StatefulSet selector is byte-identical, and that no version-bearing label appears in the selector; verify the test fails if a version label is added to the selector helper
- [x] 3.3 Add a test that renders a values file with two machines and asserts the render fails on the count guard rather than on a naming collision; verify this proves the templates already iterate the map rather than assuming a single entry

## 4. Object rendering

- [x] 4.1 Write the unittest suite for the StatefulSet: one replica, correct selector and labels, and the configured shim image on the guest container; verify it fails before implementation
- [x] 4.1a Write and satisfy the test asserting that no container's image is derived from a machine's rootfs source, for both an `oci`-sourced and an `lxc`-sourced machine; verify the `lxc` case renders a complete pod with no image derived from the template URL
- [x] 4.2 Implement the StatefulSet template, ranging over the machines map; verify 4.1 passes
- [x] 4.3 Write and satisfy the unittest suite for the rootfs volume claim template: `ReadWriteOnce` access mode, size from values, mounted at `/mnt/rootfs`, and the three storage-class states — unset omits the field, an explicit class is rendered, and an explicit empty string is preserved as empty; verify the suite passes
- [x] 4.4 Write and satisfy the unittest suite asserting `persistentVolumeClaimRetentionPolicy` is `Retain` for both `whenDeleted` and `whenScaled`; verify the suite passes
- [x] 4.4a Write and satisfy the unittest suite for the optional rootfs snapshot data source: unset emits no data source, set emits a reference to the named `VolumeSnapshot`; verify both cases
- [x] 4.4b Write and satisfy the unittest suite for the machine hostname: unset emits no `hostname` in the pod spec, set emits it; verify both cases
- [x] 4.5 Write and satisfy the unittest suite for the headless Service: `clusterIP: None` and a selector matching the machine's pod labels; verify the suite passes
- [x] 4.6 Apply the pod security posture selected by the machine's `security.mode`, per the mapping table in `design.md`: `userns` sets `hostUsers: false` and adds only `SYS_ADMIN`; `privileged` marks the guest container privileged and sets neither of the others; verify a unittest suite asserts the exact field set for each mode
- [x] 4.6a Write and satisfy the negative security tests: in `userns` mode no container is privileged, no privilege escalation is allowed, no capability beyond `SYS_ADMIN` is added, no host namespace is shared, and no `runtimeClassName` is set in either mode; verify each assertion fails if the corresponding field is introduced
- [x] 4.6b Write and satisfy the test that renders the same machine values against two different `--kube-version` values and asserts the pod security fields are identical; verify this proves the posture depends on the named mode alone
- [x] 4.7 Render the guest container with the shim image and an obvious placeholder command, defaulting `shim.image` to a placeholder reference, and add tests asserting both placeholders are present; verify the tests exist so that the change implementing the shim has to replace them deliberately
- [x] 4.8 Write `NOTES.txt` stating the machine's name and DNS name, and stating unambiguously that the machine does not boot yet in this version; verify `helm template` output contains the warning

## 5. Verification

- [x] 5.1 Validate the rendered manifest against the Kubernetes API schemas with `kubeconform` in the CI workflow; verify a deliberately malformed template is caught by the check
- [x] 5.2 Cross-check every scenario in `specs/machine-topology/spec.md`, `specs/values-validation/spec.md` and `specs/pod-security-posture/spec.md` against the test suites and record the mapping in the chart's README; verify every scenario has at least one corresponding test
- [x] 5.3 Render a complete minimal values file end to end and confirm the emitted objects are exactly one StatefulSet, one Service, and one volume claim template; verify with `helm template` output inspected in a test
- [x] 5.4 Ship two example values files, one per source kind, and render both in CI; verify each produces a valid manifest so that neither source kind can regress unnoticed
