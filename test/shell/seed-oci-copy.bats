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

# Packs a tree the way `crane export` writes one.
#
# The member names are the point. go-containerregistry cleans every header name,
# so a flattened image is `dev` and `etc/os-release` and never `./dev` - a
# fixture built with `tar -cf out .` produces a shape crane cannot emit, and an
# exclusion asserted against it would pass while excluding nothing.
pack_like_crane() {
    local src="$1" out="$2"
    ( cd "$src" && tar --numeric-owner --xattrs \
        --xattrs-include=security.capability -cf "$out" -- * )
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
    pack_like_crane "$src" "$FIXTURE_DIR/image.tar"
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
    pack_like_crane "$src" "$FIXTURE_DIR/bare.tar"
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

# A fetch that fails with a message of its own, the way crane's does when an
# index offers no build for the platform it was asked for.
stub_refusing_crane() {
    local message="$1"
    cat > "$STUB_DIR/crane" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$STUB_DIR/args"
echo "$message" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/crane"
}

crane_arg_after() {
    grep -A1 -x -- "$1" "$STUB_DIR/args" | tail -n 1
}

expected_platform() {
    case "$(uname -m)" in
        x86_64)  echo linux/amd64 ;;
        aarch64) echo linux/arm64 ;;
        *)       return 1 ;;
    esac
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
    expected="$(expected_platform)" || skip "no platform is claimed for $(uname -m)"
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
    pack_like_crane "$FIXTURE_DIR/src" "$FIXTURE_DIR/image.tar"
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

@test "a source that offers no build for this node is refused, naming the platform" {
    expected="$(expected_platform)" || skip "no platform is claimed for $(uname -m)"
    stub_refusing_crane "no child with platform $expected in index"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
    # The platform that was required, and what the source had to say about it.
    [[ "$output" == *"$expected"* ]]
    [[ "$output" == *"no child with platform"* ]]
    [ ! -e "$ROOTFS/etc" ]
}

@test "device nodes in the source are not written to the volume" {
    make_image_tar
    mkdir -p "$FIXTURE_DIR/src/dev"
    mknod "$FIXTURE_DIR/src/dev/null" c 1 3 2>/dev/null \
        || skip "this environment cannot create a device node to seed from"
    pack_like_crane "$FIXTURE_DIR/src" "$FIXTURE_DIR/image.tar"
    stub_crane "$FIXTURE_DIR/image.tar"

    # A device node cannot be recreated in a machine's own user namespace at
    # all, so one taken from a source image would fail the whole seed over
    # content the driver discards a moment later.
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/dev/null" ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "the kernel and runtime directories are not taken from the source" {
    make_image_tar
    mkdir -p "$FIXTURE_DIR/src/proc" "$FIXTURE_DIR/src/sys" "$FIXTURE_DIR/src/run"
    mkdir -p "$FIXTURE_DIR/src/usr/local/dev"
    echo stale > "$FIXTURE_DIR/src/run/leftover"
    echo stale > "$FIXTURE_DIR/src/proc/leftover"
    echo kept > "$FIXTURE_DIR/src/usr/local/dev/keep-me"
    pack_like_crane "$FIXTURE_DIR/src" "$FIXTURE_DIR/image.tar"
    stub_crane "$FIXTURE_DIR/image.tar"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/run/leftover" ]
    [ ! -e "$ROOTFS/proc/leftover" ]
    # Excluding `dev` must not also exclude a directory that merely ends in it.
    [ -e "$ROOTFS/usr/local/dev/keep-me" ]
}

@test "a rejected credential names the secret that was used" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    export SP_SOURCE_PULL_SECRET=registry-credentials
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *registry-credentials* ]]
}

@test "a rejected credential is not echoed into the message" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    export SP_SOURCE_PULL_SECRET=registry-credentials
    export DOCKER_CONFIG="$STUB_DIR/auth"
    mkdir -p "$DOCKER_CONFIG"
    cat > "$DOCKER_CONFIG/config.json" <<'JSON'
{"auths":{"registry.example.test":{"auth":"c3VwZXItc2VjcmV0LXRva2Vu"}}}
JSON
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" != *c3VwZXItc2VjcmV0LXRva2Vu* ]]
    [[ "$output" != *super-secret-token* ]]
}

@test "no secret is mentioned when the machine names none" {
    make_image_tar
    stub_crane "$FIXTURE_DIR/image.tar" 1
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" != *secret* ]]
}

@test "a producer signalled after the unpack finished is not a failed fetch" {
    make_image_tar
    # tar closes the pipe at the end-of-archive marker, so a producer still
    # writing is killed with SIGPIPE. The seed succeeded; the signal is only how
    # the pipeline ended.
    cat > "$STUB_DIR/crane" <<EOF
#!/bin/sh
cat "$FIXTURE_DIR/image.tar"
exit 141
EOF
    chmod +x "$STUB_DIR/crane"
    run sp_fill_rootfs "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -e "$ROOTFS/etc/os-release" ]
}

@test "a volume that cannot hold the image is reported as an unpack, not a fetch" {
    [ -d /small ] || skip "no size-limited filesystem available"
    make_image_tar
    dd if=/dev/urandom of="$FIXTURE_DIR/src/blob" bs=1M count=32 status=none
    pack_like_crane "$FIXTURE_DIR/src" "$FIXTURE_DIR/image.tar"
    stub_crane "$FIXTURE_DIR/image.tar"
    small="/small/rootfs3"
    rm -rf "$small"
    mkdir -p "$small"
    run sp_fill_rootfs "$small"
    [ "$status" -ne 0 ]
    # The registry did nothing wrong, and saying it did sends the reader to the
    # wrong place entirely.
    [[ "$output" == *unpacking* ]]
    [[ "$output" != *"failed with status 141"* ]]
}
