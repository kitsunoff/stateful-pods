#!/usr/bin/env bats
#
# The two helpers that run inside the machine.
#
# They are exercised against a fake root rather than a real machine: what is under
# test is which signal each init gets and when readiness flips, not whether the
# kernel delivers it. The integration test on a real cluster covers that.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    FAKE="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    mkdir -p "$FAKE/run"
    # The helpers read absolute paths inside the machine, so the suite runs them
    # with a stubbed environment rather than pretending to be root.
    cat > "$STUB_DIR/run-helper" <<EOF
#!/bin/sh
sed "s#/run/#$FAKE/run/#g; s#/proc/#$FAKE/proc/#g" "\$1" > "$STUB_DIR/helper.sh"
chmod +x "$STUB_DIR/helper.sh"
PATH="$STUB_DIR:\$PATH" sh "$STUB_DIR/helper.sh"
EOF
    chmod +x "$STUB_DIR/run-helper"
}

teardown() { rm -rf "$FAKE" "$STUB_DIR"; }

ready() { "$STUB_DIR/run-helper" "$SCRIPTS/ready.sh"; }

stub_systemctl() {
    cat > "$STUB_DIR/systemctl" <<EOF
#!/bin/sh
echo "$1"
EOF
    chmod +x "$STUB_DIR/systemctl"
}

stub_kill() {
    cat > "$STUB_DIR/kill" <<EOF
#!/bin/sh
echo "\$@" >> "$STUB_DIR/signals"
case "\$1" in
  -0) exit 1 ;;                      # PID 1 is gone, so the wait ends at once
  -s) [ "\$2" = "RTMIN+3" ] && { ${SP_KNOWS_RTMIN:-true}; exit \$?; } ; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/kill"
    : > "$STUB_DIR/signals"
}

stop() {
    stub_kill
    "$STUB_DIR/run-helper" "$SCRIPTS/stop.sh"
}

# ---------------------------------------------------------------- readiness ---

@test "a machine that has not started is not ready" {
    run ready
    [ "$status" -ne 0 ]
}

@test "a systemd machine still booting is not ready" {
    mkdir -p "$FAKE/run/systemd/system"
    stub_systemctl "starting"
    run ready
    [ "$status" -ne 0 ]
}

@test "a systemd machine that has finished booting is ready" {
    mkdir -p "$FAKE/run/systemd/system"
    stub_systemctl "running"
    run ready
    [ "$status" -eq 0 ]
}

@test "a systemd machine with a failed unit is still ready" {
    mkdir -p "$FAKE/run/systemd/system"
    stub_systemctl "degraded"
    run ready
    # A failed unit is the machine's business; taking it out of its Service for
    # that would hide it exactly when someone is looking for it.
    [ "$status" -eq 0 ]
}

@test "a systemd machine that is shutting down is not ready" {
    mkdir -p "$FAKE/run/systemd/system"
    stub_systemctl "stopping"
    run ready
    [ "$status" -ne 0 ]
}

@test "an OpenRC machine that reached its runlevel is ready" {
    mkdir -p "$FAKE/run/openrc"
    : > "$FAKE/run/openrc/softlevel"
    run ready
    [ "$status" -eq 0 ]
}

@test "any other init is ready once the machine has been handed over to it" {
    mkdir -p "$FAKE/run/stateful-pods"
    : > "$FAKE/run/stateful-pods/booted"
    run ready
    [ "$status" -eq 0 ]
}

@test "readiness needs no input describing the guest" {
    run grep -cE 'SP_[A-Z_]*INIT|guest\.init' "$SCRIPTS/ready.sh"
    [ "$output" = "0" ]
}

# ----------------------------------------------------------------- shutdown ---
#
# `kill` is a shell builtin, so a stub on PATH would never be reached. These send
# the signals to a real process instead and assert which one arrived, which is a
# stronger check than a stub could give.

start_victim() {
    local marker="$STUB_DIR/received"
    : > "$marker"
    setsid sh -c '
        trap "echo RTMIN3 >> '"$marker"'; exit 0" 37
        trap "echo TERM >> '"$marker"'; exit 0" 15
        echo ready > '"$STUB_DIR"'/victim-ready
        while :; do sleep 0.2; done
    ' &
    VICTIM=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$STUB_DIR/victim-ready" ] && return 0
        sleep 0.1
    done
    return 1
}

received() { cat "$STUB_DIR/received" 2>/dev/null; }

stop() {
    SP_INIT_PID="$VICTIM" SP_STOP_TIMEOUT=5 "$STUB_DIR/run-helper" "$SCRIPTS/stop.sh"
}

@test "a systemd machine is asked to power off, not to re-execute" {
    mkdir -p "$FAKE/run/systemd/system"
    start_victim
    run stop
    [ "$status" -eq 0 ]
    [ "$(received)" = "RTMIN3" ]
}

@test "any other init is asked to terminate" {
    start_victim
    run stop
    [ "$status" -eq 0 ]
    [ "$(received)" = "TERM" ]
}

@test "stopping waits for the machine's init to exit" {
    mkdir -p "$FAKE/run/systemd/system"
    start_victim
    run stop
    [ "$status" -eq 0 ]
    # The helper returned only once the process was gone.
    run kill -0 "$VICTIM"
    [ "$status" -ne 0 ]
}

@test "stopping gives up before the grace period rather than hanging forever" {
    mkdir -p "$FAKE/run/systemd/system"
    # A process that ignores every shutdown signal.
    setsid sh -c 'trap "" 37 15; while :; do sleep 0.2; done' &
    stubborn=$!
    start="$(date +%s)"
    SP_INIT_PID="$stubborn" SP_STOP_TIMEOUT=2 run "$STUB_DIR/run-helper" "$SCRIPTS/stop.sh"
    elapsed=$(( $(date +%s) - start ))
    kill -9 "$stubborn" 2>/dev/null || true
    [ "$elapsed" -lt 10 ]
}

@test "shutdown needs no input describing the guest" {
    run grep -cE 'SP_[A-Z_]*INIT_SYSTEM|guest\.init' "$SCRIPTS/stop.sh"
    [ "$output" = "0" ]
}
