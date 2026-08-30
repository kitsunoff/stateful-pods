#!/usr/bin/env bash
#
# Asserts the properties the toolbox image exists for, against a busybox-only
# image as the control:
#
#   1. it can open a zstd-compressed tarball at all - busybox has no zstd support
#      whatsoever, and Proxmox distributes its templates as .tar.zst;
#   2. it preserves security.capability through an unpack - busybox tar has no
#      extended-attribute support, so it drops file capabilities silently and the
#      resulting rootfs looks fine until an unprivileged `ping` fails forever;
#   3. it can fetch an image from a registry and flatten it into the same tar,
#      keeping security.capability and honouring the layer whiteouts.
#
# The third is what an oci source now depends on: the chart fetches the image
# itself rather than running it, so a flatten that dropped an attribute or
# resurrected a deleted file would seed a rootfs that looks correct and is not.
#
# Every failure above is invisible in an ordinary smoke test, which is why they
# get one of their own.
#
# The shared scratch space is a named volume rather than a bind mount: extended
# attributes are the subject of the test, and a bind mount from a non-Linux host
# cannot carry them.
#
# The command strings below are single-quoted on purpose: they are expanded by a
# shell inside a container, and $REGISTRY reaches that shell through the
# environment rather than through this one.
# shellcheck disable=SC2016
set -o errexit
set -o nounset
set -o pipefail

IMAGE="${IMAGE:-stateful-pods-shim:dev}"
CONTROL_IMAGE="${CONTROL_IMAGE:-alpine:3.22}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
ENGINE="${CONTAINER_ENGINE:-docker}"
VOLUME="stateful-pods-image-test-$$"
NETWORK="stateful-pods-image-test-$$"
REGISTRY_CONTAINER="stateful-pods-image-test-registry-$$"
# go-containerregistry speaks plain HTTP to a registry whose name ends in
# `.local`, so a throwaway registry needs no certificate and the chart needs no
# insecure-registry input. The same rule is what makes an in-cluster
# `<service>.<namespace>.svc.cluster.local` name work.
REGISTRY="registry.stateful-pods.local:5000"

cleanup() {
  "$ENGINE" rm --force "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
  "$ENGINE" volume rm --force "$VOLUME" >/dev/null 2>&1 || true
  "$ENGINE" network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$ENGINE" volume create "$VOLUME" >/dev/null
"$ENGINE" network create "$NETWORK" >/dev/null
"$ENGINE" run --detach --name "$REGISTRY_CONTAINER" \
  --network "$NETWORK" --network-alias "${REGISTRY%%:*}" \
  "$REGISTRY_IMAGE" >/dev/null

in_image() {
  "$ENGINE" run --rm --network "$NETWORK" --env "REGISTRY=$REGISTRY" \
    --volume "$VOLUME:/work" --entrypoint /bin/bash "$IMAGE" -c "$1"
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

echo "==> 4. the registry is reachable from the toolbox image"
# The registry starts asynchronously, so this waits for it rather than racing it.
registry_up=0
for _ in $(seq 1 30); do
  if in_image 'crane catalog "$REGISTRY"' >/dev/null 2>&1; then
    registry_up=1
    break
  fi
  sleep 1
done
if [[ "$registry_up" -eq 1 ]]; then
  pass "the toolbox image reaches the test registry over plain HTTP"
else
  fail "the test registry never became reachable from $IMAGE at $REGISTRY"
fi

echo "==> building the fixture image with crane, from tarballs made by GNU tar"
# No container builder is involved: `crane append` turns a layer tarball into an
# image and pushes it, so the fixture's two layers are exactly the two tarballs
# below. The first carries a file with a capability and a file the second layer
# deletes; the second carries nothing but that deletion, as a `.wh.` entry.
if ! fixture_log="$(in_image '
set -eu
rm -rf /work/layer1 /work/layer2 /work/layer1.tar /work/layer2.tar
mkdir -p /work/layer1/sbin /work/layer1/etc /work/layer2/etc
cp /bin/busybox /work/layer1/sbin/probe
setcap cap_net_raw+ep /work/layer1/sbin/probe
getcap /work/layer1/sbin/probe | grep -q cap_net_raw
echo removed > /work/layer1/etc/sp-removed
echo kept > /work/layer1/etc/sp-kept
tar -C /work/layer1 --numeric-owner --xattrs --xattrs-include=security.capability \
  -cf /work/layer1.tar .
: > /work/layer2/etc/.wh.sp-removed
tar -C /work/layer2 --numeric-owner -cf /work/layer2.tar .
crane append --new_layer /work/layer1.tar --new_tag "$REGISTRY/fixture:base"
crane append --base "$REGISTRY/fixture:base" --new_layer /work/layer2.tar \
  --new_tag "$REGISTRY/fixture:v1"
' 2>&1)"; then
  echo "$fixture_log" >&2
  fail "could not build the fixture image; the assertions below would prove nothing"
fi

echo "==> 5. the fixture really is a two-layer image"
if in_image '
set -eu
[ "$(crane manifest "$REGISTRY/fixture:v1" | jq -r ".layers | length")" = "2" ]
' >/dev/null 2>&1; then
  pass "the fixture image has two layers, so the whiteout has something to remove"
else
  fail "the fixture image is not two layers; the whiteout assertion would prove nothing"
fi

echo "==> 6. crane export preserves the capability and honours the whiteout"
if in_image '
set -eu
set -o pipefail
rm -rf /work/out-oci && mkdir -p /work/out-oci
# The flags the chart itself extracts with, taken from the image rather than
# repeated here: a copy of them could drift from what a machine really gets
# while this assertion went on passing.
. /usr/local/lib/stateful-pods/lib-seed.sh
crane export "$REGISTRY/fixture:v1" - \
  | tar -C /work/out-oci -xp $SP_TAR_FLAGS -f -
getcap /work/out-oci/sbin/probe | grep -q cap_net_raw
test -f /work/out-oci/etc/sp-kept
test ! -e /work/out-oci/etc/sp-removed
test ! -e /work/out-oci/etc/.wh.sp-removed
' >/dev/null 2>&1; then
  pass "crane export keeps security.capability and applies the layer whiteout"
else
  fail "crane export lost the capability, kept a deleted file, or left a whiteout entry behind"
fi

echo "==> 7. every entry point the chart names is executable"
# A container whose command is not executable fails the moment it starts, naming
# a path and nothing else - and it fails for every machine at once, because the
# chart runs every one of its containers from this image. The rule is derived
# from the scripts rather than listed here: a script carrying a shebang is one
# something executes, and a lib-*.sh is only ever sourced. An entry point added
# without its line in the Containerfile is caught by this and by nothing else.
if in_image '
set -eu
status=0
for script in /usr/local/lib/stateful-pods/*.sh; do
  case "$(basename "$script")" in
    lib-*)
      if [ -x "$script" ]; then
        echo "$script is executable, but a lib-*.sh is only ever sourced" >&2
        status=1
      fi
      ;;
    *)
      if ! head -n 1 "$script" | grep -q "^#!"; then
        echo "$script carries no shebang but is not a lib-*.sh" >&2
        status=1
      elif [ ! -x "$script" ]; then
        echo "$script is an entry point and is not executable" >&2
        status=1
      fi
      ;;
  esac
done
exit "$status"
' >/dev/null 2>&1; then
  pass "every entry point is executable and every sourced library is not"
else
  fail "a script the chart runs as a container command is not executable"
fi

echo "all image assertions held"
