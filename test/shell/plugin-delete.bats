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
    export SP_TEST_STATEFULSETS="$(printf 'web|lab|lab-web\nweb|prod|prod-web\n')"
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

# The claim named here is pasted into a command that destroys it, and a machine
# of the same name in another release leaves a claim carrying the same label -
# the plugin's own retention is what creates that orphan. Naming it would offer,
# ready to paste, the destruction of the volume the user was told was kept.
@test "the claim named on removal is this machine's, not another release's" {
    export SP_TEST_STATEFULSETS="$(sts_line web prod prod-web)"
    export SP_TEST_PODS="$(pod_line web prod prod-web-0 Running "$(seeded_init)" 'guest=running,,,true;')"
    export SP_TEST_PVCS="prod-web-prod-web-0"
    export SP_TEST_PVCS_ALL="$(printf 'lab-web-lab-web-0\nprod-web-prod-web-0\n')"
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"prod-web-prod-web-0"* ]]
    [[ "$output" != *"lab-web-lab-web-0"* ]]
    [[ "$(calls)" == *"persistentvolumeclaims --selector stateful-pods.io/machine=web,app.kubernetes.io/instance=prod"* ]]
}

# ------------------------------------------- a release that holds more than one ---
#
# A release may hold several machines now, and this command uninstalls the
# release. The sibling is somebody's pet, and finding out it had stopped by
# noticing would be the worst way to learn it.
#
# SP_TEST_NARROWED is what the stub answers a read narrowed to one release with,
# and SP_TEST_STATEFULSETS what it answers a read naming one machine with. That
# asymmetry is real: the two selectors this command builds are exactly those.

@test "it names the other machines the release holds" {
    export SP_TEST_NARROWED="$(sts_line web lab lab-web)
$(sts_line db lab lab-db)"
    machine delete web --namespace homelab <<< "lab"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Also removed:"* ]]
    [[ "$output" == *"db"* ]]
}

# What is being removed is the release. A confirmation that asks for the name of
# one machine reads as a promise that only that machine goes.
@test "it asks for the release's name, not the machine's, when a sibling would go too" {
    export SP_TEST_NARROWED="$(sts_line web lab lab-web)
$(sts_line db lab lab-db)"
    machine delete web --namespace homelab <<< "lab"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Type the name of the release"* ]]
    [[ "$(calls)" == *"helm uninstall lab"* ]]
}

@test "the machine's own name is not the confirmation when a sibling would go too" {
    export SP_TEST_NARROWED="$(sts_line web lab lab-web)
$(sts_line db lab lab-db)"
    machine delete web --namespace homelab <<< "web"
    [ "$status" -ne 0 ]
    ! grep --quiet 'helm uninstall' "$RECORD"
}

@test "a release holding one machine still asks for the machine's name" {
    machine delete web --namespace homelab <<< "web"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Type the name of the machine"* ]]
    [[ "$output" != *"Also removed:"* ]]
}

@test "--yes still removes a release that holds several" {
    export SP_TEST_NARROWED="$(sts_line web lab lab-web)
$(sts_line db lab lab-db)"
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"db"* ]]
    [[ "$(calls)" == *"helm uninstall lab"* ]]
}

# A removal that stops several machines keeps several volumes. Naming one of
# them would leave the rest with no name anywhere - which is worse than naming
# none, because it reads as the complete list.
@test "it points at every volume the release kept, not at one machine's" {
    export SP_TEST_NARROWED="$(sts_line web lab lab-web)
$(sts_line db lab lab-db)"
    machine delete web --namespace homelab <<< "lab"
    [ "$status" -eq 0 ]
    [[ "$output" == *"get persistentvolumeclaim --selector app.kubernetes.io/instance=lab"* ]]
    [[ "$output" != *"delete persistentvolumeclaim lab-web-lab-web-0"* ]]
}

@test "a lone machine is still shown the command that deletes its own volume" {
    machine delete web --namespace homelab <<< "web"
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete persistentvolumeclaim lab-web-lab-web-0"* ]]
}

# The answer this plugin declines to give everywhere else, and the worst one to
# give immediately before somebody uninstalls a release.
@test "a claim read that was denied is not reported as a machine with no volume" {
    export SP_TEST_PVC_STATUS=1
    machine delete web --namespace homelab <<< "web"
    [ "$status" -eq 0 ]
    [[ "$output" != *"none found under this label"* ]]
    [[ "$output" == *"could not be read"* ]]
}

@test "a release read that failed removes nothing" {
    export SP_TEST_BROAD_STATUS=1
    machine delete web --namespace homelab --yes < /dev/null
    [ "$status" -ne 0 ]
    ! grep --quiet 'helm uninstall' "$RECORD"
}
