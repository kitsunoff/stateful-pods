## Why

A machine cannot be entered with a terminal. `kubectl exec --stdin --tty` into a running machine
fails before the command starts:

```text
OCI runtime exec failed: exec failed: unable to start container process:
open /dev/ptmx: no such file or directory
```

That is `kubectl machine shell` — the plugin's headline feature, and the thing the project promises
when it argues that a real root change is what makes a machine debuggable at all. It has never
worked. Every suite and every manual check exec'd without a terminal, so nothing noticed.

The cause is a single missing symbolic link. The boot script mounts the pseudo-terminal filesystem
with `newinstance`, which gives the machine a private set of terminals with its own multiplexer at
`/dev/pts/ptmx`. With `newinstance`, `/dev/ptmx` must be a link to that multiplexer: the node's own
`/dev/ptmx` belongs to a different instance and would hand out terminals the machine cannot see. The
machine's `/dev` is a fresh tmpfs, so nothing is there unless the boot script puts it there — and it
does not.

## What Changes

- **The boot script links `/dev/ptmx` to `pts/ptmx`** where it prepares the machine's devices,
  alongside the links it already makes for `/dev/fd` and the standard streams. A link rather than a
  device node, because `newinstance` is what makes a node wrong, and because creating one is
  impossible for a pod running in its own user namespace — the same reason every other node is bound
  rather than created.
- **The integration suite enters a machine with a real terminal.** The existing assertions all exec
  without one, which is exactly why this survived to a release. The new one allocates a
  pseudo-terminal and asserts that the shell it gets is on one.

Non-goals:

- Mounting the POSIX message queue filesystem at `/dev/mqueue`, which is the only other difference
  between a machine's `/dev` and what a container runtime provides by default. It is a mount rather
  than a node or a link, an init system that wants it mounts it itself, and whether it can be
  mounted at all in the `userns` mode depends on which user namespace owns the pod's IPC namespace —
  a question this change cannot answer on the clusters it can build. Left alone deliberately rather
  than by omission.
- Any change to the mount plan, to the set of device nodes bound from the pod, or to how the root
  change is performed.

## Capabilities

### New Capabilities

None. This change fixes an existing capability rather than adding an area of behaviour.

### Modified Capabilities

- `machine-boot`: the requirement that a machine's init finds the filesystems it expects gains the
  part it was missing — a machine must be enterable with a terminal, which means the pseudo-terminal
  multiplexer has to be reachable at the path every program looks for it at, and not only at the
  path the private instance puts it at.

## Impact

- **Scripts**: `images/shim/scripts/lib-boot.sh` — one link in `sp_bind_devices`.
- **Tests**: `test/shell/boot-mounts.bats` asserts the link is made and where it points;
  `hack/integration-test.sh` gains an assertion that execs into a running machine on a
  pseudo-terminal. Getting a terminal from a non-interactive shell means `script`, whose two
  implementations disagree on their flags — the BSD one macOS ships takes the command as trailing
  arguments, util-linux takes it through `--command` and needs `--return` to pass the exit status
  on — so the suite has to handle both to run on a developer's machine and in CI.
- **Release**: the fix is inside the shim image, so it reaches a user only when that image is
  published and the digest `values.yaml` pins is moved to it. Until then a machine still cannot be
  entered with a terminal.
