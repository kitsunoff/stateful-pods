# shellcheck shell=sh
#
# Deciding what a rootfs volume is, and what may safely be done to it.
#
# Kubernetes has no conditional init container: every one of them runs on every
# pod start. "Seed exactly once" therefore cannot live in the pod spec, and has to
# be a decision made at runtime from state on the volume - the only thing that
# outlives the pod, the release and the cluster.
#
# This library is POSIX sh on purpose. It is sourced by the OCI seeding script,
# which executes inside the machine's own source image, where bash may not exist.

# Where the chart keeps its own state on the volume. Visible to the guest as
# /.stateful-pods, the way Proxmox's /.pve-ignore.* markers are.
SP_DIR_NAME=".stateful-pods"

# Entries that do not count as guest content. lost+found is created by mkfs on an
# ext filesystem before anything has ever written to the volume, so a volume that
# holds only it has never been used.
sp_is_ignored_entry() {
    case "$1" in
        "$SP_DIR_NAME"|lost+found) return 0 ;;
        *) return 1 ;;
    esac
}

# Prints one of MARKED, INTERRUPTED, EMPTY or FOREIGN.
#
#   MARKED       the volume was seeded and the seeding completed. Never touch it.
#   INTERRUPTED  a previous attempt died part-way. Nothing of value can be here,
#                because the marker is written only after the copy succeeded, so
#                it is safe to clear and seed again.
#   EMPTY        nothing has ever been written. Seed it.
#   FOREIGN      content the chart did not put here. Refuse: this is the case
#                where guessing would destroy someone's data.
sp_state() {
    _sp_root="$1"
    if [ -f "$_sp_root/$SP_DIR_NAME/provisioned" ]; then
        echo MARKED
        return 0
    fi
    if [ -f "$_sp_root/$SP_DIR_NAME/seeding" ]; then
        echo INTERRUPTED
        return 0
    fi
    for _sp_entry in "$_sp_root"/* "$_sp_root"/.[!.]* "$_sp_root"/..?*; do
        [ -e "$_sp_entry" ] || continue
        _sp_base="${_sp_entry##*/}"
        if ! sp_is_ignored_entry "$_sp_base"; then
            echo FOREIGN
            return 0
        fi
    done
    echo EMPTY
}

# Removes everything the guest owns, keeping only the chart's own directory and
# the filesystem's own. Called only for an INTERRUPTED volume, where the absence
# of a marker proves no seeding ever completed and so nothing here was ever the
# machine's.
sp_wipe() {
    _sp_root="$1"
    for _sp_entry in "$_sp_root"/* "$_sp_root"/.[!.]* "$_sp_root"/..?*; do
        [ -e "$_sp_entry" ] || continue
        _sp_base="${_sp_entry##*/}"
        if sp_is_ignored_entry "$_sp_base"; then
            continue
        fi
        rm -rf "$_sp_entry" || return 1
    done
    return 0
}
