#!/usr/bin/env bats
#
# Provisioning a machine: what the chart writes into the machine's own root
# filesystem so that it boots with users, keys and the commands its values ask
# for.
#
# The case this file exists for is not the happy one. On an image without
# cloud-init a seed is written, nothing reads it, and the machine boots with no
# users, no keys and no way in, with nothing in the logs to explain it - which
# looks exactly like a successful install. Every assertion about that path is
# here, and it is tested as hard as the path that works.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    ROOTFS="$(mktemp -d)"
    MATERIAL="$(mktemp -d)"
    export SP_ROOTFS="$ROOTFS"
    export SP_MACHINE=web
    export SP_RELEASE=lab
    export SP_NAMESPACE=machines
    export SP_PROVISIONING_DIR="$MATERIAL"
    export SP_PROVISIONING=cloud-init
    mkdir -p "$ROOTFS/etc"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-provision.sh"
}

teardown() { rm -rf "$ROOTFS" "$MATERIAL"; }

# A root filesystem that can run cloud-init under systemd: the program, and a
# unit an init system would start. Plus the marker the upstream builder writes
# into every LXC image it publishes, which is what makes a seed alone a no-op.
given_systemd_cloud_init() {
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/systemd/system" "$ROOTFS/etc/cloud"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    printf '[Unit]\nConditionPathExists=!/etc/cloud/cloud-init.disabled\n' \
        > "$ROOTFS/usr/lib/systemd/system/cloud-init-main.service"
    : > "$ROOTFS/etc/cloud/cloud-init.disabled"
}

# The same, as Alpine ships it: OpenRC service scripts rather than units.
given_openrc_cloud_init() {
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/etc/init.d" "$ROOTFS/etc/cloud"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    printf '#!/sbin/openrc-run\n' > "$ROOTFS/etc/init.d/cloud-init-local"
    : > "$ROOTFS/etc/cloud/cloud-init.disabled"
}

given_material() { printf '%s' "$2" > "$MATERIAL/$1"; }

seed_dir() { echo "$ROOTFS/var/lib/cloud/seed/nocloud"; }

# --------------------------------------------------------------- the native ---

@test "the native backend writes nothing into the machine" {
    export SP_PROVISIONING=native
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -d "$ROOTFS/var/lib/cloud" ]
    [ ! -e "$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg" ]
}

# Switching a machine to native is "stop managing this", not "undo what was
# done". The volume is the machine, and a value change that silently edited a
# running machine's /etc would be a chart that destroys state on a typo.
@test "the native backend removes nothing the machine already has" {
    export SP_PROVISIONING=native
    given_systemd_cloud_init
    mkdir -p "$(seed_dir)"
    printf 'instance-id: earlier\n' > "$(seed_dir)/meta-data"
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -e "$(seed_dir)/meta-data" ]
    [ -e "$ROOTFS/etc/cloud/cloud-init.disabled" ]
}

@test "the native backend says what it did" {
    export SP_PROVISIONING=native
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [[ "$output" == *native* ]]
}

@test "an unknown backend fails rather than doing nothing" {
    export SP_PROVISIONING=ansible
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *ansible* ]]
}

# ------------------------------------------------------- the fail-loud path ---

@test "an image with no cloud-init fails the machine" {
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
}

@test "the message names the backend that would work" {
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"guest.provisioning: native"* ]]
}

# Changing the value is not enough on its own, which was found on a cluster
# rather than by reading: a StatefulSet does not replace a pod that never became
# ready, so the new backend sits in the object while the old pod goes on failing.
# A fix that does not work when followed is worse than no fix at all.
@test "the message says the pod has to be deleted for the fix to take effect" {
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"delete this pod"* ]]
    [[ "$output" == *"never became ready"* ]]
}

@test "the message about an image that cannot start cloud-init says so too" {
    mkdir -p "$ROOTFS/usr/bin"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"delete this pod"* ]]
}

@test "the message names the machine and what was looked for" {
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *web* ]]
    [[ "$output" == *cloud-init* ]]
    [[ "$output" == *usr/bin/cloud-init* ]]
}

# The seed is the part that looks like success. A machine that failed the check
# and was left with one would be provisioned by nothing and look provisioned.
@test "a machine that fails the check is left with no seed" {
    given_material user-data '#cloud-config'
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [ ! -d "$ROOTFS/var/lib/cloud/seed" ]
}

@test "an image carrying cloud-init with no init integration fails too" {
    mkdir -p "$ROOTFS/usr/bin"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"guest.provisioning: native"* ]]
    [ ! -d "$ROOTFS/var/lib/cloud/seed" ]
}

@test "the disabled marker is left in place when the check fails" {
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/etc/cloud"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    : > "$ROOTFS/etc/cloud/cloud-init.disabled"
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [ -e "$ROOTFS/etc/cloud/cloud-init.disabled" ]
}

@test "an image that can run cloud-init under systemd passes the check" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
}

@test "an image that can run cloud-init under OpenRC passes the check" {
    given_openrc_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------- what it writes ---

# Removing the marker is not a courtesy. Every unit carries a condition on it and
# every OpenRC script tests it by hand, so a seed written while it is in place is
# read by nothing at all.
@test "the disable marker is removed, because a seed without that does nothing" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS/etc/cloud/cloud-init.disabled" ]
}

@test "the seed is written where cloud-init looks for it" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config
packages: [htop]
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$(seed_dir)/meta-data" ]
    [ -f "$(seed_dir)/user-data" ]
    grep -q 'htop' "$(seed_dir)/user-data"
}

@test "an optional seed file is written only when it was supplied" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ ! -e "$(seed_dir)/network-config" ]
    [ ! -e "$(seed_dir)/vendor-data" ]
}

@test "network-config and vendor-data are written when they are supplied" {
    given_systemd_cloud_init
    given_material network-config 'version: 2'
    given_material vendor-data '#cloud-config'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$(seed_dir)/network-config")" = "version: 2" ]
    [ "$(cat "$(seed_dir)/vendor-data")" = "#cloud-config" ]
}

# A machine that supplies nothing still gets a seed and a drop-in. The drop-in is
# what keeps cloud-init off the files the chart maintains, and it is needed
# whether or not the machine asked for anything.
@test "a machine that supplies nothing is still seeded" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$(seed_dir)/user-data" ]
    head -n 1 "$(seed_dir)/user-data" | grep -q '#cloud-config'
}

@test "the drop-in hands the machine's own files back to the chart" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    dropin="$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg"
    [ -f "$dropin" ]
    grep -q 'NoCloud' "$dropin"
    grep -q 'preserve_hostname' "$dropin"
    grep -q 'manage_etc_hosts' "$dropin"
}

# The dangerous row of the design's division of labour. The CNI configured eth0
# before any container started; a netplan written by cloud-init and applied would
# take the pod's address away.
@test "the drop-in disables cloud-init's network management" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q 'config: disabled' "$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg"
}

# The rootfs is a volume, not a partitioned block device. There is nothing to
# grow and nothing to resize.
@test "the drop-in keeps the disk modules away from the volume" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    dropin="$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg"
    grep -q 'growpart' "$dropin"
    grep -q 'resize_rootfs' "$dropin"
}

@test "a machine whose image has no cloud.cfg.d still gets the drop-in" {
    mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/systemd/system"
    printf '#!/usr/bin/python3\n' > "$ROOTFS/usr/bin/cloud-init"
    chmod 0755 "$ROOTFS/usr/bin/cloud-init"
    : > "$ROOTFS/usr/lib/systemd/system/cloud-init-main.service"
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg" ]
}

@test "provisioning again does not duplicate what it wrote" {
    given_systemd_cloud_init
    sp_provision "$ROOTFS"
    first="$(cat "$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg")"
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOTFS/etc/cloud/cloud.cfg.d/99-stateful-pods.cfg")" = "$first" ]
}

# ------------------------------------------------------------- composition ---

# A `users:` list rather than the top-level `user:` string the reference
# implementation uses. That key is deprecated since cloud-init 22.2 and
# scheduled for removal in 27.2, and a booted Alpine machine showed the rename it
# performs going wrong as well - so the account is described rather than the
# distribution's own being renamed.
@test "a named user becomes an account of its own, not a rename" {
    given_systemd_cloud_init
    given_material user 'maxim'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    head -n 1 "$(seed_dir)/user-data" | grep -q '#cloud-config'
    body="$(tail -n +2 "$(seed_dir)/user-data")"
    jq -e '.users | length == 1' <<< "$body"
    jq -e '.users[0].name == "maxim"' <<< "$body"
    jq -e '.users[0].sudo == "ALL=(ALL) NOPASSWD:ALL"' <<< "$body"
    jq -e 'has("user") | not' <<< "$body"
}

# A hash contains $ and . and / and is exactly the kind of string a generated
# YAML document mangles. Composing JSON is what makes that impossible.
@test "a password hash survives composition unmangled" {
    given_systemd_cloud_init
    given_material password '$6$rounds=4096$abc$De.F/gh0'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e '.password == "$6$rounds=4096$abc$De.F/gh0"'
    tail -n +2 "$(seed_dir)/user-data" | jq -e '.chpasswd.expire == false'
}

# lock_passwd defaults to true, so an account given a password and not this would
# be created and then be impossible to log into with it.
@test "a password given with a user lands on that account, unlocked" {
    given_systemd_cloud_init
    given_material user 'maxim'
    given_material password '$6$rounds=4096$abc$De.F/gh0'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    body="$(tail -n +2 "$(seed_dir)/user-data")"
    jq -e '.users[0].hashed_passwd == "$6$rounds=4096$abc$De.F/gh0"' <<< "$body"
    jq -e '.users[0].lock_passwd == false' <<< "$body"
    jq -e 'has("password") | not' <<< "$body"
}

# No user named means there is no account to describe, only the distribution's
# own to add to - and the top-level keys that do that are not deprecated.
@test "keys given with no user go to the distribution's default account" {
    given_systemd_cloud_init
    given_material ssh-authorized-keys 'ssh-ed25519 AAAA one
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    body="$(tail -n +2 "$(seed_dir)/user-data")"
    jq -e '.ssh_authorized_keys == ["ssh-ed25519 AAAA one"]' <<< "$body"
    jq -e 'has("users") | not' <<< "$body"
}

@test "keys given with a user land on that account instead" {
    given_systemd_cloud_init
    given_material user 'maxim'
    given_material ssh-authorized-keys 'ssh-ed25519 AAAA one
ssh-ed25519 BBBB two
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    body="$(tail -n +2 "$(seed_dir)/user-data")"
    jq -e '.users[0].ssh_authorized_keys | length == 2' <<< "$body"
    jq -e '.users[0].ssh_authorized_keys[1] == "ssh-ed25519 BBBB two"' <<< "$body"
    jq -e 'has("ssh_authorized_keys") | not' <<< "$body"
}

@test "keys, packages and commands become arrays, one item per line" {
    given_systemd_cloud_init
    given_material ssh-authorized-keys 'ssh-ed25519 AAAA one
ssh-ed25519 BBBB two
'
    given_material packages 'htop
tmux
'
    given_material runcmd 'echo one
echo two
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    body="$(tail -n +2 "$(seed_dir)/user-data")"
    jq -e '.ssh_authorized_keys | length == 2' <<< "$body"
    jq -e '.ssh_authorized_keys[1] == "ssh-ed25519 BBBB two"' <<< "$body"
    jq -e '.packages == ["htop", "tmux"]' <<< "$body"
    jq -e '.runcmd == ["echo one", "echo two"]' <<< "$body"
}

# The one key cloud-init tells us not to use. Asserted directly, because the
# deprecation has a removal date and nothing else here would notice a
# reintroduction.
@test "the deprecated top-level user key is never emitted" {
    given_systemd_cloud_init
    given_material user 'maxim'
    given_material password 'hash'
    given_material ssh-authorized-keys 'ssh-ed25519 AAAA one
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e 'has("user") | not'
}

@test "a blank line in a list-valued input is not an item" {
    given_systemd_cloud_init
    given_material packages 'htop

tmux
'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e '.packages == ["htop", "tmux"]'
}

@test "an input that was supplied empty contributes nothing" {
    given_systemd_cloud_init
    given_material user ''
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e 'has("users") | not'
}

@test "the package upgrade switch is off unless it is asked for" {
    given_systemd_cloud_init
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e 'has("package_upgrade") | not'
    given_material package-upgrade 'true'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e '.package_upgrade == true'
}

# The refusal has to be raised where it can stop the run. Inside a command
# substitution it would end the subshell and leave the caller carrying on with an
# empty string - a silent no-op, which is the failure this whole file is about.
@test "a package upgrade switch that is neither true nor false fails" {
    given_systemd_cloud_init
    given_material package-upgrade 'sometimes'
    run sp_provision "$ROOTFS"
    [ "$status" -ne 0 ]
    [[ "$output" == *sometimes* ]]
    [ ! -e "$(seed_dir)/user-data" ]
}

# --------------------------------------------------------------- shadowing ---

# Proxmox's cicustom semantics: per-file replacement, never a merge. A YAML
# merge of two cloud-configs is a misfeature waiting to happen.
@test "raw user-data is used verbatim and shadows the structured inputs" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config
users:
  - name: from-raw
'
    given_material user 'from-structured'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    grep -q 'from-raw' "$(seed_dir)/user-data"
    ! grep -q 'from-structured' "$(seed_dir)/user-data"
}

@test "shadowing is reported rather than left for the user to notice" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config'
    given_material user 'from-structured'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [[ "$output" == *userData* ]] || [[ "$output" == *user-data* ]]
    [[ "$output" == *shadow* ]]
}

@test "shadowing is per file, so network-config is unaffected" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config'
    given_material network-config 'version: 2'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [ "$(cat "$(seed_dir)/network-config")" = "version: 2" ]
}

@test "nothing is reported when no structured input was shadowed" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config'
    run sp_provision "$ROOTFS"
    [ "$status" -eq 0 ]
    [[ "$output" != *shadow* ]]
}

# -------------------------------------------------------- instance identity ---

instance_id() { sed -n 's/^instance-id: //p' "$(seed_dir)/meta-data"; }

@test "the same material yields the same instance on every start" {
    given_systemd_cloud_init
    given_material user 'maxim'
    sp_provision "$ROOTFS"
    first="$(instance_id)"
    sp_provision "$ROOTFS"
    [ -n "$first" ]
    [ "$(instance_id)" = "$first" ]
}

@test "changed material makes it a new instance, so cloud-init re-applies" {
    given_systemd_cloud_init
    given_material user 'maxim'
    sp_provision "$ROOTFS"
    first="$(instance_id)"
    given_material user 'someone-else'
    sp_provision "$ROOTFS"
    [ "$(instance_id)" != "$first" ]
}

# The clone case. A volume restored under another name is a different machine and
# must not keep the original's per-instance state.
@test "the same material under another machine name is another instance" {
    given_systemd_cloud_init
    given_material user 'maxim'
    sp_provision "$ROOTFS"
    first="$(instance_id)"
    export SP_RELEASE=other
    sp_provision "$ROOTFS"
    [ "$(instance_id)" != "$first" ]
}

@test "a changed namespace is another instance too" {
    given_systemd_cloud_init
    sp_provision "$ROOTFS"
    first="$(instance_id)"
    export SP_NAMESPACE=elsewhere
    sp_provision "$ROOTFS"
    [ "$(instance_id)" != "$first" ]
}

# The identity is computed from the seed as written, so it cannot depend on
# whether a value arrived inline or through somebody else's Secret.
@test "the identity does not depend on where the material came from" {
    given_systemd_cloud_init
    given_material user-data '#cloud-config
users: [{name: maxim}]
'
    sp_provision "$ROOTFS"
    first="$(instance_id)"
    rm -rf "$MATERIAL"
    MATERIAL="$(mktemp -d)"
    export SP_PROVISIONING_DIR="$MATERIAL"
    given_material user-data '#cloud-config
users: [{name: maxim}]
'
    sp_provision "$ROOTFS"
    [ "$(instance_id)" = "$first" ]
}

@test "the instance identity is a plausible identifier and nothing more" {
    given_systemd_cloud_init
    sp_provision "$ROOTFS"
    [[ "$(instance_id)" =~ ^[0-9a-f]{40}$ ]]
}

# --------------------------------------------------------------- the driver ---

@test "the entry point refuses a rootfs that is not mounted" {
    export SP_ROOTFS="$ROOTFS/absent"
    run bash "$SCRIPTS/provision.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$ROOTFS/absent"* ]]
}

@test "the entry point runs the whole thing" {
    given_systemd_cloud_init
    given_material user 'maxim'
    run bash "$SCRIPTS/provision.sh"
    [ "$status" -eq 0 ]
    [ -f "$(seed_dir)/meta-data" ]
    tail -n +2 "$(seed_dir)/user-data" | jq -e '.users[0].name == "maxim"'
}

@test "a machine that was given no material directory at all still provisions" {
    given_systemd_cloud_init
    export SP_PROVISIONING_DIR="$MATERIAL/absent"
    run bash "$SCRIPTS/provision.sh"
    [ "$status" -eq 0 ]
    [ -f "$(seed_dir)/user-data" ]
}
