#!/usr/bin/env bash
#
# Seeds a machine's root filesystem from an LXC template tarball.
#
# Runs in the chart's own image, which is where the archivers a template needs
# live: busybox has no zstd support at all, and Proxmox distributes its templates
# as .tar.zst.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=images/shim/scripts/lib-lxc.sh
. "$SP_SCRIPT_DIR/lib-lxc.sh"

sp_seed_main
