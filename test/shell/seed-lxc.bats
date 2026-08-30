#!/usr/bin/env bats
#
# The template path. A template is an ordinary tarball fetched over the network
# and unpacked into what becomes a privileged machine's root filesystem, so the
# order here is the whole point: verify the bytes, then check they are a root
# filesystem, and only then write anything.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    SERVE="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=db
    export SP_RELEASE=lab
    export SP_NAMESPACE=homelab
    export SP_SOURCE_KIND=lxc
    # Fixtures are served from disk; the chart itself only ever fetches over HTTPS.
    export SP_ALLOWED_PROTOCOLS="=https,file"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-lxc.sh"
    mkdir -p "$ROOTFS/.stateful-pods"
}

teardown() {
    rm -rf "$ROOTFS" "$SERVE"
}

# Builds a plausible rootfs tarball: enough members and an sbin entry, so that it
# passes inspection for the tests that are not about inspection.
make_template() {
    local compressor="$1" out="$2"
    local src="$SERVE/src"
    rm -rf "$src"
    mkdir -p "$src/sbin" "$src/etc" "$src/usr/bin" "$src/usr/lib" "$src/var/lib" "$src/opt"
    cp /bin/true "$src/sbin/init"
    setcap cap_net_raw+ep "$src/sbin/init"
    echo 'ID=debian' > "$src/etc/os-release"
    for n in 1 2 3 4 5 6; do echo "file $n" > "$src/usr/bin/f$n"; done
    pack_template "$compressor" "$out"
}

# Packs whatever is in $SERVE/src, which make_template has just built. Split out
# of it so a test can add to that tree - a device node, a stale runtime
# directory - and pack the result without restating how a template is made.
pack_template() {
    local compressor="$1" out="$2"
    tar -C "$SERVE/src" --numeric-owner --xattrs --xattrs-include=security.capability \
        -cf "$SERVE/plain.tar" .
    case "$compressor" in
        zst) zstd -q -f -o "$out" "$SERVE/plain.tar" ;;
        xz)  xz -c "$SERVE/plain.tar" > "$out" ;;
        gz)  gzip -c "$SERVE/plain.tar" > "$out" ;;
    esac
}

digest_of() { sha256sum "$1" | cut -d' ' -f1; }

@test "a template with a matching checksum is unpacked" {
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/sbin/init" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

# An LXC template is far likelier than a crane export stream to carry real
# device nodes: Proxmox's own templates routinely ship ./dev/console and
# ./dev/null. mknod(2) checks the capability in the *initial* user namespace, so
# a machine in `userns` mode cannot recreate one whatever it is granted - tar
# fails with EPERM and takes the whole seed down over content the driver wipes
# and recreates empty a moment later.
#
# sp_fill_rootfs is called here rather than sp_seed_main on purpose: the driver
# clears the runtime directories as soon as the fill returns, so a test that
# went through it would pass whether or not anything was excluded.
@test "device nodes in the template are not written to the volume" {
    make_template zst "$SERVE/t.tar.zst"
    mkdir -p "$SERVE/src/dev"
    mknod "$SERVE/src/dev/null" c 1 3 2>/dev/null \
        || skip "this environment cannot create a device node to seed from"
    pack_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/dev/null" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "the kernel and runtime directories are not taken from the template" {
    make_template zst "$SERVE/t.tar.zst"
    mkdir -p "$SERVE/src/proc" "$SERVE/src/sys" "$SERVE/src/run" "$SERVE/src/tmp"
    # Anchored, so a directory that merely ends in one of the names is kept.
    mkdir -p "$SERVE/src/usr/local/dev"
    echo stale > "$SERVE/src/run/leftover"
    echo stale > "$SERVE/src/proc/leftover"
    echo kept > "$SERVE/src/usr/local/dev/keep-me"
    pack_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/run/leftover" ]
    [ ! -e "$ROOTFS/proc/leftover" ]
    [ -e "$ROOTFS/usr/local/dev/keep-me" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "a file capability in the template survives extraction" {
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_seed_main
    [ "$status" -eq 0 ]
    run getcap "$ROOTFS/sbin/init"
    [[ "$output" == *cap_net_raw* ]]
}

@test "a mismatched checksum unpacks nothing and says the bytes are wrong" {
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -e "$ROOTFS/sbin" ]
    [[ "$output" == *"not the bytes"* ]]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
}

@test "the mismatch message shows both digests" {
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    run sp_seed_main
    [[ "$output" == *"0000000000000000000000000000000000000000000000000000000000000000"* ]]
    [[ "$output" == *"$(digest_of "$SERVE/t.tar.zst")"* ]]
}

@test "an unreachable template names the url and fails" {
    export SP_SOURCE_URL="https://stateful-pods.invalid/nothing.tar.zst"
    export SP_SOURCE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"stateful-pods.invalid"* ]]
    [ ! -f "$ROOTFS/.stateful-pods/provisioned" ]
}

@test "an archive with no sbin entry is rejected before extraction" {
    local src="$SERVE/bad"
    mkdir -p "$src/usr/bin"
    for n in 1 2 3 4 5 6 7 8 9 10 11 12; do echo x > "$src/usr/bin/f$n"; done
    tar -C "$src" -cf - . | zstd -q -o "$SERVE/bad.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/bad.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/bad.tar.zst")"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"sbin"* ]]
    [ ! -e "$ROOTFS/usr" ]
}

@test "an archive with too few members is rejected before extraction" {
    local src="$SERVE/tiny"
    mkdir -p "$src/sbin"
    cp /bin/true "$src/sbin/init"
    tar -C "$src" -cf - . | zstd -q -o "$SERVE/tiny.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/tiny.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/tiny.tar.zst")"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"members"* ]]
    [ ! -e "$ROOTFS/sbin" ]
}

@test "a multi-volume archive is rejected before extraction" {
    local src="$SERVE/multi"
    mkdir -p "$src/sbin" "$src/usr/bin"
    cp /bin/true "$src/sbin/init"
    # 3 MiB of content split into 1 MiB volumes yields a multi-volume set.
    for n in 1 2 3 4 5 6 7 8 9 10; do
        head -c 300000 /dev/urandom > "$src/usr/bin/f$n"
    done
    ( cd "$src" && tar --create --multi-volume --tape-length=1M \
        --file="$SERVE/multi.tar" --file="$SERVE/multi.tar.2" --file="$SERVE/multi.tar.3" . ) >/dev/null 2>&1
    zstd -q -f -o "$SERVE/multi.tar.zst" "$SERVE/multi.tar.2"
    export SP_SOURCE_URL="file://$SERVE/multi.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/multi.tar.zst")"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -e "$ROOTFS/sbin" ]
}

@test "an uncompressed multi-volume archive is rejected by its member flags" {
    local src="$SERVE/multi2"
    mkdir -p "$src/sbin" "$src/usr/bin"
    cp /bin/true "$src/sbin/init"
    for n in 1 2 3 4 5 6 7 8 9 10; do
        head -c 300000 /dev/urandom > "$src/usr/bin/f$n"
    done
    ( cd "$src" && tar --create --multi-volume --tape-length=1M \
        --file="$SERVE/m2.tar" --file="$SERVE/m2.tar.2" --file="$SERVE/m2.tar.3" . ) >/dev/null 2>&1
    # The second volume lists cleanly and carries a continued member, so it gets
    # past the listing check and has to be caught by the member flags.
    tar --list --verbose --file "$SERVE/m2.tar.2" | grep -q '^M'
    export SP_SOURCE_URL="file://$SERVE/m2.tar.2"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/m2.tar.2")"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"multi-volume"* ]]
    [ ! -e "$ROOTFS/sbin" ]
}

@test "an unreachable template is refused when only https is allowed" {
    export SP_ALLOWED_PROTOCOLS="=https"
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_seed_main
    [ "$status" -ne 0 ]
    [ ! -e "$ROOTFS/sbin" ]
}

@test "an xz template extracts" {
    make_template xz "$SERVE/t.tar.xz"
    export SP_SOURCE_URL="file://$SERVE/t.tar.xz"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.xz")"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/sbin/init" ]
}

@test "a gzip template extracts" {
    make_template gz "$SERVE/t.tar.gz"
    export SP_SOURCE_URL="file://$SERVE/t.tar.gz"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.gz")"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/sbin/init" ]
}

@test "the downloaded tarball is not left on the volume" {
    make_template zst "$SERVE/t.tar.zst"
    export SP_SOURCE_URL="file://$SERVE/t.tar.zst"
    export SP_SOURCE_SHA256="$(digest_of "$SERVE/t.tar.zst")"
    run sp_seed_main
    [ "$status" -eq 0 ]
    [ ! -d "$ROOTFS/.stateful-pods/download" ] || [ -z "$(ls -A "$ROOTFS/.stateful-pods/download")" ]
}
