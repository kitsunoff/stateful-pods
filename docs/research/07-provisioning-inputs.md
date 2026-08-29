# Provisioning inputs: the inline / secret-reference contract

[06](06-guest-provisioning.md) describes *which* provisioning mechanisms exist. This document
specifies *how the user supplies data to them*.

## 1. The rule

**Every provisioning input, in every backend, is expressible in two ways: inline in values, or as a
reference to a Secret or ConfigMap.** There is no input that is inline-only, and none that is
reference-only. The shape is identical everywhere, so learning it once is enough.

This is not a convenience feature. It is what makes the chart usable in the two deployment styles
that actually exist:

- **Inline** — a self-contained release, one `values.yaml`, easy to read and to hand to someone.
  Right for lab machines, demos, and anything non-sensitive.
- **Reference** — the material lives in a Secret managed by External Secrets, SOPS, Vault, or a
  sealed-secrets controller, and never appears in the values file or in the Helm release object.
  Mandatory for anything with a password or a private key in a GitOps repository.

## 2. The value source type

Modelled on `EnvVarSource`, because every Kubernetes user already knows it:

```yaml
<field>:
  # exactly one of the following
  value: |
    inline content
  valueFrom:
    secretKeyRef:
      name: my-secret
      key: user-data
      optional: false
    configMapKeyRef:
      name: my-configmap
      key: user-data
      optional: false
```

Rules:

- `value` and `valueFrom` are mutually exclusive. Supplying both fails template rendering with an
  explicit message rather than silently picking one.
- `optional: true` means a missing Secret/ConfigMap or key yields empty content instead of blocking
  pod start. Default `false`.
- ConfigMap is accepted everywhere Secret is, because forcing non-sensitive material (a
  `network-config`, a list of packages) into a Secret is pointless friction. The chart does not try
  to guess sensitivity.

For inputs that are naturally a *set* of files rather than one value — systemd credentials, files
to write into the rootfs, SSH host keys — a whole-object form is also accepted:

```yaml
<field>:
  valueFrom:
    secretRef:
      name: my-secret        # every key becomes a file named after the key
      optional: false
    configMapRef:
      name: my-configmap
```

## 3. How it is materialized

One **projected volume** assembles everything into a single directory with deterministic
filenames, mounted **only into the init containers** — never into the guest container.

```yaml
volumes:
  - name: provisioning
    projected:
      defaultMode: 0400
      sources:
        # 1. everything given inline, rendered into a chart-owned Secret
        - secret:
            name: <release>-provisioning
            items: [...]
        # 2. one source per referenced Secret / ConfigMap
        - secret:
            name: my-secret
            items:
              - key: user-data
                path: user-data
            optional: false
```

The init container therefore reads fixed paths and never needs to know where a value came from,
never needs API access, and never needs a ServiceAccount token:

```text
/provisioning/user-data
/provisioning/network-config
/provisioning/vendor-data
/provisioning/root-password
/provisioning/authorized-keys
/provisioning/ssh-host-keys/<type>
/provisioning/credentials/<name>
/provisioning/files/<encoded-path>
```

Two consequences worth noting:

- **Path collisions are the chart's responsibility.** A projected volume whose sources map two keys
  to the same path is rejected by the kubelet. Since each field has exactly one source, the chart
  can guarantee uniqueness at render time.
- `meta-data` is deliberately absent from the list. It is generated at boot, not supplied — see §5.

## 4. What each backend accepts

Everything in the "Input" column takes the §2 shape.

### 4.1 `native`

| Input | Content |
| --- | --- |
| `rootPassword` | crypt(3) hash, or plaintext with `hashed: false` |
| `authorizedKeys` | newline-separated public keys for root |
| `sshHostKeys` | pre-generated host keys; omitted means generate at first boot |
| `machineId` | pinned `/etc/machine-id`; omitted means generate |
| `files` | set of files to write into the rootfs at first boot |
| `firstBootScript` | script run once inside the rootfs after seeding |

### 4.2 `cloud-init`

| Input | Content |
| --- | --- |
| `userData` | raw `#cloud-config` or any cloud-init user-data format |
| `networkConfig` | raw network config — see the warning in [06](06-guest-provisioning.md) §5 |
| `vendorData` | raw vendor-data |
| `user`, `password`, `sshAuthorizedKeys`, `packages`, `runcmd`, `writeFiles` | structured shortcuts the chart renders into user-data |

**Raw beats structured, per file.** If `userData` is supplied, the structured shortcuts for
user-data are ignored entirely — the chart does not attempt a merge. This copies Proxmox's
`cicustom` semantics exactly (`PVE::QemuServer::Cloudinit::generate_nocloud`):

```perl
my ($user_data, $network_data, $meta_data, $vendor_data) = get_custom_cloudinit_files($conf);
$user_data    = cloudinit_userdata($conf, $vmid) if !defined($user_data);
$network_data = nocloud_network($conf)          if !defined($network_data);
```

Per-file replacement, no merging. It is predictable, and a YAML-merge of two cloud-configs is a
misfeature waiting to happen. The chart should print a NOTES warning when a raw file shadows
structured values, because silently ignoring half the values file is a bad surprise.

### 4.3 `systemd-credentials`

| Input | Content |
| --- | --- |
| `credentials` | map of credential name → value, or a whole-Secret reference |

Names are passed through verbatim, so the guest's own units can consume them with
`ImportCredential=`/`LoadCredential=`, and systemd's own consumers work unchanged:
`passwd.hashed-password.root`, `firstboot.locale`, `firstboot.timezone`, `ssh.authorized_keys.root`,
`tmpfiles.extra`.

This backend has a property the other two do not: **credentials never touch the PVC.** They are
projected into `/run/host/credentials`, which is a tmpfs. See §6.

## 5. Consequence: `instance-id` must be computed at boot, not at render time

[06](06-guest-provisioning.md) §4 proposed deriving the cloud-init `instance-id` from a hash of the
rendered config, following Proxmox. With reference-sourced inputs that is impossible: Helm cannot
read the content of a Secret it does not own. Using `lookup` would break `helm template`, `--dry-run`,
and every GitOps diff.

**Resolution: the init container computes it, from the files it actually materialized.**

```sh
instance_id=$(cat /provisioning/user-data \
                  /provisioning/network-config \
                  /provisioning/vendor-data \
                  /provisioning/identity-seed 2>/dev/null | sha1sum | cut -c1-40)
printf 'instance-id: %s\n' "$instance_id" > /mnt/rootfs/var/lib/cloud/seed/nocloud/meta-data
```

This is strictly better than the render-time version: it is uniform across inline and referenced
inputs, and it reflects what the guest will actually be configured with rather than what Helm
thought it would be.

### 5.1 The identity seed

Doc 06 suggested mixing in the PVC UID so that a snapshot restored into a new PVC is treated as a
new instance. The init container cannot read the PVC UID without API access and RBAC. A better
value is available for free through the downward API: **namespace + release + machine name**.

The machine name must be in there from the first version even while only one machine per release is
supported ([05](05-open-questions.md) §1). Once a release can hold several machines, a seed of just
namespace + release would give every machine in the release the same identity — the same
`machine-id` and the same SSH host keys — which is the exact failure the seed exists to prevent.
Adding the component later would change the identity of every already-deployed machine on its next
boot, regenerating host keys under running clients.

Check it against the two cases that matter:

| Scenario | Identity seed | Result | Correct? |
| --- | --- | --- | --- |
| Restore a snapshot into the same release (disaster recovery) | unchanged | same machine-id, same SSH host keys | yes — it is the same machine |
| Clone into a new release ("give me a copy of prod") | changed | new machine-id, new host keys | yes — it is a different machine |

That is exactly the desired behaviour, with no API access, no ServiceAccount and no RBAC. The PVC
UID remains available as an opt-in for anyone who wants clone detection to survive a rename, at the
cost of granting the init container `get` on its own PVC.

## 6. Secrets hygiene: where the material ends up

The three backends differ materially here, and users should be able to choose on this basis.

| Backend | Material written into the PVC? |
| --- | --- |
| `native` | password hash and authorized_keys land in `/etc/shadow` and `~/.ssh` — i.e. in the guest, as intended |
| `cloud-init` | yes — the seed in `/var/lib/cloud/seed/nocloud/`, **and** cloud-init's own copy in `/var/lib/cloud/instances/<iid>/user-data.txt` |
| `systemd-credentials` | no — `/run/host/credentials` is tmpfs |

**Decision: accepted, not mitigated.** The seed persists to the volume and appears in snapshots.
This is normal and the chart will not fight it.

An earlier draft of this document proposed mounting a tmpfs over `/var/lib/cloud/seed` so the seed
would never touch disk. That does not work, and it is worth recording why so nobody tries it again:
**cloud-init copies user-data onto the persistent volume by itself**, regardless of where the seed
came from. `Init.update()` in `cloudinit/stages.py`:

```python
def update(self):
    self._store_rawdata(self.ds.get_userdata_raw(), "userdata")
    self._store_processeddata(self.ds.get_userdata(), "userdata")
    ...

def _store_rawdata(self, data, datasource):
    util.write_file(self._get_ipath("%s_raw" % datasource), data, 0o600)
```

The lookup table in `cloudinit/helpers.py` resolves `userdata_raw` to `user-data.txt` inside
`/var/lib/cloud/instances/<instance-id>/`, which is on the PVC because the per-instance semaphores
of [06](06-guest-provisioning.md) §4 have to live there. The same directory also holds
`instance-data-sensitive.json`, which the table's own comment describes as containing
"security-sensitive key values". Hiding the seed would have hidden nothing.

This is also how every cloud VM already behaves — user-data is readable inside the instance for its
whole life — and how Proxmox behaves for VMs, where the cloud-init drive is an ordinary disk on
storage and is included in backups. A design that faithfully copies Proxmox lands here by
construction.

Practical guidance instead of machinery:

- Put a **crypt(3) hash** in `password`, never a plaintext one. This is what `cipassword` users do
  anyway, and a hash on the volume is the same exposure as `/etc/shadow` — which is unavoidable.
- If material genuinely must never reach the disk, use the **`systemd-credentials`** backend. That
  is the reason it exists, and it is a better answer than a tmpfs trick that does not hold.
- Snapshot and backup handling for these volumes should assume the volume contains credentials,
  because it does — via `/etc/shadow` on any backend, not only via cloud-init.

Regardless of backend, the values file must warn that **inline sensitive material is stored in the
Helm release Secret** and in whatever repository holds the values. That is a property of Helm, not
of this chart, but it is the reason the reference form exists.

## 7. Consequence: change detection differs between the two forms

| Input form | Chart can hash it? | Restart on change |
| --- | --- | --- |
| Inline | yes — it renders the chart-owned Secret | automatic, via a `checksum/provisioning` pod annotation |
| Reference | no | **not automatic** |

For referenced Secrets the chart cannot see the content, so a rotated Secret produces no pod
restart. Three honest answers, all of which should be documented rather than one being pretended
away:

1. Run a controller that does this properly — Reloader watches referenced Secrets and restarts the
   workload.
2. `kubectl rollout restart` after rotating.
3. Bump an explicit `provisioning.revision` value, which the chart folds into the pod annotation.
   Crude, but it works in a pure-Helm workflow with no extra controller.

Note that once a restart *does* happen, the change applies correctly regardless of origin, because
§5 recomputes the instance-id from the materialized files. The gap is purely in *triggering* the
restart, not in applying the change.

## 8. Validation the chart must perform at render time

Failing loudly in `helm template` is much better than failing in a CrashLoopBackOff:

- `value` and `valueFrom` both set on the same field → error naming the field.
- More than one of `secretKeyRef` / `configMapKeyRef` / `secretRef` / `configMapRef` under a single
  `valueFrom` → error.
- Whole-object form (`secretRef`) used on a field that expects a single value → error.
- A backend-specific input supplied while a different backend is selected → error, not silent
  ignore. Supplying `cloudInit.userData` with `provisioning: native` is a mistake worth catching.
- Two inputs resolving to the same projected path → error.
- `sshHostKeys` supplied without the matching public keys, or with an unrecognised key type → error.

## 9. Worked example

Both forms, side by side, doing the same thing.

Inline:

```yaml
guest:
  provisioning: cloud-init

cloudInit:
  user:
    value: maxim
  sshAuthorizedKeys:
    value: |
      ssh-ed25519 AAAAC3Nz... maxim@workstation
  packages:
    value: |
      - htop
      - tmux
```

Referenced:

```yaml
guest:
  provisioning: cloud-init

cloudInit:
  user:
    valueFrom:
      configMapKeyRef:
        name: machine-config
        key: username
  sshAuthorizedKeys:
    valueFrom:
      secretKeyRef:
        name: machine-secrets
        key: authorized_keys
  packages:
    valueFrom:
      configMapKeyRef:
        name: machine-config
        key: packages
```

Mixed, which must also work — the two forms are per field, not per release:

```yaml
cloudInit:
  user:
    value: maxim                    # not sensitive, inline is fine
  password:
    valueFrom:
      secretKeyRef:                 # sensitive, never in git
        name: machine-secrets
        key: root-password-hash
  userData:
    valueFrom:
      secretKeyRef:                 # raw escape hatch, shadows the structured fields above
        name: machine-secrets
        key: user-data
```

The third example also illustrates the §4.2 precedence trap: `userData` shadows `user` and
`password`, and the chart should say so in NOTES rather than letting the user wonder why the
password did not apply.

## 10. Open items

- Should `native.files` and `cloudInit.writeFiles` be the same input, rendered differently per
  backend? They express the same intent and duplicating them is a values-surface smell.
- Whole-Secret projection (`secretRef`) makes filenames depend on Secret keys, so a key with a
  slash or an unfortunate name can break the projection. Is a key-name allowlist needed, or is
  failing at pod start acceptable?
- Is `optional: true` genuinely useful, or does it just convert a clear render-time failure into a
  confusing half-provisioned guest?
