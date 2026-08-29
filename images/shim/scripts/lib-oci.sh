# shellcheck shell=bash
#
# Seeding from an OCI image.
#
# The image is fetched and flattened here, in the chart's own image, and never
# run. `crane export` resolves the reference, applies the layers in order -
# whiteouts included - and writes the finished filesystem as a tar stream, which
# goes straight into the same GNU tar the template path uses. So the extraction
# side of both source kinds is one code path with one flag set, and the source
# image is free to carry no shell, no archiver and no userland at all.
#
# Nothing is staged: peak disk usage is the size of the finished root filesystem.
#
# This file used to be POSIX sh, because it executed inside the machine's own
# source image where bash may not exist. That is no longer true of anything here,
# and reading the two halves of a pipeline's status needs bash.

# Maps the kernel's machine architecture onto an OCI platform.
#
# crane defaults to linux/amd64 wherever it runs, and the container runtime used
# to make this choice invisibly and correctly on the chart's behalf. Doing the
# fetch ourselves turns a non-decision into a silent failure mode: a rootfs for
# the wrong architecture unpacks perfectly and then cannot execute its own init,
# which surfaces at boot, far from its cause.
#
# The two architectures the project builds and tests for are the two it claims.
# Anything else is refused by name rather than guessed at.
sp_oci_platform() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  echo linux/amd64 ;;
        aarch64) echo linux/arm64 ;;
        *)
            sp_die "machine ${SP_MACHINE:-?}: this node reports the architecture '$machine', which this chart claims no OCI platform for. Seeding an oci source has to ask the registry for one named architecture, and guessing would fill the volume with a root filesystem that unpacks perfectly and cannot execute its own init. The supported architectures are x86_64 and aarch64; use a source of kind lxc on this node instead."
            ;;
    esac
}

# Fetches the source image and unpacks its flattened filesystem into the volume.
sp_fill_rootfs() {
    local root="$1"
    local platform
    platform="$(sp_oci_platform)" || return 1

    sp_log "machine ${SP_MACHINE:-?}: fetching ${SP_SOURCE_REFERENCE:-} for $platform"

    # The directories the kernel and the runtime own are not taken from the
    # image. Nothing in them was ever wanted, and a device node among them
    # cannot be recreated here at all: mknod(2) checks the capability in the
    # *initial* user namespace, so a machine in `userns` mode has no way to make
    # one whatever it is granted. tar would fail with EPERM and take the whole
    # seed down over content that is discarded a moment later - the driver wipes
    # and recreates all five of them empty as soon as the fill returns.
    local -a excludes=()
    local runtime_dir
    for runtime_dir in $SP_RUNTIME_DIRS; do
        excludes+=("--exclude=./$runtime_dir")
    done

    # Both halves of the pipeline are checked. A tar that exits cleanly on a
    # stream that stopped early would otherwise report a successful seed for
    # half an operating system. The group is the left side of an `||` so that
    # errexit does not abort before the statuses can be read.
    local -a piped
    # shellcheck disable=SC2086 # the flags are a word list on purpose
    {
        crane export --platform "$platform" "${SP_SOURCE_REFERENCE:-}" - \
            | tar -C "$root" -x $SP_TAR_FLAGS "${excludes[@]}" -pf -
        piped=("${PIPESTATUS[@]}")
    } || true

    if [ "${piped[0]}" -ne 0 ]; then
        sp_log "fetching ${SP_SOURCE_REFERENCE:-} for $platform failed with status ${piped[0]}${SP_SOURCE_PULL_SECRET:+, using the credentials in secret $SP_SOURCE_PULL_SECRET}"
        return 1
    fi
    if [ "${piped[1]}" -ne 0 ]; then
        sp_log "unpacking ${SP_SOURCE_REFERENCE:-} into $root failed with status ${piped[1]}"
        return 1
    fi
    return 0
}
