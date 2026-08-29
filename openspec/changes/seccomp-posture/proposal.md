## Why

The chart says nothing about seccomp anywhere. Not in the templates, not in the specs, not in the
research. Two things follow from that silence, and one of them is a live defect.

**The defect.** Containerd's default seccomp profile has `DefaultAction: SCMP_ACT_ERRNO` and does not
contain `pivot_root` at all — not in its base list, and not in the block it unlocks for
`CAP_SYS_ADMIN`, which does contain `mount`, `umount2`, `unshare` and `setns`. So on a cluster whose
kubelet runs with `--seccomp-default=true`, every pod without an explicit profile gets that profile,
and a `userns` machine fails at the root change. Meanwhile `pod-security-posture` states that the
same values render the same posture on any cluster — which is true of the manifest and false of what
the machine actually runs under. A flag on the kubelet silently changes the posture.

**The omission.** Proxmox runs every container under a seccomp profile. Ours run under none, so the
one attack surface that `userns` leaves open — the kernel, reached through the mount code paths that
`CAP_SYS_ADMIN` unlocks — is unnarrowed. The init containers, which need no privilege at all and do
nothing more exotic than unpacking an archive, run just as unconfined as the machine does.

## What Changes

- **The guest container declares `Unconfined` explicitly.** Not a security improvement — a
  correctness one. It makes the posture a property of the values rather than of a kubelet flag, and
  it is what the requirement about identical posture already promises.
- **The init containers declare `RuntimeDefault`.** They seed, prepare and customize a volume:
  they read, write, unpack and fetch, and they never mount or change a root. Nothing in the default
  profile is in their way, they need no file on any node, and it costs nothing. This is the part of
  the change that is a straightforward win.
- **A new optional input**, `machines.<name>.security.seccompProfile`, accepting `Unconfined` or
  `Localhost` with a profile path, so an operator who can place a profile on their nodes can confine
  the machine itself.
- **`RuntimeDefault` is rejected for the guest, with the reason.** It is the value a security-minded
  user reaches for first, and on containerd it produces a machine that renders, seeds and then dies
  at the root change. The rejection names `pivot_root` and points at the `Localhost` form.
- **A profile ships in the repository**, modelled on the one every Proxmox container already runs
  under: `defaultAction: SCMP_ACT_ALLOW` with `kexec_load`, `open_by_handle_at`, `init_module`,
  `finit_module` and `delete_module` returning an error, plus forced unmount. A denylist, not an
  allowlist, because the profile applies to a whole distribution's userland rather than to the
  shim's twenty lines.
- **Documentation of how to get that profile onto nodes**, which the chart cannot do: the Security
  Profiles Operator, a DaemonSet writing into the kubelet's seccomp directory, or the node image.

Non-goals:

- Shipping the mechanism that distributes the profile. A chart that wrote into a node's kubelet
  directory would need a privileged DaemonSet, which is a strange thing to add in the name of
  confinement.
- An AppArmor profile. It is the same distribution problem with a different file format and belongs
  in its own change.
- Making the machine's own profile the default. It cannot be, because the file it names does not
  exist on a node until someone puts it there.

## Capabilities

### Modified Capabilities

- `pod-security-posture`: the posture a mode names now includes the syscall filter, so it stops
  depending on how the cluster's kubelet is configured; the containers that run before the guest are
  confined by the runtime's default profile; and a machine may name a profile the cluster provides.
- `values-validation`: the new input is validated, and the one value of it that is known to produce
  an unbootable machine is rejected with the reason rather than rendered.

## Impact

- **Chart**: `initSecurityContext` gains a seccomp profile, the guest container gains one, and
  `_helpers.tpl` gains the validation. No change to any script.
- **New**: the profile JSON, its documentation, and unit tests for the four render cases.
- **Fixes a real failure** on clusters running `--seccomp-default=true`, where `userns` machines do
  not boot today. That is also the assertion that is hardest to make in CI, because it needs a
  cluster configured that way — the integration test grows a kind cluster with the flag set.
- **Verification risk**: the claim that a privileged container ignores any profile it is given.
  Containerd passes the privileged flag into its seccomp options generator, which decides whether a
  profile is applied at all. If that is what it does, the `privileged` mode cannot be confined by
  this change at all, and the note in `values.yaml` must say so plainly rather than implying a
  protection that is not there.
- **Sequencing**: independent of the other pending changes. It touches `_helpers.tpl` and
  `statefulset.yaml`, which `shim-owned-scripts` also edits, so the two conflict trivially if they
  land together.
