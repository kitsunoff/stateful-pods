#!/usr/bin/env bats
#
# Removing a machine, and not removing its root filesystem.
#
# The chart retains the claim, and this is where that rule would be easiest to
# break: a convenience flag that cleaned everything up would make an irreversible
# act as cheap as a reversible one. There is no such flag, and the last test in
# here is what keeps it that way.

load plugin-lib

setup() {
    plugin_setup
    export SP_TEST_STATEFULSETS="$(sts_line web lab lab-web)"
    export SP_TEST_PODS="$(pod_line web lab lab-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    export SP_TEST_PVCS="$(printf 'lab-web-lab-web-0\n')"
}

@test "a confirmed removal uninstalls the release" {
    machine delete web --namespace homelab <<< "web"
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"helm uninstall lab"* ]]
    [[ "$(calls)" == *"--namespace homelab"* ]]
}

@test "the context, namespace, machine and object name are stated before it acts" {
    machine delete web --namespace homelab <<< "web"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kind-lab"* ]]
    [[ "$output" == *"homelab"* ]]
    [[ "$output" == *"web"* ]]
    [[ "$output" == *"lab-web"* ]]
    [[ "$output" == *"==> helm uninstall"* ]]
}

@test "a confirmation that is not the machine's name removes nothing" {
    machine delete web --namespace homelab <<< "yes"
    [ "$status" -ne 0 ]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

@test "an empty confirmation removes nothing" {
    machine delete web --namespace homelab <<< ""
    [ "$status" -ne 0 ]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

# A pipeline that answers no question must not be read as consent.
@test "a non-interactive run without --yes does nothing" {
    machine delete web --namespace homelab < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes"* ]]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

@test "--yes is the non-interactive form" {
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"helm uninstall lab"* ]]
}

@test "the root filesystem is named before the removal, and said to survive" {
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab-web-lab-web-0"* ]]
    [[ "$output" == *"root filesystem"* ]]
}

@test "the command that would destroy the root filesystem is printed, and not run" {
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete persistentvolumeclaim lab-web-lab-web-0"* ]]
    ! grep --quiet 'kubectl.*delete persistentvolumeclaim' "$RECORD"
}

@test "no flag anywhere in the plugin removes a machine and its root filesystem together" {
    machine --help
    [ "$status" -eq 0 ]
    machine delete --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"--purge"* ]]
    [[ "$output" != *"--with-volume"* ]]
    [[ "$output" != *"--delete-pvc"* ]]
    # The claim is named in a line the plugin prints and in no line it runs:
    # every call it makes goes through the one runner, and none of them deletes.
    ! grep --quiet 'kubectl_run delete' "$PLUGIN"
    ! grep --quiet 'kubectl_run .*persistentvolumeclaim.*delete' "$PLUGIN"
}

@test "an unknown machine is not uninstalled on a guess" {
    export SP_TEST_STATEFULSETS=""
    machine delete ghost --namespace homelab --yes
    [ "$status" -ne 0 ]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

@test "an ambiguous name is never uninstalled" {
    export SP_TEST_STATEFULSETS="$(printf 'web\tlab\tlab-web\nweb\tprod\tprod-web\n')"
    machine delete web --namespace homelab --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"--release"* ]]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

# A machine whose claim was named something else, or is already gone: the
# removal still happens and the line printed is the one that finds what is there.
@test "a machine with no claim of its own still names where to look" {
    export SP_TEST_PVCS=""
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"persistentvolumeclaim"* ]]
}

@test "delete needs helm" {
    rm "$STUB_DIR/helm"
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"helm"* ]]
}
