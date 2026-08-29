#!/bin/sh
#
# Seeds a machine's root filesystem from an OCI image.
#
# Runs inside the machine's own source image. See lib-oci.sh for why, and for
# what that means about which shell features may be used here.
set -eu

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=charts/stateful-pods/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-oci.sh
. "$SP_SCRIPT_DIR/lib-oci.sh"

sp_seed_main
