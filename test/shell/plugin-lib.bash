#!/usr/bin/env bash
#
# Shared harness for the plugin's suites.
#
# The plugin never talks to an API server: every read is a `kubectl get` and
# every change is a `kubectl` or `helm` invocation. So the whole of it can be
# tested by putting a `kubectl` and a `helm` on PATH that record what they were
# asked to do and answer with canned output - which is also the only way to
# exercise a machine that is half-way through being made, since a real one is in
# that state for a minute and then stops being.

# The plugin under test. Run through MACHINE_BASH when it is set, which is how
# the macOS job runs the suite against the system bash 3.2 rather than whatever
# `/usr/bin/env bash` happens to find first.
plugin_setup() {
    PLUGIN="${BATS_TEST_DIRNAME}/../../cmd/kubectl-machine"
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    RECORD="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$STUB_DIR"
    : > "$RECORD"
    # The interpreter, not a tool the plugin calls: with these here a test can
    # cut PATH down to the stub directory alone and still start the plugin, which
    # is what turns "the plugin needs nothing else" into something asserted
    # rather than believed.
    ln -sf "$(command -v env)" "$STUB_DIR/env"
    ln -sf "$(command -v bash)" "$STUB_DIR/bash"
    export PATH="$STUB_DIR:$PATH"
    export SP_TEST_RECORD="$RECORD"
    # Answers, per resource kind. Empty means "nothing matched", which is the
    # shape kubectl really produces for a selector that hits nothing.
    export SP_TEST_STATEFULSETS=""
    export SP_TEST_PODS=""
    export SP_TEST_PVCS=""
    export SP_TEST_CONTEXT="kind-lab"
    export SP_TEST_KUBECTL_STATUS=0
    export SP_TEST_HELM_STATUS=0
    export SP_TEST_HELM_OUTPUT=""
    export SP_TEST_UNAME="Linux"
    stub_kubectl
    stub_helm
    stub_uname
}

machine() {
    if [ -n "${MACHINE_BASH:-}" ]; then
        run "$MACHINE_BASH" "$PLUGIN" "$@"
    else
        run "$PLUGIN" "$@"
    fi
}

# Every argument of every call, one call per line, in the order they were made.
calls() { cat "$RECORD"; }

# The last call made to the named binary.
last_call() { grep "^$1 " "$RECORD" | tail -1; }

stub_kubectl() {
    cat > "$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
set -o nounset
printf 'kubectl %s\n' "$*" >> "$SP_TEST_RECORD"

# Answers the query for one machine's objects and the query for every machine in
# the namespace separately, because the difference between them is exactly what a
# name that resolves to nothing has to fall back on.
answer() {
    local one="$1" all="$2" body
    if [[ "$SP_ARGS" == *"stateful-pods.io/machine="* ]]; then
        body="$one"
    else
        body="$all"
    fi
    [ -n "$body" ] && printf '%s\n' "$body"
    exit "$SP_TEST_KUBECTL_STATUS"
}

SP_ARGS="$*"
case "$SP_ARGS" in
    *statefulsets*) answer "$SP_TEST_STATEFULSETS" "${SP_TEST_ALL_STATEFULSETS:-$SP_TEST_STATEFULSETS}" ;;
    *persistentvolumeclaims*) answer "$SP_TEST_PVCS" "$SP_TEST_PVCS" ;;
    *" pods"*) answer "$SP_TEST_PODS" "${SP_TEST_ALL_PODS:-$SP_TEST_PODS}" ;;
    *current-context*) printf '%s\n' "$SP_TEST_CONTEXT"; exit 0 ;;
esac
exit "$SP_TEST_KUBECTL_STATUS"
STUB
    chmod +x "$STUB_DIR/kubectl"
}

stub_helm() {
    cat > "$STUB_DIR/helm" <<'STUB'
#!/usr/bin/env bash
set -o nounset
printf 'helm %s\n' "$*" >> "$SP_TEST_RECORD"
[ -n "$SP_TEST_HELM_OUTPUT" ] && printf '%s\n' "$SP_TEST_HELM_OUTPUT"
exit "$SP_TEST_HELM_STATUS"
STUB
    chmod +x "$STUB_DIR/helm"
}

# The platform check reads `uname -s`, so the platforms the plugin refuses can be
# exercised on the one running the suite.
stub_uname() {
    cat > "$STUB_DIR/uname" <<'STUB'
#!/usr/bin/env bash
set -o nounset
printf '%s\n' "$SP_TEST_UNAME"
STUB
    chmod +x "$STUB_DIR/uname"
}

# A projected statefulset line: the machine's name, its release, its object name.
sts_line() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# A projected pod line, in the encoding the plugin asks kubectl to produce:
# machine, release, pod, phase, init container states, container states.
pod_line() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }

# The init container states of a machine that finished being made.
seeded_init() { printf 'seed=terminated,Completed,0,true;prepare=terminated,Completed,0,true;customize=terminated,Completed,0,true;'; }

# The subcommands the plugin answers to. Kept here rather than in a suite so that
# a command added without a help of its own fails in one place.
implemented_subcommands() { printf 'list status shell console create delete\n'; }
