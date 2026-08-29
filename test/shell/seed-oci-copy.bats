#!/usr/bin/env bats
#
# The copy itself, against the real archiver rather than a stub. These assertions
# are the reason the flags are what they are: each one fails if a flag is dropped,
# and each failure it guards against is invisible in the resulting filesystem.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
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

# A copy that fails with no explanation is the failure mode this whole change
# exists to avoid, and a test that fails the same way is no better.
fill() {
    run sp_fill_rootfs "$1"
    if [ "$status" -ne 0 ]; then
        echo "sp_fill_rootfs exited $status" >&2
        echo "$output" >&2
    fi
}

@test "a file capability in the image survives the copy" {
    cp /bin/true /usr/local/bin/sp-probe
    setcap cap_net_raw+ep /usr/local/bin/sp-probe
    getcap /usr/local/bin/sp-probe | grep -q cap_net_raw

    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS/usr/local/bin/sp-probe" ]
    run getcap "$ROOTFS/usr/local/bin/sp-probe"
    [[ "$output" == *cap_net_raw* ]]
}

@test "device nodes are not copied" {
    [ -c /dev/null ] || skip "no device node to copy in this environment"
    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/dev/null" ]
}

@test "kernel filesystems are not copied" {
    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    # The directories may exist as mount points in the image; what must not be
    # here is their contents.
    [ ! -e "$ROOTFS/proc/self" ]
    [ ! -e "$ROOTFS/sys/kernel" ]
}

@test "another mounted filesystem is not copied" {
    # The repository is bind-mounted at /src, which is a different filesystem.
    [ -e /src/Makefile ] || skip "the repository is not mounted at /src"
    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/src/Makefile" ]
}

@test "the destination volume is not copied into itself" {
    echo canary > "$ROOTFS/canary"
    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS$ROOTFS" ]
}

@test "the copy produces a root filesystem at the top level" {
    fill "$ROOTFS"
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

@test "a live kernel filesystem in the source does not fail the copy" {
    # /proc and /sys are mounted in this container and change while they are read.
    # Excluding only their contents leaves tar reading the mount point itself,
    # which it reports as "file changed as we read it" and which fails the copy
    # for something that was never wanted.
    [ -d /proc/self ] || skip "no live kernel filesystem to read"
    fill "$ROOTFS"
    [ "$status" -eq 0 ]
    # The mount point is not copied at all; the driver recreates it empty.
    [ ! -e "$ROOTFS/sys" ]
    [ ! -e "$ROOTFS/proc" ]
}
