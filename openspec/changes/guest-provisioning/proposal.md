## Why

A machine boots with the accounts its source image shipped, which for every preset this project
publishes means no accounts at all. There is no way to put a user, an SSH key, a password or a
first-boot command into a machine, so the only way in is `kubectl machine shell` — and a machine
nobody can reach over SSH is not a machine anyone runs.

The design for this was settled before the chart existed and has not been revisited since:
[`docs/research/06-guest-provisioning.md`](../../../docs/research/06-guest-provisioning.md) and
[`docs/research/07-provisioning-inputs.md`](../../../docs/research/07-provisioning-inputs.md),
with the decisions recorded in
[`docs/research/05-open-questions.md`](../../../docs/research/05-open-questions.md) §0 and §5a.
cloud-init via a NoCloud seed directory, three backends with `cloud-init` the default, every input
expressible inline or as a Secret reference, and — the part that matters most — an image that
cannot run cloud-init must fail the pod loudly rather than boot a machine with no way in.

The presets moved to their upstream `cloud` variant so that this could land. cloud-init is on three
of the four presets today, installed and inert.

## What Changes

- **A machine declares a provisioning backend**, at `machines.<name>.guest.provisioning`.
  `cloud-init` is the default and `native` is the escape hatch. **BREAKING**: a machine that
  declares nothing now selects `cloud-init`, and on an image that cannot run it the pod fails
  instead of starting. That is the settled default working as designed, and it is why the
  `void-current` preset — whose upstream publishes no cloud variant — must now name
  `provisioning: native` explicitly.
- **The cloud-init backend writes a NoCloud seed** at `/var/lib/cloud/seed/nocloud/` in the
  machine's own root filesystem, together with a `/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg`
  drop-in that hands hostname, host table, resolver and network configuration back to the layers
  that already own them. It also **removes `/etc/cloud/cloud-init.disabled`**, the marker the
  upstream builder writes into every LXC image it publishes. Writing a seed without removing that
  marker does nothing whatsoever, which makes removing it part of what writing a seed means.
- **`instance-id` is computed at boot** from the files that were actually materialized plus an
  identity seed of namespace, release and machine name. A changed configuration re-applies on the
  next start; an unchanged one does not; a clone into another release regenerates the machine's
  identity for free.
- **Every provisioning input is expressible inline or as a Secret/ConfigMap reference**, in one
  shape borrowed from `EnvVarSource`. Referenced material never appears in the values file or in
  the Helm release. The inputs are assembled by a projected volume mounted into one init container
  and into nothing else — never into the guest a user execs into.
- **Raw provisioning files shadow structured values per file**, with no merging, following
  Proxmox's `cicustom` semantics. `NOTES.txt` says so when it happens rather than letting the user
  wonder why the password did not apply.
- **An image that cannot run cloud-init fails the pod**, naming `guest.provisioning: native` as the
  fix. Presence is established from the seeded root filesystem — the executable and an integration
  with an init system that will actually start it — and never used to switch backends silently.
- **`values.yaml`, the chart README, the project README and `NOTES.txt`** document which presets can
  serve which backend, at the point of use.

Non-goals, deferred deliberately and named so they are not mistaken for omissions:

- **The `systemd-credentials` backend.** It is a third mechanism with its own delivery path — a
  tmpfs at `/run/host/credentials` that has to survive the root change — and its own reason to
  exist (nothing sensitive reaches the volume). It shares no code with the two backends here beyond
  the input contract this change establishes, and shipping it alongside them would double a change
  that is already large. It is refused as a value with a message saying so, rather than accepted
  and ignored.
- **The `native` backend's own provisioning inputs** — `rootPassword`, `authorizedKeys`,
  `sshHostKeys`, `machineId`, `files`, `firstBootScript`. `native` in this change is exactly what
  the design calls layer 0: the files the chart already maintains, and nothing else. It is a
  complete and honest contract, it is what the fail-loud message points at, and it is what a Void
  machine gets. Its inputs need a first-boot mechanism of their own — the chart's containers never
  execute the guest's programs, so a first-boot script cannot simply be run — and that is a design
  question this change does not have to answer to be useful.
- **`cloudInit.writeFiles`.** Every other structured shortcut is a scalar; a set of files with
  paths, permissions and encodings is a different shape, and `runcmd` covers the same ground until
  it exists.
- **Undoing a seed.** Switching a machine back to `native` leaves what cloud-init already did in
  place. The volume is the machine, and a backend switch is not a licence to edit it.

## Capabilities

### New Capabilities

- `guest-provisioning`: the backend a machine selects, the inline-or-reference contract every
  provisioning input takes, how those inputs reach the machine without passing through the guest
  container, what the cloud-init backend writes into the machine and when it re-applies, and the
  refusal to provision an image that cannot run the backend it named.

### Modified Capabilities

- `values-validation`: the provisioning inputs gain their own render-time refusals — an input that
  is both inline and referenced, a `valueFrom` naming more than one source, an input belonging to a
  backend the machine did not select, an unrecognised backend, an unknown key under `cloudInit`.
- `machine-topology`: the pod gains a fourth init container and a projected volume, with the
  requirement that provisioning material reaches the init container and never the guest.
- `distro-presets`: which backends a preset can serve becomes a property the catalog documents,
  because a preset whose upstream ships no cloud variant cannot serve the default one.

## Impact

- **Chart**: `templates/_helpers.tpl` (the value-source resolution, the projected volume, the
  provisioning environment, the new validation), `templates/statefulset.yaml` (the `provision` init
  container, the volume, the `checksum/provisioning` annotation), a new
  `templates/provisioning-secret.yaml`, `templates/NOTES.txt`, `values.yaml`, `examples/`.
- **Shim image**: a new `provision.sh` entry point and `lib-provision.sh`, and the executable bit
  for it in the `Containerfile`. The change reaches a user only when the image is published and the
  digest in `values.yaml` moves to it.
- **Tests**: new `helm unittest` suites for the inputs, the volume and the refusals; a new
  `test/shell/provision.bats` for what the init container writes and what it refuses; and
  `hack/integration-test.sh` gains both halves — a machine provisioned from user-data with a real
  SSH key, and a machine whose image cannot run cloud-init failing the pod with the message the
  design demands.
- **Documentation**: `README.md`, `charts/stateful-pods/README.md`, `values.yaml`. The Void preset
  needs its `native` requirement stated everywhere a preset is chosen, because the alternative is
  meeting it as a crash loop.
