#!/usr/bin/env bash
#
# Programs the pod's network namespace so that the machine's outbound traffic
# meets the policy its values describe.
#
# This runs after the machine's root filesystem has been prepared and after the
# proxy beside it has started, and before the machine itself. All three
# constraints are real:
#
#   * after preparation, because seeding fetches a root filesystem from a
#     registry and a policy applied before it would need a rule for the chart's
#     own source;
#   * after the proxy, because traffic redirected to a port nothing is listening
#     on is traffic refused;
#   * before the machine, because a machine whose first connections escaped the
#     policy would be a policy that depends on timing.
#
# It is the one container in this pod granted NET_ADMIN, and it exits. The
# machine is not granted it and cannot undo any of this from inside itself.
set -o errexit
set -o nounset
set -o pipefail

SP_SCRIPT_DIR="$(dirname "$0")"
# shellcheck source=images/shim/scripts/lib-state.sh
. "$SP_SCRIPT_DIR/lib-state.sh"
# shellcheck source=images/shim/scripts/lib-seed.sh
. "$SP_SCRIPT_DIR/lib-seed.sh"
# shellcheck source=images/shim/scripts/lib-egress.sh
. "$SP_SCRIPT_DIR/lib-egress.sh"

sp_main() {
    sp_require_env SP_MACHINE
    sp_require_env SP_EGRESS_PROXY_PORT
    sp_require_env SP_EGRESS_PROXY_USER
    sp_egress_apply
}

sp_main "$@"
