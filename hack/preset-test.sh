#!/usr/bin/env bash
#
# Runs the bats suite for the preset build.
#
# In a container for the same reason the shim's suite is: the build's job is to
# refuse things, and what it refuses must not depend on which gpg, which curl or
# which coreutils the person running it happens to have. A verification that
# passes on one machine and not another is not a verification.
#
# Nothing here touches a registry. The suite runs against a mirror on the local
# filesystem and a repository on a port nothing listens on, so a build that got
# as far as packaging would fail with a connection error instead of the refusal
# the assertions expect.
set -o errexit
set -o nounset
set -o pipefail

SUITE_DIR="${SUITE_DIR:-test/presets}"
TEST_IMAGE="${TEST_IMAGE:-stateful-pods-preset-test:local}"
ENGINE="${CONTAINER_ENGINE:-docker}"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "the preset tests need a container engine; '$ENGINE' was not found" >&2
  echo "install one, or set CONTAINER_ENGINE" >&2
  exit 1
fi

if [[ "${REBUILD_TEST_IMAGE:-0}" == "1" ]] || ! "$ENGINE" image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
  echo "==> building the preset test image $TEST_IMAGE"
  "$ENGINE" build --tag "$TEST_IMAGE" --file test/presets/Containerfile.test test/presets
fi

echo "==> running the preset tests in $TEST_IMAGE"
exec "$ENGINE" run --rm \
  --volume "$PWD:/src:ro" \
  --workdir /src \
  "$TEST_IMAGE" \
  bats --recursive "$SUITE_DIR"
