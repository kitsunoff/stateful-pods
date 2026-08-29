#!/usr/bin/env bats
#
# The four states a rootfs volume can be in, and the one safe action each admits.
# The distinction between "we died half-way" and "the user put something here" is
# the reason the `seeding` file exists at all: without it the chart would have to
# choose between destroying data and getting permanently stuck.

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../images/shim/scripts/lib-state.sh"
    ROOTFS="$(mktemp -d)"
    # shellcheck disable=SC1090
    . "$LIB"
}

teardown() {
    rm -rf "$ROOTFS"
}

mark_provisioned() {
    mkdir -p "$ROOTFS/.stateful-pods"
    echo '{"schemaVersion":1}' > "$ROOTFS/.stateful-pods/provisioned"
}

mark_seeding() {
    mkdir -p "$ROOTFS/.stateful-pods"
    : > "$ROOTFS/.stateful-pods/seeding"
}

@test "an empty volume is EMPTY" {
    run sp_state "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$output" = "EMPTY" ]
}

@test "a volume holding only lost+found is EMPTY" {
    mkdir -p "$ROOTFS/lost+found"
    run sp_state "$ROOTFS"
    [ "$output" = "EMPTY" ]
}

@test "a volume with a marker is MARKED" {
    mark_provisioned
    run sp_state "$ROOTFS"
    [ "$output" = "MARKED" ]
}

@test "a marker wins over a leftover seeding file" {
    mark_seeding
    mark_provisioned
    run sp_state "$ROOTFS"
    [ "$output" = "MARKED" ]
}

@test "a seeding file without a marker is INTERRUPTED" {
    mark_seeding
    mkdir -p "$ROOTFS/usr"
    run sp_state "$ROOTFS"
    [ "$output" = "INTERRUPTED" ]
}

@test "content with neither file is FOREIGN" {
    mkdir -p "$ROOTFS/usr/bin"
    echo hello > "$ROOTFS/usr/bin/thing"
    run sp_state "$ROOTFS"
    [ "$output" = "FOREIGN" ]
}

@test "a hidden file with neither marker is still FOREIGN" {
    echo secret > "$ROOTFS/.hidden"
    run sp_state "$ROOTFS"
    [ "$output" = "FOREIGN" ]
}

@test "an empty .stateful-pods directory alone is EMPTY" {
    mkdir -p "$ROOTFS/.stateful-pods"
    run sp_state "$ROOTFS"
    [ "$output" = "EMPTY" ]
}

@test "wiping removes guest content but keeps the chart's own directory" {
    mark_seeding
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/lost+found"
    echo stale > "$ROOTFS/usr/bin/leftover"
    echo stale > "$ROOTFS/.hidden"
    run sp_wipe "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/usr" ]
    [ ! -e "$ROOTFS/.hidden" ]
    [ -e "$ROOTFS/lost+found" ]
    [ -e "$ROOTFS/.stateful-pods/seeding" ]
}

@test "wiping an already empty volume succeeds" {
    run sp_wipe "$ROOTFS"
    [ "$status" -eq 0 ]
}
