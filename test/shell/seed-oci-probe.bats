#!/usr/bin/env bats
#
# The archiver probe. This is the check that keeps an Alpine source image from
# being seeded badly: busybox tar extracts happily and drops security.capability,
# so the rootfs looks correct and an unprivileged `ping` fails forever after with
# nothing in the logs to explain it. Failing loudly is the whole point.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    STUB_DIR="$(mktemp -d)"
    ROOTFS="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    export SP_SOURCE_KIND=oci
    export SP_SOURCE_REFERENCE=docker.io/library/alpine:3.22
}

teardown() {
    rm -rf "$STUB_DIR" "$ROOTFS"
}

stub_busybox_tar() {
    cat > "$STUB_DIR/tar" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "tar (busybox) 1.37.0"; exit 0 ;;
  --help) echo "Usage: tar -[cxtZzJjahmvO] [-X FILE] [-T FILE] [-f TARFILE]"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/tar"
}

stub_gnu_tar_without_xattrs() {
    cat > "$STUB_DIR/tar" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "tar (GNU tar) 1.35"; exit 0 ;;
  --help) echo "  -p, --preserve-permissions   extract information about file permissions"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/tar"
}

run_probe() {
    PATH="$STUB_DIR:$PATH" run sh -c ". $SCRIPTS/lib-state.sh; . $SCRIPTS/lib-seed.sh; . $SCRIPTS/lib-oci.sh; sp_probe_archiver"
}

@test "the real GNU tar in this environment passes the probe" {
    run sh -c ". $SCRIPTS/lib-state.sh; . $SCRIPTS/lib-seed.sh; . $SCRIPTS/lib-oci.sh; sp_probe_archiver"
    [ "$status" -eq 0 ]
}

@test "a busybox tar fails the probe" {
    stub_busybox_tar
    run_probe
    [ "$status" -ne 0 ]
}

@test "a busybox tar failure names the lxc source kind as the alternative" {
    stub_busybox_tar
    run_probe
    [[ "$output" == *"lxc"* ]]
}

@test "a busybox tar failure explains what would have been lost" {
    stub_busybox_tar
    run_probe
    [[ "$output" == *"security.capability"* ]]
}

@test "a GNU tar without extended-attribute support fails the probe" {
    stub_gnu_tar_without_xattrs
    run_probe
    [ "$status" -ne 0 ]
    [[ "$output" == *"lxc"* ]]
}

@test "a missing tar fails the probe with a message naming tar" {
    printf '#!/bin/sh\nexit 127\n' > "$STUB_DIR/tar"
    chmod +x "$STUB_DIR/tar"
    run_probe
    [ "$status" -ne 0 ]
    [[ "$output" == *"tar"* ]]
}
