## Why

The chart now fills a machine's root filesystem correctly and then runs a placeholder that sleeps on
top of it. Everything is in place except the part the project exists for: nothing mounts that
filesystem as a root and hands control to the operating system living on it.

This is also the change where the security modes stop being decoration. `userns` and `privileged`
exist because mounting filesystems and changing the root require privilege; until now no code
exercised either. The same is true of the shim image, whose reason for existing is the twenty lines
of mount work described below.

## What Changes

- **The guest container boots the machine.** It mounts the kernel filesystems the guest's init needs
  into the seeded volume, binds the device nodes the runtime already gave the pod, changes the root
  to the volume, and hands over to the guest's `/sbin/init`. The placeholder command is gone.
- **The mount set is fixed, not configured.** Every machine gets the same one, including a writable
  cgroup2 in the new root. A systemd guest needs it; a runit guest ignores it; mounting it always
  removes an entire configuration axis and costs nothing.
- **The root change is `pivot_root`, not `chroot`** — a requirement rather than a preference,
  because it is what makes `kubectl exec` and exec probes land in the machine rather than in the
  shim.
- **The guest is told it is a container.** Without it, systemd concludes it is running on bare metal
  and starts trying to load kernel modules and run fsck.
- **Three files the chart maintains inside the guest, on every boot**: `/etc/hostname`, `/etc/hosts`
  and `/etc/resolv.conf`, taken from the ones the kubelet wrote for the pod. After the root change
  the pod's own copies are unreachable, which is exactly the situation Proxmox is in and why its
  pre-start hook does the same. A per-file marker inside the guest opts any of them out, so a
  machine that manages its own resolver keeps it.
- **The machine shuts down instead of being killed.** A stop hook sends the signal the guest's init
  actually understands — which for systemd is not `SIGTERM` — and waits for it, with a grace period
  matching Proxmox's own.
- **`kubectl logs` shows the machine booting**, rather than nothing.
- **A readiness probe reports when the machine has finished booting.** No liveness probe: restarting
  a pet because a service was briefly unresponsive is worse than leaving it degraded and visible.

Non-goals, each deliberately left to a later change:

- cloud-init, systemd credentials, SSH host keys, root password and `authorized_keys`. The machine
  boots with the identity and accounts its source shipped.
- Masking the guest's network-management units, and the rest of the per-distribution customization
  Proxmox performs.
- `rootfs.mode`, the overlay architecture, and any re-seeding policy.
- A journal-tailing sidecar as an alternative to console output.
- A `sysbox` security mode.

## Capabilities

### New Capabilities

- `machine-boot`: what the chart does between a filled volume and a running operating system — the
  filesystems the guest is entitled to find, the root change itself, what the guest is told about
  where it is running, and what must be true of the result.
- `guest-managed-files`: the files the chart maintains inside a running machine, why they cannot
  come from the pod, and how a machine takes one of them back.
- `machine-lifecycle`: how a machine reports that it has finished booting, how it is asked to stop,
  and what its logs show while both happen.

### Modified Capabilities

- `machine-topology`: a machine's stable name must keep resolving while it is still booting, now
  that readiness gates its Service endpoint.

## Impact

- **Changed files**: the guest container in the StatefulSet template gains its real command, a stop
  hook, a probe and a grace period; the chart's script set gains the boot, customization, probe and
  stop scripts.
- **The placeholder assertions go.** The tests that pin a placeholder image reference and a
  placeholder command were written so that this change would have to remove them deliberately.
- **The privilege modes become load-bearing.** A `userns` machine that renders today may fail to
  boot on a cluster whose nodes cannot support user namespaces — a prerequisite the chart documents
  and cannot observe. The integration test therefore exercises `privileged`, and `userns` is
  verified where an environment allows it.
- **Failure moves from render time to boot time.** Everything before this change either rendered or
  failed loudly at render. A machine can now fail while booting, which is why the console goes to
  `kubectl logs` and why every mount is checked and reported by path.
- **The research is the rationale**: `docs/research/03-mapping-and-architecture.md` §3.1 (the mount
  sequence and the device-node binds) and §4.2–§4.4, `02-kubernetes-primitives.md` §4.2 (why
  `pivot_root`), §7 (shutdown signals) and §8 (the files that vanish after the root change),
  `05-open-questions.md` §4 (no init-system input), §8 and §9, and `06-guest-provisioning.md` §6.
