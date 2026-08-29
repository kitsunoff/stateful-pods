# How Proxmox VE starts an LXC container

Source of truth for this document: the `master` branch of
[`proxmox/pve-container`](https://github.com/proxmox/pve-container) (Proxmox VE 9.x). File and
function references below point into that tree.

## 1. The central idea: two distinct phases

Everything that makes LXC-on-Proxmox feel like a virtual machine comes from one design decision:
guest customization is split into two phases that run at different times and do different things.

| Phase | When | Implemented by | Idempotent? |
| --- | --- | --- | --- |
| **Create** | Once, at `pct create` / restore / clone | `PVE::LXC::Setup::post_create_hook()` | No — destroys and rewrites |
| **Start** | On every boot | `PVE::LXC::Setup::pre_start_hook()` | Yes — converges a subset of files |

The rootfs volume is written by the *create* phase and then belongs to the guest forever. The
template is never consulted again. Upgrades happen inside the guest (`apt upgrade`), not by
re-deploying a template. The *start* phase only refreshes the handful of files that describe the
guest's place in the world: hostname, hosts, resolv.conf, network interfaces, TTY/getty setup.

This is the exact inversion of the Kubernetes model, and it is the thing worth copying.

## 2. Create phase

Entry point: `PVE::API2::LXC::create_vm()` (`src/PVE/API2/LXC.pm`, around line 540).

1. **Allocate the root volume.** `PVE::LXC::create_disks()` creates the rootfs volume on the
   configured storage. Depending on the storage type this is a ZFS subvolume, an LVM-thin logical
   volume with a fresh ext4, an RBD image, or a raw file on a directory storage. The container
   never sees the storage type — only a mounted directory.

2. **Mount it.** `PVE::LXC::mount_all()` mounts the volume at `/var/lib/lxc/<vmid>/rootfs`.

3. **Seed it from the template.** Two code paths exist:

   - **Tarball template** (`restore_tar_archive()` in `src/PVE/LXC/Create.pm`). The command is
     effectively:

     ```bash
     tar xpf - --numeric-owner --totals --skip-old-files --anchored --exclude './dev/*' -C "$rootdir"
     ```

     For unprivileged containers the whole `tar` runs inside a user namespace
     (`PVE::LXC::userns_command()`), so extracted files land with shifted ownership. Note
     `--exclude ./dev/*`: **device nodes are never persisted**, `/dev` is populated at runtime.
     `check_tar_archive()` validates the archive first, requiring at least a `sbin` entry and
     10 members.

   - **OCI image** (`restore_oci_archive()`, same file). Proxmox VE 9 can create a container
     directly from an OCI image. The image is extracted with `PVE::RS::OCI::parse_and_extract_image()`
     inside a user namespace, and the OCI config is then *translated into container config*:

     | OCI config field | Becomes |
     | --- | --- |
     | `Entrypoint` + `Cmd` | `entrypoint` → `lxc.init.cmd` |
     | `User` | `lxc.init.uid`, `lxc.init.gid`, `lxc.init.groups` |
     | `WorkingDir` | `lxc.init.cwd` |
     | `Env` | `env` (NUL-separated) |
     | `StopSignal` | `lxc.signal.halt` (default `SIGTERM`) |
     | `Volumes` | best-effort `mkdir` of the paths inside the rootfs |

     If the resulting entrypoint is not `/sbin/init`, PVE also flips `cmode` to `console` and
     enables host-managed networking, because a non-init entrypoint cannot configure its own
     network or drive TTYs. All values coming out of the image are treated as untrusted and are
     screened for control characters before being written into the config.

4. **Detect the OS.** `PVE::LXC::Setup->new()` reads `/etc/os-release` from inside the new rootfs
   and picks a distribution plugin by `ID`, with `plugin_alias` handling flavours
   (`rocky`/`almalinux` → `centos`, `sles`/`opensuse-*` → `opensuse`, …). If `os-release` is
   missing it falls back to marker files (`/etc/debian_version`, `/etc/alpine-release`,
   `/nix/store`, …) and finally to the `unmanaged` plugin, which customizes nothing.

5. **Run `post_create_hook()`** (`src/PVE/LXC/Setup/Base.pm:718`):

   ```text
   clear_machine_id()          # so systemd generates a fresh one on first boot
   snakeoil_fixup()            # regenerate the pre-baked ssl-cert snakeoil pair on first boot
   template_fixup()            # per-distro template repairs
   randomize_crontab()
   set_user_password('root')
   set_user_authorized_ssh_keys('root')
   setup_init() / setup_network() / set_hostname() / set_dns() / set_timezone()
   ```

   Then, outside the chroot, `rewrite_ssh_host_keys()` generates SSH host keys **on the host**
   (`ssh-keygen` into `/run/pve/`) and writes them into the guest rootfs. This avoids running
   guest binaries on the host and gives each container stable, unique host keys from birth.

6. **Unmount, write the config.**

## 3. Start phase

Entry point: `pct start` → `systemctl start pve-container@<vmid>.service`.

### 3.1 The systemd unit

`src/pve-container@.service`:

```ini
[Service]
Type=simple
Delegate=yes
KillMode=mixed
TimeoutStopSec=120s
ExecStart=/usr/bin/lxc-start -F -n %i
ExecStop=/usr/share/lxc/pve-container-stop-wrapper %i
StandardOutput=null
StandardError=file:/run/pve/ct-%i.stderr
```

Three details matter for us:

- `Delegate=yes` hands the unit's cgroup subtree to the container, which is what lets the guest's
  systemd manage its own cgroups.
- `StandardOutput=null` — Proxmox deliberately **throws away the guest init's stdout** so it does
  not flood the host journal. Guest logs are reached through the console or the guest's own
  journal, not through the host's log pipeline.
- `KillMode=mixed` + a 120 s stop timeout: shutdown is a guest-driven process, not a `SIGKILL`.

### 3.2 The generated LXC config

`PVE::LXC::update_lxc_config()` (`src/PVE/LXC.pm`, from line ~700) regenerates
`/var/lib/lxc/<vmid>/config` from the PVE config on every start. The interesting keys:

```ini
lxc.arch = amd64
lxc.include = /usr/share/lxc/config/debian.common.conf
lxc.include = /usr/share/lxc/config/debian.userns.conf   # unprivileged only
lxc.seccomp.profile = ...
lxc.apparmor.profile = generated
lxc.cgroup.relative = 0
lxc.cgroup.dir.monitor = lxc.monitor/<vmid>
lxc.cgroup.dir.container = lxc/<vmid>
lxc.cgroup.dir.container.inner = ns
lxc.mount.auto = sys:mixed                # unprivileged, unless force_rw_sys
lxc.idmap = u 0 100000 65536              # unprivileged
lxc.idmap = g 0 100000 65536
lxc.monitor.unshare = 1
lxc.tty.max = <ttycount>
lxc.environment = TERM=linux
lxc.uts.name = <hostname>
lxc.cgroup2.memory.max / memory.high / memory.swap.max
lxc.cgroup2.cpu.max / cpu.weight
lxc.rootfs.path = /var/lib/lxc/<vmid>/rootfs
lxc.init.cmd = <entrypoint>               # only if set; default is /sbin/init
lxc.net.<N>.type = veth ...
```

Notes:

- `lxc.mount.auto = sys:mixed` for unprivileged containers: `/sys` read-only, because a fully
  writable `/sys` breaks `systemd-networkd`, per the
  [systemd container interface](https://systemd.io/CONTAINER_INTERFACE/).
- When the entrypoint is *not* `/sbin/init`, PVE adds an explicit `/dev/shm` tmpfs, because there
  is no init system to set it up.
- Resource limits are plain cgroup v2 writes. Changing memory or CPU does not require a restart —
  the VM-like "hot plug" behaviour is just a cgroup file write.

### 3.3 Hooks

`src/lxc-pve.conf` registers three hooks:

```ini
lxc.hook.pre-start = /usr/share/lxc/hooks/lxc-pve-prestart-hook
lxc.hook.autodev   = /usr/share/lxc/hooks/lxc-pve-autodev-hook
lxc.hook.post-stop = /usr/share/lxc/hooks/lxc-pve-poststop-hook
```

**`lxc-pve-prestart-hook`** runs in the *host* namespace, before the container's namespaces exist.
In order:

1. Check cluster quorum and the config lock; refuse to start otherwise.
2. `cleanup_cgroups()` — remove leftover `/sys/fs/cgroup/lxc/<vmid>` trees, which otherwise make
   `lxc-start` fail with no useful error.
3. Recursively unmount `$ROOTFS_PATH` in case someone left a `pct mount` behind.
4. For each volume (`foreach_volume`, rootfs first): stage the mount
   (`mountpoint_stage`), optionally apply an **idmapped mount** via
   `mount_setattr(..., MOUNT_ATTR_IDMAP, ...)` against a userns file descriptor, then insert it
   (`mountpoint_insert_staged`). Everything after the rootfs is mounted *relative to the rootfs
   file descriptor*, so a malicious symlink inside the guest cannot redirect a mount.
5. Create device-passthrough nodes in a tiny tmpfs at `/var/lib/lxc/<vmid>/passthrough`.
6. **`PVE::LXC::Setup->pre_start_hook()`** — the guest customization (see below).
7. Warn if the guest's systemd is too old for a pure cgroup v2 environment
   (`unified_cgroupv2_support()` inspects the init binary).
8. Register SDN/DHCP mappings for each veth.

**`lxc-pve-autodev-hook`** runs after the container's rootfs is mounted but before init starts. It
`mknod`s and bind-mounts passthrough devices into `$ROOTFS_MOUNT/dev` and writes the device cgroup
allow-lists.

**`lxc-pve-poststop-hook`** recursively unmounts everything, deletes veths that netlink may have
leaked, applies pending config changes, and — for a reboot — writes a `/var/lib/lxc/<vmid>/reboot`
trigger file and exits non-zero so that `lxc-start` stops instead of rebooting in place. A guest
reboot is therefore a full stop/start cycle on the host, which is how pending config changes get
applied. **A guest reboot in Proxmox is exactly what a container restart is in Kubernetes.**

### 3.4 Guest customization: `pre_start_hook`

`src/PVE/LXC/Setup/Base.pm:698`:

```perl
sub pre_start_hook {
    my ($self, $conf) = @_;
    $self->ct_file_set_contents('/fastboot', '');  # skips fsck etc.
    $self->setup_init($conf);
    $self->setup_network($conf);
    $self->set_hostname($conf);
    $self->set_dns($conf);
    $self->set_timezone($conf);
}
```

Every one of these runs inside `PVE::LXC::Setup::protected_call()`, which **forks and `chroot`s
into the guest rootfs** before touching anything. That is the safety boundary: path traversal and
symlink attacks from inside the guest cannot escape, and the code can use plain absolute paths.

What each does:

- **`set_hostname`** — writes `/etc/hostname` (short name) and rewrites the guest's `/etc/hosts`
  entry for the primary IP, using the *old* hostname to find the line to replace.
- **`set_dns`** — replaces `/etc/resolv.conf` wholesale with `search` + `nameserver` lines.
- **`setup_network`** — per-distro. Debian writes `/etc/network/interfaces`; Ubuntu ≥ 17.10 gets
  `systemd-networkd` units; CentOS 9/10 gets NetworkManager `.nmconnection` files; SUSE gets
  `ifcfg-*`/`ifroute-*`; Alpine gets `/etc/network/interfaces`. This per-distro divergence is the
  bulk of the plugin code.
- **`setup_init`** — TTY plumbing: rewrites `/etc/inittab` getty lines, installs
  `container-getty@.service` overrides, patches `getty@.service`'s `ConditionPathExists` for
  ancient systemd, and applies systemd presets (e.g. Debian ≥ 12 gets `systemd-networkd.service`
  disabled because Debian uses ifupdown).
- **`set_timezone`** — copies the host's `/etc/localtime` target.

### 3.5 The opt-out mechanism: `.pve-ignore.<file>`

`src/PVE/LXC/Setup/Base.pm:742`:

```perl
sub ct_is_file_ignored {
    my ($self, $file) = @_;
    my ($name, $path) = fileparse($file);
    return -f "$path/.pve-ignore.$name";
}
```

If `/etc/network/.pve-ignore.interfaces` exists, PVE will not touch
`/etc/network/interfaces`. Same for `/etc/.pve-ignore.hosts`, `/etc/.pve-ignore.resolv.conf`, and
so on. This is a small mechanism with a large consequence: **the guest owner can take ownership of
any managed file, per file, without disabling management entirely.** Any system that rewrites files
inside someone else's root filesystem needs an equivalent escape hatch.

## 4. What Proxmox deliberately does *not* persist

From the create-time `--exclude './dev/*'` and the runtime mounts:

- `/dev` — tmpfs, populated by LXC's autodev and the `lxc.autodev` machinery.
- `/proc`, `/sys` — kernel filesystems, mounted per boot (`sys:mixed` for unprivileged).
- `/run` — tmpfs, created by the guest's init.
- `/etc/machine-id` — cleared at create and at clone, regenerated on first boot.
- SSH host keys — generated once at create; persisted thereafter.

Everything else in the rootfs is persistent state.

## 5. Facts worth carrying into the Kubernetes design

1. The image is a **seed**, not a source of truth. Consulted once.
2. Customization is split into a destructive create-time pass and an idempotent per-boot pass.
3. The per-boot pass runs **on the host, chrooted into the guest rootfs** — not inside the guest.
4. A per-file opt-out marker (`.pve-ignore.<name>`) prevents management from fighting the user.
5. Device nodes and kernel filesystems are never persisted, and are re-created every boot.
6. Reboot is implemented as stop + start, which is also how pending config is applied.
7. Guest init stdout is discarded; logging goes through the guest's own journal.
8. Resource limits are cgroup writes that can be applied to a live container.
9. Unprivileged containers use a UID shift (`lxc.idmap 0 → 100000`), either baked into the
   on-disk ownership or applied at mount time with idmapped mounts.
10. Proxmox VE 9 already accepts OCI images as container templates and translates the OCI config
    into container config — the "OCI image as a seed for a persistent rootfs" idea is not novel,
    it is shipping.
