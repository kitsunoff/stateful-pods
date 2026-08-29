#!/usr/bin/env bash
#
# Writes the files the chart maintains inside the machine, on every start.
#
# Runs before the root change, in the chart's own image, where the pod's own
# copies of those files are still reachable.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=charts/stateful-pods/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-customize.sh
. "$SP_SCRIPT_DIR/lib-customize.sh"

sp_main() {
    local root="${SP_ROOTFS:-/mnt/rootfs}"
    sp_require_env SP_MACHINE
    [[ -d "$root" ]] || sp_die "the rootfs volume is not mounted at $root"
    sp_customize "$root"
    sp_log "machine $SP_MACHINE: the files the chart maintains are up to date"
}

sp_main "$@"
