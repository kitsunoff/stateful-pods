# shellcheck shell=sh
#
# Seeding from an OCI image.
#
# This one is different from every other script here: it executes inside the
# machine's own source image, not inside the chart's. Copying an image's
# filesystem faithfully needs a tool from inside that image, because a binary
# from the chart's image is linked against a different libc and cannot run there.
#
# So this file may assume /bin/sh and GNU tar, and nothing else. No bash, no
# chart-supplied binaries, no packages. What it cannot assume, it probes for and
# refuses to guess about.

# The flags Proxmox uses for exactly this job
# (@PVE::Storage::Plugin::COMMON_TAR_FLAGS). Each one earns its place:
#
#   --one-file-system   keeps /proc, /sys and the mounted volume itself out of
#                       the copy without having to enumerate them
#   --numeric-owner     the guest's /etc/passwd is not this container's
#   --acls --xattrs     an ACL or attribute lost here is lost forever
#   security.capability the quiet one: drop it and an unprivileged ping fails
#                       with a permission error that nothing explains
#   --sparse            a sparse file in the image should not balloon on the disk
SP_TAR_FLAGS="--one-file-system --numeric-owner --acls --xattrs --xattrs-include=user.* --xattrs-include=security.capability --sparse --warning=no-file-ignored --warning=no-xattr-write"

# Refuses to copy rather than copy badly. busybox tar has no extended-attribute
# support at all, so it would produce a rootfs that looks right and is not.
sp_probe_archiver() {
    if ! _sp_version="$(tar --version 2>/dev/null)"; then
        sp_die "machine ${SP_MACHINE:-?}: no usable tar was found in the source image ${SP_SOURCE_REFERENCE:-}. Seeding from an oci source copies the image with its own tar, so the image must provide GNU tar. Use a source of kind lxc instead if this image cannot."
    fi
    case "$_sp_version" in
        *"GNU tar"*) ;;
        *)
            sp_die "machine ${SP_MACHINE:-?}: the source image ${SP_SOURCE_REFERENCE:-} provides '$(echo "$_sp_version" | head -n 1)' rather than GNU tar. That tar cannot preserve security.capability, so the seeded root filesystem would look correct while an unprivileged ping and anything else relying on file capabilities failed with no explanation. Use a source of kind lxc for this distribution instead."
            ;;
    esac
    if ! tar --help 2>&1 | grep -q -- '--xattrs'; then
        sp_die "machine ${SP_MACHINE:-?}: the GNU tar in the source image ${SP_SOURCE_REFERENCE:-} was built without extended-attribute support, so it would silently drop security.capability. Use a source of kind lxc for this image instead."
    fi
    return 0
}

# Copies this container's own root filesystem into the machine's volume.
#
# The pipe carries the archive rather than a temporary file, so nothing needs
# room for a second copy. POSIX sh has no pipefail, so the producer's failure is
# recorded explicitly instead of being swallowed by the consumer's success.
sp_fill_rootfs() {
    _sp_root="$1"
    sp_probe_archiver

    _sp_err="$_sp_root/$SP_DIR_NAME/producer-status"
    rm -f "$_sp_err"

    # The runtime directories are excluded whole, not just their contents, and
    # recreated empty afterwards.
    #
    # Excluding only the contents is not enough: tar still reads the mount point
    # itself, and a live /sys or /proc changes while it is being read, which tar
    # reports as a failure. Nothing in these directories was ever wanted, so the
    # entry goes too and the copy stops depending on what the kernel does to a
    # filesystem the machine will not keep.
    _sp_excludes=""
    for _sp_dir in $SP_RUNTIME_DIRS; do
        _sp_excludes="$_sp_excludes --exclude=./$_sp_dir"
    done

    # shellcheck disable=SC2086 # the flags are a word list on purpose
    {
        tar -C / $SP_TAR_FLAGS $_sp_excludes \
            --exclude=".$_sp_root" \
            --exclude="./$SP_DIR_NAME" \
            -cf - . || echo "$?" > "$_sp_err"
    } | {
        # shellcheck disable=SC2086
        tar -C "$_sp_root" $SP_TAR_FLAGS -xpf -
    } || {
        sp_log "reading the copy failed while writing to $_sp_root"
        return 1
    }

    if [ -s "$_sp_err" ]; then
        _sp_code="$(cat "$_sp_err")"
        rm -f "$_sp_err"
        sp_log "reading the source image failed with status $_sp_code"
        return 1
    fi
    rm -f "$_sp_err"
    return 0
}
