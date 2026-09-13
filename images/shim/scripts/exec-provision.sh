#!/usr/bin/env bash
#
# Runs a machine's own script, inside the machine, once the machine is up.
#
# This is the only part of the chart that acts on a machine from outside it, and
# it is the only part that talks to the cluster's API. Both are deliberate: a
# script that configures an operating system needs that operating system to
# exist, and at every other point in this chart's life it does not. The steps
# before the guest run against a directory of another architecture's binaries
# with no init, no package manager and no network of its own; a container in the
# machine's own pod cannot enter the machine's mount namespace without the pod
# sharing its process namespace, which takes PID 1 away from the machine's init.
#
# So: a Job beside the machine, holding the right to get one pod and to exec
# into that same pod, and nothing else in the namespace.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=images/shim/scripts/lib-exec.sh
. "$SP_SCRIPT_DIR/lib-exec.sh"

sp_main() {
    sp_require_env SP_MACHINE
    sp_require_env SP_TARGET_POD
    sp_require_env SP_NAMESPACE
    sp_exec_provision
}

sp_main "$@"
