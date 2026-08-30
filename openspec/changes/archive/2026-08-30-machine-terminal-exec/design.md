## Context

See proposal.md — Why. The state this design starts from, confirmed on a running machine rather
than reasoned about:

- `sp_mount_plan` mounts `devpts` at `$root/dev/pts` with `newinstance,ptmxmode=0666,mode=0620,gid=5`.
  `ptmxmode=0666` only means anything if something links to `pts/ptmx`, so the intent was already
  there; the link was not.
- A machine's `/dev` is a `tmpfs` mounted by the same plan, so it starts empty. `sp_bind_devices`
  then binds seven nodes from the pod and makes four symbolic links (`fd`, `stdin`, `stdout`,
  `stderr`).
- Inside a booted machine, `/dev` holds `console full null random tty urandom zero` plus `pts/` and
  `shm/`. `/dev/pts/ptmx` exists as `crw-rw-rw- 5, 2`. `/dev/ptmx` does not exist.
- `kubectl exec` without a terminal succeeds. With `--stdin --tty` it fails before the command
  starts, in the runtime rather than in the machine: `open /dev/ptmx: no such file or directory`.
  Creating the link by hand inside the running guest turns that into a working shell on
  `/dev/pts/0`.

## Goals / Non-Goals

**Goals:**

- A machine is enterable with a terminal, on both security modes, without the guest's init having
  to do anything.
- A test that fails against the unfixed script. The bug reached a release because every existing
  assertion exec'd without a terminal; a fix whose test cannot fail would leave that hole open.

**Non-Goals:**

- Anything about `/dev/console`, which is bound from the pod when the runtime provided one and is a
  separate concern from an exec'd shell's terminal.
- Widening the mount plan. See proposal.md — What Changes for why `/dev/mqueue` is left alone.

## Decisions

### A symbolic link to `pts/ptmx`, not a device node and not a bind mount

`newinstance` gives the machine a private `devpts` instance. Its multiplexer is `/dev/pts/ptmx`, and
opening a `(5, 2)` node created anywhere else allocates from whichever instance that node's
filesystem is associated with — for a node made in the machine's own `/dev` tmpfs, the node's
initial instance, which is the host's. The terminal handed back would then not be in
`/dev/pts` as the machine sees it. So the path has to *resolve* to the instance's own multiplexer.

Three ways to do that:

- **A symbolic link `ptmx -> pts/ptmx`.** What LXC's `autodev` hook and runc both do. One line, no
  privileges, no failure mode: the target is inside the mount that has already been made by the time
  the link is created, and a dangling link would only be possible if the `devpts` mount had failed,
  which is fatal earlier.
- **A bind mount of `/dev/pts/ptmx` onto `/dev/ptmx`.** Equivalent in effect, but it is a mount, so
  it needs a mount point created first, it can fail, and it adds a line to `/proc/mounts` that the
  machine carries for its whole life. It buys nothing over the link.
- **`mknod` in the machine's `/dev`.** Wrong for the reason above, and separately impossible:
  `mknod(2)` checks `CAP_MKNOD` in the *initial* user namespace, which is exactly why every other
  node here is bound from the pod rather than created.

Relative (`pts/ptmx`) rather than absolute (`/dev/pts/ptmx`), so that the link is correct both
before the root change — when the machine's root is still at `$root` — and after it.

### The link is made in `sp_bind_devices`, not in the mount plan

`sp_mount_plan` returns lines of `<type> <source> <target> <options>` and `sp_apply_mounts` mounts
each one. A link is not a mount and does not fit that shape. `sp_bind_devices` is where the four
existing links are made, it runs after `sp_apply_mounts`, and "after the mounts" is a real ordering
requirement here: the link's target only exists once `devpts` is mounted.

### The integration assertion allocates a real pseudo-terminal

The point of this change is a test that could have caught it, so the test has to ask for the thing
that was broken. `kubectl exec --stdin --tty` from a non-interactive shell does not ask for it —
kubectl sees that its own stdin is not a terminal and downgrades, and the assertion would pass
against the unfixed script. The terminal has to be real.

`script` is the portable way to get one, and its two implementations disagree:

- BSD, which macOS ships: `script -q /dev/null <command> <args...>`. The command is trailing
  arguments; it exits with the child's status; it does not accept `-c`.
- util-linux, which every Linux CI runner ships: `script --quiet --return --command '<command>'
  /dev/null`. The command goes through `--command` as one string, and without `--return` the exit
  status is `script`'s own and a failing assertion passes.

Both are confirmed by hand on this host. The suite detects which one it has from `script --version`
and passes a single shell command string either way, so the two branches take the same argument.

Alternatives rejected: `expect`, which is another dependency and is not installed on the CI runner;
`ssh -tt`, which needs a server in the guest; a Go or Python helper opening a pty, which is a new
build artefact for one assertion.

### The unit suite asserts the link too

`test/shell/boot-mounts.bats` cannot mount anything, but `sp_bind_devices` makes its links with
plain `ln`, which needs no privileges. Asserting there that the link is made and where it points
gives the fix a check that runs in `make all` — on every push, in seconds, without a cluster — and
leaves the integration suite to prove the thing only a real cluster can: that a terminal actually
opens.

## Risks / Trade-offs

- **The integration assertion is the only one that can really fail, and it needs a cluster.** →
  The bats assertion runs everywhere and catches the link being deleted or repointed, which is the
  regression that is actually likely. The integration one catches the rest.
- **`script`'s two implementations could grow a third.** → The detection tests for util-linux
  explicitly and falls back to the BSD form, so an unknown implementation takes the BSD branch and
  fails loudly at the assertion rather than passing quietly.
- **The fix is inert until the shim image is published and `values.yaml`'s pinned digest is moved to
  it.** → Accepted, and stated in the proposal. It is how every script fix in this repository
  reaches a user, and this change deliberately does not bump the digest or cut a tag.
- **`sp_bind_devices` makes its existing links with `|| true`, so a failure there is silent.** →
  The new link is made the same way for consistency, and is covered by an assertion on the result
  rather than on the command's status, which is the stronger check anyway.

## Migration Plan

None. No values change, no volume is touched, and a machine picks the link up on its next start
once it runs a shim image built from this commit. Rolling back is deleting the line.
