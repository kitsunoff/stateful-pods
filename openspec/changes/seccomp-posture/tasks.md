## 1. Settle what a privileged container actually gets

- [ ] 1.1 On a throwaway cluster, run a pod with `privileged: true` and an explicit
  `seccompProfile` naming a profile that denies an obvious system call, and check whether that call
  is denied; verify by observing the call succeed or fail, and record the result in `design.md`
- [ ] 1.2 Write what was observed into the `values.yaml` comment for the `privileged` mode — either
  that a filter applies to it or that it does not — because documenting a protection that is not
  applied is worse than documenting its absence; verify `make docs` passes

## 2. The part that is free

- [ ] 2.1 Write the helm-unittest suite first: every container that runs before the guest declares
  the runtime's default filter, in both modes, and the guest declares `Unconfined`; verify
  `make test` fails on the current chart for exactly that
- [ ] 2.2 Add the filter to `stateful-pods.machine.initSecurityContext` and the explicit
  `Unconfined` to the guest container, with a comment stating that the explicit declaration exists
  so a kubelet flag cannot change the machine's posture; verify `make test` passes the suite from
  2.1
- [ ] 2.3 Confirm the preparation steps still work under the default filter for both source kinds —
  unpacking with extended attributes, and an HTTPS fetch; verify with `make integration-test`

## 3. The part an operator can opt into

- [ ] 3.1 Write the validation suite first: an unknown filter form is rejected listing the accepted
  ones, the form needing a path is rejected without one, a path supplied to a form that takes none
  is rejected, and the runtime default on the guest is rejected naming `pivot_root` and the
  `Localhost` form; verify `make test` fails on the current chart for each case
- [ ] 3.2 Add `machines.<name>.security.seccompProfile` to the guest container and validate it in
  `stateful-pods.validate.semantics`; verify `make test` passes the suite from 3.1
- [ ] 3.3 Assert that a named filter reaches the guest container and no other; verify with a render
  test over every container in the pod
- [ ] 3.4 Add the profile JSON to the repository — `defaultAction: SCMP_ACT_ALLOW` with
  `kexec_load`, `open_by_handle_at`, `init_module`, `finit_module` and `delete_module` returning
  `EPERM`, and `umount2` filtered on `MNT_FORCE` — with a comment naming it as LXC's own list and
  why it is a denylist; verify it parses as a valid seccomp profile
- [ ] 3.5 Document the three ways to place that file on nodes, in preference order, naming the
  DaemonSet form as a privileged workload; verify the documented path works end to end for at least
  one of them
- [ ] 3.6 Document the new input in `values.yaml` with a comment above every key; verify `make docs`
  passes

## 4. Prove the original defect is gone

- [ ] 4.1 Add a kind cluster configured with `--seccomp-default=true` to the integration suite;
  verify a machine on the current chart fails at the root change there, which is the defect
- [ ] 4.2 Assert that the same machine boots on that cluster with this change applied; verify with
  `make integration-test`
- [ ] 4.3 Boot a machine under the shipped profile and assert it both starts and shuts down inside
  the grace period, since the stop path depends on systemd's poweroff signal and on `reboot(2)`;
  verify with `make integration-test`
- [ ] 4.4 Assert the five denied system calls are actually denied under that profile, from inside a
  running machine; verify each returns an error rather than succeeding
