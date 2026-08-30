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
    export SP_TEST_ALL_STATEFULSETS="$(printf 'api|lab|lab-api\ndb|prod|prod-db\n')"
    machine status ghost --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"ghost"* ]]
    [[ "$output" == *"api"* ]]
    [[ "$output" == *"db"* ]]
}

@test "an ambiguous name is reported with every match, and nothing is done" {
    export SP_TEST_STATEFULSETS="$(printf 'web|lab|lab-web\nweb|prod|prod-web\n')"
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
    export SP_TEST_STATEFULSETS="$(printf 'api|lab|lab-api\ndb|lab|lab-db\n')"
    export SP_TEST_PODS="$(printf 'api|lab|lab-api-0|Running|%s|guest=running,,,true;\ndb|lab|lab-db-0|Pending|seed=running,,,false;|\n' "$(seeded_init)")"
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

@test "a machine name given to list is answered with the command that takes one" {
    machine list web --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"status web"* ]]
}

# Two releases in one namespace, each with a machine called `web`. The header of
# this file calls picking the wrong pet the one mistake this must not make, and a
# listing is the first place a user meets that case - before they know to reach
# for --release.
@test "two machines of the same name are listed with their own stages" {
    export SP_TEST_ALL_STATEFULSETS="$(printf 'web|lab|lab-web\nweb|prod|prod-web\n')"
    export SP_TEST_ALL_PODS="$(printf 'web|lab|lab-web-0|Running|%s|guest=running,,,true;\nweb|prod|prod-web-0|Pending|seed=running,,,false;|\n' "$(seeded_init)")"
    machine list --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab      ready"* ]]
    [[ "$output" == *"prod     seeding"* ]]
}

@test "list narrows to a release when it is given one" {
    export SP_TEST_ALL_STATEFULSETS="$(sts_line web lab lab-web)"
    export SP_TEST_ALL_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    machine list --release lab --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"statefulsets --selector stateful-pods.io/machine,app.kubernetes.io/instance=lab"* ]]
}

# The read for one named machine succeeds and the read for every machine is
# denied. Without the failure being reported where it can stop the program, the
# right answer is printed and then contradicted by a wrong one.
@test "a broad read that is denied does not become 'no machines at all'" {
    export SP_TEST_STATEFULSETS=""
    export SP_TEST_BROAD_STATUS=1
    machine status ghost --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" != *"no machines at all"* ]]
    [[ "$output" != *"These are there"* ]]
}

# A pod another release left behind carries the same machine label, so a read
# that is not narrowed to the resolved release sees two pods for one machine.
@test "a pod belonging to another release is not mistaken for this machine's" {
    export SP_TEST_STATEFULSETS="$(sts_line web prod prod-web)"
    export SP_TEST_PODS="$(pod_line web prod prod-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    machine status web --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready"* ]]
    [[ "$(calls)" == *"pods --selector stateful-pods.io/machine=web,app.kubernetes.io/instance=prod"* ]]
}

# Once --release narrows what is read, a message about "everything here" is about
# that release. Saying it about the namespace is a claim about objects the plugin
# did not look at, and in a namespace that holds other releases it is simply
# false - the same class of confidently wrong answer the plugin exists to remove.
@test "an empty release does not report the whole namespace as empty" {
    export SP_TEST_ALL_STATEFULSETS="$(printf 'api|lab|lab-api\ndb|prod|prod-db\n')"
    export SP_TEST_NARROWED=""
    machine list --release nope --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"release nope"* ]]
    [[ "$output" != "There are no machines in namespace homelab." ]]
}

@test "a name not in a release does not claim the namespace has no machines" {
    export SP_TEST_STATEFULSETS=""
    export SP_TEST_ALL_STATEFULSETS="$(printf 'api|lab|lab-api\ndb|prod|prod-db\n')"
    export SP_TEST_NARROWED=""
    machine status ghost --release nope --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"release nope"* ]]
    [[ "$output" == *"no machines at all"* ]]
}

@test "without a release the messages still speak for the namespace" {
    export SP_TEST_ALL_STATEFULSETS=""
    machine list --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"no machines in namespace homelab"* ]]
    [[ "$output" != *"release"* ]]
}
