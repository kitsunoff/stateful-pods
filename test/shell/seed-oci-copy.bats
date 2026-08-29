#!/usr/bin/env bats
#
# The OCI fill. The source image is fetched by the chart's own image and its
# flattened filesystem is streamed into GNU tar, so what is under test here is
# the plumbing around that stream: that the volume really is filled from it, that
# neither side of the pipe can fail unnoticed, and that the platform asked for is
# the one the machine will run on.
#
# `crane` is stubbed, because a registry is not what this suite is about - that
# `crane export` preserves capabilities and honours whiteouts is asserted against
# the real thing in hack/image-test.sh, and end to end in the integration test.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    FIXTURE_DIR="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    export SP_RELEASE=lab
    export SP_NAMESPACE=homelab
    export SP_SOURCE_KIND=oci
    export SP_SOURCE_REFERENCE=docker.io/library/debian:13
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-oci.sh"
    mkdir -p "$ROOTFS/.stateful-pods"
    PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf "$ROOTFS" "$STUB_DIR" "$FIXTURE_DIR"
}

# A rootfs that looks like a real one: an init, an os-release, and a file
# carrying a capability, which is the attribute the whole seeding path exists to
# preserve.
make_image_tar() {
    local src="$FIXTURE_DIR/src"
    rm -rf "$src"
    mkdir -p "$src/sbin" "$src/etc" "$src/usr/local/bin"
    cp /bin/true "$src/sbin/init"
    cp /bin/true "$src/usr/local/bin/sp-probe"
    setcap cap_net_raw+ep "$src/usr/local/bin/sp-probe"
    echo 'ID=debian' > "$src/etc/os-release"
    tar -C "$src" --numeric-owner --xattrs --xattrs-include=security.capability \
        -cf "$FIXTURE_DIR/image.tar" .
}

# A source that carries no userland at all: no shell, no archiver, nothing that
# could have been executed inside it. The old path refused an image like this;
# nothing is run from it any more, so it is an ordinary source.
make_bare_image_tar() {
    local src="$FIXTURE_DIR/bare"
    rm -rf "$src"
    mkdir -p "$src/etc" "$src/app"
    echo 'ID=distroless' > "$src/etc/os-release"
    printf 'not a shell\n' > "$src/app/server"
    tar -C "$src" --numeric-owner -cf "$FIXTURE_DIR/bare.tar" .
}

# Stands in for the registry client. It records the arguments it was called with,
# so that what the fill asked for is an assertion rather than an assumption.
stub_crane() {
    local tarball="$1" exit_code="${2:-0}"
    cat > "$STUB_DIR/crane" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$STUB_DIR/args"
if [ "$exit_code" -ne 0 ]; then
    echo "stub: refusing to fetch" >&2
    exit $exit_code
fi
cat "$tarball"
EOF
    chmod +x "$STUB_DIR/crane"
}

# A fetch that dies part-way through, which is the case a tar that exits cleanly
# on a short stream would hide.
stub_truncated_crane() {
    local tarball="$1"
    cat > "$STUB_DIR/crane" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$STUB_DIR/args"
head -c 4096 "$tarball"
echo "stub: the connection dropped" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/crane"
}

crane_arg_after() {
    grep -A1 -x -- "$1" "$STUB_DIR/args" | tail -n 1
}

@test "the volume is filled from what the registry client emits" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/sbin/init" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "a file capability in the image survives the fill" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    run getcap "$ROOTFS/usr/local/bin/sp-probe"
    [[ "$output" == *cap_net_raw* ]]
}

@test "the fill produces a root filesystem at the top level" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -d "$ROOTFS/etc" ]
    [ -d "$ROOTFS/sbin" ]
    [ ! -e "$ROOTFS/src" ]
}

@test "a source carrying no shell and no archiver is seeded all the same" {
    make_bare_image_tar
    stub_crane "$FIXTURE_DIR/bare.tar"
    export SP_SOURCE_REFERENCE=docker.io/library/alpine:3.22
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/app/server" ]
    [ ! -e "$ROOTFS/bin/sh" ]
}

@test "the image is asked for at the architecture this machine runs on" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    case "$(uname -m)" in
        x86_64)  expected=linux/amd64 ;;
        aarch64) expected=linux/arm64 ;;
        *)       skip "no platform is claimed for $(uname -m)" ;;
    esac
    [ "$(crane_arg_after --platform)" = "$expected" ]
}

@test "the reference the machine declared is the one that is fetched" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q -x -- 'docker.io/library/debian:13' "$STUB_DIR/args"
}

@test "an architecture the project claims no platform for fails by name" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar"
    uname() { echo "sparc64"; }
    export -f uname
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *sparc64* ]]
}

@test "a registry client that fails fails the fill" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
}

@test "a failed fetch is reported as a fetch, not as a failed unpack" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    run sp_fill_rootfs "$ROOTFS"
    [[ "$output" == *"docker.io/library/debian:13"* ]]
    [[ "$output" == *fetching* ]]
    [[ "$output" != *unpacking* ]]
}

@test "a fetch that dies part-way is a failure, not a seeded machine" {
    make_image_tar
    stub_truncated_crane "$FIXTURE_DIR/image.tar"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
    run sh -c ". $SCRIPTS/lib-state.sh; sp_state $ROOTFS"
    [ "$output" = "INTERRUPTED" ]
}

@test "an unreachable image leaves the volume recorded as unseeded" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
    [[ "$output" == *"$ROOTFS"* ]]
    [[ "$output" == *"docker.io/library/debian:13"* ]]
}

@test "running out of room fails, names the volume and leaves no marker" {
    [ -d /small ] || skip "no size-limited filesystem available"
    make_image_tar
    # Bigger than the 8M /small, so the extraction cannot finish.
    dd if=/dev/urandom of="$FIXTURE_DIR/src/blob" bs=1M count=32 status=none
    tar -C "$FIXTURE_DIR/src" --numeric-owner -cf "$FIXTURE_DIR/image.tar" .
    stub_crane "$FIXTURE_DIR/image.tar"
    small="/small/rootfs"
    rm -rf "$small"
    mkdir -p "$small"
    export SP_ROOTFS="$small"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"$small"* ]]
    [[ "$output" == *"docker.io/library/debian:13"* ]]
    [ ! -f "$small/.stateful-pods/provisioned" ]
}
