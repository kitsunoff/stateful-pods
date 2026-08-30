# shellcheck shell=bash
#
# Provisioning a machine: the users, keys, packages and commands its values ask
# for, written into the machine's own root filesystem.
#
# Two backends. `native` is layer 0 and nothing else - the three files the chart
# already maintains on every boot - and it works with any image. `cloud-init` is
# the default and writes a NoCloud seed directory, which is four files and a
# drop-in and no ISO, no block device and no privilege.
#
# This runs before the root change, in the chart's own image, and it manipulates
# files in the machine's filesystem. It never executes anything belonging to the
# machine: a guest built for another architecture could not be executed here at
# all, and a chart that ran a stranger's program to find out what the stranger is
# would have a much larger problem than the one it was solving.

# Where the machine's provisioning material is mounted, and where cloud-init
# looks for a NoCloud seed. `paths.seed_dir` is /var/lib/cloud/seed, and
# DataSourceNoCloud's seed_dirs are `nocloud` and `nocloud-net` under it.
SP_PROVISIONING_DIR_DEFAULT="/provisioning"
SP_SEED_DIR="var/lib/cloud/seed/nocloud"
SP_CLOUD_DROPIN="etc/cloud/cloud.cfg.d/99-stateful-pods.cfg"
SP_CLOUD_DISABLED="etc/cloud/cloud-init.disabled"

# Where a distribution puts the cloud-init program. Enumerated rather than
# searched, so that a failure can say exactly what was looked for.
SP_CLOUD_INIT_BINARIES="usr/bin/cloud-init bin/cloud-init usr/sbin/cloud-init sbin/cloud-init usr/local/bin/cloud-init"

# What an init system needs in order to start it. One entry from either list is
# enough: the first is systemd's, the second is OpenRC's, and an image has one
# init system rather than both.
SP_CLOUD_INIT_UNITS="usr/lib/systemd/system/cloud-init-main.service usr/lib/systemd/system/cloud-init-local.service usr/lib/systemd/system/cloud-init.target lib/systemd/system/cloud-init-main.service lib/systemd/system/cloud-init-local.service lib/systemd/system/cloud-init.target etc/init.d/cloud-init-local etc/init.d/cloud-init"

# The structured inputs that compose user-data, and the file each arrives in.
# `userData` is not here: it is the raw form, and it replaces the whole of this
# rather than contributing to it.
SP_CLOUD_INIT_STRUCTURED="user password ssh-authorized-keys packages runcmd package-upgrade"

# sp_material <name>
# The content of one materialized input, or nothing. Every input is read this
# way, which is what makes the script unable to tell an inline value from a
# projected Secret key.
sp_material() {
    _sp_file="${SP_PROVISIONING_DIR:-$SP_PROVISIONING_DIR_DEFAULT}/$1"
    [ -f "$_sp_file" ] || return 0
    cat "$_sp_file"
}

sp_has_material() {
    [ -n "$(sp_material "$1")" ]
}

# sp_json_lines <name>
# One materialized input as a JSON array, one item per line.
#
# Newline-separated rather than a YAML fragment, because turning a fragment into
# JSON needs a YAML parser and this image has none - and because it is already
# the shape the design specifies for a list of authorized keys, so the three
# list-valued inputs are one shape rather than two. Blank lines are not items:
# a block scalar in a values file almost always ends in one.
sp_json_lines() {
    sp_material "$1" | jq --raw-input --slurp \
        'split("\n") | map(select(length > 0))'
}

# sp_compose_user_data
# The cloud-config the structured inputs describe, as JSON.
#
# JSON rather than YAML, and deliberately: a cloud-config document may be JSON,
# because YAML is a superset of it and cloud-init parses with yaml.safe_load. A
# password hash full of `$`, a key with a comment, a runcmd line with a colon -
# every one of those is a way a generated YAML document silently becomes a
# different document, and none of them can happen here.
#
# The shape is the reference implementation's own for the same job: `user` names
# the distribution's default user rather than replacing the user list, so the
# keys, the password and the sudo rule all land on one account that the
# distribution already considers the way in.
sp_compose_user_data() {
    _sp_config='{}'

    if sp_has_material user; then
        _sp_config="$(jq --arg user "$(sp_material user)" \
            '. + {user: $user}' <<< "$_sp_config")"
    fi

    if sp_has_material password; then
        # `expire: false`, so that a machine provisioned with a password is one
        # somebody can log into rather than one that demands a change over a
        # console nothing is attached to.
        _sp_config="$(jq --arg password "$(sp_material password)" \
            '. + {password: $password, chpasswd: {expire: false}}' <<< "$_sp_config")"
    fi

    if sp_has_material ssh-authorized-keys; then
        _sp_config="$(jq --argjson keys "$(sp_json_lines ssh-authorized-keys)" \
            '. + {ssh_authorized_keys: $keys}' <<< "$_sp_config")"
    fi

    if sp_has_material packages; then
        _sp_config="$(jq --argjson packages "$(sp_json_lines packages)" \
            '. + {packages: $packages}' <<< "$_sp_config")"
    fi

    if sp_has_material runcmd; then
        _sp_config="$(jq --argjson runcmd "$(sp_json_lines runcmd)" \
            '. + {runcmd: $runcmd}' <<< "$_sp_config")"
    fi

    if sp_has_material package-upgrade; then
        _sp_config="$(jq --argjson upgrade "$(sp_material package-upgrade)" \
            '. + {package_upgrade: $upgrade}' <<< "$_sp_config")"
    fi

    printf '#cloud-config\n%s\n' "$_sp_config"
}

# sp_check_material
# That the material the chart could not check while it rendered is usable.
#
# Called before anything is written, and outside any command substitution. The
# distinction matters: a refusal raised inside `$( … )` ends the subshell and
# leaves the caller carrying on with an empty string, so a check placed where the
# value is consumed is a check that can be swallowed. That is precisely the class
# of silent no-op this file exists to prevent, so the check is here instead.
sp_check_material() {
    # A switch, so a value that is neither is a mistake rather than something to
    # guess at. Unlike Proxmox, which defaults ciupgrade to true: on a machine
    # that is a container, a first boot spent upgrading every package is a
    # machine that looks hung, so this is opt-in.
    if sp_has_material package-upgrade; then
        case "$(sp_material package-upgrade)" in
            true|false) ;;
            *)
                sp_die "machine ${SP_MACHINE:-?}: packageUpgrade is \"$(sp_material package-upgrade)\", which is neither true nor false. It decides whether the machine upgrades every package it has on its first boot, so there is no third answer. Nothing has been written into the machine."
                ;;
        esac
    fi
    return 0
}

# sp_check_cloud_init <rootfs>
# That the machine can actually run cloud-init, and not merely that it has it.
#
# This is the most important thing in this file. On an image without cloud-init
# the seed is written, nothing reads it, and the machine boots with no users, no
# keys and no way in, with nothing in the logs to explain it. That failure looks
# exactly like a successful install, which is what makes it the worst outcome
# available to this chart - so it is a refusal, before anything is written, and
# the message names the backend that would have worked.
#
# What is checked is the program and an init-system integration. What is
# deliberately not checked is whether the units are enabled, whether a runlevel
# link exists, or whether the generator would reach ds-identify: those have
# several valid shapes per distribution and per cloud-init version - the systemd
# path went from a generator to a socket-activated single process inside one
# release series - and a check that guessed wrong would refuse an image that
# works. These two are true of every image that can run cloud-init and false of
# every image that cannot.
#
# Both messages end by naming the pod deletion, because changing the value is not
# enough on its own: a StatefulSet will not replace a pod that never became
# ready, so the new value sits in the object while the old pod goes on failing.
# Verified on a cluster, and a fix that does not work when followed is worse than
# no fix at all.
sp_check_cloud_init() {
    _sp_root="$1"
    _sp_binary=""
    for _sp_candidate in $SP_CLOUD_INIT_BINARIES; do
        if [ -e "$_sp_root/$_sp_candidate" ]; then
            _sp_binary="$_sp_candidate"
            break
        fi
    done
    if [ -z "$_sp_binary" ]; then
        sp_die "machine ${SP_MACHINE:-?}: this machine is provisioned by cloud-init, and its root filesystem does not carry cloud-init. Looked for: $SP_CLOUD_INIT_BINARIES (under $_sp_root). Nothing has been written into the machine. Either seed it from an image that carries cloud-init - the distributions publish a 'cloud' variant for exactly this - or set machines.${SP_MACHINE:-<name>}.guest.provisioning: native, which provisions nothing beyond the host name, host table and resolver the chart maintains on every boot and works with any image. Then delete this pod: a StatefulSet does not replace a pod that never became ready, so the new value will sit in the object while this pod goes on failing."
    fi

    _sp_unit=""
    for _sp_candidate in $SP_CLOUD_INIT_UNITS; do
        if [ -e "$_sp_root/$_sp_candidate" ]; then
            _sp_unit="$_sp_candidate"
            break
        fi
    done
    if [ -z "$_sp_unit" ]; then
        sp_die "machine ${SP_MACHINE:-?}: this machine is provisioned by cloud-init, and its root filesystem carries $_sp_binary but nothing that would start it. Looked for: $SP_CLOUD_INIT_UNITS (under $_sp_root). A seed written into an image whose init system never runs cloud-init is read by nothing, so nothing has been written. Set machines.${SP_MACHINE:-<name>}.guest.provisioning: native and then delete this pod - a StatefulSet does not replace a pod that never became ready. Or report this image: the check is deliberately narrow, and the paths above are what it searched."
    fi

    sp_log "machine ${SP_MACHINE:-?}: the machine can run cloud-init ($_sp_binary, started by $_sp_unit)"
    return 0
}

# sp_write_file <path> <content>
# Atomically, because this runs on every start and a machine that was restarted
# while it wrote would otherwise boot on half a file.
sp_write_file() {
    _sp_path="$1"
    mkdir -p "$(dirname "$_sp_path")" \
        || sp_die "machine ${SP_MACHINE:-?}: could not create $(dirname "$_sp_path") in the machine"
    printf '%s' "$2" > "$_sp_path.tmp" \
        || sp_die "machine ${SP_MACHINE:-?}: could not write $_sp_path in the machine"
    chmod 0600 "$_sp_path.tmp"
    mv "$_sp_path.tmp" "$_sp_path" \
        || sp_die "machine ${SP_MACHINE:-?}: could not write $_sp_path in the machine"
}

# The configuration the chart owns inside the machine.
#
# `99-` so that it sorts after everything the distribution ships, and a file of
# the chart's own rather than an edit to cloud.cfg, so that nothing the chart
# owns is entangled with what the image owns.
#
# The first four settings hand back what other layers already own: the pod's
# addressing belongs to the CNI, and the host name, host table and resolver are
# written into the machine on every boot by the step before this one. Two owners
# of one file means whichever ran last wins, and the network row is worse than
# that - a netplan written here and applied would take away the address the pod
# was given.
#
# The last two are about the volume. A machine's root filesystem is a mounted
# volume and not a partitioned block device: there is no partition to grow and no
# filesystem to resize, and the modules that would try are switched off here
# rather than removed from the module list, which would be a per-distribution
# fight with cloud.cfg.
sp_cloud_dropin() {
    cat <<'EOF'
# Written by the stateful-pods chart on every start. Edit the machine's values,
# not this file.
datasource_list: [NoCloud, None]
network:
  config: disabled
preserve_hostname: true
manage_etc_hosts: false
growpart:
  mode: "off"
resize_rootfs: false
EOF
}

# sp_provision_cloud_init <rootfs>
sp_provision_cloud_init() {
    _sp_root="$1"

    sp_check_cloud_init "$_sp_root"
    sp_check_material

    # Only now. An image that failed the check above is left exactly as it was,
    # and removing this is what makes a seed readable at all: every systemd unit
    # carries ConditionPathExists=!/etc/cloud/cloud-init.disabled, and every
    # OpenRC script tests the same file by hand. The upstream builder writes it
    # into every LXC image it publishes, on purpose - its LXD and Incus outputs
    # write a seed and remove the marker in one step, and the plain LXC archive
    # is that with the enabling left out.
    if [ -e "$_sp_root/$SP_CLOUD_DISABLED" ]; then
        rm -f "$_sp_root/$SP_CLOUD_DISABLED" \
            || sp_die "machine ${SP_MACHINE:-?}: could not remove /$SP_CLOUD_DISABLED, so cloud-init would not run and the seed would be read by nothing"
        sp_log "machine ${SP_MACHINE:-?}: removed /$SP_CLOUD_DISABLED, which this image ships to keep cloud-init from running"
    fi

    sp_write_file "$_sp_root/$SP_CLOUD_DROPIN" "$(sp_cloud_dropin)"

    # Raw beats structured, per file, with no merge. This is the reference
    # implementation's own rule for the same choice, and it is the only one a
    # user can predict: a YAML merge of two cloud-configs is a misfeature
    # waiting to happen.
    _sp_shadowed=""
    if sp_has_material user-data; then
        for _sp_field in $SP_CLOUD_INIT_STRUCTURED; do
            if sp_has_material "$_sp_field"; then
                _sp_shadowed="$_sp_shadowed $_sp_field"
            fi
        done
        if [ -n "$_sp_shadowed" ]; then
            sp_log "machine ${SP_MACHINE:-?}: userData was supplied, so it is used as it stands and these structured inputs are shadowed and take no effect:$_sp_shadowed. Raw files replace structured values per file and are never merged with them."
        fi
        _sp_user_data="$(sp_material user-data)"
    else
        _sp_user_data="$(sp_compose_user_data)"
    fi

    _sp_seed="$_sp_root/$SP_SEED_DIR"
    sp_write_file "$_sp_seed/user-data" "$_sp_user_data"

    # Written only when supplied. cloud-init treats both as optional, and an
    # empty network-config is not the same thing as no network-config.
    for _sp_optional in network-config vendor-data; do
        if sp_has_material "$_sp_optional"; then
            sp_write_file "$_sp_seed/$_sp_optional" "$(sp_material "$_sp_optional")"
        else
            rm -f "$_sp_seed/$_sp_optional"
        fi
    done

    # Last, because it carries the hash of the others.
    #
    # Computed here rather than by Helm, and it has to be: Helm cannot read a
    # Secret it does not own, so a render-time hash would be impossible for every
    # referenced input and `lookup` would break `helm template`, `--dry-run` and
    # every GitOps diff. Computed over the files as they were written rather than
    # over what they were composed from, so it reflects what the guest will
    # actually be configured with.
    #
    # cloud-init keys its per-instance semaphores on this, so it is what makes a
    # changed configuration re-apply and an unchanged one not. The identity seed
    # is namespace, release and machine name - the same triple the machine's
    # objects are named from - which makes a volume restored under another name a
    # different instance, and a volume restored into its own machine the same
    # one.
    _sp_identity="$(
        {
            cat "$_sp_seed/user-data"
            [ -f "$_sp_seed/network-config" ] && cat "$_sp_seed/network-config"
            [ -f "$_sp_seed/vendor-data" ] && cat "$_sp_seed/vendor-data"
            printf '%s/%s/%s' "${SP_NAMESPACE:-}" "${SP_RELEASE:-}" "${SP_MACHINE:-}"
        } | sha1sum | cut -c1-40
    )"
    sp_write_file "$_sp_seed/meta-data" "$(printf 'instance-id: %s\n' "$_sp_identity")"

    sp_log "machine ${SP_MACHINE:-?}: seeded cloud-init at /$SP_SEED_DIR as instance $_sp_identity"
    return 0
}

# sp_provision <rootfs>
sp_provision() {
    _sp_root="$1"
    case "${SP_PROVISIONING:-cloud-init}" in
        cloud-init)
            sp_provision_cloud_init "$_sp_root"
            ;;
        native)
            # Layer 0 and nothing else, which the step before this one has
            # already done. Nothing is removed either: switching a machine to
            # this backend means "stop managing this", not "undo what was done",
            # and the volume is the machine.
            sp_log "machine ${SP_MACHINE:-?}: provisioning is native, so nothing is written into the machine beyond the host name, host table and resolver the chart maintains"
            ;;
        *)
            sp_die "machine ${SP_MACHINE:-?}: ${SP_PROVISIONING:-} is not a provisioning backend this image implements. The chart refuses an unknown backend while it renders, so reaching here means the chart and this image are different versions of themselves."
            ;;
    esac
    return 0
}
