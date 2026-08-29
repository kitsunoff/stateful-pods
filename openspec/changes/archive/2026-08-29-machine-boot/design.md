## Context

See `proposal.md` — Why. The decisions this change implements were settled in `docs/research/`:
`03-mapping-and-architecture.md` §3.1 for the mount sequence and the device-node binds, and §4.2–§4.4
for logging, exec and shutdown; `02-kubernetes-primitives.md` §4.2 for the root change, §7 for the
shutdown signals and §8 for the files that vanish with it; `05-open-questions.md` §4 for why there is
no init-system input, §8 and §9 for logging and health checking; `06-guest-provisioning.md` §6 for
telling the guest where it is running.

What the chart already fixes and this change must not move: the volume is mounted at `/mnt/rootfs`,
the chart's own state on the volume lives under `.stateful-pods/`, every object for a machine is
named `<release>-<machine>`, the scripts arrive as a mounted ConfigMap and read their inputs from the
environment, and the guest container runs `shim.image`.

Three constraints shape everything below.

**A root change is not a mount.** The kernel filesystems have to go into the new root *before* the
root changes, which is an ordering no pod spec can express. It is therefore the container's own
entrypoint that does the work `lxc-start` does.

**After the root change, the pod's own filesystem is gone.** The ConfigMap with the chart's scripts,
and the three files the kubelet wrote for the pod, are mounts into the container image's rootfs, not
into the volume. Anything that has to run *after* the boot — a probe, a stop hook — cannot be at
`/scripts`, because `/scripts` no longer exists.

**The pod's declared privilege is all there is.** `hostUsers: false` with `SYS_ADMIN`, or
`privileged`. Nothing in this change may need more, or the security modes would be a fiction.

## Goals / Non-Goals

**Goals:**

- Boot every machine with one fixed mount set, so that "which init does this guest run" is never an
  input and never a branch in the pod spec.
- Make every failure name the step and the path, because a boot failure is otherwise diagnosed by
  reading a kernel oops.
- Keep everything that must outlive the root change on the volume, which is the only thing that does.
- Keep the shell testable without a cluster, the way the seeding scripts are.

**Non-Goals:**

- Any per-distribution customization beyond the three managed files. See `proposal.md`.
- Making `userns` work where the node cannot support it. The chart cannot see a node's kernel and
  will not pretend to.

## Decisions

### `pivot_root`, and a failure rather than a fallback

The root change is `pivot_root`. `chroot` is not offered as a fallback, and a cluster where
`pivot_root` fails gets a boot failure that says so.

`03-mapping-and-architecture.md` §4.3 treats this as a requirement rather than a preference, and the
reason is `kubectl exec`. With `pivot_root` the container's mount namespace root *is* the machine, so
a shell, an exec probe and `/proc/1/root` all land inside it. With `chroot` they land in the chart's
image, and every probe definition and every debugging session has to be wrapped in something that
follows the machine's init into its root — a leak into every later change and into the user's own
commands.

A silent fallback would be worse than either: the machine would boot, and the difference would only
surface the first time someone tried to get a shell.

### The mount set, written once and never branched

Proxmox's own sequence, adapted (`03-mapping-and-architecture.md` §3.1):

```text
proc      -> /mnt/rootfs/proc
sysfs     -> /mnt/rootfs/sys
tmpfs     -> /mnt/rootfs/dev
  bind each device node the runtime already put in the pod's own /dev
devpts    -> /mnt/rootfs/dev/pts
tmpfs     -> /mnt/rootfs/dev/shm
tmpfs     -> /mnt/rootfs/run
tmpfs     -> /mnt/rootfs/tmp
cgroup2   -> /mnt/rootfs/sys/fs/cgroup
```

The cgroup2 mount is unconditional. A systemd guest needs a hierarchy it can own; Kubernetes mounts
`/sys/fs/cgroup` read-only, so the guest cannot use the pod's. Mounting a fresh one in the new root is
permitted inside a user namespace because the filesystem carries `FS_USERNS_MOUNT`, and a guest
running a lighter init simply ignores it. That is what removes the `guest.init` input the earlier
drafts wanted (`05-open-questions.md` §4).

**Device nodes are bound, never created.** `mknod(2)` checks the capability in the *initial* user
namespace, so a `hostUsers: false` pod cannot create `/dev/null` no matter what it is granted. The
workaround is Proxmox's: create an empty regular file as a mount point and bind the real device over
it. The nodes come from the pod's own `/dev`, which the runtime has already populated, so no host
access is involved — and the code path is then identical in both security modes, which is one fewer
thing that can differ between them.

*Alternative considered:* mounting only what the detected init needs. Rejected — it makes the mount
set depend on the guest, which is the coupling `05-open-questions.md` §4 exists to remove, and the
saving is one tmpfs.

### What must survive the root change goes on the volume

Before pivoting, the boot script copies the helpers that have to run *later* — the readiness check
and the stop hook — into `.stateful-pods/bin/` on the volume.

They cannot stay in the ConfigMap. `readinessProbe.exec` and `lifecycle.preStop.exec` run in the
container's mount namespace, which after the pivot is the machine's root; `/scripts` is on the other
side of the change and is gone. The volume is the one thing present in both roots, at `/mnt/rootfs`
before and `/` after, so a helper copied there is reachable at a fixed absolute path once the machine
is up.

A useful property falls out: before the pivot completes the path does not exist, so the readiness
probe fails, which is the correct answer while a machine is still booting.

*Alternative considered:* writing the probe and the hook as `sh -c` one-liners in the pod spec, using
only guest binaries. Rejected because they must branch on which init the guest runs, and a branch
that lives in a YAML string cannot be tested by anything.

### The guest is told it is a container through the environment

`container=lxc` is exported into the environment of the exec'd init.

systemd's `detect_container()` checks its own environment first when it is PID 1, and only then looks
for `/run/.containerenv` and `/.dockerenv` — conventions written by Podman and Docker, and by neither
containerd nor Kubernetes. Without the variable, systemd concludes it is on bare metal: it takes over
the cgroup hierarchy, loads modules and runs `fsck`. `lxc` is the honest value for this architecture
and is what cloud-init's own container detection recognises, which matters for the change after this
one.

### The three managed files, and the marker that opts out

`/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` are copied from the pod's own into the volume on
every boot, before the pivot, unless the machine has claimed one.

They are copied rather than bound because a bind would be undone by the root change. They are
rewritten on every boot rather than seeded once because the pod's values legitimately change — a
machine rescheduled onto another node gets a different `/etc/hosts`.

The opt-out is Proxmox's, in form and in spelling: a marker file inside the guest named after the
file it protects. It lives on the volume, so it travels with the machine rather than with the release,
and it is per file, so a machine that manages its own resolver does not also have to manage its own
host name.

*Alternative considered:* chart inputs for hostname and DNS. Rejected — `values.yaml` already
documents that per-guest network and DNS configuration are the cluster's business, and adding them
here would contradict it. The marker gives a machine the escape hatch without giving the release one.

### Shutdown branches at runtime, on the guest's own marker

The stop hook checks for the directory systemd itself uses to answer "am I booted", and sends
`SIGRTMIN+3` if it is there and `SIGTERM` otherwise, then waits for the machine's init to exit.

`SIGTERM` to systemd means *re-execute yourself*, not shut down, so the default Kubernetes behaviour
would leave every machine to be killed when the grace period expired — an unclean shutdown of a pet on
every ordinary delete. Sending `SIGRTMIN+3` unconditionally would be equally wrong: systemd's own
container interface notes that only systemd reads it that way.

This is the second thing that removes the need for an init-system input, and it is why the hook is a
script rather than the declarative stop-signal field: the field would have to be filled in from a
value the user should not have to supply. When `ContainerStopSignals` graduates it replaces the hook
exactly, one-to-one.

`terminationGracePeriodSeconds` becomes 120, copying Proxmox's own `TimeoutStopSec`. It is fixed
rather than an input in this change: the right value is a property of what a machine has to stop, not
of the release, and 120 is what the reference implementation chose.

### Readiness is a script on the volume, and there is no liveness probe

The readiness check asks systemd whether the system has finished starting when systemd is what is
running, and otherwise falls back to a check any init satisfies once it is up.

There is deliberately no liveness probe. A liveness probe restarts the container it watches; on a pet
that means rebooting a machine because something inside it was briefly unresponsive, and destroying
the state that would have explained why. Readiness gates the Service endpoint without touching the
machine, which is the signal that is actually wanted.

### The Service publishes addresses before the machine is ready

The headless Service sets `publishNotReadyAddresses: true`.

Adding a readiness probe would otherwise change something the chart already promises: a machine's
stable name would stop resolving for the several minutes an operating system takes to boot, and again
whenever it became unwell — exactly when someone is trying to reach it. A machine is a pet with an
address, not a member of a pool whose traffic must be withheld. Readiness still means what it says for
anything else that selects the pod.

This is why `machine-topology` gains a requirement rather than quietly changing behaviour.

### The console goes to the container's output

The guest's console is pointed at the container's standard output, so `kubectl logs` shows the boot.

Proxmox sends it to `/dev/null` and expects users to read the journal, which is defensible on a host
where the journal is one command away. In a pod it is not: a pod with empty logs reads as broken, and
the first thing anyone does when a machine does not come up is exactly the thing that would tell them
nothing. The output is noisy and unstructured, and that is the accepted cost. A journal-tailing
sidecar remains the cleaner opt-in for later.

### The scripts stay POSIX-shell-testable, and stay out of the guest's way

The boot script runs in the chart's image, so it may use `bash`. The helpers copied onto the volume
run there too — they are executed by the kubelet inside the machine's mount namespace, but they are the
chart's own files, invoked with an interpreter the chart image no longer provides once the root has
changed.

That is a real constraint and it decides their form: **the copied helpers must be plain POSIX `sh`
scripts that use only what any operating system has** — `test`, `kill`, `sleep`, and, when systemd is
running, `systemctl`. They must not run a program from the chart's image, because after the pivot the
chart's image is not there, and they must not assume `bash`, because the machine may not have it.

## Risks / Trade-offs

- **`userns` may not boot where it renders.** The chart can see the cluster's version, not the node's
  kernel, its runtime's configuration, or whether the storage supports idmapped mounts. → Documented
  as a prerequisite, as `values-validation` already requires; the failure is a boot failure with a
  named mount, not silence. `privileged` remains the mode that works anywhere.
- **`userns` cannot be exercised on the project's own CI.** A kind node is itself a container, so
  user namespaces nest, and every volume in the pod would additionally have to support idmapping
  (`05-open-questions.md` §12). → The integration test boots `privileged`; the `userns` path is
  verified by hand where an environment allows it, and that is stated rather than implied.
- **The console output is noisy.** → Accepted, and reversible: a sidecar that tails the journal is
  additive and changes nothing rendered here.
- **A machine can now fail after rendering succeeded.** Every change so far either produced correct
  objects or refused; this one can produce objects that do not boot. → Every mount is checked and
  reported by path, the console is in `kubectl logs`, and the readiness probe distinguishes "still
  booting" from "up".
- **`SIGRTMIN+3` is not portable to every init.** → Which is why it is chosen at runtime from
  systemd's own marker rather than declared, and why the fallback is the signal every other init
  treats correctly.
- **The three managed files are written on every boot.** A machine that edits one without claiming it
  will lose the edit at the next restart. → That is the same contract Proxmox has, the marker is the
  documented way to take a file back, and `NOTES.txt` and the README say so.

## Migration Plan

A release upgraded to this version keeps its volume and its seeding record; the next pod start boots
the machine instead of sleeping. Nothing on the volume is rewritten except the three managed files,
and the machine's own state is untouched.

Rolling back returns the guest container to a placeholder that sleeps. The machine stops running but
its filesystem is intact, and rolling forward again boots it. Neither direction touches the seeding
record, so neither can cause a re-seed.

The one-way part is inside the machine: an operating system that has booted has written to its own
filesystem, as a machine does. That is the point of the project rather than a migration hazard.

## Open Questions

- Whether to offer `terminationGracePeriodSeconds` as an input once someone has a machine that needs
  longer than Proxmox's default. Additive, and invisible until it is needed.
- Whether the journal-tailing sidecar is worth shipping as an opt-in alongside console output.
  Additive, and answerable only once there are machines whose logs are being read in anger.
