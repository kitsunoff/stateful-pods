#!/usr/bin/env bats
#
# The mount plan.
#
# Mounting needs privileges a test container does not have, so what is under test
# here is the plan - which filesystems, where, in what order - and the handling of
# a mount that fails. Whether the kernel accepts the plan is what the integration
# test on a real cluster is for.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    mkdir -p "$ROOTFS/sbin" "$ROOTFS/etc" "$ROOTFS/.stateful-pods"
    : > "$ROOTFS/sbin/init"
    chmod +x "$ROOTFS/sbin/init"
    echo '{"schemaVersion":1}' > "$ROOTFS/.stateful-pods/provisioned"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-boot.sh"
}

teardown() {
    rm -rf "$ROOTFS" "$STUB_DIR"
}

plan() { sp_mount_plan "$ROOTFS"; }
targets() { plan | awk '{print $3}'; }

@test "the plan mounts the process filesystem into the new root" {
    run bash -c "$(declare -f sp_mount_plan); sp_mount_plan '$ROOTFS' | grep -c '^proc '"
    [ "$output" = "1" ]
}

@test "the plan covers every filesystem an init system expects" {
    run targets
    for t in /proc /sys /dev /dev/pts /dev/shm /run /tmp /sys/fs/cgroup; do
        [[ "$output" == *"$ROOTFS$t"* ]] || { echo "missing $t"; false; }
    done
}

@test "every target is inside the machine's root" {
    while read -r target; do
        [[ "$target" == "$ROOTFS"/* ]] || { echo "escapes the root: $target"; false; }
    done < <(targets)
}

@test "kernel filesystems are mounted before the directories nested in them" {
    order="$(targets)"
    sys_line="$(echo "$order" | grep -n "^$ROOTFS/sys\$" | cut -d: -f1)"
    cgroup_line="$(echo "$order" | grep -n "^$ROOTFS/sys/fs/cgroup\$" | cut -d: -f1)"
    dev_line="$(echo "$order" | grep -n "^$ROOTFS/dev\$" | cut -d: -f1)"
    pts_line="$(echo "$order" | grep -n "^$ROOTFS/dev/pts\$" | cut -d: -f1)"
    [ "$sys_line" -lt "$cgroup_line" ]
    [ "$dev_line" -lt "$pts_line" ]
}

@test "the control group filesystem is writable, whatever the guest runs" {
    options="$(plan | awk '$1 == "cgroup2" {print $4}')"
    [ -n "$options" ]
    # A read-only hierarchy is exactly what Kubernetes already gives the pod and
    # what a guest's init cannot use, so the point is that this one is not.
    run bash -c "echo ',$options,' | grep -q ',ro,'"
    [ "$status" -ne 0 ]
}

@test "the kernel filesystem the guest must not write to is read-only" {
    options="$(plan | awk '$1 == "sysfs" {print $4}')"
    run bash -c "echo ',$options,' | grep -q ',ro,'"
    [ "$status" -eq 0 ]
}

@test "the plan does not depend on what the volume holds" {
    before="$(plan)"
    mkdir -p "$ROOTFS/usr/lib/systemd"
    : > "$ROOTFS/usr/lib/systemd/systemd"
    after_systemd="$(plan)"
    rm -rf "$ROOTFS/usr/lib/systemd"
    mkdir -p "$ROOTFS/sbin"
    ln -sf /bin/runit "$ROOTFS/sbin/runit-init"
    after_runit="$(plan)"
    [ "$before" = "$after_systemd" ]
    [ "$before" = "$after_runit" ]
}

@test "applying the plan reports the path and the filesystem type when a mount fails" {
    cat > "$STUB_DIR/mount" <<'EOF'
#!/bin/sh
echo "mount: permission denied" >&2
exit 32
EOF
    chmod +x "$STUB_DIR/mount"
    PATH="$STUB_DIR:$PATH" run sp_apply_mounts "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$ROOTFS/proc"* ]]
    [[ "$output" == *"proc"* ]]
}

@test "applying the plan creates missing mount points" {
    cat > "$STUB_DIR/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$STUB_DIR/mount"
    rm -rf "$ROOTFS/sys" "$ROOTFS/run"
    PATH="$STUB_DIR:$PATH" run sp_apply_mounts "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -d "$ROOTFS/sys" ]
    [ -d "$ROOTFS/run" ]
}

# The pseudo-terminal filesystem.
#
# `newinstance` is what makes the terminals a machine hands out its own rather
# than the node's, and it is also what makes the multiplexer at the conventional
# path a link rather than a node: the instance has its own multiplexer, and a
# node made anywhere else allocates from a different one. The two assertions
# below are a pair - the first pins the option, the second the link it forces.

@test "the pseudo-terminal filesystem is a private instance an unprivileged process can use" {
    options="$(plan | awk '$1 == "devpts" {print $4}')"
    [ -n "$options" ]
    [[ ",$options," == *",newinstance,"* ]] || { echo "not a private instance: $options"; false; }
    [[ ",$options," == *",ptmxmode=0666,"* ]] || { echo "multiplexer is not usable unprivileged: $options"; false; }
}

@test "preparing the devices leaves the pseudo-terminal multiplexer at the path programs open" {
    cat > "$STUB_DIR/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$STUB_DIR/mount"
    mkdir -p "$ROOTFS/dev"
    PATH="$STUB_DIR:$PATH" run sp_bind_devices "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -L "$ROOTFS/dev/ptmx" ] || { echo "/dev/ptmx is not a symbolic link"; false; }
    # Relative, so that it resolves to the machine's own instance both before the
    # root change - when the machine is still at $ROOTFS - and after it.
    [ "$(readlink "$ROOTFS/dev/ptmx")" = "pts/ptmx" ]
}

@test "the multiplexer is not left as a device node of its own" {
    cat > "$STUB_DIR/mount" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$STUB_DIR/mount"
    mkdir -p "$ROOTFS/dev"
    PATH="$STUB_DIR:$PATH" run sp_bind_devices "$ROOTFS"
    [ "$status" -eq 0 ]
    # A node here would allocate from whichever instance it is associated with,
    # which is not the machine's, and creating one is refused outright for a pod
    # in its own user namespace.
    [ ! -c "$ROOTFS/dev/ptmx" ] || { echo "/dev/ptmx is a character device"; false; }
    # Nor is it bound from the pod's own, which belongs to the node's instance.
    [ -n "$SP_DEVICE_NODES" ]
    [[ " $SP_DEVICE_NODES " != *" ptmx "* ]] \
        || { echo "ptmx is bound from the pod: $SP_DEVICE_NODES"; false; }
}
