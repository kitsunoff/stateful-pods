# shellcheck shell=bash
#
# Turning a filled volume into a running machine.
#
# Everything here happens in the guest container, before its process becomes the
# machine's own init. The ordering is the whole point and is why none of it can be
# expressed in a pod spec: the kernel filesystems have to be inside the new root
# *before* the root changes, and a volume cannot be handed to a runtime as `/`.

# Where the machine's root filesystem is mounted before the root change, and where
# the chart's own state lives on it.
SP_OLDROOT_DIR="oldroot"

# Device nodes are bound from the ones the runtime already placed in this pod,
# never created. mknod(2) checks the capability in the *initial* user namespace, so
# a pod running in its own user namespace cannot create /dev/null at all, whatever
# it is granted. Binding is what Proxmox does for the same reason, and it makes the
# two security modes take the identical code path.
SP_DEVICE_NODES="null zero full random urandom tty console"

# The mount plan: one line per mount, "<type> <source> <target> <options>".
#
# Fixed for every machine. An init that does not use a control-group hierarchy
# ignores the one that was mounted, at no cost, and the alternative is an input
# whose wrong value produces a machine that fails to boot for a reason no message
# could explain.
#
# sysfs is read-only, which is what Proxmox gives an unprivileged container and
# what keeps a guest's network manager from trying to write to it. Mounting the
# control-group hierarchy over a path inside it is still allowed.
sp_mount_plan() {
    local root="$1"
    cat <<PLAN
proc proc $root/proc nosuid,noexec,nodev
sysfs sysfs $root/sys ro,nosuid,noexec,nodev
tmpfs tmpfs $root/dev mode=0755,nosuid
devpts devpts $root/dev/pts newinstance,ptmxmode=0666,mode=0620,gid=5,nosuid,noexec
tmpfs tmpfs $root/dev/shm mode=1777,nosuid,nodev
tmpfs tmpfs $root/run mode=0755,nosuid,nodev
tmpfs tmpfs $root/tmp mode=1777,nosuid,nodev
cgroup2 none $root/sys/fs/cgroup nsdelegate,nosuid,noexec,nodev
PLAN
}

sp_apply_mounts() {
    local root="$1" type source target options
    while read -r type source target options; do
        [ -n "$type" ] || continue
        mkdir -p "$target" \
            || sp_die "machine ${SP_MACHINE:-?}: could not create the mount point $target"
        mount -t "$type" -o "$options" "$source" "$target" \
            || sp_die "machine ${SP_MACHINE:-?}: could not mount $type at $target. The machine has not been started. In the userns security mode this usually means the node cannot support user-namespaced pods; the privileged mode works on any cluster."
    done < <(sp_mount_plan "$root")
}

# Creates an empty regular file as a mount point and binds the real device over
# it, exactly as Proxmox's autodev hook does. A node the runtime did not provide
# is skipped: /dev/console only exists when the container asked for a terminal,
# and a machine without it boots fine with quieter logs.
sp_bind_devices() {
    local root="$1" node
    for node in $SP_DEVICE_NODES; do
        if [ ! -e "/dev/$node" ]; then
            sp_log "machine ${SP_MACHINE:-?}: /dev/$node was not provided to this pod, skipping it"
            continue
        fi
        : > "$root/dev/$node" \
            || sp_die "machine ${SP_MACHINE:-?}: could not create the mount point for /dev/$node"
        mount --bind "/dev/$node" "$root/dev/$node" \
            || sp_die "machine ${SP_MACHINE:-?}: could not bind /dev/$node into the machine"
    done
    ln -sf /proc/self/fd "$root/dev/fd" 2>/dev/null || true
    ln -sf /proc/self/fd/0 "$root/dev/stdin" 2>/dev/null || true
    ln -sf /proc/self/fd/1 "$root/dev/stdout" 2>/dev/null || true
    ln -sf /proc/self/fd/2 "$root/dev/stderr" 2>/dev/null || true
}

# The helpers that have to run after the root change cannot stay in the mounted
# ConfigMap: the probe and the stop hook run in this container's mount namespace,
# which by then is the machine's root, and /scripts is on the other side of the
# change. The volume is the one thing present in both roots, so they are copied
# onto it and referenced at a path that is valid once the machine is up.
sp_install_runtime_helpers() {
    local root="$1" script_dir="$2" helper
    mkdir -p "$root/$SP_DIR_NAME/bin" \
        || sp_die "machine ${SP_MACHINE:-?}: could not create $root/$SP_DIR_NAME/bin"
    for helper in ready.sh stop.sh; do
        cp "$script_dir/$helper" "$root/$SP_DIR_NAME/bin/$helper" \
            || sp_die "machine ${SP_MACHINE:-?}: could not install $helper onto the volume"
        chmod 0755 "$root/$SP_DIR_NAME/bin/$helper"
    done
}

# The machine's init, as an absolute path inside the machine.
sp_find_init() {
    local root="$1" candidate
    for candidate in /sbin/init /usr/sbin/init /usr/lib/systemd/systemd /bin/init; do
        if [ -x "$root$candidate" ] || [ -L "$root$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

sp_check_bootable() {
    local root="$1"
    [ -d "$root" ] || sp_die "the rootfs volume is not mounted at $root"
    if [ ! -f "$root/$SP_DIR_NAME/provisioned" ]; then
        sp_die "machine ${SP_MACHINE:-?}: the rootfs volume at $root has not been seeded, so there is no operating system to start. The seeding step should have run before this one."
    fi
    sp_find_init "$root" >/dev/null \
        || sp_die "machine ${SP_MACHINE:-?}: the root filesystem on $root holds no init system to hand over to. A machine's source must be an operating system, not an application image."
}

# Changes the root of this mount namespace to the machine's filesystem, so that
# the machine - and every shell, exec and probe that follows - is inside it.
#
# chroot is not offered as a fallback. With chroot, `kubectl exec` and exec probes
# land in the chart's image rather than in the machine, and every probe and every
# debugging session would have to be wrapped in something that follows the
# machine's init into its root.
sp_pivot() {
    local root="$1"
    mount --make-rprivate / \
        || sp_die "machine ${SP_MACHINE:-?}: could not make the container's mounts private, which pivot_root requires"
    mkdir -p "$root/$SP_DIR_NAME/$SP_OLDROOT_DIR" \
        || sp_die "machine ${SP_MACHINE:-?}: could not create the pivot directory on $root"
    cd "$root" \
        || sp_die "machine ${SP_MACHINE:-?}: could not enter $root"
    pivot_root . "$SP_DIR_NAME/$SP_OLDROOT_DIR" \
        || sp_die "machine ${SP_MACHINE:-?}: could not make $root the machine's root. The machine has not been started."
    cd / || sp_die "machine ${SP_MACHINE:-?}: could not enter the machine's root"
    umount -l "/$SP_DIR_NAME/$SP_OLDROOT_DIR" 2>/dev/null || true
}
