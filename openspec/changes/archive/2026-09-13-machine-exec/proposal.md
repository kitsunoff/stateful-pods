## Why

`native` is a backend that provisions nothing. It is what a machine on an image without cloud-init
has to name — two of the four presets, and almost every `lxc` template — and what it gives such a
machine is the host name, the host table and the resolver, which is layer 0 and nothing else. The
machine boots with the accounts its source shipped, which for the presets this project publishes is
none at all, and the only way in is `kubectl machine shell`.

So half the images this chart ships a name for can only be provisioned by hand. That is the gap the
`native` backend was always a placeholder for, and the design filed its own inputs —
`rootPassword`, `authorizedKeys`, `firstBootScript` — for later. Later has arrived, and reopening it
showed that the list was the wrong shape: every one of those inputs is a way of writing files into a
root filesystem from outside, before anything in the machine has ever run, which is precisely what
cannot install a package, enable a service, or ask the machine's own package manager anything at
all.

What a machine that cannot run cloud-init actually needs is a way to run **its own commands, inside
itself, once it is up** — the machine's shell, the machine's package manager, the machine's init. A
step before the root change can never be that: the machine does not exist yet.

## What Changes

- **`native` becomes `exec`.** **BREAKING**: `guest.provisioning: native` is refused, with a message
  saying the backend was renamed and that `exec` with no script behaves exactly as `native` did. The
  name changes because the behaviour does: the backend is no longer defined by writing nothing.
- **A machine may supply a script**, at `machines.<name>.exec.script`, inline or by reference in the
  same two forms every provisioning input already takes. It runs **inside the machine, after the
  machine has booted**, as the machine's own root, with the machine's own shell.
- **The script is carried by a Job beside the machine**, not by a step inside its pod. The Job waits
  for the machine to pass the root change and report itself ready, streams the script into the
  machine's own `tmpfs`, runs it, and reports what it did. A step in the pod could not do this: every
  step runs before the machine exists, and a container in the machine's pod cannot enter the
  machine's mount namespace without taking PID 1 away from its init.
- **The Job is named for what it would do** — the machine, plus a digest of the script, the
  environment and `guest.provisioningRevision`. An unchanged script is the same Job and runs once; a
  changed one is a different Job and runs again; and the machine's pod is **not** restarted by
  either, because the script is applied from outside and restarting a pet to re-read a value it never
  reads would be a chart that reboots a database to change a comment.
- **The Job is given the narrowest access that can work**: a ServiceAccount of its own, and a Role
  that can `get` one pod and `create` an `exec` on that same pod, by name. Nothing else in the
  namespace is reachable from it, and the machine's own pod has no API access at all.
- **An environment may be supplied beside the script**, at `machines.<name>.exec.environment`, so
  that a script can stay readable in the values file while the secret it needs is named rather than
  spelled out. It is written into the machine's `tmpfs` and never appears on a command line.
- **`kubectl` joins the shim image**, because the Job runs from it like every other container the
  chart renders.
- **`values.yaml`, both READMEs and `NOTES.txt`** document the backend, what it can and cannot do,
  and the access the Job is given — which is a real grant and is stated as one.

Non-goals, named so they are not mistaken for omissions:

- **`kubectl cp`.** It is what this does, and it is not how it does it: `kubectl cp` needs `tar`
  inside the target container, and a machine that has none would fail for a reason that has nothing
  to do with its script. The script is streamed through `exec` instead, which needs only a shell.
- **Running the script on every boot.** It runs when its content changes, and that is a Job's
  semantics rather than a sidecar's. A machine whose volume is destroyed and re-seeded while the Job
  is already complete is not re-provisioned; `NOTES.txt` says so and says which command re-runs it.
- **Undoing what a script did.** Removing the script from the values removes the Job and changes
  nothing inside the machine, exactly as switching away from `native` never undid anything. The
  volume is the machine.
- **`systemd-credentials`.** Still described in the design, still not implemented, still refused by
  name.
