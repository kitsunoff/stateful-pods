# Guest provisioning: cloud-init and the alternatives

Doc [01](01-proxmox-lxc-boot.md) covers how Proxmox customizes a container. This document covers
the standard, guest-cooperative provisioning mechanisms — cloud-init first — and how they fit the
architecture from [03](03-mapping-and-architecture.md).

## 1. Where Proxmox actually stands

A fact worth stating plainly, because it shapes everything below:

```console
$ grep -rni "cloud.init\|cloudinit" pve-container-master/src/
$ echo $?
1
```

**Proxmox LXC containers have no cloud-init support at all.** Guest customization for containers is
entirely `PVE::LXC::Setup` and its per-distro plugins. Cloud-init in Proxmox exists only for QEMU
VMs, in `qemu-server`'s `PVE::QemuServer::Cloudinit`, where it is exposed as `citype`
(`nocloud` / `configdrive2` / `opennebula`), `ciuser`, `cipassword`, `sshkeys`, `ipconfigN`,
`nameserver`, `searchdomain`, `ciupgrade` and `cicustom`.

So "Proxmox-style containers **with** cloud-init" is a combination Proxmox itself does not ship. It
is a genuine addition, not a re-implementation — and the two mechanisms overlap, so the division of
labour has to be designed rather than assumed.

## 2. Does cloud-init work inside a container?

Yes. Verified in the cloud-init source:

- **`ds-identify` does not exclude containers from NoCloud.** `dscheck_NoCloud()` checks the seed
  directories *first*, before any DMI or block-device probing:

  ```sh
  for d in nocloud nocloud-net; do
      check_seed_dir "$d" meta-data user-data && return ${DS_FOUND}
      check_writable_seed_dir "$d" meta-data user-data && return ${DS_FOUND}
  done
  ```

  `is_container()` only suppresses DMI reads, kernel-cmdline reads, `blkid` probing
  (`DI_FS_LABELS="$UNAVAILABLE:container"`) and the cloud-platform datasources (EC2, Azure, GCE…).

- **The systemd units have no container condition.** `cloud-init-local.service` and
  `cloud-init-main.service` gate only on `ConditionPathExists=!/etc/cloud/cloud-init.disabled` and
  the `cloud-init=disabled` kernel argument. The systemd generator reads `$container` into a
  variable and does nothing with it.

- **Production proof:** cloud-init ships `DataSourceLXD.py`, and LXD/Incus expose
  `cloud-init.user-data` as a first-class config key for *containers*, not just VMs.

The catch is §6: in a Kubernetes pod there is nothing that tells the guest it is a container, so
`is_container()` returns false unless we fix it.

## 3. The mechanism: a NoCloud seed directory

From `cloudinit/sources/DataSourceNoCloud.py`:

```python
self.seed_dirs = [
    os.path.join(paths.seed_dir, "nocloud"),
    os.path.join(paths.seed_dir, "nocloud-net"),
]
...
pp2d_kwargs = {
    "required": ["user-data", "meta-data"],
    "optional": ["vendor-data", "network-config"],
}
```

`paths.seed_dir` is `/var/lib/cloud/seed`. So the entire integration is:

```text
/var/lib/cloud/seed/nocloud/meta-data       (required)
/var/lib/cloud/seed/nocloud/user-data       (required)
/var/lib/cloud/seed/nocloud/network-config  (optional)
/var/lib/cloud/seed/nocloud/vendor-data     (optional)
```

Four files written into the PVC by an init container. That is the whole thing.

This matters more than it looks: the usual NoCloud delivery is a `cidata`-labelled vfat/iso9660
image attached as a block device. In a Kubernetes pod that would require a raw block volume — and
`volumeDevices` is **forbidden entirely** in user-namespaced pods (see
[02](02-kubernetes-primitives.md) §5). The seed-directory form has no such problem and needs no
privileges at all.

The files can come from a Secret or ConfigMap mounted into the init container and copied into the
PVC, which keeps `cipassword`-equivalent material out of the pod spec.

## 4. `instance-id`: cloud-init already implements our clone semantics

This is the most valuable finding in this document.

`Init._reflect_cur_instance()` in `cloudinit/stages.py` writes `/var/lib/cloud/data/instance-id`
and `previous-instance-id`, and points the `/var/lib/cloud/instance` symlink at
`/var/lib/cloud/instances/<instance-id>/`. Module semaphores live under that directory, so:

| Frequency | Semaphore location | Re-runs when |
| --- | --- | --- |
| `per-once` | `/var/lib/cloud/sem/` | never again |
| `per-instance` | `/var/lib/cloud/instances/<iid>/sem/` | **`instance-id` changes** |
| `per-boot` | not persisted | every boot |

So whoever controls `instance-id` controls re-provisioning. Proxmox exploits this for VMs
(`PVE::QemuServer::Cloudinit`):

```perl
sub nocloud_gen_metadata {
    my ($user, $network) = @_;
    my $uuid_str = Digest::SHA::sha1_hex($user . $network);
    return nocloud_metadata($uuid_str);
}
```

The instance-id is a **hash of the generated cloud-init config**. Change `ciuser`, `sshkeys` or
`ipconfig0`, and the instance-id changes, and cloud-init re-runs every per-instance module on the
next boot. That is how Proxmox makes cloud-init config declarative without any agent.

**Proposed refinement.** Derive the instance-id from the config *and* an identity seed:

```text
instance-id = sha1(user-data ‖ network-config ‖ vendor-data ‖ identity-seed)
```

This gives both behaviours at once:

- Config changed → new instance-id → cloud-init re-applies on the next pod restart.
- Pod restarted with no config change → same instance-id → nothing re-runs.
- Cloned into a different release → new identity seed → new instance-id → users, SSH host keys and
  per-instance state are regenerated.

The last row solves the clone-identity problem from [03](03-mapping-and-architecture.md) §4.5 for
free, with no hand-written detection heuristic.

Two details are settled in [07](07-provisioning-inputs.md) rather than here, because they follow
from the input contract: the hash must be computed **by the init container at boot**, not by Helm
at render time (Helm cannot read a Secret it does not own), and the identity seed is
**namespace + release + machine name** rather than the PVC UID, which would require API access. See
[07](07-provisioning-inputs.md) §5.

Note the deliberate asymmetry with the rootfs seeding marker: the *rootfs* is seeded once and never
again (upgrade policy `Never`), while the *cloud-init config* is reconciled on every restart. Those
are different lifecycles and should not share a marker.

## 5. Division of labour, and where the two will fight

cloud-init and the chart's own pre-start hook both want to own parts of `/etc`. Left alone they
will overwrite each other, or worse, break pod networking.

| Concern | Owner | Why |
| --- | --- | --- |
| `container=` marker, `/run/host/*` | **chart shim** | must exist before init starts; see §6 |
| `/etc/hostname`, `/etc/hosts` | **chart** (layer 0) | kubelet is authoritative; set `preserve_hostname: true` and `manage_etc_hosts: false` in the drop-in |
| `/etc/resolv.conf` | **chart** (layer 0) | the pod's DNS policy is authoritative; cloud-init's `manage_resolv_conf` must stay off (it is off by default) |
| Network interface config | **neither — disable both** | CNI has already configured `eth0` before any container starts |
| Users, groups, passwords | cloud-init | this is the value |
| `ssh_authorized_keys`, host keys | cloud-init (`cc_ssh`) | replaces the hand-rolled key generation |
| `write_files`, `runcmd`, `bootcmd` | cloud-init | this is the value |
| `package_update` / `package_upgrade` | cloud-init, opt-in | Proxmox defaults `ciupgrade: true`; on a container that is a slow first boot |
| `disk_setup`, `growpart`, `resizefs`, `mounts` | **must not run** | the rootfs is a bind-mounted PVC, not a partitioned block device |

The network row is the dangerous one. If cloud-init writes a netplan or `ENI` config for `eth0` and
anything applies it, the pod loses the address the CNI assigned. This is the exact inverse of
Proxmox, where writing `/etc/network/interfaces` is the *point* of `setup_network()`. Here the
correct action is to **disable network management entirely**.

Concretely, the chart writes a drop-in at `/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg`:

```yaml
datasource_list: [NoCloud, None]
network:
  config: disabled
preserve_hostname: true
manage_etc_hosts: false
```

## 6. What the shim must do regardless of cloud-init

A Kubernetes pod has **no** `/.dockerenv` and **no** `/run/.containerenv` — those are Docker and
Podman conventions, and containerd's CRI writes neither. From systemd's `detect_container()`
(`src/basic/virt.c`):

```c
if (getpid_cached() == 1) {
        /* If we are PID 1 we can just check our own environment variable,
         * and that's authoritative. */
        e = getenv("container");
        if (!e)
                goto check_files;
        ...
}
```

`check_files` then looks only for `/run/.containerenv` and `/.dockerenv`. So without intervention
**systemd inside the pod concludes it is running on bare metal**, and will try to behave
accordingly — udev, module loading, fsck, mounting `/sys/fs/cgroup` itself. Cloud-init's
`is_container()` is equally blind, so it will probe DMI and block devices that are not there.

The shim must therefore, before `exec /sbin/init`:

1. Set `container=lxc` in the environment of the exec'd init. Accepted values in systemd's
   `container_table[]` are `lxc`, `lxc-libvirt`, `systemd-nspawn`, `docker`, `podman`, `rkt`,
   `wsl`, `proot`, `pouch`; anything else is reported as `container-other`. `lxc` is the honest
   choice for this architecture and is what cloud-init's `is_container()` recognises.
2. Optionally populate the `/run/host/` hierarchy, which systemd documents as the
   privilege-free alternative:

   | Path | Contents |
   | --- | --- |
   | `/run/host/container-manager` | same value as `$container` |
   | `/run/host/container-uuid` | same value as `$container_uuid` |
   | `/run/host/os-release` | the *host's* `/etc/os-release` |
   | `/run/host/credentials/` | see §7 |

3. Use `SIGRTMIN+3` for shutdown, which the same document confirms is the clean-shutdown signal for
   a container-managed systemd — matching [02](02-kubernetes-primitives.md) §7.

This is required work for any systemd guest, cloud-init or not, and it is cheap. It should not be
optional.

## 7. The systemd-native alternative to cloud-init

For systemd guests there is a lighter path that needs no extra package in the image.

- **System credentials.** systemd's container interface states that the credential directory path
  is passed via `$CREDENTIALS_DIRECTORY` and that *"the container manager can choose any path, but
  `/run/host/credentials` is recommended"*. Units then consume them with `ImportCredential=` or
  `LoadCredential=`. A Kubernetes Secret mounted at that path is a direct, idiomatic fit — and
  unlike cloud-init user-data, the material never has to be written into the PVC at all.
- **`ConditionFirstBoot=yes`**, which fires when `/etc/machine-id` is uninitialised. This is the
  same trigger Proxmox uses: `clear_machine_id()` at create and clone time, plus its own
  `proxmox-regenerate-snakeoil.service` with `ConditionFirstBoot=yes`. Our provisioning step
  clearing machine-id gives the guest a real first boot for free.
- **`systemd-firstboot`** consumes credentials such as `passwd.hashed-password.root`,
  `firstboot.locale`, `firstboot.keymap`, `firstboot.timezone`.
- **`/run/host/userdb/`** takes drop-in JSON user records that `nss-systemd` inside the guest will
  serve — users injected without ever touching `/etc/passwd`.
- **`systemd-ssh-generator`** binds an SSH socket at `/run/host/unix-export/ssh`, which the manager
  can bind-mount out. Interesting as a `kubectl exec`-free access path, though it needs a socket
  reachable from outside the pod to be useful.

For a systemd guest this covers most of what cloud-init is used for, with no dependency in the
image and no state written into the rootfs. It deserves to be a supported backend, not a footnote.

## 8. Ignition

Ignition (Fedora CoreOS, Flatcar) is not a realistic target:

- It is designed to run **in the initramfs, before `switch-root`**. There is no initramfs here.
- It is strictly first-boot-only by design and does no reconciliation, so it cannot express the
  "config changed, re-apply" behaviour that §4 gets from instance-id.

The one technically viable slice is running `ignition --stage files --root /mnt/rootfs` from the
provisioning init container, which writes files, systemd units and users into the mounted rootfs.
That would work, but it serves an audience (CoreOS-derived images) that mostly does not want a
persistent mutable rootfs in the first place. Low priority; not a blocker.

## 9. The LXD/Incus model, for comparison

`DataSourceLXD` reads configuration from the `devlxd` unix socket the manager exposes into the
container. The manager stays authoritative and the guest pulls config live, so `incus config set
… cloud-init.user-data` can take effect without a rebuild.

Reproducing that here means shipping an agent and a socket — considerably more machinery than
writing four files. Worth recording as the design to steal *if* live reconfiguration without a
restart ever becomes a requirement.

## 10. Recommendation: three backends, one always-on layer

```yaml
guest:
  provisioning: native | cloud-init | systemd-credentials
```

- **Layer 0, always on, not selectable.** `container=` marker, `/run/host/*`, `/etc/hostname`,
  `/etc/hosts`, `/etc/resolv.conf`, `/etc/localtime`, and the kernel filesystems. This is the
  Proxmox `pre_start_hook` equivalent and it must work with any image, including one with no init
  system and no provisioning agent.
- **`native`** — layer 0 only, plus the chart's own first-boot steps (machine-id, host keys, root
  password/authorized_keys). No guest cooperation required, so it works with any image.
- **`cloud-init`** (**default**) — layer 0 plus the NoCloud seed and the `99-stateful-pods.cfg`
  drop-in. Gains `write_files`, `runcmd`, users, packages, and the instance-id reconciliation of
  §4. Requires cloud-init in the image, and its absence must fail the pod loudly rather than
  silently do nothing — see [05](05-open-questions.md) §5a.
- **`systemd-credentials`** — layer 0 plus `/run/host/credentials`. Requires systemd, nothing else.
  Uniquely, nothing sensitive is written to the PVC — see [07](07-provisioning-inputs.md) §6.

The layering matters: a user should be able to start on `native`, switch to `cloud-init`, and not
have the hostname handling change underneath them.

Every input to every backend is expressible either inline in values or as a reference to a Secret
or ConfigMap. That contract, and how it is materialized, is specified in
[07](07-provisioning-inputs.md).

## 11. Values naming

The audience knows Proxmox, so mirroring its VM cloud-init vocabulary lowers the learning cost:

| Proxmox VM option | Proposed value | Note |
| --- | --- | --- |
| `ciuser` | `cloudInit.user` | |
| `cipassword` | `cloudInit.passwordSecretRef` | never inline in values |
| `sshkeys` | `cloudInit.sshAuthorizedKeys` | |
| `ciupgrade` | `cloudInit.packageUpgrade` | default `false`, unlike Proxmox's `true` — a slow first boot is worse in a pod |
| `cicustom` | `cloudInit.userDataSecretRef` etc. | raw escape hatch, per file |
| `citype` | — | always NoCloud; ConfigDrive buys nothing here |
| `ipconfigN`, `nameserver`, `searchdomain` | — | **do not copy**; networking and DNS belong to CNI and the pod's DNS policy |

The last row is where the analogy has to be broken deliberately, and the values file should say so
in a comment rather than silently omitting the options.

## 12. Consequences for the other documents

- [03](03-mapping-and-architecture.md) §4.5 (clone identity) is largely solved by §4 above when the
  `cloud-init` backend is used; the `native` backend still needs the hand-written path.
- [02](02-kubernetes-primitives.md) §7 (shutdown signals) is reinforced by systemd's own container
  interface naming `SIGRTMIN+3`.
- The `container=` marker of §6 is a **new hard requirement** on the shim that none of the earlier
  documents captured.
