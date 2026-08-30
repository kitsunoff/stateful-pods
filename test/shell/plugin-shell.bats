#!/usr/bin/env bats
#
# Getting into a machine, and being told the truth when that is not possible.
#
# "Cannot exec into container guest" is a true statement about a machine whose
# root filesystem is still being unpacked, and a useless one. This is the reason
# the plugin exists, so the failures below are tested at least as hard as the
# success.

load plugin-lib

setup() {
    plugin_setup
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
}

running() {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" "guest=running,,,${1:-true};")"
}

@test "a running machine is entered, in its guest container" {
    running true
    machine shell web --namespace homelab --tty
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"exec --stdin --tty lab-web-0 --container guest"* ]]
}

# /bin/sh exists in every root filesystem the chart can seed; bash does not,
# because Alpine and Void do not ship it. Choosing inside the machine costs one
# round trip instead of two and cannot be wrong.
@test "the shell is chosen inside the machine, in one round trip" {
    running true
    machine shell web --namespace homelab --tty
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"/bin/sh -c"* ]]
    [[ "$(calls)" == *"command -v bash"* ]]
    [[ "$(calls)" == *"exec sh"* ]]
    # One exec, not a probe followed by a shell.
    [ "$(grep --count 'exec --stdin' "$RECORD")" -eq 1 ]
}

@test "a booting machine can still be entered, since its guest is running" {
    running false
    machine shell web --namespace homelab --tty
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"exec --stdin"* ]]
}

@test "a trailing -- passes a command through instead of opening a shell" {
    running true
    machine shell web --namespace homelab -- cat /etc/os-release
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"--container guest -- cat /etc/os-release"* ]]
    [[ "$(calls)" != *"command -v bash"* ]]
}

@test "a machine still being seeded reports the stage, not a container error" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Pending 'seed=running,,,false;' '')"
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"root filesystem"* ]]
    [[ "$output" == *"logs lab-web-0 --container seed --follow"* ]]
    [[ "$output" != *"cannot exec"* ]]
    ! grep --quiet 'exec --stdin' "$RECORD"
}

@test "a machine whose seed step failed names the step and how to read it" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Pending 'seed=terminated,Error,1,false;' '')"
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"--container seed"* ]]
    ! grep --quiet 'exec --stdin' "$RECORD"
}

@test "a machine being prepared reports that stage" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Pending 'seed=terminated,Completed,0,true;prepare=running,,,false;' '')"
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"preparing"* ]]
    [[ "$output" == *"--container prepare"* ]]
}

@test "a stopped machine says it is stopped and where its last output is" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Succeeded "$(seeded_init)" 'guest=terminated,Completed,0,false;')"
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"stopped"* ]]
    [[ "$output" == *"--previous"* ]]
    ! grep --quiet 'exec --stdin' "$RECORD"
}

@test "a machine with no pod at all says so rather than exec'ing into nothing" {
    export SP_TEST_PODS=""
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"not running"* ]]
    ! grep --quiet 'exec --stdin' "$RECORD"
}

@test "an ambiguous name never opens a shell into either machine" {
    export SP_TEST_STATEFULSETS="$(printf 'web|lab|lab-web\nweb|prod|prod-web\n')"
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"--release"* ]]
    ! grep --quiet 'exec --stdin' "$RECORD"
}

@test "the command that will be run is printed before it runs" {
    running true
    machine shell web --namespace homelab --tty
    [ "$status" -eq 0 ]
    [[ "$output" == *"==> kubectl"* ]]
    [[ "$output" == *"--namespace homelab"* ]]
}

@test "console is the guest container's logs" {
    running true
    machine console web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"logs lab-web-0 --container guest"* ]]
}

@test "console follows when asked" {
    running true
    machine console web --namespace homelab --follow
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"--follow"* ]]
}

# The boot output is the thing worth watching while a machine boots, so this is
# the one read that does not refuse a machine that is not ready.
@test "console works while the machine is still booting" {
    running false
    machine console web --namespace homelab --follow
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"logs lab-web-0 --container guest"* ]]
}

@test "console on a machine that has not booted yet points at the step that is running" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Pending 'seed=running,,,false;' '')"
    machine console web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"--container seed"* ]]
}

@test "console can read the output of a machine that has stopped" {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Succeeded "$(seeded_init)" 'guest=terminated,Error,1,false;')"
    machine console web --namespace homelab --previous
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"--container guest --previous"* ]]
}
