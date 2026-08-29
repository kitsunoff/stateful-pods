#!/usr/bin/env bats
#
# The copy itself, against the real archiver rather than a stub. These assertions
# are the reason the flags are what they are: each one fails if a flag is dropped,
# and each failure it guards against is invisible in the resulting filesystem.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../charts/stateful-pods/scripts"
    ROOTFS="$(mktemp -d)"
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
}

teardown() {
    rm -rf "$ROOTFS" /usr/local/bin/sp-probe
}

@test "a file capability in the image survives the copy" {
    cp /bin/true /usr/local/bin/sp-probe
    setcap cap_net_raw+ep /usr/local/bin/sp-probe
    getcap /usr/local/bin/sp-probe | grep -q cap_net_raw

    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS/usr/local/bin/sp-probe" ]
    run getcap "$ROOTFS/usr/local/bin/sp-probe"
    [[ "$output" == *cap_net_raw* ]]
}

@test "device nodes are not copied" {
    [ -c /dev/null ] || skip "no device node to copy in this environment"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/dev/null" ]
}

@test "kernel filesystems are not copied" {
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    # The directories may exist as mount points in the image; what must not be
    # here is their contents.
    [ ! -e "$ROOTFS/proc/self" ]
    [ ! -e "$ROOTFS/sys/kernel" ]
}

@test "another mounted filesystem is not copied" {
    # The repository is bind-mounted at /src, which is a different filesystem.
    [ -e /src/Makefile ] || skip "the repository is not mounted at /src"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/src/Makefile" ]
}

@test "the destination volume is not copied into itself" {
    echo canary > "$ROOTFS/canary"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS$ROOTFS" ]
}

@test "the copy produces a root filesystem at the top level" {
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -d "$ROOTFS/usr" ]
    [ -d "$ROOTFS/etc" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "running out of room fails, names the volume and leaves no marker" {
    [ -d /small ] || skip "no size-limited filesystem available"
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

@test "an interrupted copy leaves the volume recorded as unseeded" {
    [ -d /small ] || skip "no size-limited filesystem available"
    small="/small/rootfs2"
    rm -rf "$small"
    mkdir -p "$small"
    export SP_ROOTFS="$small"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ -f "$small/.stateful-pods/seeding" ]
    run sh -c ". $SCRIPTS/lib-state.sh; sp_state $small"
    [ "$output" = "INTERRUPTED" ]
}
