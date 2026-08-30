#!/usr/bin/env bats
#
# The marker and the machine's identity.
#
# The marker is what makes seeding happen once, so when it is written matters as
# much as what it says: it replaces the in-progress file only after the fill has
# succeeded, and it records which machine the volume was filled for so that a
# volume restored under another name is recognised as a clone rather than
# silently sharing an identity.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_NAMESPACE=homelab
    export SP_RELEASE=lab
    export SP_MACHINE=web
    export SP_CHART_VERSION=0.1.0
    export SP_SOURCE_KIND=oci
    export SP_SOURCE_REFERENCE=docker.io/library/debian:13
    mkdir -p "$ROOTFS/etc" "$ROOTFS/usr/bin" "$ROOTFS/.stateful-pods"
    echo 'ID=debian' > "$ROOTFS/etc/os-release"
}

teardown() {
    rm -rf "$ROOTFS"
}

just_seeded() { : > "$ROOTFS/.stateful-pods/seeding"; }

marker() { echo "$ROOTFS/.stateful-pods/provisioned"; }

field() { jq -r "$1" "$(marker)"; }

prepare() { run bash "$SCRIPTS/prepare.sh"; }

@test "the marker is written after a successful seeding" {
    just_seeded
    prepare
    [ "$status" -eq 0 ]
    [ -f "$(marker)" ]
    [ ! -f "$ROOTFS/.stateful-pods/seeding" ]
}

@test "the marker records the machine it was seeded for" {
    just_seeded
    prepare
    [ "$(field .machine.namespace)" = "homelab" ]
    [ "$(field .machine.release)" = "lab" ]
    [ "$(field .machine.name)" = "web" ]
}

@test "the marker records the source precisely enough to tell two apart" {
    just_seeded
    prepare
    [ "$(field .source.kind)" = "oci" ]
    [ "$(field .source.reference)" = "docker.io/library/debian:13" ]
}

# Without this the volume records a digest and nothing else. A digest answers
# "what was this made from" only for as long as the reference is still in the
# catalog, and the question is usually asked long after it has aged out.
@test "the marker records which preset the machine was made from" {
    export SP_SOURCE_PRESET=debian-trixie
    just_seeded
    prepare
    [ "$status" -eq 0 ]
    [ "$(field .source.kind)" = "oci" ]
    [ "$(field .source.preset)" = "debian-trixie" ]
    [ "$(field .source.reference)" = "docker.io/library/debian:13" ]
}

# An additive field, so the record's schema version does not move and a reader
# written before presets existed is unaffected by them.
@test "the marker leaves the preset field out when the source is not a preset" {
    just_seeded
    prepare
    [ "$status" -eq 0 ]
    [ "$(field '.source | has("preset")')" = "false" ]
    [ "$(field .schemaVersion)" = "1" ]
}

@test "the marker records an lxc source with its url and checksum" {
    just_seeded
    export SP_SOURCE_KIND=lxc
    unset SP_SOURCE_REFERENCE
    export SP_SOURCE_URL=https://example.test/debian.tar.zst
    export SP_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000
    prepare
    [ "$status" -eq 0 ]
    [ "$(field .source.kind)" = "lxc" ]
    [ "$(field .source.url)" = "https://example.test/debian.tar.zst" ]
    [ "$(field .source.sha256)" = "0000000000000000000000000000000000000000000000000000000000000000" ]
}

@test "the marker records the chart version, a timestamp and a schema version" {
    just_seeded
    prepare
    [ "$(field .chartVersion)" = "0.1.0" ]
    [ "$(field .schemaVersion)" = "1" ]
    [[ "$(field .seededAt)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "the marker is valid json" {
    just_seeded
    prepare
    run jq empty "$(marker)"
    [ "$status" -eq 0 ]
}

@test "seeding clears the machine identity inherited from the image" {
    just_seeded
    echo "deadbeefdeadbeefdeadbeefdeadbeef" > "$ROOTFS/etc/machine-id"
    mkdir -p "$ROOTFS/var/lib/dbus"
    echo "deadbeefdeadbeefdeadbeefdeadbeef" > "$ROOTFS/var/lib/dbus/machine-id"
    prepare
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS/etc/machine-id" ]
    [ ! -s "$ROOTFS/etc/machine-id" ]
    [ ! -e "$ROOTFS/var/lib/dbus/machine-id" ]
}

@test "an image with no machine id is not given one" {
    just_seeded
    prepare
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/etc/machine-id" ] || [ ! -s "$ROOTFS/etc/machine-id" ]
}

@test "an ordinary restart changes nothing" {
    just_seeded
    prepare
    before="$(cat "$(marker)")"
    echo "guest data" > "$ROOTFS/usr/bin/written-by-guest"
    echo "1111111111111111" > "$ROOTFS/etc/machine-id"
    prepare
    [ "$status" -eq 0 ]
    [ "$(cat "$(marker)")" = "$before" ]
    [ "$(cat "$ROOTFS/etc/machine-id")" = "1111111111111111" ]
    [ -e "$ROOTFS/usr/bin/written-by-guest" ]
}

@test "a volume restored under a different machine name is a clone" {
    just_seeded
    prepare
    echo "1111111111111111" > "$ROOTFS/etc/machine-id"
    export SP_MACHINE=web2
    prepare
    [ "$status" -eq 0 ]
    [ ! -s "$ROOTFS/etc/machine-id" ]
    [ "$(field .machine.name)" = "web2" ]
}

@test "a volume restored under a different release is a clone" {
    just_seeded
    prepare
    echo "1111111111111111" > "$ROOTFS/etc/machine-id"
    export SP_RELEASE=lab2
    prepare
    [ "$status" -eq 0 ]
    [ ! -s "$ROOTFS/etc/machine-id" ]
    [ "$(field .machine.release)" = "lab2" ]
}

@test "a volume restored under a different namespace is a clone" {
    just_seeded
    prepare
    echo "1111111111111111" > "$ROOTFS/etc/machine-id"
    export SP_NAMESPACE=other
    prepare
    [ "$status" -eq 0 ]
    [ ! -s "$ROOTFS/etc/machine-id" ]
    [ "$(field .machine.namespace)" = "other" ]
}

@test "a clone records where it came from" {
    just_seeded
    prepare
    export SP_MACHINE=web2
    prepare
    [ "$(field .clonedFrom.name)" = "web" ]
    [ "$(field .clonedFrom.release)" = "lab" ]
}

@test "a clone is not re-seeded and keeps its data" {
    just_seeded
    prepare
    echo "years of state" > "$ROOTFS/usr/bin/written-by-guest"
    export SP_MACHINE=web2
    prepare
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/usr/bin/written-by-guest")" = "years of state" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "a volume with neither a marker nor a seeding record is refused" {
    prepare
    [ "$status" -ne 0 ]
    [[ "$output" == *"web"* ]]
}
