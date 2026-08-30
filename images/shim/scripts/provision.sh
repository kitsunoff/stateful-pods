#!/usr/bin/env bash
#
# Provisions a machine: the users, keys, packages and commands its values ask
# for, written into the machine's own root filesystem.
#
# Runs on every start, after the step that writes the files the chart maintains,
# and before the guest. Provisioning is not the same lifecycle as seeding: a root
# filesystem is filled once and never again, while a machine whose key has
# rotated must be able to take the new one by restarting. The two deliberately
# share no marker.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=images/shim/scripts/lib-provision.sh
. "$SP_SCRIPT_DIR/lib-provision.sh"

sp_main() {
    local root="${SP_ROOTFS:-/mnt/rootfs}"
    sp_require_env SP_MACHINE
    [[ -d "$root" ]] || sp_die "the rootfs volume is not mounted at $root"
    sp_provision "$root"
}

sp_main "$@"
