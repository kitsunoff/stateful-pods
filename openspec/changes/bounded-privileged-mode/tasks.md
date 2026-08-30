## 1. Find the capability set by experiment, not by argument

- [x] 1.1 Confirm the premise this change rests on is still what `seccomp-posture` found — that a
  container marked privileged does not get the syscall filter its values name; verify by reading
  that change's recorded result, and re-argue this change before continuing if it came out the other
  way
- [x] 1.2 On a throwaway cluster, run a machine whose guest container has the default container
  capability set plus `SYS_ADMIN` instead of `privileged: true`, and see whether it mounts, changes
  root and boots; verify with a systemd guest and record the outcome
- [x] 1.3 Repeat for a non-systemd guest and for both source kinds, since the mount work is
  identical but what an init system reaches for is not; verify each boots or record exactly what
  failed and which capability the failure named
- [x] 1.4 Add only the capabilities that something demonstrably needed, each with a comment naming
  the machine and the failure that required it, and confirm `dac_read_search` and `sys_boot` are not
  among them; verify the final set boots every case from 1.2 and 1.3
- [x] 1.5 Write the resulting set into `design.md` under Decisions, replacing the method with the
  answer; verify the document names the set and what needed each addition

## 2. Change what the mode renders

- [x] 2.1 Rewrite the suites that pin the current posture — `values_security_mode_test.yaml`,
  `security_posture_test.yaml`, `init_security_test.yaml`, `security_negative_test.yaml` — to assert
  the named set, that no container is marked privileged, and that the excluded capabilities are
  absent; verify `make test` fails on the current chart for exactly those reasons
- [x] 2.2 Change the guest container's security context in `statefulset.yaml` to the named set, and
  update the comment that currently explains why the mode is privileged; verify `make test` passes
  the suites from 2.1
- [x] 2.3 Assert `allowPrivilegeEscalation` is not set to `false` in this mode, since that is
  incompatible with an added `SYS_ADMIN`; verify with a render test in both modes
- [x] 2.4 Assert the preparation steps are unchanged — still no capability, still
  `allowPrivilegeEscalation: false`; verify `make test` covers both modes

## 3. Prove a machine still works

- [ ] 3.1 Run the full integration suite in this mode, which is what it already uses; verify seeding,
  booting, the readiness transition and the shutdown-within-grace-period assertion all still hold
- [ ] 3.2 Assert that a machine in this mode now honours a named syscall filter, which is the second
  reason for the change; verify one of the denied system calls fails from inside a running machine
- [ ] 3.3 Assert the machine no longer has what the mode gave up — that loading a kernel module
  fails and that the node's block devices are not present in the machine; verify from inside a
  running machine

## 4. Say what changed

- [ ] 4.1 Rewrite the `privileged` entry in the mode ladder in `_helpers.tpl`, which is both the
  error message and the documentation of the modes, to describe a named capability set rather than a
  privileged container; verify the rejection message for a missing mode reads correctly
- [ ] 4.2 Document in `values.yaml` what the mode no longer grants — host devices, unmasked `/proc`
  paths, module loading, raw I/O — with what to do instead for each, and keep a comment above every
  key; verify `make docs` passes
- [ ] 4.3 Write the release note as a breaking change: what is removed, what a machine that depended
  on it should do, and that the volume is untouched so recovery is a values change; verify it names
  every item from the table in `design.md`
