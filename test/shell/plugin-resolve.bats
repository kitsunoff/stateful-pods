#!/usr/bin/env bats
#
# Addressing a machine by the name it was declared under.
#
# The name a user knows is the key under `machines` in their values; the object
# name is a rule the chart applies to it. The plugin resolves one to the other
# through the label the chart puts on every object, and the case that matters is
# the ambiguous one: two releases in a namespace can each declare a machine
# called `web`, and picking the wrong pet is the one mistake this must not make.

load plugin-lib

setup() { plugin_setup; }

@test "a machine is found by its own name, never by the naming rule" {
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"web"* ]]
    [[ "$output" == *"lab-web"* ]]
    # The selector, not a name the plugin assembled for itself.
    [[ "$(calls)" == *"--selector stateful-pods.io/machine=web"* ]]
}

@test "an unknown name reports what is in the namespace instead" {
    export SP_TEST_STATEFULSETS=""
    machine status ghost --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"ghost"* ]]
    # Having found nothing under that name, it asks what is there.
    [[ "$(calls)" == *"--selector stateful-pods.io/machine"* ]]
}

@test "an unknown name lists the machines that do exist" {
    export SP_TEST_STATEFULSETS=""
    export SP_TEST_ALL_STATEFULSETS="$(printf 'api\tlab\tlab-api\ndb\tprod\tprod-db\n')"
    machine status ghost --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"ghost"* ]]
    [[ "$output" == *"api"* ]]
    [[ "$output" == *"db"* ]]
}

@test "an ambiguous name is reported with every match, and nothing is done" {
    export SP_TEST_STATEFULSETS="$(printf 'web\tlab\tlab-web\nweb\tprod\tprod-web\n')"
    machine status web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"lab"* ]]
    [[ "$output" == *"prod"* ]]
    [[ "$output" == *"--release"* ]]
    # Nothing was read about either of them beyond the question of which is which.
    ! grep --quiet '^kubectl get pods' "$RECORD"
}

@test "--release settles an ambiguous name" {
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    machine status web --release lab --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"stateful-pods.io/machine=web,app.kubernetes.io/instance=lab"* ]]
}

@test "list names every machine with its stage and its object" {
    export SP_TEST_STATEFULSETS="$(printf 'api\tlab\tlab-api\ndb\tlab\tlab-db\n')"
    export SP_TEST_PODS="$(printf 'api\tlab\tlab-api-0\tRunning\t%s\tguest=running,,,true;\ndb\tlab\tlab-db-0\tPending\tseed=running,,,false;\t\n' "$(seeded_init)")"
    machine list --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"api"* ]]
    [[ "$output" == *"ready"* ]]
    [[ "$output" == *"db"* ]]
    [[ "$output" == *"seeding"* ]]
    [[ "$output" == *"lab-db"* ]]
}

@test "a machine whose pod has not been created yet still appears in a list" {
    export SP_TEST_STATEFULSETS="$(sts_line db lab lab-db)"
    export SP_TEST_PODS=""
    machine list --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"db"* ]]
}

@test "an empty namespace says so rather than printing a bare header" {
    export SP_TEST_STATEFULSETS=""
    machine list --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"no machines"* ]]
}

@test "the namespace and context asked for are the ones passed through" {
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    machine status web --namespace homelab --context other
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"--namespace homelab"* ]]
    [[ "$(calls)" == *"--context other"* ]]
}

# A read that failed is not an empty answer. Reporting an unreachable cluster as
# a namespace with no machines in it would be the same confidently wrong answer
# that "cannot exec into container guest" is, one level up.
@test "a cluster that cannot be read is not reported as an empty namespace" {
    export SP_TEST_KUBECTL_STATUS=1
    machine list --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" != *"no machines in"* ]]
}

@test "a read that failed does not become a machine that is not there" {
    export SP_TEST_KUBECTL_STATUS=1
    machine status web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" != *"no machines at all"* ]]
}

@test "a read that failed opens no shell and uninstalls nothing" {
    export SP_TEST_KUBECTL_STATUS=1
    machine shell web --namespace homelab
    [ "$status" -ne 0 ]
    machine delete web --namespace homelab --yes
    [ "$status" -ne 0 ]
    ! grep --quiet 'exec --stdin' "$RECORD"
    ! grep --quiet 'helm uninstall' "$RECORD"
}
