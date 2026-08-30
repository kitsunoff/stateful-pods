#!/usr/bin/env bats
#
# Where a machine is in its life, one test per row of the table in the change's
# design document.
#
# A machine takes minutes to become usable and a pod-level view spends most of
# that time saying `Init:1/3`, which answers a question about containers. Every
# answer here comes from that machine's own status: no stage is inferred from how
# long something has been happening, because a 400 MB template legitimately takes
# minutes and a timer would call a healthy machine broken.

load plugin-lib

setup() {
    plugin_setup
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
}

# Puts the machine in a state, expressed as its init and guest container statuses.
in_state() {
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 "$3" "$1" "$2")"
}

@test "the seed step running is seeding the root filesystem" {
    in_state 'seed=running,,,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"root filesystem"* ]]
    [[ "$output" == *"--container seed"* ]]
}

@test "the prepare step running is preparing the machine's identity" {
    in_state 'seed=terminated,Completed,0,true;prepare=running,,,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"preparing"* ]]
    [[ "$output" == *"identity"* ]]
}

@test "the customize step running is writing the files the chart maintains" {
    in_state 'seed=terminated,Completed,0,true;prepare=terminated,Completed,0,true;customize=running,,,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"customizing"* ]]
    [[ "$output" == *"files"* ]]
}

@test "a guest that is running but not ready is booting" {
    in_state "$(seeded_init)" 'guest=running,,,false;' Running
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"booting"* ]]
}

@test "a guest that is running and ready is ready" {
    in_state "$(seeded_init)" 'guest=running,,,true;' Running
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready"* ]]
}

@test "a guest that exited cleanly is stopped, and the container is named" {
    in_state "$(seeded_init)" 'guest=terminated,Completed,0,false;' Succeeded
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"stopped"* ]]
    [[ "$output" == *"guest"* ]]
}

@test "a guest that is backing off has failed, and the container is named" {
    in_state "$(seeded_init)" 'guest=waiting,CrashLoopBackOff,,false;' Running
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"guest"* ]]
    [[ "$output" == *"CrashLoopBackOff"* ]]
}

@test "a guest that exited non-zero has failed" {
    in_state "$(seeded_init)" 'guest=terminated,Error,137,false;' Running
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"137"* ]]
}

@test "an init step in error names the stage it failed in and how to read it" {
    in_state 'seed=terminated,Error,1,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"logs lab-web-0 --container seed"* ]]
}

@test "an init step backing off names the stage it failed in" {
    in_state 'seed=terminated,Completed,0,true;prepare=waiting,CrashLoopBackOff,,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"preparing"* ]]
    [[ "$output" == *"--container prepare"* ]]
}

@test "a pod that has not started anything yet is pending, not a guessed stage" {
    in_state '' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending"* ]]
    [[ "$output" == *"describe"* ]]
}

@test "a machine with no pod says so, and that its release is there" {
    export SP_TEST_PODS=""
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"not running"* ]]
    [[ "$output" == *"lab"* ]]
}

# The whole point of deriving a stage rather than reporting a container state.
@test "no stage is derived from anything but that machine's own status" {
    in_state 'seed=running,,,false;' '' Pending
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    # The status read is a projection of the pod, and nothing else is consulted.
    ! grep --quiet '^kubectl get events' "$RECORD"
    [[ "$(calls)" == *"go-template"* ]]
}
