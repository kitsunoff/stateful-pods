#!/usr/bin/env bash
#
# Seeds a machine's root filesystem from an OCI image.
#
# Runs in the chart's own image, which is where the registry client and the
# archiver live. Nothing from the source image is executed, so the source is free
# to carry no userland at all.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=images/shim/scripts/lib-oci.sh
. "$SP_SCRIPT_DIR/lib-oci.sh"

sp_seed_main
