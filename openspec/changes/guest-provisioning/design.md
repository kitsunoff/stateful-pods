## Context

See [proposal.md](proposal.md) for motivation. The mechanism is not being designed here — it was
settled in [`docs/research/06-guest-provisioning.md`](../../../docs/research/06-guest-provisioning.md),
[`07-provisioning-inputs.md`](../../../docs/research/07-provisioning-inputs.md) and
[`05-open-questions.md`](../../../docs/research/05-open-questions.md) §0 and §5a. This document
records how those decisions become templates and scripts, and every place where the implementation
departs from what the research documents wrote.

The constraints that shape it:

- **The chart's containers never execute the guest's programs** (`shim-image`). Everything below is
  file manipulation from the outside, which is why "is cloud-init installed" can only be answered by
  reading the seeded root filesystem and never by running anything in it.
- **Helm cannot read a Secret it does not own.** `lookup` would break `helm template`, `--dry-run`
  and every GitOps diff, so anything derived from provisioning content has to be derived at boot.
- **The values are already fleet-shaped.** Every helper takes an explicit machine context, so the
  new ones do too.
- **The pod already runs three init containers** — `seed`, `prepare`, `customize` — each on the
  shim image, each mounting the rootfs volume, all under the runtime's default syscall filter.

### What the images actually contain

Read out of the published presets rather than assumed, because the whole fail-loud requirement turns
on it:

| | `debian-trixie` / `ubuntu-noble` | `alpine-3.24` | `void-current` |
| --- | --- | --- | --- |
| Program | `/usr/bin/cloud-init` | `/usr/bin/cloud-init` | absent |
| Init integration | `/usr/lib/systemd/system/cloud-init-*.service`, plus a generator at `/usr/lib/systemd/system-generators/cloud-init-generator` and `ds-identify` at `/usr/lib/cloud-init/ds-identify` | `/etc/init.d/cloud-init{,-local,-config,-final}`, already linked into the `boot` and `default` runlevels | absent |
| Disabled marker | `/etc/cloud/cloud-init.disabled`, empty | same | n/a |

The marker is the single gate on both init systems, and it is checked in two different ways. On
systemd every unit carries `ConditionPathExists=!/etc/cloud/cloud-init.disabled`, and the generator
stops before `ds-identify` runs at all. On Alpine each OpenRC script tests the file by hand and warns
instead of starting. Either way, **a seed written while the marker is in place does nothing**, which
is why removing it is part of what writing a seed means rather than a separate feature.

## Goals / Non-Goals

Goals beyond the proposal's:

- One code path for inline and referenced material. The script that writes into the machine must not
  be able to tell which form an input arrived in.
- No YAML parser in the shim. The image has `jq` and busybox; teaching it to read YAML in order to
  merge a user's cloud-config is exactly the misfeature the per-file replacement rule exists to
  avoid.
- The layer-0 behaviour is identical under both backends. A user who starts on `native` and moves to
  `cloud-init` must not find that the hostname handling changed underneath them.

Non-goals at the design level:

- Live reconfiguration without a restart. That is the LXD `devlxd` model, and it means shipping an
  agent and a socket.
- Reading the PVC UID for clone detection. It needs API access and RBAC; namespace + release +
  machine name is available through what the pod already has.

## Decisions

### 1. A fourth init container, `provision`, running last

The step runs after `customize`, on the shim image, mounting the rootfs volume and — only it — the
provisioning volume.

Its own container rather than the tail of `customize` for two reasons. `customize` writes the three
files the chart maintains on every boot and is mounted nowhere sensitive; giving it the provisioning
material would put a Secret's contents into a container that has no use for them. And a failure in
provisioning should be legible as a failure in provisioning: the fail-loud message is the headline
feature of this change, and `kubectl logs pod -c provision` is where someone will look for it.

Last rather than first because the seed has to exist before it can be inspected and written into,
and because the drop-in it writes is about files `customize` has already placed.

The container is rendered under both backends. Under `native` it logs one line and exits. A pod whose
shape changes when a backend changes would make a backend switch a rolling replacement of a different
kind of pod, and the log line is what tells someone reading the logs that the chart deliberately did
nothing.

### 2. The value-source shape, and where it is resolved

```yaml
<input>:
  value: |
    inline content
  valueFrom:
    secretKeyRef: {name: …, key: …}
    configMapKeyRef: {name: …, key: …}
```

Modelled on `EnvVarSource` because every Kubernetes user already knows it. Resolution happens in the
pod spec, not in a script:

- every `value` is collected into one chart-owned Secret, `<release>-<machine>-provisioning`;
- every `valueFrom` becomes one source of a projected volume, mapping its key to the file name the
  input is defined to use;
- the chart-owned Secret is another source of the same projected volume.

The projected volume is mounted at `/provisioning` in the `provision` container and nowhere else. The
script reads `/provisioning/<name>` and cannot tell the two forms apart, which is what makes "inline
or reference" a property of the values rather than a branch in the code.

**Alternative rejected:** rendering everything into the chart-owned Secret and having the init
container fetch referenced Secrets itself. That needs a ServiceAccount token, RBAC on Secrets, and an
API client in the shim image, to do worse what a projected volume does natively.

`optional` is deliberately not exposed. Doc 07 §10 asks whether it is useful; the answer here is that
it converts a clear pod-start failure into a half-provisioned guest, which is the same class of
outcome as the silent no-op this change exists to prevent. A missing Secret stops the pod.

### 3. Structured shortcuts are composed at boot, not at render time

Doc 07 §4.2 says the chart "renders" the structured shortcuts into user-data. It cannot: `user` may
be a reference. So the composition happens in the `provision` container, from the materialized files,
and the seed's `user-data` is what the composition produced.

This is not a deviation in substance — §5 of the same document already moves the `instance-id`
computation into the init container for exactly this reason, and the composition has to be on the
same side of that line as the hash.

Composition is done with `jq`, emitting JSON. A cloud-config document may be JSON: YAML is a superset
of it and cloud-init parses with `yaml.safe_load`. That removes every quoting question — a password
hash containing `$`, a key with a comment, a `runcmd` line with a colon — which is otherwise the way
a generated YAML document silently becomes a different document.

### 4. List-valued inputs are newline-separated, not YAML fragments

Doc 07 §9's example shows `packages` as a YAML list inside a block scalar. This implementation takes
one item per line instead:

```yaml
packages:
  value: |
    htop
    tmux
```

**Deviation, argued rather than assumed.** A YAML fragment cannot be turned into JSON without a YAML
parser in the shim image, which decision 3 rules out. Newline separation is also what §4.1 already
specifies for `authorizedKeys` ("newline-separated public keys"), so it makes the three list-valued
inputs — `sshAuthorizedKeys`, `packages`, `runcmd` — one shape rather than two. And it cannot be
broken by indentation, which is a real failure mode when the same content has to survive a round trip
through a Secret written by something else.

The escape hatch is unaffected: anyone who wants a cloud-config the chart did not compose supplies
`userData` and gets it verbatim.

### 5. `instance-id` is computed from the seed, after it is written

```text
instance-id = sha1( user-data ‖ network-config ‖ vendor-data ‖ namespace/release/machine )
```

Computed over the files as they were placed in the seed directory — the composed `user-data`, not
its ingredients — so that it reflects what the guest will actually be configured with. `meta-data` is
written last, since it carries the result.

**Deviation from doc 07 §5:** the identity seed is not a file at `/provisioning/identity-seed`. It is
composed in the script from `SP_NAMESPACE`, `SP_RELEASE` and `SP_MACHINE`, which the pod already
supplies to every step through the downward API and the existing seeding environment. The value is
identical; a projected file carrying it would be a fourth way to say what three environment variables
already say, and it would have to be rendered even for a machine that supplies nothing.

### 6. The fail-loud check

Under the cloud-init backend, before anything is written:

1. the program must exist in the seeded root filesystem, at any of `usr/bin`, `bin`, `usr/sbin`,
   `sbin`, `usr/local/bin`;
2. an init-system integration must exist — a `cloud-init-main.service`, `cloud-init-local.service` or
   `cloud-init.target` under `usr/lib/systemd/system` or `lib/systemd/system`, or an
   `/etc/init.d/cloud-init-local`.

Either missing fails the pod. The message states what was looked for, which root filesystem it looked
in, and that `machines.<name>.guest.provisioning: native` is the fix.

Then, and only then, `/etc/cloud/cloud-init.disabled` is removed. Removing it is not a third check —
it is the act that makes the seed readable at all, and doing it after the two checks means an image
that fails them is left exactly as it was.

**What is deliberately not checked:** whether the units are enabled, whether a runlevel link exists,
whether the generator would find `ds-identify`. Those have several valid shapes per distribution and
per cloud-init version — the systemd path went from a generator to a socket-activated single process
within one release series — and a check that guessed wrong would refuse an image that works. The two
above are the ones that are true of every image that can run cloud-init and false of every image that
cannot, and both real cases behind them were read out of the published presets rather than assumed.

**Alternative rejected:** running `cloud-init --version` in the guest root with `chroot`. It executes
the guest's programs, which the `shim-image` capability forbids and which cannot work at all when the
guest is built for another architecture.

### 7. The drop-in

`/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg`, rewritten on every start:

```yaml
datasource_list: [NoCloud, None]
network: {config: disabled}
preserve_hostname: true
manage_etc_hosts: false
growpart: {mode: "off"}
resize_rootfs: false
```

The first four are doc 06 §5 verbatim. The last two are an addition: the same section's table says
`growpart`, `resizefs` and `disk_setup` "must not run" because the rootfs is a bind-mounted volume
and not a partitioned block device, but the snippet beside the table does not switch them off. These
two settings are the supported way to do it without rewriting the module list, which would be a
per-distribution fight with `cloud.cfg`.

`99-` so it sorts after everything a distribution ships, and the file is the chart's rather than
merged into `cloud.cfg`, so nothing the chart owns is entangled with what the image owns.

### 8. `native` is layer 0, and it is not a demolition tool

`native` writes nothing and removes nothing. In particular it does not delete a seed a previous
`cloud-init` install left behind, and it does not put the disabled marker back.

The volume is the machine. A value change that silently edited a running machine's `/etc` and
`/var/lib` would be a chart that destroys state on a typo. Switching to `native` means "stop managing
this", and it is documented as exactly that.

### 9. Restart on change

The chart hashes the chart-owned Secret into a `checksum/provisioning` pod annotation, so inline
material restarts the machine on upgrade. Referenced material cannot be hashed, so
`machines.<name>.guest.provisioningRevision` is folded into the same annotation: it is the pure-Helm
answer from doc 07 §7, and the two alternatives — a Reloader-style controller, or
`kubectl rollout restart` — are documented rather than built.

## Risks / Trade-offs

**The default breaks a Void machine that declares nothing** → This is the settled decision, and it is
the one that makes the default mean something: the alternative is a machine that installs cleanly and
has no way in. It is mitigated only by documentation, and the documentation has to be at the point of
use — `values.yaml` beside the preset input, the preset table in both READMEs, and the upgrade note —
because the failure otherwise arrives as a crash loop.

**The fail-loud check could refuse an image that works** → The two conditions are as weak as they can
be while still being false for an image with no cloud-init. Both were verified against the four
presets. If a real image is ever refused, the message names the paths it searched, which is the
information needed to widen the check.

**A cloud-config the chart composes is not a cloud-config the user wrote** → Mitigated by the
`userData` escape hatch and by the shadowing warning. The composed document is deliberately small:
a default user, a password, keys, packages, commands, and nothing clever.

**Provisioning material persists to the volume and appears in snapshots** → Accepted, not mitigated,
by doc 07 §6. cloud-init copies user-data onto the volume itself, so hiding the seed would hide
nothing. The values file says to put a crypt(3) hash in `password` and says why.

**The material is in the Helm release when supplied inline** → A property of Helm, not of this chart,
and the reason the reference form exists. Stated in `values.yaml` beside the input rather than left
for someone to discover.

## Migration Plan

1. The shim image is built and published, and `values.yaml` moves to its digest. Nothing in this
   change reaches a user before that: the templates render a container whose command lives in the
   image.
2. A machine that already exists and declares no backend gets `cloud-init` on its next start. On the
   three cloud presets it is provisioned, from an empty configuration, and boots. On `void-current`,
   or on any image without cloud-init, **the pod fails and says so**. The upgrade note names this as
   the break, and names `guest.provisioning: native` as the one-line fix.
3. Rollback is a chart downgrade. The seed left in the machine is inert without the drop-in, and
   `cloud-init.disabled` having been removed only means the guest's own cloud-init runs and finds
   nothing to do — the state doc 06's own experiments describe as clean.

## Open Questions

- Whether `native` should eventually own the `rootPassword` / `authorizedKeys` / `sshHostKeys` inputs
  of doc 07 §4.1, or whether the answer for an image without cloud-init is `systemd-credentials`.
  Deferring it does not change anything here: both would use the input contract this change
  establishes.
- Whether `cloudInit.instanceId` is worth exposing as an escape hatch, per doc 05 §5a's open item
  about re-apply-on-change and regenerate-on-clone being coupled. Nobody has yet wanted a
  byte-identical clone.
