## 1. The boot script

Tests come first in every pair below — write the failing test, then make it pass.

- [ ] 1.1 Write the `bats` suite for the mount plan: the fixed set, its order, and that kernel filesystems land in the new root before anything else; verify it fails before any script exists
- [ ] 1.2 Implement the mount step against a fake root in the suite's temporary directory, checking every mount and failing with the path and the filesystem type; verify 1.1 passes
- [ ] 1.3 Write and satisfy the test that the device nodes present in the container's own `/dev` are bound rather than created, and that a node the runtime did not provide is skipped without failing the boot; verify with the nodes the test container actually has
- [ ] 1.4 Write and satisfy the test that the control-group filesystem is mounted for every machine regardless of what the volume contains; verify the mount plan is identical for a volume holding systemd and one holding a lighter init
- [ ] 1.5 Write and satisfy the test that a failing mount stops the boot naming the path and the filesystem type, and that the guest's init is never started afterwards; verify with a mount that cannot succeed
- [ ] 1.6 Write and satisfy the test that a volume with no init to hand over to fails saying so, and that an unseeded volume is refused before any mount is attempted; verify both messages
- [ ] 1.7 Implement the root change and the handover, exporting the container marker into the init's environment; verify a test asserts the environment the init would be executed with

## 2. The files the chart manages inside the machine

- [ ] 2.1 Write the `bats` suite for the three managed files: each is written into the volume from the pod's own copy, and re-written when the pod's copy has changed; verify it fails before implementation
- [ ] 2.2 Implement the customization step; verify 2.1 passes and that it runs before the root change
- [ ] 2.3 Write and satisfy the suite for the opt-out marker: a claimed file is neither written nor removed, an unclaimed one still is, and claiming one file does not claim the others; verify each of the three files independently
- [ ] 2.4 Write and satisfy the test that the marker is read from the volume rather than from any input, so that it survives a restore under a different release; verify by running the step twice under different release names

## 3. Readiness and shutdown

- [ ] 3.1 Write the `bats` suite for the readiness check: negative while the machine is still starting, positive once it has finished, for a systemd guest and for one running something else; verify it fails before implementation
- [ ] 3.2 Implement the readiness helper as a POSIX `sh` script using only what an operating system provides; verify 3.1 passes and that `shellcheck` accepts it with the `sh` dialect
- [ ] 3.3 Write the `bats` suite for the stop helper: the systemd signal when systemd's own marker is present, the ordinary signal otherwise, and waiting for the init to exit in both cases; verify it fails before implementation
- [ ] 3.4 Implement the stop helper, POSIX `sh`, running no program from the chart's image; verify 3.3 passes and that the script references no path that disappears with the root change
- [ ] 3.5 Implement copying both helpers onto the volume before the root change; verify a test asserts they are present and executable at their post-boot paths, and absent before the boot step runs

## 4. Rendering the running machine

- [ ] 4.1 Write the unittest suite asserting the guest container runs the boot script and no placeholder command, and that the placeholder assertions are gone; verify it fails before implementation
- [ ] 4.2 Replace the guest container's command with the boot script and pass its inputs through the environment; verify 4.1 passes and that no value is interpolated into script text
- [ ] 4.3 Write and satisfy the unittest suite for the stop hook: present on the guest container, invoking the helper by its post-boot path, with the grace period set; verify the rendered value matches the reference implementation's
- [ ] 4.4 Write and satisfy the unittest suite for the readiness probe: present, invoking the helper by its post-boot path, and no liveness probe rendered in either security mode; verify the assertion fails if a liveness probe is added
- [ ] 4.5 Write and satisfy the unittest suite asserting the headless Service publishes addresses before the machine is ready; verify the assertion fails if the field is removed
- [ ] 4.6 Write and satisfy the unittest suite asserting the security posture is unchanged by everything above — the guest container alone carries the mode's privilege, and the preparation steps still carry none; verify in both modes
- [ ] 4.7 Update `NOTES.txt` to say the machine boots, how to watch it and how to reach it, and remove the statement that it does not; verify a unittest asserts the warning is gone and the new statements are present

## 5. Documentation

- [ ] 5.1 Document in the chart README what a machine gets at boot — the fixed mount set, the three managed files and their opt-out markers, the shutdown signal and the grace period; verify by review against the messages the scripts emit
- [ ] 5.2 Document the prerequisites the chart cannot check for the user-namespace mode — the node's kernel, the runtime and idmap-capable storage — and that the privileged mode is the alternative; verify the text matches what the render-time check already says
- [ ] 5.3 Update `values.yaml` comments where booting changes what an input means; verify `make docs` passes and every key still carries an adjacent comment

## 6. Verification

- [ ] 6.1 Extend the integration job to assert a machine actually boots in `privileged` mode: its init is running as process 1 inside the machine, and a shell opened in it is the machine's own; verify the job fails if the root change is removed
- [ ] 6.2 Add the integration assertion that the machine's own output appears in the pod's logs; verify by matching output the operating system produces during boot
- [ ] 6.3 Add the integration assertion that the machine reports itself ready only after its operating system has finished starting; verify by observing the transition rather than the final state
- [ ] 6.4 Add the integration assertion that deleting the pod shuts the machine down rather than killing it, and that it completes well inside the grace period; verify by timing the deletion and by what the machine logged on the way out
- [ ] 6.5 Add the integration assertion that the three managed files hold the pod's values inside the machine, and that a claimed file is left untouched across a restart; verify both
- [ ] 6.6 Attempt the `userns` mode by hand on an environment that supports it and record the result in the README, including what to look for when it fails; verify the documented failure matches what the boot script actually prints
- [ ] 6.7 Cross-check every scenario in `specs/machine-boot/spec.md`, `specs/guest-managed-files/spec.md`, `specs/machine-lifecycle/spec.md` and the `machine-topology` delta against the test suites, and extend the coverage table in the chart README; verify every scenario has at least one corresponding test
