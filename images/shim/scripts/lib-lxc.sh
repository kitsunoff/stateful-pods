# shellcheck shell=sh
#
# Seeding from a conventional LXC template tarball.
#
# Unlike an OCI image, nothing about a template establishes what it is. It is
# fetched over plain HTTPS and unpacked into what becomes a privileged machine's
# root filesystem, and Proxmox - which verifies its own templates against a signed
# index this chart has no counterpart for - still sanity-checks every archive
# before extracting it. So does this.
#
# The order is the point: verify the bytes are the ones the machine asked for,
# then check they are a root filesystem, and only then write anything.

# Proxmox's check_tar_archive(): an archive that is not a root filesystem is
# rejected before extraction rather than discovered afterwards.
SP_MIN_ARCHIVE_MEMBERS=10

# Templates are fetched over HTTPS and nothing else. The suite overrides this to
# serve fixtures from disk; nothing in the chart ever does.
SP_ALLOWED_PROTOCOLS="${SP_ALLOWED_PROTOCOLS:-=https}"

sp_download_template() {
    _sp_dest="$1"
    sp_require_env SP_SOURCE_URL
    sp_log "machine $SP_MACHINE: fetching $SP_SOURCE_URL"
    if ! curl --silent --show-error --location --fail --proto "$SP_ALLOWED_PROTOCOLS" \
            --output "$_sp_dest" "$SP_SOURCE_URL"; then
        sp_die "machine $SP_MACHINE: could not fetch the template at $SP_SOURCE_URL. Nothing has been written to the volume. Check the URL is reachable from this cluster and that it is served over HTTPS."
    fi
}

sp_verify_template() {
    _sp_file="$1"
    sp_require_env SP_SOURCE_SHA256
    _sp_found="$(sha256sum "$_sp_file" | cut -d' ' -f1)"
    if [ "$_sp_found" != "$SP_SOURCE_SHA256" ]; then
        sp_die "machine $SP_MACHINE: the template fetched from $SP_SOURCE_URL is not the bytes this machine asked for. Declared sha256 $SP_SOURCE_SHA256, downloaded sha256 $_sp_found. Nothing has been unpacked. Either the declared checksum is wrong or the file behind that URL changed."
    fi
    sp_log "machine $SP_MACHINE: checksum verified"
}

# Lists the archive without extracting it, and refuses anything that does not
# look like a root filesystem. A checksum proves the bytes are the ones that were
# named; it does not prove that what was named is an operating system.
sp_inspect_template() {
    _sp_file="$1"
    _sp_listing="$2"

    if ! tar --list --file "$_sp_file" > "$_sp_listing" 2>"$_sp_listing.err"; then
        sp_die "machine $SP_MACHINE: the template fetched from $SP_SOURCE_URL could not be read as a tar archive: $(head -n 3 "$_sp_listing.err" | tr '\n' ' '). Nothing has been unpacked."
    fi

    _sp_members="$(wc -l < "$_sp_listing")"
    if [ "$_sp_members" -lt "$SP_MIN_ARCHIVE_MEMBERS" ]; then
        sp_die "machine $SP_MACHINE: the template fetched from $SP_SOURCE_URL holds only $_sp_members members, fewer than the $SP_MIN_ARCHIVE_MEMBERS a root filesystem must have. That is not an operating system. Nothing has been unpacked."
    fi

    if ! grep -qE '(^|/)sbin(/|$)' "$_sp_listing"; then
        sp_die "machine $SP_MACHINE: the template fetched from $SP_SOURCE_URL contains no sbin entry, so it is not a root filesystem. Nothing has been unpacked."
    fi

    sp_log "machine $SP_MACHINE: the archive holds $_sp_members members and looks like a root filesystem"
}

# A truncated filesystem that extracts without an error is the worst outcome
# available here: a machine that boots and is quietly missing files.
#
# This runs before the listing check rather than after it. Listing one volume of a
# set fails at the volume's end, so the listing check would otherwise catch every
# multi-volume archive first and report it as unreadable - true, but far less
# useful than saying what it actually is. tar still writes the member flags before
# it fails, so the marker is visible even though the exit status is not zero.
sp_reject_multi_volume() {
    _sp_file="$1"
    if tar --list --verbose --file "$_sp_file" 2>/dev/null | grep -q '^M'; then
        sp_die "machine $SP_MACHINE: the template fetched from $SP_SOURCE_URL is one volume of a multi-volume archive. Unpacking it would produce a truncated root filesystem without reporting an error. Nothing has been unpacked."
    fi
}

sp_fill_rootfs() {
    _sp_root="$1"
    _sp_work="$_sp_root/$SP_DIR_NAME/download"

    rm -rf "$_sp_work"
    mkdir -p "$_sp_work" || return 1
    _sp_tarball="$_sp_work/template"

    sp_download_template "$_sp_tarball"
    sp_verify_template "$_sp_tarball"
    sp_reject_multi_volume "$_sp_tarball"
    sp_inspect_template "$_sp_tarball" "$_sp_work/listing"

    sp_log "machine $SP_MACHINE: unpacking the template"
    # shellcheck disable=SC2086 # the flags are a word list on purpose
    if ! tar -C "$_sp_root" $SP_TAR_FLAGS -xpf "$_sp_tarball"; then
        rm -rf "$_sp_work"
        return 1
    fi

    # The tarball is the largest transient thing on the volume; it goes as soon as
    # it is no longer needed, so the machine does not carry it forever.
    rm -rf "$_sp_work"
    return 0
}
