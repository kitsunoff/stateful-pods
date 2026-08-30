## Context

See `proposal.md` — Why. What the plugin has to work with:

- Every machine's objects carry `stateful-pods.io/machine: <name>` and
  `app.kubernetes.io/instance: <release>`, and the pod is `<release>-<machine>-0` with containers
  `seed`, `prepare`, `customize` (init) and `guest`.
- After the root change, `kubectl exec` already lands inside the machine rather than in the shim.
  The plugin does not have to arrange that; it has to make it reachable by name.
- The chart validates every input and its messages name the values path and the accepted set.
- The repository has no build tooling for a binary and no Go. It has `shellcheck` over every script
  and `bats` suites that stub external commands on `PATH`.
- CI publishes the shim image on a tag. It does not package or publish the chart.

## Goals / Non-Goals

**Goals:**

- The three things a person actually does — get in, see what is happening, make one — are one
  command each.
- The plugin is transparent: it prints what it runs, so it teaches rather than hides.
- It adds no dependency a `kubectl` user does not already have.

**Non-Goals:**

- Talking to the API server directly. Auth plugins, exec credentials and proxies already work
  through `kubectl`, and none of that is reimplementable in bash.
- Any behaviour that only the plugin knows about. Anything worth guaranteeing about a machine
  belongs in the chart, where it applies to every install.

## Decisions

### One bash program at `cmd/kubectl-machine`, with no extension

`kubectl` discovers plugins by finding an executable named exactly `kubectl-<name>` on `PATH`, so
the file cannot be `kubectl-machine.sh`.

That has a consequence worth stating loudly: `hack/shell-lint.sh` collects scripts with
`find ... -name '*.sh'`, so it will skip this file and report success having never read it. The lint
must take the plugin's path explicitly, and the suite must assert the number of files linted, because
a lint that silently checks nothing is worse than no lint.

### It shells out to `kubectl` and `helm`, and needs nothing else

Every cluster read is `kubectl get` with `--output jsonpath` or `--output go-template`. No `jq`.
This is deliberate: `jq` is the dependency that turns "download one file" into "install two things",
and every value the plugin needs is a field on an object that `kubectl` can already project.

Both binaries are checked for at startup, and a missing one is named rather than producing a
`command not found` from inside a pipeline.

### Machine resolution is by label, and ambiguity stops it

`kubectl get pods --selector stateful-pods.io/machine=<name>` finds a machine without knowing the
naming rule. Two releases in one namespace can each declare a machine called `web`, so a match count
above one is reported with the release each belongs to, and `--release` disambiguates. Nothing is
picked for the user; picking the wrong pet is the one mistake this tool must not make.

### The stage is derived from container states, and named in the machine's own terms

This mapping is the plugin's actual value, and it is fixed:

| What the pod shows | What the plugin says |
| --- | --- |
| init container `seed` running | seeding the root filesystem from its source |
| init container `prepare` running | preparing the machine's identity |
| init container `customize` running | writing the files the chart maintains |
| `guest` running, not ready | booting |
| `guest` running and ready | ready |
| `guest` terminated or backing off | stopped, or failed — with the container named |
| any init container in error or backoff | failed while <that stage>, with the command to read its output |
| no pod at all | not running, with whether a release exists |

Every one of these is read from the pod's own status. No stage is inferred from how long something
has been happening, because a large template legitimately takes minutes and a timer would report a
healthy machine as broken.

### Entering the machine is one round trip and does not assume `bash`

```sh
kubectl exec --stdin --tty <pod> --container guest -- \
  /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash --login; else exec sh; fi'
```

`/bin/sh` exists in every root filesystem the chart can seed; `bash` does not — Alpine and Void do
not ship it. Choosing inside the machine costs one round trip instead of two and cannot be wrong.

A trailing `--` passes a command through instead of opening a shell.

### `create` composes values and hands them to Helm

Flags map to values paths (`--preset`, `--source-oci`, `--source-lxc-url` with `--source-sha256`,
`--mode`, `--size`, `--storage-class`, `--hostname`) and become `--set` arguments to
`helm upgrade --install`. The plugin does not check them. A machine with no `--mode` produces the
chart's own message about there being no default, which is a better message than the plugin would
write and stays correct when the chart changes.

`--release` defaults to the machine's name, so `kubectl machine create web` yields objects named
`web-web`. That duplication is inherent to the chart's `<release>-<machine>` rule while a release
holds one machine, and the plugin prints the resulting object name rather than hiding it. When the
chart lifts the one-machine restriction, `--release` becomes the way to add a machine to an existing
release and nothing already created gets renamed.

### `delete` removes the release and says where the state still is

`helm uninstall <release>`, after printing the context, namespace, machine and object name, and
after a confirmation that requires typing the machine's name. `--yes` is the non-interactive form;
without it, a non-interactive run does nothing rather than proceeding.

The root filesystem survives — the chart's retention policy keeps the claim — and the plugin says so
and prints the `kubectl delete persistentvolumeclaim` line that would destroy it. There is no flag
that does both, because a pet's disk should not be removable by a habit.

### The chart has to be published, which it is not today

`create` runs `helm upgrade --install <release> <chart>`, and for a user who installed the plugin
through krew there is no checkout for `<chart>` to point at. So this change adds one step to the
existing tag build: `helm package` followed by `helm push` to `oci://ghcr.io/<owner>/charts`.

`--chart` defaults to that reference, and `--version` to the plugin's own version, which is what
keeps a plugin and the chart it drives in step. Until the first chart is published, `create` fails
with a message telling the user to pass `--chart` a local path — a real failure with a real
instruction, not a stack trace.

### Bash 3.2 is the target, because macOS ships it

macOS still ships bash 3.2, and a plugin that requires bash 4 fails on half its audience with a
syntax error. No associative arrays, no `mapfile`, no `${var^^}`, no `declare -A`.

`shellcheck` does not enforce a version by default, so this is held by a CI job that runs the
plugin's suite on a macOS runner against the system bash. That job is the whole enforcement; without
it the constraint is a comment nobody checks.

## Risks / Trade-offs

- **A lint that skips the plugin** → The file has no `.sh` extension by necessity. Handled by passing
  it explicitly and asserting the linted file count.
- **Bash 3.2** → Held by a macOS CI job, not by discipline.
- **Label assumptions couple the plugin to the chart's rendering** → They are the labels the chart's
  own spec requires to be stable, and the selector labels are immutable for the life of a machine, so
  this is the most stable thing to depend on.
- **`create` cannot work before the chart is published** → Sequenced first in the migration plan;
  until then the failure is explicit.
- **No Windows** → Accepted with the choice of bash, stated in the plugin's own platform check and
  in the README rather than discovered at runtime.
- **A generic krew name** → `machine` may be too generic for the upstream index. It costs nothing
  now, since this change ships a manifest rather than a submission.

## Migration Plan

1. Add chart packaging and publishing to the tag build, and publish once. `create` depends on it.
2. Build the plugin and its suite. Nothing outside `cmd/` and `test/` changes.
3. Add the macOS lint and test job.
4. Add the release archives, checksums and the krew manifest to the tag build.
5. Point `NOTES.txt` and the README at the plugin, once it is installable.

Rollback is deleting the plugin: nothing in the chart, the image or the scripts depends on it, and a
machine created through it is an ordinary Helm release that `helm` continues to manage.

### Implementation order

Group 1 is a prerequisite for `create` but blocks nothing else, so it can run in parallel with group
2. Groups 3 and 4 both need group 2. Group 5 needs everything. The only file this change shares with
`shim-owned-scripts` is `hack/shell-lint.sh`, and only its list of search roots.

## Open Questions

- Whether the upstream krew index will accept `machine` as a plugin name, or whether it wants
  something like `stateful-pods`. Deferrable: the manifest is local until a release exists to submit.
- Whether `status` should eventually show the seeding record from the volume, which would mean an
  exec into a machine that may not be running. Deferrable and additive.
