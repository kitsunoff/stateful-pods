## Context

See `proposal.md` — Why. The evidence this design rests on, checked against upstream sources rather
than recalled:

- Containerd's default profile (`contrib/seccomp/seccomp_default.go`) declares
  `DefaultAction: specs.ActErrno`. Its `CAP_SYS_ADMIN` block allows `mount`, `umount`, `umount2`,
  `unshare`, `setns`, `mount_setattr`, `move_mount`, `open_tree`, `fsopen`, `fsconfig`, `fsmount`
  and others. `pivot_root` does not appear anywhere in the file.
- LXC's own default profile (`config/templates/common.seccomp`) is five lines: a denylist rejecting
  `kexec_load`, `open_by_handle_at`, `init_module`, `finit_module` and `delete_module`, plus
  `reject_force_umount`. Everything else is allowed. This is what every Proxmox container runs
  under.
- LXC's `userns.conf` empties both the capability drop list and the device allowlist for
  unprivileged containers, on the stated grounds that a full capability set inside a user namespace
  is safe.
- Containerd's CRI passes `securityContext.GetPrivileged()` into `GenerateSeccompSpecOpts`, so
  whether a profile is applied at all depends on the privileged flag.
- The chart currently sets no seccomp field anywhere, so the effective filter is whatever the
  kubelet decides.

## Goals / Non-Goals

**Goals:**

- The filter every container runs under is visible in the machine's own manifest.
- The containers that can be confined for free are confined.
- An operator who can place a file on their nodes can confine the machine itself, and is told
  exactly how.

**Non-Goals:**

- Distributing a profile to nodes from inside the chart.
- Confining the guest by default. The default cannot name a file that may not exist.
- AppArmor.

## Decisions

### Three different answers for three different containers

| Container | Filter | Why |
| --- | --- | --- |
| `seed`, `prepare`, `customize` | `RuntimeDefault` | They unpack, write and fetch. Nothing they do is withheld by the default profile, and it needs no file on the node. |
| `guest`, by default | `Unconfined`, declared | The default profile withholds `pivot_root`. Declaring it explicitly is what stops a kubelet flag from changing the machine's posture. |
| `guest`, when asked | `Localhost` with the operator's path | The only form that can carry a filter permitting `pivot_root`. |

The init containers are the part worth doing regardless of anything else in this change: it is a
real narrowing, it applies to every install, and it costs an operator nothing.

### `RuntimeDefault` on the guest is rejected rather than rendered

It is the obvious thing to reach for, and on containerd it produces a machine that renders cleanly,
downloads and unpacks an operating system, and then fails at the root change with `pivot_root`
returning an error. Rejecting it at render time with the reason and the alternative costs one
validation branch.

The alternative considered was accepting it with a documented warning. Rejected because a warning in
`values.yaml` is read after the failure, not before, and because a machine that takes four minutes
to fail is exactly the failure mode this chart's validation was built to convert into a render
error.

CRI-O ships its own default profile, and whether it permits `pivot_root` has not been checked here.
That is why the rejection message names the `Localhost` form rather than claiming the value is wrong
in principle: a user on a runtime whose default profile does permit it can express exactly that
profile by path.

### The shipped profile is a denylist, because it confines an operating system

The profile applies to every process in the container, which after the root change means the
machine's init and everything it starts. An allowlist would have to enumerate what an entire
distribution's userland uses, and would break whenever a new systemd reached for a new system call.

So the shipped profile is LXC's list, expressed as Kubernetes seccomp JSON:
`defaultAction: SCMP_ACT_ALLOW`, with `kexec_load`, `open_by_handle_at`, `init_module`,
`finit_module` and `delete_module` returning `EPERM`, and `umount2` filtered on `MNT_FORCE` by
argument. Five system calls, and it is the profile every Proxmox container in the world already runs
under, which is the strongest evidence available that it does not break a booting distribution.

### What that profile is actually worth, per mode

Worth stating plainly, because the answer is not what it looks like:

| System call | Capability it needs | `userns` | `privileged` |
| --- | --- | --- | --- |
| `init_module`, `finit_module`, `delete_module` | `CAP_SYS_MODULE` | not granted | granted |
| `kexec_load` | `CAP_SYS_BOOT` | not granted | granted |
| `open_by_handle_at` | `CAP_DAC_READ_SEARCH` | not granted | granted |

In `userns` the capability set already denies all five, so the profile mostly restates a boundary
that exists. What it does add there is narrower and harder to name: the kernel is the only remaining
target, and `CAP_SYS_ADMIN` in a user namespace unlocks a large amount of mount-related kernel code.
The profile does not close that, and this design does not claim it does.

In `privileged` all three are open, and `open_by_handle_at` is a classic escape primitive — so that
is where the profile would matter most, and it is exactly where containerd appears not to apply one.
That contradiction is not resolvable inside this change; it is what the follow-up change about the
privileged mode exists for.

### Distribution is documented, not implemented

Three ways to get the file to `/var/lib/kubelet/seccomp/`, in the order they should be preferred:
the Security Profiles Operator, which exists for this; the node image or provisioning system, for
anyone who controls it; a DaemonSet mounting the kubelet directory, which works and is worth naming
honestly as a privileged workload added in the name of confinement.

The chart documents all three and implements none. A chart that shipped the DaemonSet would be
shipping the thing this change is trying to reduce.

## Risks / Trade-offs

- **A privileged container may ignore any profile** → Containerd's CRI passes the privileged flag
  into the decision, which strongly suggests the profile is skipped. Task group 1 settles it with an
  experiment before `values.yaml` documents anything, because documenting a protection that is not
  applied is worse than documenting its absence.
- **`RuntimeDefault` on the init containers might not be as free as it looks** → `setxattr`,
  `chown`, `mknod`-free extraction and an HTTPS fetch are all ordinary, but this is asserted by the
  integration test rather than assumed, on both source kinds.
- **A machine under the shipped profile might not shut down** → `reboot(2)` is gated on
  `CAP_SYS_BOOT` in the runtime default, and the machine's stop path sends systemd its poweroff
  signal and waits for PID 1 to exit. Under an allow-by-default profile `reboot` is permitted, so
  this should be unaffected — which is a prediction, and the integration test that already measures
  shutdown time is where it gets checked.
- **CRI-O's default profile is unexamined** → Handled by rejecting the runtime default with a
  message that offers the explicit form rather than asserting the value is always wrong.
- **The guest's default stays unconfined** → This change does not improve the machine's own
  confinement unless an operator acts. It makes the posture honest and confines the steps around the
  machine; the rest needs a file on a node, and no amount of chart design produces one.

## Migration Plan

1. Settle the privileged-container question by experiment.
2. Land the init container filter and the explicit guest declaration. These are safe on every
   cluster and fix the `--seccomp-default` failure.
3. Land the input, its validation and the shipped profile with its documentation.
4. Add a kind cluster with `--seccomp-default=true` to the integration suite, which is the only
   place the original defect can be reproduced.

Rollback is a chart revision. Nothing on any volume is affected, and a machine already running is
unaffected until its pod is replaced.

### Implementation order

Group 1 is an experiment whose result changes what `values.yaml` says, but blocks nothing else.
Groups 2 and 3 are sequential — the validation depends on the field existing. Group 4 needs both.

## Open Questions

- Whether CRI-O's default profile permits `pivot_root`. Deferrable: the rejection message is written
  so that it stays correct either way, and a user on CRI-O can express the runtime default by path.
- Whether the shipped profile should also deny the system calls that AppArmor covers in Proxmox,
  such as writes to `/proc/sys`. Deferrable and belongs with the AppArmor change: seccomp filters
  system calls, not paths, so most of that is not expressible here.
