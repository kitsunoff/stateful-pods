# shellcheck shell=sh
#
# The seeding driver: everything that is the same for both source kinds.
#
# A script that sources this defines sp_fill_rootfs() - which puts the source's
# contents into the volume and returns non-zero if it cannot - and then calls
# sp_seed_main. Both source kinds therefore share one decision, one set of
# messages and one definition of "done", and only the fill differs.
#
# POSIX sh, still. Nothing sources this from a foreign image any more, so the
# constraint that produced the dialect is gone; it is left as it is because
# rewriting it would change no behaviour and would bury this file's actual
# content under a dialect change. It applies here and in lib-state.sh only:
# ready.sh and stop.sh keep POSIX sh permanently, because they genuinely do run
# inside the machine, where bash may not exist.

sp_log() {
    echo "stateful-pods: $*"
}

sp_die() {
    echo "stateful-pods: $*" >&2
    exit 1
}

sp_require_env() {
    eval "_sp_value=\${$1:-}"
    [ -n "$_sp_value" ] || sp_die "$1 is not set; the chart must supply it"
}

# The flags every fill extracts with, whatever the source kind. They are Proxmox's
# for exactly this job (@PVE::Storage::Plugin::COMMON_TAR_FLAGS), minus the
# creation-only ones, and each earns its place:
#
#   --numeric-owner     the guest's /etc/passwd is not this container's
#   --acls --xattrs     an ACL or attribute lost here is lost forever
#   security.capability the quiet one: drop it and an unprivileged ping fails
#                       with a permission error that nothing explains
#   --sparse            a sparse file in the source should not balloon on disk
#
# One definition, so that the properties the project asserts about an extraction
# are asserted about every extraction.
#
# shellcheck disable=SC2034 # read by whichever fill the sourcing script defines
SP_TAR_FLAGS="--numeric-owner --acls --xattrs --xattrs-include=user.* --xattrs-include=security.capability --sparse --warning=no-file-ignored --warning=no-xattr-write"

# The directories the kernel, the runtime and the init system own at boot. Nothing
# belongs to the volume here: whatever a source ships in them is stale by
# definition, and a device node copied in is either ignored or wrong. They exist
# so the guest's init has somewhere to mount over.
SP_RUNTIME_DIRS="dev proc sys run tmp"

sp_ensure_runtime_dirs() {
    _sp_root="$1"
    for _sp_dir in $SP_RUNTIME_DIRS; do
        rm -rf "${_sp_root:?}/$_sp_dir" || return 1
        mkdir -p "$_sp_root/$_sp_dir" || return 1
        # 0755 for every one of them; /run world-writable would be a hole, and
        # /proc and /sys get their real modes from the kernel when mounted over.
        chmod 0755 "$_sp_root/$_sp_dir" || return 1
    done
    # /tmp is the exception every Unix expects: world-writable with the sticky bit.
    chmod 1777 "$_sp_root/tmp" || return 1
    return 0
}

sp_seed_main() {
    _sp_root="${SP_ROOTFS:-/mnt/rootfs}"
    sp_require_env SP_MACHINE

    [ -d "$_sp_root" ] || sp_die "the rootfs volume is not mounted at $_sp_root"

    _sp_state="$(sp_state "$_sp_root")"
    case "$_sp_state" in
        MARKED)
            sp_log "machine $SP_MACHINE: the root filesystem is already seeded, leaving it alone"
            return 0
            ;;
        FOREIGN)
            sp_die "machine $SP_MACHINE: the rootfs volume at $_sp_root already holds content that was not created by this chart, and it carries no seeding record. Nothing has been touched. Empty the volume if it should be seeded from the declared ${SP_SOURCE_KIND:-source}, or point the machine at the volume that already holds its root filesystem."
            ;;
        INTERRUPTED)
            sp_log "machine $SP_MACHINE: a previous seeding did not finish; clearing the partial result and starting again"
            sp_wipe "$_sp_root" || sp_die "machine $SP_MACHINE: could not clear the partial result at $_sp_root"
            ;;
        EMPTY)
            ;;
        *)
            sp_die "machine $SP_MACHINE: could not tell what state the volume at $_sp_root is in"
            ;;
    esac

    # Written before the first byte, and removed only once the marker replaces it.
    # This is what makes a death half-way through recoverable instead of
    # indistinguishable from someone else's data.
    mkdir -p "$_sp_root/$SP_DIR_NAME" || sp_die "machine $SP_MACHINE: could not write to $_sp_root"
    : > "$_sp_root/$SP_DIR_NAME/seeding" || sp_die "machine $SP_MACHINE: could not write to $_sp_root"

    sp_log "machine $SP_MACHINE: seeding the root filesystem from ${SP_SOURCE_KIND:-source}"
    sp_fill_rootfs "$_sp_root" || sp_die "machine $SP_MACHINE: could not seed the rootfs volume at $_sp_root from the declared ${SP_SOURCE_KIND:-source} ${SP_SOURCE_REFERENCE:-${SP_SOURCE_URL:-}}. The volume is left unseeded and will be seeded again on the next start; the cause is in the output above."

    sp_ensure_runtime_dirs "$_sp_root" || sp_die "machine $SP_MACHINE: could not prepare the runtime directories on $_sp_root"

    sp_log "machine $SP_MACHINE: the root filesystem has been seeded"
    return 0
}
