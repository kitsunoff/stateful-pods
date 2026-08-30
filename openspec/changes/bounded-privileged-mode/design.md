## Context

See `proposal.md` — Why. What is established, from upstream sources rather than recollection:

- LXC's `common.conf` drops `mac_admin mac_override sys_time sys_module sys_rawio` and nothing else,
  and denies all devices before allowing back about twelve — `null`, `zero`, `full`, `tty`,
  `console`, `ptmx`, `random`, `urandom`, `pts/*` and `fuse`. That is the posture of a Proxmox
  *privileged* container.
- LXC's `userns.conf` empties the drop list and the device lists entirely for unprivileged
  containers, because inside a user namespace a full capability set is void on the host.
- Containerd's CRI passes `securityContext.GetPrivileged()` into `GenerateSeccompSpecOpts`, so
  whether any seccomp profile is applied depends on that flag.
- The chart's guest container today gets `privileged: true` in this mode, and
  `capabilities.add: [SYS_ADMIN]` in the other. `allowPrivilegeEscalation` is deliberately left
  unset in the `userns` mode, because setting it false is incompatible with an added `SYS_ADMIN`.
- What the shim itself does: `mount` of proc, sysfs, tmpfs, devpts and cgroup2; `mount --bind` of
  device nodes the runtime already placed in the pod; `mount --make-rprivate`; `pivot_root`; `umount
  -l`. It creates no device node, because `mknod(2)` checks in the initial user namespace.

## Goals / Non-Goals

**Goals:**

- The privilege this mode grants is enumerated in the manifest, so a reviewer can read it.
- The mode becomes something the runtime will apply a syscall filter and an access-control profile
  to.
- The posture matches the reference implementation's privileged container rather than exceeding it.

**Non-Goals:**

- Touching `userns`.
- Shipping an AppArmor profile. This change makes one applicable; it does not write one.
- Guaranteeing that every workload that ran under `privileged: true` still runs. Some will not, and
  the point is to find out which and say so.

## Decisions

### The set is the default container set, plus what the shim needs, minus what Proxmox refuses

Three parts, each with a separate justification:

1. **What a container gets by default.** Unchanged. `chown`, `dac_override`, `fowner`, `fsetid`,
   `kill`, `setgid`, `setuid`, `setpcap`, `net_bind_service`, `net_raw`, `sys_chroot`, `mknod`,
   `audit_write`, `setfcap`. An operating system's services need these — `net_bind_service` for
   anything on a low port, `setuid`/`setgid` for every daemon that drops privilege.
2. **What the shim needs on top.** `SYS_ADMIN`, for `mount(2)` and `pivot_root(2)`. This is the same
   capability the `userns` mode grants, and it is the reason both modes exist.
3. **What Proxmox refuses.** `mac_admin`, `mac_override`, `sys_time`, `sys_module`, `sys_rawio`.
   None is in the default set, so this is a statement about what is not added rather than a removal
   — but it is stated in the spec because the temptation, when a machine misbehaves, is to add one.

The candidates that are neither in the default set nor obviously needed — `sys_ptrace`,
`sys_resource`, `sys_nice`, `dac_read_search`, `sys_boot`, `net_admin`, `ipc_lock` — are left out
until a machine is shown to need one. `dac_read_search` and `sys_boot` are left out deliberately and
permanently: they are what `open_by_handle_at` and `kexec_load` need, and those are the two escape
primitives LXC's seccomp profile exists to close.

### The set, as the experiment settled it

The method above was run before anything was written. Nothing had to be added: the set is the default
container set plus `SYS_ADMIN` and nothing else, in every case tried.

```text
AUDIT_WRITE  CHOWN  DAC_OVERRIDE  FOWNER  FSETID  KILL  MKNOD  NET_BIND_SERVICE
NET_RAW      SETFCAP  SETGID  SETPCAP  SETUID  SYS_ADMIN  SYS_CHROOT
```

Fifteen capabilities, rendered as `drop: [ALL]` and an explicit `add` list rather than an `add` of
`SYS_ADMIN` alone. The two produce the same set under today's runtimes, but only the first says so in
the manifest, and only the first keeps saying so if a runtime's idea of a default changes.

What was run, on Kubernetes 1.35 with containerd 2.2, each machine seeded from scratch and booted:

| Case | Source kind | Init | Result |
| --- | --- | --- | --- |
| Debian 13, slim image with systemd | `oci` | systemd | reached `graphical.target`, no failed units |
| Alpine 3.22 | `oci` | busybox init | booted, process 1 is the machine's own |
| Debian 12, a full distribution image | `lxc` | systemd | reached `graphical.target`, no failed units |

The whole integration suite was run against the first two: seeding, the file capability, the root
change, the managed files, the readiness transition, the shutdown inside the grace period and the
restart that does not re-seed all held unchanged. The machine's bounding set inside all three is
`0x00000000a82425fb`, which is exactly the fifteen above and nothing else.

The capabilities left out stay out until a machine is shown to need one, and `dac_read_search` and
`sys_boot` stay out permanently. Every addition later should name the machine and the failure that
required it.

### What is lost, and what to say about each

`privileged: true` grants more than capabilities. Losing each of these is the point, and each needs
an answer in `values.yaml` rather than silence:

| Lost | Consequence | What to say |
| --- | --- | --- |
| The node's devices | A machine can no longer reach a device the pod was not given, even by creating the node for it itself | Proxmox's privileged container is allowed the same short list. A machine needing more is a case for a device plugin, not for suspending policy. |
| Kernel module loading | `CAP_SYS_MODULE` is gone, so nothing inside a machine can load or unload one | Modules are the node's business. Load them on the node. |
| Raw I/O | `CAP_SYS_RAWIO` is gone | The machine's disk is its volume. |
| The host's clock | `CAP_SYS_TIME` is gone, so a machine cannot set the node's time | A node's clock is the node's. A machine reads it. |
| Everything else outside the default set | Notably `net_admin`, `sys_ptrace`, `sys_nice`, `sys_resource`, `ipc_lock`, `syslog` and `bpf` | Not refused on principle, merely not yet needed. `net_admin` is the one to watch: a machine running its own firewall or tunnel wants it, and a pod's addressing already belongs to the cluster's CNI. |

Two entries an earlier draft of this table carried have been removed, because the experiment showed
they are not losses at all:

- **The masked and read-only `/proc` paths are not a loss.** The runtime applies them to the
  container it builds; the shim then mounts a *fresh* procfs inside the new root, and a fresh procfs
  carries none of them. Measured: `/proc/sys/kernel/shmmax` is writable inside a machine in this
  mode, while an ordinary container's `/proc/sys` is a separate read-only mount. The machine's
  `/proc` is the same in both modes, and always was.
- **What `/dev` *contains* does not change either.** The machine's `/dev` is a fresh tmpfs holding
  the seven nodes the shim binds, in both modes. What changes is whether the machine can reach one of
  the node's devices by creating its own node for it: privileged could — `mknod` a block device and
  open it — and this mode gets `EPERM` from the device cgroup instead. That is the entry above.

  The errno matters, and the integration assertion turns on it. A `nodev` mount refuses the same open
  with `EACCES`, and the machine's `/tmp` and `/run` are both `nodev` — so a probe made there would
  be refused whatever the device cgroup allowed, and would have been refused under the old posture
  too. The probe is made in `/dev`, which is not `nodev`, and only `EPERM` is accepted as the answer.

### The runtime's default AppArmor profile denies `mount`

Not foreseen when this was written, and load-bearing. A container that is no longer marked privileged
is one containerd will confine with its own default AppArmor profile, `cri-containerd.apparmor.d`, on
any node where AppArmor is supported. That profile is embedded in the containerd binary this
repository's own test node image ships, and it contains:

```text
  umount,
  ...
  deny mount,
```

The guest exists to mount. Under that profile it cannot, and the mode would break on exactly the
nodes it is for — an ordinary Ubuntu or Debian node with `apparmor_parser` installed.

So the guest container declares the access-control profile it runs under, `Unconfined`, for the same
reason it already declares its syscall filter: leaving the field out hands the machine's posture to
the node. It is not a profile this change ships, and the non-goal above still holds — a real profile
for a machine is a later change, and this field is where it will be named.

It is declared for the guest in both modes rather than only in this one. The field describes the
guest container, not the mode; `userns` already runs an unprivileged guest that mounts, so leaving it
out there would make the same latent break the mode's to discover.

This could not be reproduced here. Neither this host's kernel nor the `kind` node image has AppArmor
— the node image ships no `apparmor_parser`, so containerd reports AppArmor unsupported and applies
nothing — which is also why no machine has hit it yet. The evidence is the profile text read out of
the containerd binary under test, not a run.

### The mode keeps its name

Renaming it would be a breaking values change on top of a breaking behaviour change, and the name
stays accurate: this mode's capabilities are real on the node, unlike the other mode's. Proxmox uses
the same word for a container that also has capabilities dropped. Changing the meaning of a mode
while keeping its name is a real cost, and it is paid once, in a release note that says what a
machine loses.

### The seccomp premise has to hold, or half of this is gone

One of the two reasons for this change is that a non-privileged container is one a filter can be
applied to. That rests on containerd skipping seccomp for privileged containers, which the
`seccomp-posture` change settles by experiment. If it turns out a privileged container does honour a
profile, this change still stands on the capability argument alone — an enumerated set is reviewable
and `privileged: true` is not — but it should be re-argued at that reduced value before anyone
implements it.

## Risks / Trade-offs

- **A machine may not boot under a named set** → This is the whole empirical question, and it comes
  first: boot every preset and both source kinds, with a systemd guest and a non-systemd guest,
  before any of the chart changes are considered done.
- **A machine may boot and then fail later, inside a service** → Booting is not the same as running.
  The integration assertions cover the boot and the shutdown path; a service failing three days
  later is not something CI will find, which is why the release note names what was removed instead
  of claiming equivalence.
- **Breaking existing machines** → Unavoidable and intended. The volume is untouched, so a machine
  that breaks is recovered by a values change and a pod replacement, not by a rebuild.
- **The temptation to widen the set** → Every capability added later should carry a note saying
  which machine needed it and why. Without that, the set drifts back toward the blanket flag one
  well-intentioned commit at a time.
- **`allowPrivilegeEscalation`** → It is left unset in both modes, and the reason given here while
  this was being written was wrong. `false` is *not* incompatible with an added `SYS_ADMIN`: the API
  accepts the pair and the container keeps the capability, which was checked on a cluster. What
  `false` does is set `no_new_privs`, and `no_new_privs` makes the kernel ignore setuid bits and file
  capabilities on every following `execve`. A machine is a whole operating system built on both —
  its `su`, its `sudo`, its `ping`, and the file capability the seeding step preserves on purpose.
  The cost is not to the container's privilege but to the machine's own userland. The render tests
  pin that it is not set to `false`.

## Migration Plan

1. `seccomp-posture` lands first, including its experiment.
2. Determine the capability set empirically on a cluster: start from the default set plus
   `SYS_ADMIN`, boot each preset, and record what, if anything, has to be added.
3. Change the render and its tests.
4. Write the release note naming what a machine in this mode loses, item by item.

Rollback is a chart revision: the previous revision renders `privileged: true` again and the pod is
replaced. No volume is affected in either direction.

### Implementation order

Group 1 is the experiment and everything depends on its result — do not write the template change
before the set is known. Groups 2 and 3 follow it in order. Group 4 is documentation and can be
written alongside group 3.

## Open Questions

- ~~Whether any of the four presets needs a capability beyond the default set plus `SYS_ADMIN`.~~
  Answered by the experiment: none did. See *The set, as the experiment settled it*.
- Whether a machine that genuinely needs host devices should get a third mode. Deferrable: it should
  be added only if a real case appears, and adding a mode later renames nothing.
