# shellcheck shell=bash
#
# Carrying a machine's own script into the machine and running it there.
#
# Everything here runs in a Job beside the machine, never in the machine's pod,
# and reaches the machine through the cluster's API. The ordering is the whole
# point: the script has to run after the root change and after the machine's init
# has come up, which is the one moment no container in the machine's own pod can
# act in.
#
# Nothing here interpolates a value into a shell command that runs inside the
# machine. The script arrives as bytes on standard input and is executed by path;
# the environment arrives the same way and is sourced from a file. A value the
# chart was given is therefore never parsed as shell by this script, and never
# appears on a command line, in the machine's process table or in the cluster's
# audit log.

# Where the material the chart assembled is mounted, in this Job's own pod.
SP_EXEC_DIR_DEFAULT="/provisioning"

# Where it is placed inside the machine. /run is a tmpfs the boot sequence
# mounts, so the script and the environment are gone at the machine's next boot
# and never reach its volume or any snapshot of it. That matters because the
# environment is where a secret would be.
SP_EXEC_TARGET_DIR="/run/stateful-pods/provision"

# How often the machine is asked whether it is up, and how loudly the wait
# narrates. A machine seeding an operating system onto an empty volume takes
# minutes, and a Job that printed nothing for those minutes would be
# indistinguishable from one that is stuck.
SP_EXEC_POLL_SECONDS="${SP_EXEC_POLL_SECONDS:-5}"
SP_EXEC_REPORT_EVERY="${SP_EXEC_REPORT_EVERY:-12}"

# sp_exec_material <name>
# The content of one materialized input, or nothing. The same contract the
# provisioning step reads its own directory by: this script cannot tell an inline
# value from a projected Secret key.
sp_exec_material() {
    _sp_file="${SP_EXEC_DIR:-$SP_EXEC_DIR_DEFAULT}/$1"
    [ -f "$_sp_file" ] || return 0
    cat "$_sp_file"
}

sp_exec_has_material() {
    [ -f "${SP_EXEC_DIR:-$SP_EXEC_DIR_DEFAULT}/$1" ]
}

sp_kubectl() {
    kubectl --namespace "${SP_NAMESPACE:?}" "$@"
}

# The container inside the machine's pod that *is* the machine, after the root
# change. Fixed rather than an input: the pod is this chart's own and the name is
# part of it.
sp_exec_container() {
    printf '%s' "${SP_TARGET_CONTAINER:-guest}"
}

# sp_exec_in_machine <command...>
# One command, inside the machine, as the machine's own root.
sp_exec_in_machine() {
    sp_kubectl exec "$SP_TARGET_POD" --container "$(sp_exec_container)" -- "$@"
}

# Waits until the machine's own init has come up.
#
# Readiness rather than the boot marker alone, because the marker says the root
# changed and readiness says the operating system started - and a script that
# installs a package needs the second. The marker is confirmed as well, below,
# because readiness is derived per init system while the marker means exactly
# "this process is the machine and not the shim".
#
# A poll rather than `kubectl wait`. `kubectl wait` opens a watch, and a watch
# cannot be restricted to one object by name - `resourceNames` does not apply to
# list and watch - so a Job that used it would need the right to watch every pod
# in the namespace. Polling is what lets the Role name a single pod.
#
# There is no timeout here on purpose. The Job's own activeDeadlineSeconds bounds
# the whole of it, wait and run together, so a machine that never comes up fails
# the Job with DeadlineExceeded rather than being timed out twice with two
# different messages.
sp_exec_wait_for_machine() {
    _sp_waited=0
    _sp_polls=0
    while true; do
        _sp_ready="$(sp_kubectl get pod "$SP_TARGET_POD" --output \
            "jsonpath={.status.containerStatuses[?(@.name==\"$(sp_exec_container)\")].ready}" \
            2>/dev/null || true)"
        if [ "$_sp_ready" = "true" ]; then
            sp_log "machine ${SP_MACHINE:-?}: the machine reports itself ready after ${_sp_waited}s"
            return 0
        fi
        # Counted in polls rather than in seconds, because the interval is an
        # input and a suite that makes it instant would otherwise divide by zero.
        if [ $((_sp_polls % SP_EXEC_REPORT_EVERY)) -eq 0 ]; then
            _sp_phase="$(sp_kubectl get pod "$SP_TARGET_POD" --output \
                "jsonpath={.status.phase}" 2>/dev/null || true)"
            sp_log "machine ${SP_MACHINE:-?}: waiting for the machine to finish starting (pod ${_sp_phase:-not created yet}, ${_sp_waited}s so far). A machine seeding an operating system onto an empty volume takes minutes."
        fi
        sleep "$SP_EXEC_POLL_SECONDS"
        _sp_polls=$((_sp_polls + 1))
        _sp_waited=$((_sp_waited + SP_EXEC_POLL_SECONDS))
    done
}

# That what this is about to exec into is the machine, and not the shim that
# precedes it. boot.sh writes this marker immediately after pivot_root, onto the
# tmpfs it has just mounted, so its presence means the root change happened in
# this boot and not in some earlier one.
sp_exec_confirm_machine() {
    if sp_exec_in_machine /bin/sh -c 'test -f /run/stateful-pods/booted' >/dev/null 2>&1; then
        sp_log "machine ${SP_MACHINE:-?}: the root change has happened, so this is the machine"
        return 0
    fi
    sp_die "machine ${SP_MACHINE:-?}: the pod reports itself ready but /run/stateful-pods/booted is not there, so the container is not past its root change. Nothing has been run. This is the chart and the shim image disagreeing about the boot sequence, which means they are different versions of themselves."
}

# Places one file inside the machine, from this Job's standard input.
#
# This is what `kubectl cp` does and is deliberately not `kubectl cp`: that runs
# tar INSIDE the target container and pipes an archive to it, so a machine
# without an archiver would fail for a reason that has nothing to do with its
# script. Streaming through a shell needs only a shell.
sp_exec_place_file() {
    _sp_name="$1"
    if ! sp_exec_material "$_sp_name" | sp_kubectl exec --stdin "$SP_TARGET_POD" \
        --container "$(sp_exec_container)" -- /bin/sh -c \
        "umask 0077; mkdir -p $SP_EXEC_TARGET_DIR && cat > $SP_EXEC_TARGET_DIR/$_sp_name"
    then
        sp_die "machine ${SP_MACHINE:-?}: could not write $_sp_name into the machine at $SP_EXEC_TARGET_DIR. Nothing has been run."
    fi
}

# Removes what was placed, whether the script succeeded or not. Best effort: the
# directory is on a tmpfs and is gone at the machine's next boot in any case, so
# a failure to remove it is not worth failing a run that otherwise worked.
sp_exec_clean() {
    sp_exec_in_machine /bin/sh -c "rm -rf $SP_EXEC_TARGET_DIR" >/dev/null 2>&1 || true
}

sp_exec_provision() {
    if ! sp_exec_has_material script; then
        sp_die "machine ${SP_MACHINE:-?}: no script was mounted at ${SP_EXEC_DIR:-$SP_EXEC_DIR_DEFAULT}/script. The chart renders this Job only for a machine that supplies one, so reaching here means the chart and this image are different versions of themselves."
    fi

    sp_exec_wait_for_machine
    sp_exec_confirm_machine

    sp_exec_place_file script
    if sp_exec_has_material environment; then
        sp_exec_place_file environment
        sp_log "machine ${SP_MACHINE:-?}: the environment was placed beside the script, on the machine's tmpfs, and is read from there rather than passed as arguments"
    fi

    _sp_interpreter="${SP_EXEC_INTERPRETER:-/bin/sh}"
    sp_log "machine ${SP_MACHINE:-?}: running the machine's script with $_sp_interpreter"
    _sp_status=0
    if sp_exec_has_material environment; then
        # `sh -c <program> <name> <arg>...` puts the arguments in "$@", so the
        # interpreter and the path are arguments rather than text spliced into a
        # program. An interpreter that is not a shell works unchanged.
        sp_exec_in_machine /bin/sh -c \
            "set -a; . $SP_EXEC_TARGET_DIR/environment; set +a; exec \"\$@\"" \
            stateful-pods-exec "$_sp_interpreter" "$SP_EXEC_TARGET_DIR/script" \
            || _sp_status=$?
    else
        sp_exec_in_machine "$_sp_interpreter" "$SP_EXEC_TARGET_DIR/script" || _sp_status=$?
    fi

    sp_exec_clean

    if [ "$_sp_status" -ne 0 ]; then
        sp_die "machine ${SP_MACHINE:-?}: the machine's script exited $_sp_status. Its output is above, in this Job's logs. The machine itself is untouched by this failure and is still running; what it did before it failed has been done."
    fi
    sp_log "machine ${SP_MACHINE:-?}: the machine's script completed"
    return 0
}
