#!/usr/bin/env bats
#
# The seeding driver: what it does with each volume state, and what it refuses.
# The fill step is stubbed here, because what is under test is the decision, not
# the copy.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    export SP_RELEASE=lab
    export SP_NAMESPACE=homelab
    export SP_CHART_VERSION=0.1.0
    export SP_SOURCE_KIND=oci
    export SP_SOURCE_REFERENCE=docker.io/library/debian:13
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    FILL_MARKER="$(mktemp)"
}

teardown() {
    rm -rf "$ROOTFS" "$FILL_MARKER"
}

# Stands in for the real copy or extraction.
sp_fill_rootfs() {
    echo filled > "$FILL_MARKER"
    mkdir -p "$1/usr/bin" "$1/sbin"
    echo binary > "$1/sbin/init"
}

filled() { [ "$(cat "$FILL_MARKER")" = "filled" ]; }

@test "an empty volume is filled and left in progress for the next step" {
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/sbin/init" ]
    [ -f "$ROOTFS/.stateful-pods/seeding" ]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
}

@test "the in-progress file is written before the fill begins" {
    sp_fill_rootfs() {
        # If the driver has not written it yet, the failure below is the point.
        [ -f "$SP_ROOTFS/.stateful-pods/seeding" ] || return 1
        echo filled > "$FILL_MARKER"
    }
    run sp_seed_main
    [ "$status" -eq 0 ]
    filled
}

@test "a marked volume is left alone and the fill never runs" {
    mkdir -p "$ROOTFS/.stateful-pods" "$ROOTFS/usr"
    echo '{"schemaVersion":1}' > "$ROOTFS/.stateful-pods/provisioned"
    echo guest > "$ROOTFS/usr/data"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/usr/data")" = "guest" ]
    ! filled
}

@test "a volume the chart did not create is refused, naming the machine" {
    mkdir -p "$ROOTFS/usr/bin"
    echo mine > "$ROOTFS/usr/bin/thing"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"web"* ]]
    [[ "$output" == *"not created by this chart"* ]]
}

@test "a refused volume is not touched" {
    mkdir -p "$ROOTFS/usr/bin"
    echo mine > "$ROOTFS/usr/bin/thing"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ "$(cat "$ROOTFS/usr/bin/thing")" = "mine" ]
    [ ! -e "$ROOTFS/.stateful-pods/seeding" ]
    ! filled
}

@test "an interrupted attempt is cleared and seeded again" {
    mkdir -p "$ROOTFS/.stateful-pods" "$ROOTFS/usr/bin"
    : > "$ROOTFS/.stateful-pods/seeding"
    echo half > "$ROOTFS/usr/bin/leftover"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/usr/bin/leftover" ]
    [ -e "$ROOTFS/sbin/init" ]
    filled
}

@test "a failing fill leaves no marker and reports the cause" {
    sp_fill_rootfs() {
        echo "the archive could not be opened" >&2
        return 1
    }
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
    [[ "$output" == *"could not be opened"* ]]
}

@test "the runtime directories exist and are empty after seeding" {
    sp_fill_rootfs() {
        mkdir -p "$1/usr" "$1/dev" "$1/tmp"
        echo stale > "$1/dev/leftover"
        echo stale > "$1/tmp/leftover"
    }
    run sp_seed_main
    [ "$status" -eq 0 ]
    for d in dev proc sys run tmp; do
        [ -d "$ROOTFS/$d" ]
        [ -z "$(ls -A "$ROOTFS/$d")" ]
    done
}

@test "a missing rootfs path is reported rather than assumed" {
    export SP_ROOTFS="$ROOTFS/does-not-exist"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"does-not-exist"* ]]
}

@test "the runtime directories are recreated with the modes a guest expects" {
    just_seeded_fill() { mkdir -p "$1/usr"; }
    run sp_seed_main
    [ "$status" -eq 0 ]
    # /run world-writable would be a hole; /tmp not sticky breaks every Unix.
    [ "$(stat -c %a "$ROOTFS/run")" = "755" ]
    [ "$(stat -c %a "$ROOTFS/dev")" = "755" ]
    [ "$(stat -c %a "$ROOTFS/tmp")" = "1777" ]
}
