#!/usr/bin/env bash
#
# Records what the volume holds, and makes sure the machine's identity is its own.
#
# This runs after the seeding step, in the chart's own image, for both source
# kinds. It is a separate step rather than the tail of the seed script because
# the marker must be written by something that runs *after* the fill, so that a
# fill which died half-way cannot leave one behind. A step of its own is also
# what makes the record the same for both source kinds: it is written by one
# piece of code, and neither fill can decide what a seeded volume looks like.
#
# It runs on every pod start, and on all but the first it has only one job: to
# notice that this volume was seeded for a different machine.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"

SP_MARKER_SCHEMA_VERSION=1

sp_source_json() {
    case "${SP_SOURCE_KIND:-}" in
        oci)
            jq --null-input --arg ref "${SP_SOURCE_REFERENCE:-}" \
                '{kind: "oci", reference: $ref}'
            ;;
        lxc)
            jq --null-input --arg url "${SP_SOURCE_URL:-}" --arg sha "${SP_SOURCE_SHA256:-}" \
                '{kind: "lxc", url: $url, sha256: $sha}'
            ;;
        *)
            jq --null-input --arg kind "${SP_SOURCE_KIND:-unknown}" '{kind: $kind}'
            ;;
    esac
}

sp_write_marker() {
    local root="$1" marker="$1/$SP_DIR_NAME/provisioned" cloned_from="${2:-}"
    local source_json
    source_json="$(sp_source_json)"

    jq --null-input \
        --argjson schemaVersion "$SP_MARKER_SCHEMA_VERSION" \
        --argjson source "$source_json" \
        --arg seededAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg chartVersion "${SP_CHART_VERSION:-unknown}" \
        --arg namespace "${SP_NAMESPACE:-}" \
        --arg release "${SP_RELEASE:-}" \
        --arg name "${SP_MACHINE:-}" \
        --argjson clonedFrom "${cloned_from:-null}" \
        '{
            schemaVersion: $schemaVersion,
            source: $source,
            seededAt: $seededAt,
            chartVersion: $chartVersion,
            machine: {namespace: $namespace, release: $release, name: $name}
        }
        + (if $clonedFrom == null then {} else {clonedFrom: $clonedFrom} end)' \
        > "$marker.tmp"
    mv "$marker.tmp" "$marker"
    rm -f "$root/$SP_DIR_NAME/seeding"
}

# An image ships the identity of the machine it was built on, and a snapshot ships
# the identity of the machine it was taken from. Neither belongs to this machine.
# The file is left present and empty rather than removed: that is the state
# systemd reads as "first boot", and the state Proxmox's clear_machine_id leaves.
sp_clear_identity() {
    local root="$1"
    if [[ -e "$root/etc/machine-id" ]]; then
        : > "$root/etc/machine-id"
    fi
    rm -f "$root/var/lib/dbus/machine-id"
}

sp_marker_field() {
    jq -r "$2 // \"\"" "$1"
}

sp_main() {
    local root="${SP_ROOTFS:-/mnt/rootfs}"
    sp_require_env SP_MACHINE
    [[ -d "$root" ]] || sp_die "the rootfs volume is not mounted at $root"

    local marker="$root/$SP_DIR_NAME/provisioned"

    # The seeding step has just filled the volume: it is still marked in progress,
    # and it only got here because that step exited successfully.
    if [[ ! -f "$marker" && -f "$root/$SP_DIR_NAME/seeding" ]]; then
        sp_clear_identity "$root"
        sp_write_marker "$root"
        sp_log "machine $SP_MACHINE: recorded the root filesystem as seeded"
        return 0
    fi

    if [[ ! -f "$marker" ]]; then
        sp_die "machine $SP_MACHINE: the rootfs volume at $root carries neither a seeding record nor a completed one. The seeding step should have produced one; this state should be unreachable."
    fi

    local was_namespace was_release was_name
    was_namespace="$(sp_marker_field "$marker" .machine.namespace)"
    was_release="$(sp_marker_field "$marker" .machine.release)"
    was_name="$(sp_marker_field "$marker" .machine.name)"

    if [[ "$was_namespace" == "${SP_NAMESPACE:-}" \
       && "$was_release" == "${SP_RELEASE:-}" \
       && "$was_name" == "${SP_MACHINE:-}" ]]; then
        sp_log "machine $SP_MACHINE: the root filesystem is the one this machine was seeded into"
        return 0
    fi

    # Restoring a snapshot back into the machine it was taken from is a restore and
    # keeps that machine's identity. Restoring it under another name is a clone,
    # and a clone that kept the original's identity would be a second machine
    # claiming to be the first.
    sp_log "machine $SP_MACHINE: this root filesystem was seeded for $was_namespace/$was_release/$was_name; treating it as a clone and regenerating the machine identity"
    sp_clear_identity "$root"
    local cloned_from
    cloned_from="$(jq --null-input \
        --arg namespace "$was_namespace" --arg release "$was_release" --arg name "$was_name" \
        '{namespace: $namespace, release: $release, name: $name}')"
    sp_write_marker "$root" "$cloned_from"
    return 0
}

sp_main "$@"
