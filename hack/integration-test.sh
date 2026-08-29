#!/usr/bin/env bash
#
# End-to-end seeding, on a real cluster.
#
# A rendering test cannot tell whether the copy that filled a volume preserved a
# file capability, whether the volume survives a restart, or whether the second
# start really does nothing. Those are the assertions here, and they are the only
# ones that can fail in a way the unit tests would not notice.
#
# privileged mode throughout: a kind node is itself a container, so user
# namespaces nested inside one are unreliable and would make this test flaky for
# reasons that have nothing to do with seeding.
set -o errexit
set -o nounset
set -o pipefail

CLUSTER="${CLUSTER:-stateful-pods-test}"
CONTEXT="kind-${CLUSTER}"
NAMESPACE="${NAMESPACE:-stateful-pods-integration}"
CHART="${CHART:-charts/stateful-pods}"
SHIM_IMAGE="${SHIM_IMAGE:-stateful-pods-shim:dev}"
SOURCE_IMAGE="${SOURCE_IMAGE:-stateful-pods-test-source:integration}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

# An lxc template has to be fetched over HTTPS, which the chart enforces. Point
# these at a reachable template to exercise that path; without them the lxc
# assertions are skipped rather than silently passed.
TEMPLATE_URL="${TEMPLATE_URL:-}"
TEMPLATE_SHA256="${TEMPLATE_SHA256:-}"

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
skip() { printf 'skip - %s\n' "$1"; }
step() { printf '\n==> %s\n' "$1"; }

# check <description> <command...>
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

kc() { kubectl --context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }

on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo "--- pods ---" >&2
    kc get pods >&2 2>&1 || true
    for container in seed prepare; do
      echo "--- $container logs ---" >&2
      kc logs --selector stateful-pods.io/machine --container "$container" --tail 40 >&2 2>&1 || true
    done
  fi
  if [[ "$KEEP_CLUSTER" == "1" ]]; then
    echo "cluster $CLUSTER kept; remove it with: kind delete cluster --name $CLUSTER"
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap on_exit EXIT

step "building the images"
docker build --tag "$SHIM_IMAGE" --file images/shim/Containerfile images/shim >/dev/null
docker build --tag "$SOURCE_IMAGE" --file test/integration/Containerfile.source test/integration >/dev/null

step "creating the cluster $CLUSTER"
if ! kind get clusters 2>/dev/null | grep --quiet --line-regexp "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kind load docker-image "$SHIM_IMAGE" --name "$CLUSTER"
kind load docker-image "$SOURCE_IMAGE" --name "$CLUSTER"
kubectl --context "$CONTEXT" create namespace "$NAMESPACE" --dry-run=client --output yaml \
  | kubectl --context "$CONTEXT" apply --filename - >/dev/null

# ---------------------------------------------------------------- oci source ---
step "installing a machine with an oci source"
helm --kube-context "$CONTEXT" upgrade --install oci "$CHART" \
  --namespace "$NAMESPACE" \
  --values test/integration/oci.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --wait --timeout 5m >/dev/null
kc wait --for=condition=Ready pod/oci-web-0 --timeout=300s >/dev/null

step "asserting the oci machine's volume"
guest() { kc exec oci-web-0 --container guest -- "$@"; }

check "the volume carries a seeding record" guest test -f /mnt/rootfs/.stateful-pods/provisioned
marker="$(guest cat /mnt/rootfs/.stateful-pods/provisioned)"
check "the record names the source kind" \
  bash -c "echo '$marker' | jq -e '.source.kind == \"oci\"'"
check "the record names the machine it was seeded for" \
  bash -c "echo '$marker' | jq -e '.machine.name == \"web\" and .machine.release == \"oci\"'"
check "the source image's content is on the volume" guest test -f /mnt/rootfs/etc/sp-source-marker
check "no device node was copied" guest test ! -e /mnt/rootfs/dev/null
# shellcheck disable=SC2016 # the guest expands these, not this shell
check "the runtime directories are empty" guest bash -c '[ -z "$(ls -A /mnt/rootfs/proc)" ]'
check "the machine identity was cleared" guest bash -c '[ ! -s /mnt/rootfs/etc/machine-id ]'

caps="$(guest /usr/sbin/getcap /mnt/rootfs/usr/local/bin/sp-probe 2>/dev/null || true)"
if [[ "$caps" == *cap_net_raw* ]]; then
  pass "the file capability survived the copy"
else
  fail "security.capability was lost in the copy: got '${caps:-nothing}'"
fi

step "asserting that a restart does not re-seed"
# shellcheck disable=SC2016 # the redirection belongs to the guest's shell
guest bash -c 'echo "written by the guest" > /mnt/rootfs/etc/guest-state'
before="$(guest cat /mnt/rootfs/.stateful-pods/provisioned)"
kc delete pod oci-web-0 --wait >/dev/null
kc wait --for=condition=Ready pod/oci-web-0 --timeout=300s >/dev/null

if [[ "$(guest cat /mnt/rootfs/etc/guest-state)" == "written by the guest" ]]; then
  pass "the guest's own file survived the restart"
else
  fail "the volume was re-seeded and the guest's file is gone"
fi
if [[ "$(guest cat /mnt/rootfs/.stateful-pods/provisioned)" == "$before" ]]; then
  pass "the seeding record is unchanged by an ordinary restart"
else
  fail "the seeding record was rewritten on an ordinary restart"
fi

# ---------------------------------------------------------------- lxc source ---
if [[ -z "$TEMPLATE_URL" || -z "$TEMPLATE_SHA256" ]]; then
  skip "the lxc assertions: set TEMPLATE_URL and TEMPLATE_SHA256 to an https template"
else
  step "installing a machine with an lxc source"
  helm --kube-context "$CONTEXT" upgrade --install lxc "$CHART" \
    --namespace "$NAMESPACE" \
    --values test/integration/lxc.yaml \
    --set "shim.image=$SHIM_IMAGE" \
    --set "machines.db.source.url=$TEMPLATE_URL" \
    --set-string "machines.db.source.sha256=$TEMPLATE_SHA256" \
    --wait --timeout 10m >/dev/null
  kc wait --for=condition=Ready pod/lxc-db-0 --timeout=600s >/dev/null

  step "asserting the lxc machine's volume"
  dbguest() { kc exec lxc-db-0 --container guest -- "$@"; }
  check "the template's content is on the volume" dbguest test -e /mnt/rootfs/sbin
  check "the downloaded tarball was removed" dbguest test ! -d /mnt/rootfs/.stateful-pods/download
  check "the volume carries a seeding record" dbguest test -f /mnt/rootfs/.stateful-pods/provisioned
fi

echo
echo "every integration assertion held"
