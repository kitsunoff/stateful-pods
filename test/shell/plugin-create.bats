#!/usr/bin/env bats
#
# Making a machine.
#
# The plugin composes values and hands them to Helm. It validates nothing: the
# chart already refuses to guess a security mode or a source, and its rejections
# name the values path and the accepted set. A second validator here would drift
# from that one, and a default invented here would be a machine configured by a
# tool rather than by its owner. Half of this suite exists to hold that line.

load plugin-lib

setup() { plugin_setup; }

@test "an oci source becomes the values the chart takes" {
    machine create web --source-oci docker.io/library/debian:13 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"helm upgrade --install web"* ]]
    [[ "$(calls)" == *"machines.web.source.kind=oci"* ]]
    [[ "$(calls)" == *"machines.web.source.reference=docker.io/library/debian:13"* ]]
    [[ "$(calls)" == *"machines.web.security.mode=userns"* ]]
    [[ "$(calls)" == *"--namespace homelab"* ]]
}

@test "an lxc source carries its url and its checksum" {
    machine create db \
        --source-lxc-url https://example.invalid/rootfs.tar.zst \
        --source-sha256 0123456789012345678901234567890123456789012345678901234567890123 \
        --mode privileged --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"machines.db.source.kind=lxc"* ]]
    [[ "$(calls)" == *"machines.db.source.url=https://example.invalid/rootfs.tar.zst"* ]]
    [[ "$(calls)" == *"machines.db.source.sha256=0123456789012345678901234567890123456789012345678901234567890123"* ]]
}

# A checksum of nothing but digits is a number to any YAML parser, and a number
# is not a checksum by the time the chart reads it. --set-string is what keeps a
# value the string it was typed as.
@test "every value the plugin composes is passed as a string" {
    machine create db \
        --source-lxc-url https://example.invalid/rootfs.tar.zst \
        --source-sha256 1234567890123456789012345678901234567890123456789012345678901234 \
        --mode privileged --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" != *" --set machines"* ]]
    [[ "$(calls)" == *"--set-string machines.db.source.sha256=1234"* ]]
}

@test "a preset composes the source kind the chart resolves from its catalog" {
    machine create web --preset debian-trixie --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"machines.web.source.kind=preset"* ]]
    [[ "$(calls)" == *"machines.web.source.name=debian-trixie"* ]]
}

@test "the optional inputs reach the values paths they belong to" {
    machine create web --preset alpine-3.24 --mode userns \
        --size 20Gi --storage-class fast --hostname web01 --pull-secret ghcr \
        --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"machines.web.rootfs.size=20Gi"* ]]
    [[ "$(calls)" == *"machines.web.rootfs.storageClassName=fast"* ]]
    [[ "$(calls)" == *"machines.web.hostname=web01"* ]]
    [[ "$(calls)" == *"machines.web.source.pullSecretName=ghcr"* ]]
}

@test "--set and --values are handed to helm untouched" {
    machine create web --preset alpine-3.24 --mode userns \
        --set shim.image=ghcr.io/example/shim:dev \
        --values /tmp/extra.yaml \
        --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"--set shim.image=ghcr.io/example/shim:dev"* ]]
    [[ "$(calls)" == *"--values /tmp/extra.yaml"* ]]
}

@test "the release defaults to the machine's name, and the object name is printed" {
    machine create web --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"upgrade --install web "* ]]
    [[ "$output" == *"web-web"* ]]
}

@test "--release puts the machine in a release of another name" {
    machine create web --release lab --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"upgrade --install lab "* ]]
    [[ "$output" == *"lab-web"* ]]
}

@test "the chart reference and version default to the published chart at this version" {
    machine create web --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"oci://ghcr.io/"* ]]
    [[ "$(calls)" == *"--version $(sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml)"* ]]
}

@test "--chart takes a local checkout instead" {
    machine create web --chart ./charts/stateful-pods --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" == *"./charts/stateful-pods"* ]]
    [[ "$(calls)" != *"oci://"* ]]
}

@test "the context, namespace and object name are stated before helm runs" {
    machine create web --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$output" == *"homelab"* ]]
    [[ "$output" == *"kind-lab"* ]]
    [[ "$output" == *"web-web"* ]]
    [[ "$output" == *"==> helm upgrade --install"* ]]
}

# The line this change must not cross.
@test "a missing mode produces the chart's message, not one the plugin wrote" {
    export SP_TEST_HELM_STATUS=1
    export SP_TEST_HELM_OUTPUT='Error: execution error at (stateful-pods/templates/statefulset.yaml:1:2): machines.web.security.mode is required: one of userns, privileged'
    machine create web --preset alpine-3.24 --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"machines.web.security.mode is required: one of userns, privileged"* ]]
}

@test "a machine with no source is still handed to the chart to refuse" {
    export SP_TEST_HELM_STATUS=1
    export SP_TEST_HELM_OUTPUT='Error: machines.web.source.kind is required: one of oci, lxc, preset'
    machine create web --mode userns --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"machines.web.source.kind is required"* ]]
    # It got as far as helm rather than refusing on its own.
    [[ "$(calls)" == *"helm upgrade"* ]]
}

@test "the plugin composes no value the user did not ask for" {
    machine create web --preset alpine-3.24 --namespace homelab
    [ "$status" -eq 0 ]
    [[ "$(calls)" != *"security.mode"* ]]
    [[ "$(calls)" != *"rootfs.size"* ]]
    [[ "$(calls)" != *"storageClassName"* ]]
    [[ "$(calls)" != *"hostname"* ]]
}

@test "two sources at once is a plugin error, since the flags contradict" {
    machine create web --preset alpine-3.24 --source-oci docker.io/library/debian:13 --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"one source"* ]]
    ! grep --quiet '^helm' "$RECORD"
}

@test "a chart reference that cannot be pulled says to pass a local path" {
    export SP_TEST_HELM_STATUS=1
    export SP_TEST_HELM_OUTPUT='Error: failed to download "oci://ghcr.io/kitsunoff/charts/stateful-pods"'
    machine create web --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to download"* ]]
    [[ "$output" == *"--chart"* ]]
    [[ "$output" == *"charts/stateful-pods"* ]]
}

@test "a rejection from the chart is not turned into advice about --chart" {
    export SP_TEST_HELM_STATUS=1
    export SP_TEST_HELM_OUTPUT='Error: execution error at (stateful-pods/templates/statefulset.yaml:1:2): machines.web.security.mode is required'
    machine create web --preset alpine-3.24 --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" != *"pass --chart"* ]]
}

@test "create needs helm, and says so when it is missing" {
    rm "$STUB_DIR/helm"
    machine create web --preset alpine-3.24 --mode userns --namespace homelab
    [ "$status" -ne 0 ]
    [[ "$output" == *"helm"* ]]
}

@test "create needs a machine name" {
    machine create --preset alpine-3.24 --namespace homelab
    [ "$status" -ne 0 ]
    ! grep --quiet '^helm' "$RECORD"
}
