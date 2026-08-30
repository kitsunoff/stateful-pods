## 1. Reproduce the failure before fixing it

- [x] 1.1 On a cluster running a machine from the published shim, list the machine's `/dev` and
  confirm `/dev/ptmx` is absent while `/dev/pts/ptmx` exists; verify that `kubectl exec` without a
  terminal succeeds and that the same exec with `--stdin --tty`, given a real pseudo-terminal, fails
  with `open /dev/ptmx: no such file or directory`
- [x] 1.2 Create the link by hand inside that running machine and confirm the same terminal exec
  then succeeds and reports a `/dev/pts/*` terminal; verify the diagnosis is the whole cause and not
  one of several
- [x] 1.3 Compare the machine's `/dev` against what a container runtime provides by default and
  record every difference; verify by listing both, and decide each difference in `proposal.md`
  rather than leaving it unmentioned

## 2. The unit assertion, before the fix

- [x] 2.1 Add a case to `test/shell/boot-mounts.bats` asserting that `sp_bind_devices` leaves
  `dev/ptmx` a symbolic link pointing at the multiplexer of the machine's own pseudo-terminal
  instance; verify it fails against the unmodified `lib-boot.sh`, for the right reason
- [x] 2.2 Add the two cases that guard the fix rather than detect the bug, and which therefore pass
  already: that the pseudo-terminal filesystem is mounted with a private instance and a
  world-readable-and-writable multiplexer, which is what makes the link both necessary and usable
  unprivileged, and that the multiplexer is left neither a device node nor bound from the pod —
  the two wrong ways to satisfy 2.1. Verify both pass before the fix and after it

## 3. The fix

- [ ] 3.1 In `sp_bind_devices` in `images/shim/scripts/lib-boot.sh`, link `dev/ptmx` to `pts/ptmx`
  with a comment stating that the private instance is what forces a link rather than a device node,
  and that a node cannot be created by a pod in its own user namespace anyway; verify `make
  shell-test` now passes the cases from 2.1
- [ ] 3.2 Run `make shell-lint`; verify shellcheck reports nothing

## 4. The integration assertion, which is the one that could have caught this

- [ ] 4.1 Add a helper to `hack/integration-test.sh` that runs a shell command on a real
  pseudo-terminal, handling both `script` implementations — util-linux through `--command` with
  `--return`, the BSD one macOS ships as trailing arguments — with a comment naming the difference;
  verify the helper reports a non-zero status for a command that fails, on this host
- [ ] 4.2 Add an assertion that execs into the booted machine with `--stdin --tty` through that
  helper and requires the shell to report a pseudo-terminal belonging to the machine; verify it
  fails against a machine booted from the unfixed script and passes against one booted from the
  fixed script

## 5. Prove the whole thing on a cluster

- [ ] 5.1 Build the shim from this branch, boot a machine on it, and confirm a terminal exec
  succeeds; verify by opening a shell with a terminal and reading back the terminal's name
- [ ] 5.2 Run `make all`, then `make integration-test`; verify both are green at the final commit
  and state in the report which targets ran and which could not
