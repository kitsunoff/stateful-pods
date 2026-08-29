#!/usr/bin/env bash
#
# Boots a machine: mounts what its init system expects to find, changes the root
# to the machine's own filesystem, and hands over.
#
# This is the guest container's command. Everything it does happens before the
# machine's init exists, and after `exec` this process *is* the machine.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=charts/stateful-pods/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=charts/stateful-pods/scripts/lib-boot.sh
. "$SP_SCRIPT_DIR/lib-boot.sh"

sp_main() {
    local root="${SP_ROOTFS:-/mnt/rootfs}"
    sp_require_env SP_MACHINE

    sp_check_bootable "$root"
    local init
    init="$(sp_find_init "$root")"

    sp_install_runtime_helpers "$root" "$SP_SCRIPT_DIR"

    sp_log "machine $SP_MACHINE: preparing the filesystems the machine's init expects"
    sp_apply_mounts "$root"
    sp_bind_devices "$root"

    sp_log "machine $SP_MACHINE: handing over to $init"
    sp_pivot "$root"

    # The machine has finished being prepared. /run is the tmpfs mounted above, so
    # this marker is gone at the next boot, which is what makes it a usable answer
    # to "has this machine started" for an init that offers no marker of its own.
    mkdir -p /run/stateful-pods
    : > /run/stateful-pods/booted

    # Without this, systemd concludes it is running on hardware and starts loading
    # kernel modules, checking filesystems and taking over the control-group
    # hierarchy. It checks its own environment first when it is PID 1; the file
    # conventions it falls back to are Docker's and Podman's, and Kubernetes writes
    # neither. `lxc` is the honest value for this architecture and is what
    # cloud-init's own container detection recognises.
    export container=lxc

    exec "$init"
}

sp_main "$@"
