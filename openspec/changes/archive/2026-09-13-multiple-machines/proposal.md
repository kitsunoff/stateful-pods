## Why

The chart has always accepted machines as a map keyed by name, and has always refused the map when
it held more than one entry. The map form was put in first so that lifting the restriction would
rename nothing that already existed; everything since has been built per machine on that
assumption — every helper takes an explicit machine context and reads no global, every object is
named `<release>-<machine>`, and the volume claim a machine declares is named for the volume alone
so that two machines may each have a `data`.

The restriction is now the only thing in the way. Rendering two machines produces eighteen objects
with eighteen distinct names, each machine's inputs reaching only its own; the refusal is a line of
validation and nothing else.

What it costs is not in the chart. It is in the two plugin commands that act on the **release**
rather than on the machine — `delete`, which uninstalls it, and `create`, which installs it from one
machine's flags. Both would take a sibling with them, and the sibling is somebody's pet.

## What Changes

- **A release may hold as many machines as you like.** The count refusal is removed. Nothing else in
  the chart changes: the names, the labels, the claim templates and the per-machine helpers were
  already what they had to be, which the new rendering suite asserts rather than assumes.
- **`kubectl machine delete` names the other machines the release holds**, before it does anything,
  and then asks for the **release's** name to confirm instead of the machine's. A confirmation that
  asked for one machine's name would read as a promise that only that machine goes.
- **`kubectl machine create` refuses a `--release` that already holds another machine.** Helm takes
  the values it is given and nothing else, so installing one machine's flags over such a release
  would leave it holding that machine alone and delete the sibling's objects. The refusal names the
  machines it would have removed and prints the `helm upgrade` that adds one properly.
- **`values.yaml`, both READMEs and the plugin's own help** say what machines in one release share:
  nothing but the release's lifetime.

Non-goals:

- **`--reuse-values` in `create`.** It would make the chart's own defaults stop moving on upgrade —
  a decision about somebody else's machine that a convenience command has no business making. Adding
  a machine to a release that already has one is a values file and a `helm upgrade`, and the refusal
  says so.
- **Removing one machine from a release.** That is an edit to the values that declare it, and the
  plugin deliberately owns no values file. `delete` removes releases, which is what it has always
  done and now says more plainly.
- **Any ordering or dependency between machines in a release.** They are independent pets that
  happen to be installed together; a machine that must start after another is two releases, or a
  thing the machine itself waits for.
