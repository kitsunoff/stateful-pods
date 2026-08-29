#!/usr/bin/env bats
#
# Device nodes, the refusals, and what the machine's init is handed.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    mkdir -p "$ROOTFS/sbin" "$ROOTFS/dev" "$ROOTFS/.stateful-pods"
    : > "$ROOTFS/sbin/init"
    chmod +x "$ROOTFS/sbin/init"
    echo '{"schemaVersion":1}' > "$ROOTFS/.stateful-pods/provisioned"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-boot.sh"
    stub_mount
}

teardown() { rm -rf "$ROOTFS" "$STUB_DIR"; }

stub_mount() {
    cat > "$STUB_DIR/mount" <<'EOF'
#!/bin/sh
echo "$@" >> "${SP_MOUNT_LOG:-/dev/null}"
exit 0
EOF
    chmod +x "$STUB_DIR/mount"
    export SP_MOUNT_LOG="$STUB_DIR/mounts"
    : > "$SP_MOUNT_LOG"
}

@test "device nodes are bound, never created" {
    PATH="$STUB_DIR:$PATH" run sp_bind_devices "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q -- "--bind /dev/null $ROOTFS/dev/null" "$SP_MOUNT_LOG"
    # A regular file is the mount point, because mknod is impossible in a pod's
    # own user namespace whatever it is granted.
    [ -f "$ROOTFS/dev/null" ]
    [ ! -c "$ROOTFS/dev/null" ]
}

@test "a device the runtime did not provide is skipped without failing the boot" {
    SP_DEVICE_NODES="null sp-not-a-real-device"
    PATH="$STUB_DIR:$PATH" run sp_bind_devices "$ROOTFS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sp-not-a-real-device"* ]]
    [[ "$output" == *"skipping"* ]]
    grep -q -- "--bind /dev/null" "$SP_MOUNT_LOG"
}

@test "the standard stream links a guest expects are present" {
    PATH="$STUB_DIR:$PATH" run sp_bind_devices "$ROOTFS"
    [ -L "$ROOTFS/dev/stdout" ]
    [ -L "$ROOTFS/dev/fd" ]
}

@test "an unseeded volume is refused before anything is mounted" {
    rm -f "$ROOTFS/.stateful-pods/provisioned"
    PATH="$STUB_DIR:$PATH" run sp_check_bootable "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"has not been seeded"* ]]
    [ ! -s "$SP_MOUNT_LOG" ]
}

@test "a volume with no init to hand over to says so" {
    rm -f "$ROOTFS/sbin/init"
    run sp_check_bootable "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no init system"* ]]
}

@test "a machine whose init is elsewhere is still found" {
    rm -f "$ROOTFS/sbin/init"
    mkdir -p "$ROOTFS/usr/lib/systemd"
    : > "$ROOTFS/usr/lib/systemd/systemd"
    chmod +x "$ROOTFS/usr/lib/systemd/systemd"
    run sp_find_init "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/lib/systemd/systemd" ]
}

@test "a missing rootfs is reported rather than assumed" {
    run sp_check_bootable "$ROOTFS/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does-not-exist"* ]]
}

@test "the machine's init is told it is running in a container" {
    run grep -c 'container=lxc' "$SCRIPTS/boot.sh"
    [ "$status" -eq 0 ]
    run bash -c "grep -n 'export container=lxc' '$SCRIPTS/boot.sh' | cut -d: -f1"
    export_line="$output"
    run bash -c "grep -n 'exec \"\$init\"' '$SCRIPTS/boot.sh' | cut -d: -f1"
    exec_line="$output"
    # It has to be in the environment of the exec'd init, so it must be set first.
    [ "$export_line" -lt "$exec_line" ]
}

@test "the helpers that must outlive the root change are installed on the volume" {
    run sp_install_runtime_helpers "$ROOTFS" "$SCRIPTS"
    [ "$status" -eq 0 ]
    for helper in ready.sh stop.sh; do
        [ -x "$ROOTFS/.stateful-pods/bin/$helper" ]
    done
}

@test "the installed helpers reference no path that disappears with the root change" {
    sp_install_runtime_helpers "$ROOTFS" "$SCRIPTS"
    for helper in ready.sh stop.sh; do
        run grep -c '/usr/local/lib/stateful-pods/' "$ROOTFS/.stateful-pods/bin/$helper"
        [ "$output" = "0" ]
    done
}

@test "the installed helpers ask for no interpreter the machine may not have" {
    sp_install_runtime_helpers "$ROOTFS" "$SCRIPTS"
    for helper in ready.sh stop.sh; do
        run head -n 1 "$ROOTFS/.stateful-pods/bin/$helper"
        [ "$output" = "#!/bin/sh" ]
    done
}
