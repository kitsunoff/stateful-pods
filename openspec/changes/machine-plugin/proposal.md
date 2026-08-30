## Why

Everything the chart does well is invisible from the command line. A machine is a pet with a name,
but reaching it means knowing that the name is really `<release>-<machine>-0`, that the container is
called `guest`, and that the shell inside it might be `bash` or might only be `sh`. Creating one
means writing a values file and remembering the four inputs the chart requires. Both are printed in
`NOTES.txt`, which is exactly where nobody looks a week later.

The gap is sharpest at the one moment it hurts most. A machine that has not finished booting cannot
be entered at all, and `kubectl exec` answers that with an error about a container, not with the
fact that the volume is still being seeded from a 400 MB template. The user's next move is to go
find out which of four containers is running and read its logs — every time.

## What Changes

- **A new `kubectl machine` plugin**, a single bash program in `cmd/kubectl-machine`, covered by the
  same `shellcheck` and `bats` the chart's scripts already are.
- **`kubectl machine list`** — the machines in a namespace, by their own names, with the stage each
  one is in.
- **`kubectl machine shell <name>`** — a shell inside the machine, resolved from the machine's name
  through the labels the chart already sets. When the machine cannot be entered, the failure says
  which stage it is in and what to look at, instead of reporting a container that is not running.
- **`kubectl machine console <name>`** — the machine's own boot output, which is what the guest
  container's logs are.
- **`kubectl machine status <name>`** — where the machine is: seeding, preparing, booting, ready, or
  stopped, derived from the container states and the readiness the chart already produces.
- **`kubectl machine create <name>`** — assembles values from flags and calls `helm upgrade
  --install`. The chart validates; the plugin only passes through, and shows the chart's own
  rejection unchanged.
- **`kubectl machine delete <name>`** — removes the release after naming what it is about to remove
  and confirming. The root filesystem survives, because the chart retains it, and the plugin says so
  and prints the separate command that would destroy it. There is no flag that does both in one
  step.
- **Every command that changes the cluster prints the context and namespace it is acting on, and the
  `kubectl` or `helm` command it is about to run**, in full flag form.
- **Release archives with checksums, plus a krew manifest in the repository**, so the plugin
  installs with `kubectl krew install --manifest` or with a plain download.

Non-goals:

- Re-implementing any of the chart's input validation. Two validators drift, and the chart's
  messages are better than anything the plugin would invent.
- A flag that deletes a machine and its root filesystem together.
- Windows. A bash plugin covers Linux and macOS; that is the trade accepted by choosing bash over
  Go, and it is recorded rather than papered over.
- Submitting to the upstream krew index in this change. The manifest is prepared here; the
  submission needs a published release to point at.

## Capabilities

### New Capabilities

- `machine-plugin`: the command-line surface for machines — how a machine is addressed, what
  entering one guarantees, what the plugin is and is not allowed to decide on the user's behalf, and
  how it is installed.

### Modified Capabilities

None. The chart, the shim and the scripts are untouched.

## Impact

- **A prerequisite discovered while planning: the chart is not published anywhere.** CI publishes
  the shim image on a tag and nothing else, so `helm install stateful-pods` has no reference to
  resolve and every install today is from a checkout. `create` cannot work for someone who installed
  the plugin through krew until the chart is packaged and pushed. This change therefore adds chart
  publishing — one `helm package` and `helm push` to GHCR on the existing tag build — and defaults
  `--chart` to that reference at the plugin's own version.
- **New**: `cmd/kubectl-machine`, `test/shell/plugin*.bats`, a krew manifest, a release workflow
  step, and a chart publishing step.
- **`hack/shell-lint.sh` needs both a new search root and a way to see a file with no `.sh`
  extension** — a plugin must be named exactly `kubectl-machine` to be found on `PATH`, so the
  extension-based `find` misses it silently, which is the failure mode where a lint passes by
  checking nothing.
- **Overlaps with `shim-owned-scripts`**: that change also edits the search roots in
  `hack/shell-lint.sh`. Whichever lands second resolves a one-line conflict.
- **Partially depends on `distro-presets`**: `create --preset` composes a source kind that does not
  exist until that change lands. The `--source-oci` and `--source-lxc-url` forms do not depend on it,
  so the plugin is useful before it; the flag and its tests are the part that has to wait. Nothing
  else here is sequenced against the other two changes.
- **Documentation**: the README gains an installation section, and `NOTES.txt` can point at the
  plugin instead of spelling out raw `kubectl` invocations.
