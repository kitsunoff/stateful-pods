# shellcheck shell=bash
#
# The files the chart maintains inside a running machine.
#
# A pod is handed its host name, its host table and its resolver configuration as
# mounts into the container image's filesystem. Once the machine's root becomes
# the volume, those mounts are no longer in the machine's root - so a machine that
# did nothing would boot with whatever its source image happened to ship: no
# resolver at all, and a host name belonging to the machine the image was built
# on. Proxmox writes the same three files into a container's root filesystem on
# every start, for exactly this reason.
#
# They are copied rather than bound, because a bind would be undone by the root
# change, and rewritten on every boot rather than seeded once, because the pod's
# own values legitimately change - a machine rescheduled onto another node gets a
# different host table.

# The files, relative to the machine's root.
SP_MANAGED_FILES="etc/hostname etc/hosts etc/resolv.conf"

# Where the pod's own copies are. A variable so the suite can point it at a
# fixture; nothing in the chart ever sets it.
SP_POD_ETC_DEFAULT="/etc"

# Proxmox's own escape hatch, in form and in spelling: a marker next to the file
# it protects, named after it. It lives on the volume, so it travels with the
# machine rather than with the release, and it is per file, so a machine that
# manages its own resolver does not also have to manage its own host name.
sp_ignore_marker() {
    local relative="$1"
    echo "$(dirname "$relative")/.stateful-pods-ignore.$(basename "$relative")"
}

sp_customize() {
    local root="$1" pod_etc="${SP_POD_ETC:-$SP_POD_ETC_DEFAULT}"
    local relative source target marker

    for relative in $SP_MANAGED_FILES; do
        source="$pod_etc/$(basename "$relative")"
        target="$root/$relative"
        marker="$root/$(sp_ignore_marker "$relative")"

        if [ -e "$marker" ]; then
            sp_log "machine ${SP_MACHINE:-?}: /$relative is claimed by the machine, leaving it alone"
            continue
        fi

        if [ ! -f "$source" ]; then
            # The pod was not given one either. Writing an empty file here would
            # be worse than leaving the machine's own: an empty resolv.conf is a
            # machine that cannot resolve anything and cannot say why.
            sp_log "machine ${SP_MACHINE:-?}: this pod has no $source, leaving /$relative as the machine has it"
            continue
        fi

        mkdir -p "$(dirname "$target")" \
            || sp_die "machine ${SP_MACHINE:-?}: could not create $(dirname "$target") in the machine"
        cp "$source" "$target.tmp" \
            || sp_die "machine ${SP_MACHINE:-?}: could not write /$relative into the machine"
        chmod 0644 "$target.tmp"
        mv "$target.tmp" "$target" \
            || sp_die "machine ${SP_MACHINE:-?}: could not write /$relative into the machine"
    done
    return 0
}
