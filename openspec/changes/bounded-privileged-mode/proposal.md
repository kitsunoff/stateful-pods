## Why

The `privileged` mode is the one a user picks when their cluster cannot do user namespaces, which
means it is the mode that runs on the oldest and least defended clusters. It is also the weakest
posture this project can produce, and it is weaker than it needs to be.

`privileged: true` is not a capability set. It is an instruction to the runtime to stop applying
policy: every capability, every host device, the unmasked `/proc` paths, AppArmor unconfined, and —
by the look of containerd's own code, which passes the privileged flag into the decision about
whether to apply a seccomp profile at all — no syscall filter either, whatever the pod asks for.

Proxmox's privileged container is not that. It drops `mac_admin`, `mac_override`, `sys_time`,
`sys_module` and `sys_rawio`; it denies all devices and allows about twelve back; it runs under an
AppArmor profile and under a seccomp denylist that closes `open_by_handle_at`, the classic escape
primitive for exactly this kind of container. The word is the same, the posture is not.

Nothing about what the shim does requires the runtime to stop applying policy. It mounts, it binds
device nodes that are already in the pod, and it changes the root. Those are capabilities, and
capabilities can be asked for by name.

## What Changes

- **BREAKING: `privileged` stops rendering `privileged: true`.** It renders an explicit capability
  set instead, modelled on what Proxmox gives a privileged container: what a container gets by
  default, plus what the shim needs to mount and change the root, minus the capabilities Proxmox
  refuses to hand a container.
- **The mode keeps its name.** Proxmox calls its equivalent a privileged container while still
  dropping capabilities, and the name describes the relationship to the host — the machine's root is
  the node's root — which stays true.
- **The mode becomes confinable.** A container that is not marked privileged is one the runtime will
  apply a seccomp profile to, which makes the profile from `seccomp-posture` mean something in the
  mode where it matters most.
- **The guest names the access-control profile it runs under**, in both modes. The same reasoning
  applies to AppArmor as to seccomp, but with the sign reversed: a container the runtime is willing
  to confine is one it confines with a default profile that denies `mount(2)` outright, so a machine
  that named nothing would stop booting on any node with AppArmor enabled. The field is declared;
  no profile is shipped in it.
- **What the mode loses is stated, not discovered**: the node's own devices, and the ability to load
  kernel modules, perform raw I/O or set the node's clock from inside a machine. Each is named in
  `values.yaml` with what to do instead. The unmasked `/proc` paths were on this list until the
  experiment showed they are not lost at all - the shim mounts a fresh procfs inside the new root,
  which carries none of the runtime's masking, in either mode. See `design.md`.
- **An escape hatch for a machine that genuinely needs the old behaviour.** If one is needed at all,
  it is a separate, explicitly named mode rather than a flag that quietly re-widens `privileged`,
  and it is added only if the integration suite finds a real case.

Non-goals:

- Changing the `userns` mode. It already grants one capability and is the stricter of the two.
- An AppArmor profile. This change makes one possible; it does not add one.
- Removing the `privileged` mode or discouraging it. It exists because user namespaces need a
  cluster that many people do not have.

## Capabilities

### Modified Capabilities

- `pod-security-posture`: the `privileged` mode renders a named capability set rather than the
  runtime's blanket privileged flag, and the requirement that only the guest receives the mode's
  privilege is restated in terms of that set.

### Added Capabilities

- `pod-security-posture`: the guest container names the access-control profile it runs under, in
  both modes, rather than leaving it to the node. Not foreseen when this was proposed - see
  `design.md` for what the experiment found.

## Impact

- **Depends on `seccomp-posture`.** Half the value of this change is that a filter can be applied at
  all, and that change is where the filter comes from. It also settles by experiment whether a
  privileged container ignores a profile, which is the premise this change is built on — if that
  premise turns out to be false, this change loses one of its two reasons and should be re-argued
  before it is implemented.
- **Chart**: the guest container's security context in `statefulset.yaml`, the mode's documentation
  in `values.yaml`, and the render tests that currently assert `privileged: true`.
- **Breaking for existing machines in this mode.** The pod is replaced with a differently
  privileged one on the next upgrade. A machine whose guest reaches for one of the node's devices,
  loads a kernel module or performs raw I/O will stop being able to. The volume is untouched, so the
  recovery is a values change, not a rebuild.
- **Breaking for clusters below Kubernetes 1.30.** The guest names the access-control profile it
  runs under, and that field does not exist before 1.30, so the chart's floor moves up from 1.27.
  Nothing below 1.30 could run the other mode anyway, and all of those releases are out of support.
- **The main risk is empirical and belongs first**: whether a machine actually boots and runs under
  a named capability set. The mount work is well understood; a full systemd exercising a whole
  distribution is not, and the two source kinds and four presets are different enough that this is
  a question for the integration suite rather than for reasoning.
