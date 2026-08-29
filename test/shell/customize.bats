#!/usr/bin/env bats
#
# The three files the chart maintains inside a machine.
#
# A pod is given them as mounts into the container image's filesystem. Once the
# machine's root becomes the volume those mounts are somewhere else entirely, so a
# machine that did nothing would boot with whatever its source image shipped: no
# resolver, and a host name belonging to the image's build machine.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    POD="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    export SP_POD_ETC="$POD"
    mkdir -p "$ROOTFS/etc"
    printf 'lab-web-0\n'                     > "$POD/hostname"
    printf '127.0.0.1 localhost\n10.0.0.5 lab-web-0\n' > "$POD/hosts"
    printf 'nameserver 10.96.0.10\nsearch homelab.svc.cluster.local\n' > "$POD/resolv.conf"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-customize.sh"
}

teardown() { rm -rf "$ROOTFS" "$POD"; }

@test "the machine is given the host name the pod was given" {
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = "lab-web-0" ]
}

@test "the machine can resolve names" {
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q 'nameserver 10.96.0.10' "$ROOTFS/etc/resolv.conf"
    grep -q 'search homelab' "$ROOTFS/etc/resolv.conf"
}

@test "the machine's host table is the pod's" {
    run sp_customize "$ROOTFS"
    grep -q 'lab-web-0' "$ROOTFS/etc/hosts"
}

@test "the values are refreshed on a later boot, not seeded once" {
    sp_customize "$ROOTFS"
    printf 'nameserver 10.96.0.99\n' > "$POD/resolv.conf"
    printf '10.0.0.9 lab-web-0\n' > "$POD/hosts"
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q '10.96.0.99' "$ROOTFS/etc/resolv.conf"
    grep -q '10.0.0.9' "$ROOTFS/etc/hosts"
}

@test "a file the machine claims is left alone" {
    sp_customize "$ROOTFS"
    printf 'nameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"
    : > "$ROOTFS/etc/.stateful-pods-ignore.resolv.conf"
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/resolv.conf")" = "nameserver 1.1.1.1" ]
}

@test "a claimed file is not removed either" {
    : > "$ROOTFS/etc/.stateful-pods-ignore.resolv.conf"
    printf 'nameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"
    sp_customize "$ROOTFS"
    [ -f "$ROOTFS/etc/resolv.conf" ]
}

@test "claiming one file does not claim the others" {
    : > "$ROOTFS/etc/.stateful-pods-ignore.resolv.conf"
    printf 'nameserver 1.1.1.1\n' > "$ROOTFS/etc/resolv.conf"
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/hostname")" = "lab-web-0" ]
    grep -q 'lab-web-0' "$ROOTFS/etc/hosts"
    [ "$(cat "$ROOTFS/etc/resolv.conf")" = "nameserver 1.1.1.1" ]
}

@test "each of the three files can be claimed independently" {
    for f in hostname hosts resolv.conf; do
        rm -rf "${ROOTFS:?}/etc"
        mkdir -p "$ROOTFS/etc"
        : > "$ROOTFS/etc/.stateful-pods-ignore.$f"
        printf 'claimed\n' > "$ROOTFS/etc/$f"
        run sp_customize "$ROOTFS"
        [ "$status" -eq 0 ]
        [ "$(cat "$ROOTFS/etc/$f")" = "claimed" ]
    done
}

@test "the claim travels with the machine, not with the release" {
    : > "$ROOTFS/etc/.stateful-pods-ignore.hostname"
    printf 'chosen-by-the-guest\n' > "$ROOTFS/etc/hostname"
    SP_RELEASE=lab sp_customize "$ROOTFS"
    SP_RELEASE=other-release sp_customize "$ROOTFS"
    [ "$(cat "$ROOTFS/etc/hostname")" = "chosen-by-the-guest" ]
}

@test "a machine whose etc is missing still gets its files" {
    rm -rf "${ROOTFS:?}/etc"
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS/etc/hostname" ]
}

@test "a file the pod itself was not given is skipped rather than emptied" {
    rm -f "$POD/resolv.conf"
    run sp_customize "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/etc/resolv.conf" ]
    [ -f "$ROOTFS/etc/hostname" ]
}

@test "the managed files are readable by the machine" {
    sp_customize "$ROOTFS"
    for f in hostname hosts resolv.conf; do
        [ "$(stat -c %a "$ROOTFS/etc/$f")" = "644" ]
    done
}
