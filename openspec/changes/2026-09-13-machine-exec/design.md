## Context

A machine is provisioned by one of two backends. `cloud-init` writes a NoCloud seed into the root
filesystem before the machine starts, and the machine's own cloud-init reads it on the first boot.
`native` writes nothing at all beyond the three files the chart maintains, and exists so that an
image without cloud-init can still start.

Both run in an init container, before the root change. That is the right place for `cloud-init`,
whose entire mechanism is a file left where the machine will look. It is the wrong place for
anything that has to *run*: at that moment there is no machine, only a directory full of another
architecture's binaries that this container must never execute.

Which is why `native` provisions nothing and why the inputs filed for it —
`rootPassword`, `authorizedKeys`, `firstBootScript` — were the wrong shape. Every one of them is a
file written from outside. None of them can install a package.

## Goals

- A machine on any image, including every preset that cannot run cloud-init, can be configured by
  its own commands.
- The commands run once per change of what they are, not once per pod start and not once per upgrade.
- The mechanism's access to the cluster is the narrowest that can work, and it is stated plainly
  rather than buried.
- A failure is legible: the Job fails, `helm install --wait --wait-for-jobs` fails with it, and
  the logs are the script's own output.

## Non-goals

See the proposal.

## Decisions

### The name changes with the behaviour

`native` meant "layer 0 and nothing else". The backend now runs arbitrary commands inside a booted
machine, which is not that, and keeping the name would leave every existing values file and every
piece of documentation describing something the chart no longer does.

So `native` is refused with a message naming `exec` — the same treatment `systemd-credentials`
gets, and for the same reason: the reader has read something true about an older version and telling
them the name is a typo would send them looking for a spelling that does not exist.

`exec` with no script writes nothing and renders nothing beyond what `native` rendered, so the
migration is a rename and only a rename.

### A Job beside the machine, not a container inside its pod

Three shapes were considered.

**An init container**, like the two existing backends. Impossible by construction: every init
container runs before the guest container, so the machine has not booted and, after the root change,
the init container's filesystem is on the other side of it. This is the same wall `native` hit.

**A container in the machine's own pod**, entering the machine's namespaces with `nsenter`. This
needs `shareProcessNamespace: true` so the sibling's PID is visible — and that makes the pause
container PID 1, which takes PID 1 away from the machine's init. systemd refuses to run at all when
it is not PID 1. The whole point of this chart is that a machine runs its own init, so the option
disqualifies itself.

**A Job beside the machine**, reaching it through the API server the way an operator would. This is
what is implemented. It costs a ServiceAccount, a Role, a RoleBinding and `kubectl` in the image,
and it buys the only shape in which the script runs inside a booted machine as that machine's root.

It also composes with Helm rather than against it: `helm install --wait --wait-for-jobs` does not
report success until the machine has booted and its script has run, and a script that fails fails
the release. Both flags are needed and the second is the one people forget — `--wait` alone waits for
workloads and not for Jobs, so an install that omits it reports success while the machine is still
unconfigured. The documentation says so wherever it says the install can be waited on.

### It waits for the root change, and readiness is how it knows

`boot.sh` writes `/run/stateful-pods/booted` immediately after `pivot_root`, on the `tmpfs` it just
mounted, and the readiness probe the chart already ships reports the machine ready once its init has
come up. The Job waits for the pod's `guest` container to report ready and then confirms the marker
before it does anything.

Readiness rather than the marker alone, because the marker says the root changed and readiness says
the operating system started — and a script that installs a package needs the second. Confirming the
marker as well, because readiness is derived per init system and the marker is the one signal that
means exactly "this is the machine, not the shim".

Waiting is a poll of `kubectl get pod`, not `kubectl wait`. `kubectl wait` opens a watch, and a
watch cannot be restricted to one object by name: `resourceNames` does not apply to `list` and
`watch`. Polling is what lets the Role name a single pod.

### The script is streamed through exec, not copied with `kubectl cp`

`kubectl cp` is `tar` on both ends: it runs `tar` **inside the target container** and pipes an
archive to it. A machine without `tar` — a busybox rootfs, a deliberately minimal image — would fail
with a message about an archiver it never asked for.

So the script is written with `kubectl exec -i … -- /bin/sh -c 'cat > …'`, which is the same
operation with a shell as its only requirement. It lands in `/run/stateful-pods/provision/`, which is
a `tmpfs` the boot sequence mounts: the script and its environment are gone at the next boot and
never reach the machine's volume or its snapshots. That matters, because the environment is where a
secret would be.

The environment is written as a file and sourced, never passed as arguments. Arguments appear in the
Job's own logs, in `ps` inside the machine, and in the API server's audit log.

### The Job is named for what it would do

`<release>-<machine>-exec-<eight hex of a digest>`, over the script, the environment as it was
materialized, the names of anything referenced, and `guest.provisioningRevision`.

This is the whole of the re-run policy, and it falls out of Helm's own semantics rather than being
enforced anywhere:

| What happened | What follows |
| --- | --- |
| The script changed | a different name, so a new Job is created and runs |
| Nothing changed | the same name and the same content, so the upgrade is a no-op |
| The release is upgraded for an unrelated reason | the same name, so nothing re-runs |
| `provisioningRevision` is bumped | a different name, so it runs again |
| The release is uninstalled | the Job is the release's, so it goes with it |

A Job's spec is immutable, which is what makes the digest part of the name necessary rather than
decorative: a Job whose name stayed the same while its script changed would be a `helm upgrade` that
fails with `field is immutable`.

**The machine's pod is not restarted by any of this**, and the `checksum/provisioning` annotation is
deliberately not applied under this backend. The script is applied from outside a running machine;
restarting the machine to change something it never reads at boot would be a chart that reboots a
database to change a comment.

The hole this leaves is stated rather than hidden: if a machine's volume is destroyed and re-seeded
while its Job is already complete, the script does not run again. Deleting the Job and upgrading
re-runs it, and `NOTES.txt` says so.

### The access it is given, and why it is the smallest that works

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
    resourceNames: ["<release>-<machine>-0"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
    resourceNames: ["<release>-<machine>-0"]
```

`create` on `pods/exec` for one named pod is **root inside that machine**, and it is stated in
`values.yaml` in those words. It is also exactly what the capability is: a mechanism that runs a
script as root inside a machine cannot be given less than the right to run a command as root inside
that machine.

What it cannot do is anything else. It cannot list pods, read a Secret, reach another machine in the
same namespace, or exec into a neighbour. The machine's own pod is unchanged and still has no
ServiceAccount token of its own.

The Job's pod runs the same preparation security context every other step of this chart runs under —
`RuntimeDefault`, no privilege escalation — because it unpacks nothing and mounts nothing. It is a
`kubectl` invocation.

### Failure is a failure

`backoffLimit: 0` by default. A provisioning script is somebody's shell, and re-running one that
failed half-way is a decision only its author can make; the chart will not make it by default. It is
an input, so a script that is idempotent can say so.

`activeDeadlineSeconds` covers the whole Job — the wait and the run together — so a machine that
never becomes ready fails the Job with `DeadlineExceeded` rather than leaving it pending forever.
The default is generous, because the wait includes seeding an operating system onto an empty volume.

### What the image gains

`kubectl`, from the base image's own repository, which is about 58 MiB uncompressed on top of a
39 MiB image. That is a real cost and it is paid by every machine, including those that never use
this backend.

It is paid anyway, for the reason `images/shim/Containerfile` already gives about `crane` and `tar`:
the chart runs every container from one image so that a running machine cannot have two versions of
itself. A second image for this one Job would double the release surface — a second digest to pin, a
second package to make public, a second thing to keep in step with the chart — to save a layer that
a node pulls once and shares between every machine on it.
