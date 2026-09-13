#!/usr/bin/env bats
#
# Carrying a machine's own script into the machine and running it there.
#
# This is the only part of the chart that acts on a machine from outside it and
# the only part that talks to the cluster's API, so it is the only part whose
# mistakes are invisible from inside a pod. The cases that matter are the ones
# where it would appear to work: execing into a container that has not yet
# become the machine, putting a secret on a command line, or reporting success
# for a script that failed.
#
# kubectl is stubbed. What is asserted is what this library asks the cluster to
# do - which commands, in which order, with what on standard input - because
# that is the whole of its behaviour.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    MATERIAL="$(mktemp -d)"
    CONTROL="$(mktemp -d)"
    BIN="$(mktemp -d)"
    export SP_EXEC_DIR="$MATERIAL"
    export SP_MACHINE=web
    export SP_RELEASE=lab
    export SP_NAMESPACE=machines
    export SP_TARGET_POD=lab-web-0
    export SP_TARGET_CONTAINER=guest
    # The poll is real, so the wait is exercised rather than stubbed out; it is
    # just made instant.
    export SP_EXEC_POLL_SECONDS=0
    export SP_TEST_CONTROL="$CONTROL"
    printf 'true\n' > "$CONTROL/ready"
    printf 'Running\n' > "$CONTROL/phase"
    printf '0\n' > "$CONTROL/booted"
    printf '0\n' > "$CONTROL/run"
    : > "$CONTROL/calls"
    given_kubectl
    PATH="$BIN:$PATH"
    export PATH
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-exec.sh"
}

teardown() { rm -rf "$MATERIAL" "$CONTROL" "$BIN"; }

# A kubectl that records every invocation and answers from files this suite
# writes. Each call is recorded as one line, so a test can assert both what was
# asked and the order it was asked in.
given_kubectl() {
    cat > "$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
# Joined first: a prefix removal applied to "$*" is applied to each positional
# parameter and then joined, which is not what reading the last path component
# of the whole command means.
argv="$*"
printf '%s\n' "$argv" >> "$SP_TEST_CONTROL/calls"
case "$argv" in
    *containerStatuses*)
        # One answer per line; the last one repeats, so a sequence can end in
        # "true" and the wait terminates.
        answers="$SP_TEST_CONTROL/ready"
        head -n 1 "$answers"
        if [ "$(wc -l < "$answers")" -gt 1 ]; then
            tail -n +2 "$answers" > "$answers.next"
            mv "$answers.next" "$answers"
        fi
        ;;
    *status.phase*)
        cat "$SP_TEST_CONTROL/phase"
        ;;
    *"/run/stateful-pods/booted"*)
        exit "$(cat "$SP_TEST_CONTROL/booted")"
        ;;
    *"cat > "*)
        # The placement. Its standard input is the file being written.
        name="${argv##*/}"
        cat > "$SP_TEST_CONTROL/placed-$name"
        ;;
    *"rm -rf"*)
        : > "$SP_TEST_CONTROL/cleaned"
        ;;
    *)
        exit "$(cat "$SP_TEST_CONTROL/run")"
        ;;
esac
STUB
    chmod 0755 "$BIN/kubectl"
}

given_script() { printf '%s' "$1" > "$MATERIAL/script"; }
given_environment() { printf '%s' "$1" > "$MATERIAL/environment"; }
calls() { cat "$CONTROL/calls"; }

# --------------------------------------------------------------- the refusal ---

# The chart renders this Job only for a machine that supplies a script, so an
# empty directory means the chart and the image are different versions of
# themselves - which is worth saying rather than exiting zero having done
# nothing.
@test "it refuses to run with no script mounted, and execs into nothing" {
    run sp_exec_provision
    [ "$status" -ne 0 ]
    [[ "$output" == *"no script was mounted"* ]]
    [ ! -s "$CONTROL/calls" ]
}

# ------------------------------------------------------------------ the wait ---

@test "it waits until the machine reports itself ready before it execs" {
    given_script 'echo hello'
    printf 'false\nfalse\ntrue\n' > "$CONTROL/ready"
    run sp_exec_provision
    [ "$status" -eq 0 ]
    # Three readiness questions, and nothing else asked before the third.
    [ "$(grep -c containerStatuses "$CONTROL/calls")" -eq 3 ]
    first_exec="$(grep -n 'exec' "$CONTROL/calls" | head -n 1 | cut -d: -f1)"
    last_ready="$(grep -n containerStatuses "$CONTROL/calls" | tail -n 1 | cut -d: -f1)"
    [ "$first_exec" -gt "$last_ready" ]
}

@test "it asks about one pod by name, which is the whole of what its Role allows" {
    given_script 'echo hello'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    # No list, no watch: both are what `kubectl wait` would need and neither can
    # be restricted to a single object by name.
    ! grep -q 'kubectl.*wait' "$CONTROL/calls"
    grep -q 'get pod lab-web-0' "$CONTROL/calls"
    ! grep -qE 'get pods( |$)' "$CONTROL/calls"
}

# ------------------------------------------------------------ the root change ---

# Readiness says the operating system started. This says the container is past
# pivot_root and is therefore the machine rather than the shim - which is the one
# thing that must be true before a script runs as "the machine's own root".
@test "it confirms the boot marker before it places anything" {
    given_script 'echo hello'
    printf '1\n' > "$CONTROL/booted"
    run sp_exec_provision
    [ "$status" -ne 0 ]
    [[ "$output" == *"/run/stateful-pods/booted"* ]]
    [ ! -e "$CONTROL/placed-script" ]
}

# ----------------------------------------------------------- the placement ---

# `kubectl cp` runs tar INSIDE the target container, so a machine without an
# archiver would fail for a reason that has nothing to do with its script.
@test "it streams the script through a shell rather than an archiver" {
    given_script 'echo the script itself'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    [ "$(cat "$CONTROL/placed-script")" = 'echo the script itself' ]
    ! grep -q 'tar' "$CONTROL/calls"
}

@test "it writes the script where the machine's next boot will lose it" {
    given_script 'echo hello'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    grep -q '/run/stateful-pods/provision/script' "$CONTROL/calls"
    # /run is a tmpfs the boot sequence mounts, so nothing placed there reaches
    # the machine's volume or any snapshot of it.
    ! grep -q '/var/lib/stateful-pods' "$CONTROL/calls"
}

@test "it places nothing but the script when no environment was supplied" {
    given_script 'echo hello'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    [ ! -e "$CONTROL/placed-environment" ]
}

# --------------------------------------------------------- the environment ---

# An environment is where a secret would be. An argument appears in this Job's
# own logs, in the machine's process table and in the cluster's audit log; a file
# on a tmpfs appears in none of them.
@test "the environment is written to a file and never passed as an argument" {
    given_script 'echo hello'
    given_environment 'TOKEN=hunter2'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    [ "$(cat "$CONTROL/placed-environment")" = 'TOKEN=hunter2' ]
    ! grep -q 'hunter2' "$CONTROL/calls"
}

@test "the environment is sourced by the command that runs the script" {
    given_script 'echo hello'
    given_environment 'TOKEN=hunter2'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    grep -q '\. /run/stateful-pods/provision/environment' "$CONTROL/calls"
}

# ------------------------------------------------------------------- the run ---

@test "it runs the script with the interpreter the machine named" {
    given_script 'echo hello'
    export SP_EXEC_INTERPRETER=/usr/bin/python3
    run sp_exec_provision
    [ "$status" -eq 0 ]
    grep -q '/usr/bin/python3 /run/stateful-pods/provision/script' "$CONTROL/calls"
}

@test "it runs the script with a shell when the machine named none" {
    given_script 'echo hello'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    grep -q '/bin/sh /run/stateful-pods/provision/script' "$CONTROL/calls"
}

@test "a script that fails fails the run, naming its status" {
    given_script 'exit 3'
    printf '3\n' > "$CONTROL/run"
    run sp_exec_provision
    [ "$status" -ne 0 ]
    [[ "$output" == *"exited 3"* ]]
}

@test "what the script did before it failed is not claimed to be undone" {
    given_script 'exit 3'
    printf '3\n' > "$CONTROL/run"
    run sp_exec_provision
    [ "$status" -ne 0 ]
    [[ "$output" == *"has been done"* ]]
}

@test "it removes what it placed, whether the script succeeded or not" {
    given_script 'exit 3'
    printf '3\n' > "$CONTROL/run"
    run sp_exec_provision
    [ "$status" -ne 0 ]
    [ -e "$CONTROL/cleaned" ]
}

@test "it says what it did when the script succeeded" {
    given_script 'echo hello'
    run sp_exec_provision
    [ "$status" -eq 0 ]
    [[ "$output" == *"completed"* ]]
    [ -e "$CONTROL/cleaned" ]
}
