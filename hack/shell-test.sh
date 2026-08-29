#!/usr/bin/env bash
#
# Runs the bats suites for the scripts the shim image carries.
#
# Always inside a Linux container, on every host including CI. The scripts exist
# to manipulate another system's root filesystem, so what they do - ownership,
# extended attributes, file capabilities, running out of space - only exists on
# Linux and only reproducibly in a fixed environment. One environment everywhere
# means a failure here is the same failure there.
set -o errexit
set -o nounset
set -o pipefail

SUITE_DIR="${SUITE_DIR:-test/shell}"
TEST_IMAGE="${TEST_IMAGE:-stateful-pods-shell-test:local}"
ENGINE="${CONTAINER_ENGINE:-docker}"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "the shell tests need a container engine; '$ENGINE' was not found" >&2
  echo "install one, or set CONTAINER_ENGINE" >&2
  exit 1
fi

if [[ "${REBUILD_TEST_IMAGE:-0}" == "1" ]] || ! "$ENGINE" image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
  echo "==> building the shell test image $TEST_IMAGE"
  "$ENGINE" build --tag "$TEST_IMAGE" --file test/shell/Containerfile.test test/shell
fi

echo "==> running the shell tests in $TEST_IMAGE"
# /small is a deliberately tiny filesystem, so that running out of room during a
# copy is a case the suite can actually exercise rather than assume.
exec "$ENGINE" run --rm \
  --volume "$PWD:/src:ro" \
  --tmpfs /small:size=8m,exec,mode=1777 \
  --workdir /src \
  "$TEST_IMAGE" \
  bats --recursive "$SUITE_DIR"
