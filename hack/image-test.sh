#!/usr/bin/env bash
#
# Asserts the two properties the toolbox image exists for, against a busybox-only
# image as the control:
#
#   1. it can open a zstd-compressed tarball at all - busybox has no zstd support
#      whatsoever, and Proxmox distributes its templates as .tar.zst;
#   2. it preserves security.capability through an unpack - busybox tar has no
#      extended-attribute support, so it drops file capabilities silently and the
#      resulting rootfs looks fine until an unprivileged `ping` fails forever.
#
# Both failures are invisible in an ordinary smoke test, which is why they get one
# of their own.
#
# The shared scratch space is a named volume rather than a bind mount: extended
# attributes are the subject of the test, and a bind mount from a non-Linux host
# cannot carry them.
set -o errexit
set -o nounset
set -o pipefail

IMAGE="${IMAGE:-stateful-pods-shim:dev}"
CONTROL_IMAGE="${CONTROL_IMAGE:-alpine:3.22}"
ENGINE="${CONTAINER_ENGINE:-docker}"
VOLUME="stateful-pods-image-test-$$"

cleanup() { "$ENGINE" volume rm --force "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$ENGINE" volume create "$VOLUME" >/dev/null

in_image() {
  "$ENGINE" run --rm --volume "$VOLUME:/work" --entrypoint /bin/bash "$IMAGE" -c "$1"
}
in_control() {
  "$ENGINE" run --rm --volume "$VOLUME:/work" --entrypoint /bin/sh "$CONTROL_IMAGE" -c "$1"
}

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

echo "==> building the fixture archives in $IMAGE"
in_image '
set -eu
rm -rf /work/src /work/fixture.tar.zst /work/fixture.tar.gz
mkdir -p /work/src/sbin
cp /bin/busybox /work/src/sbin/probe
setcap cap_net_raw+ep /work/src/sbin/probe
getcap /work/src/sbin/probe | grep -q cap_net_raw
tar -C /work/src --numeric-owner --xattrs --xattrs-include=security.capability -cf - . \
  | zstd -q -o /work/fixture.tar.zst
tar -C /work/src --numeric-owner --xattrs --xattrs-include=security.capability -czf /work/fixture.tar.gz .
' >/dev/null

echo "==> 1. the toolbox image unpacks .tar.zst and keeps the capability"
if in_image '
set -eu
rm -rf /work/out-zst && mkdir -p /work/out-zst
zstd -dc /work/fixture.tar.zst \
  | tar -C /work/out-zst --xattrs --xattrs-include=security.capability -xpf -
getcap /work/out-zst/sbin/probe | grep -q cap_net_raw
' >/dev/null 2>&1; then
  pass "toolbox unpacks .tar.zst preserving security.capability"
else
  fail "toolbox lost the capability, or could not open the archive"
fi

echo "==> 2. a busybox-only image cannot open .tar.zst at all"
if in_control '
set -eu
rm -rf /work/out-ctl-zst && mkdir -p /work/out-ctl-zst
tar -C /work/out-ctl-zst -xpf /work/fixture.tar.zst
' >/dev/null 2>&1; then
  fail "the control image opened a .tar.zst; it is not busybox-only and proves nothing"
else
  pass "busybox-only image cannot open .tar.zst, as expected"
fi

echo "==> 3. a busybox-only image unpacks .tar.gz but drops the capability"
in_control '
set -eu
rm -rf /work/out-ctl-gz && mkdir -p /work/out-ctl-gz
tar -C /work/out-ctl-gz -xpf /work/fixture.tar.gz
' >/dev/null
if in_image 'getcap /work/out-ctl-gz/sbin/probe 2>/dev/null | grep -q cap_net_raw' >/dev/null 2>&1; then
  fail "the control image kept the capability; the extended-attribute claim is wrong"
else
  pass "busybox-only image dropped security.capability, as expected"
fi

echo "all image assertions held"
