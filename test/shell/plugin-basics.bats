#!/usr/bin/env bats
#
# What the plugin does before it does anything: says what it is, refuses a
# platform it cannot run on, and names a tool it needs rather than failing
# somewhere inside a pipeline once it has already printed half an answer.

load plugin-lib

setup() { plugin_setup; }

@test "the plugin is executable, so kubectl can find it on PATH" {
    [ -x "$PLUGIN" ]
}

@test "the file is named exactly kubectl-machine, which is how kubectl finds it" {
    [ "$(basename "$PLUGIN")" = "kubectl-machine" ]
}

@test "--help names every subcommand" {
    machine --help
    [ "$status" -eq 0 ]
    for subcommand in $(implemented_subcommands); do
        [[ "$output" == *"$subcommand"* ]] || {
            echo "no mention of $subcommand in:"
            echo "$output"
            return 1
        }
    done
}

@test "each subcommand has a help of its own" {
    for subcommand in $(implemented_subcommands); do
        machine "$subcommand" --help
        [ "$status" -eq 0 ]
        [[ "$output" == *"$subcommand"* ]]
    done
}

@test "no arguments prints the help rather than an error" {
    machine
    [ "$status" -eq 0 ]
    [[ "$output" == *"kubectl machine"* ]]
}

@test "an unknown subcommand is named, and the known ones listed" {
    machine frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"frobnicate"* ]]
    [[ "$output" == *"list"* ]]
}

@test "version reports the plugin's version" {
    machine version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml)"* ]]
}

# The plugin defaults --version to its own, so a plugin whose version has drifted
# from the chart's asks a registry for a chart revision that does not exist. The
# duplication is unavoidable - the plugin is one file and cannot read Chart.yaml
# from a user's machine - so it is held here instead.
@test "the plugin's version is the chart's version" {
    local chart_version plugin_version
    chart_version="$(sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml)"
    plugin_version="$(sed -n 's/^SP_VERSION="\(.*\)"$/\1/p' "$PLUGIN")"
    [ -n "$plugin_version" ]
    [ "$plugin_version" = "$chart_version" ]
}

# PATH is cut down to the stubs alone, which is also an assertion in itself: the
# plugin gets kubectl, helm and uname and nothing else, because a plugin that
# quietly needs a fourth tool is one a user discovers is broken on their machine.
@test "a missing kubectl is named, before anything is attempted" {
    rm "$STUB_DIR/kubectl"
    PATH="$STUB_DIR" machine list
    [ "$status" -ne 0 ]
    [[ "$output" == *"kubectl"* ]]
    [[ "$output" == *"not"* ]]
}

@test "the plugin needs no tool beyond kubectl, helm and uname" {
    PATH="$STUB_DIR" machine list
    [ "$status" -eq 0 ]
}

# There is no bash on Windows worth targeting, and the trade was accepted when
# the plugin was written in bash rather than Go. What must not happen is
# discovering it half-way through a create.
@test "an unsupported platform is refused by name, before any action" {
    export SP_TEST_UNAME="MINGW64_NT-10.0"
    machine list
    [ "$status" -ne 0 ]
    [[ "$output" == *"MINGW64_NT-10.0"* ]]
    # Nothing was asked of the cluster on the way to that refusal.
    ! grep --quiet '^kubectl get' "$RECORD"
}

@test "a supported platform runs" {
    export SP_TEST_UNAME="Darwin"
    machine list
    [ "$status" -eq 0 ]
}

# Not a style preference: the plugin prints the commands it runs so that a reader
# learns the underlying invocation, and a short flag teaches an invocation that
# is harder to read back later.
@test "the plugin composes long flags only" {
    machine list
    [ "$status" -eq 0 ]
    ! grep --quiet --extended-regexp ' -[a-zA-Z]([ =]|$)' "$RECORD"
}
