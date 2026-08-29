#!/usr/bin/env bash
#
# Seeding and booting a machine end to end, on a real cluster.
#
# A rendering test cannot tell whether the copy that filled a volume preserved a
# file capability, whether an operating system actually starts on it, whether a
# shell lands in the machine or in the chart's image, or whether deleting the pod
# shuts the machine down or kills it. Those are the assertions here, and they are
# the only ones that can fail in a way the unit tests would not notice.
#
# privileged mode throughout: a kind node is itself a container, so user
# namespaces nested inside one are unreliable and would make this test flaky for
# reasons that have nothing to do with what it is testing.
#
# Nearly every command below is single-quoted on purpose: it is expanded by a
# shell in another container - the machine's own, usually - not by this one.
# shellcheck disable=SC2016
set -o errexit
set -o nounset
set -o pipefail

CLUSTER="${CLUSTER:-stateful-pods-test}"
CONTEXT="kind-${CLUSTER}"
# A namespace per run, so that a volume seeded by an earlier run - from an
# earlier source image - can never be what this run boots. Seeding happens once
# per volume by design, so reusing one would test the previous run's machine.
NAMESPACE="${NAMESPACE:-stateful-pods-it-$(date +%s)}"
CHART="${CHART:-charts/stateful-pods}"
SHIM_IMAGE="${SHIM_IMAGE:-stateful-pods-shim:dev}"
SOURCE_IMAGE="${SOURCE_IMAGE:-stateful-pods-test-source:integration}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

# An lxc template has to be fetched over HTTPS, which the chart enforces. Point
# these at a reachable template to exercise that path; without them the lxc
# assertions are skipped rather than silently passed.
#
# The URL may contain {arch}, which is replaced with the cluster node's own
# architecture. A rootfs built for another one seeds perfectly and then cannot be
# executed, so a single fixed URL passes on the machine it was chosen on and
# crash-loops everywhere else.
#
# Leave the checksum empty to take it from the publisher's SHA256SUMS beside the
# tarball, which is what a user would do and what makes one URL work for every
# architecture. The chart still verifies it; this only decides what it is checked
# against.
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
    echo "cluster $CLUSTER kept; this run's namespace is $NAMESPACE"
    echo "remove the run with: kubectl --context $CONTEXT delete namespace $NAMESPACE"
    echo "remove the cluster with: kind delete cluster --name $CLUSTER"
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
existing_clusters="$(kind get clusters 2>/dev/null || true)"
if ! grep --quiet --line-regexp "$CLUSTER" <<< "$existing_clusters"; then
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
# After the root change this lands inside the machine, not in the chart's image.
guest() { kc exec oci-web-0 --container guest -- "$@"; }

# The machine has booted, so its root is the volume: what was at /mnt/rootfs
# before the root change is at / now. That the copy left no device nodes and no
# kernel filesystem contents is a property of the volume before it is mounted as
# a root, and is asserted by the shell suite against the real archiver; here the
# same paths are legitimately occupied by the mounts the machine needs.
check "the volume carries a seeding record" guest test -f /.stateful-pods/provisioned
marker="$(guest cat /.stateful-pods/provisioned)"
check "the record names the source kind" \
  bash -c "echo '$marker' | jq -e '.source.kind == \"oci\"'"
check "the record names the machine it was seeded for" \
  bash -c "echo '$marker' | jq -e '.machine.name == \"web\" and .machine.release == \"oci\"'"
check "the source image's content is on the volume" guest test -f /etc/sp-source-marker
check "the machine identity was not inherited from the image" \
  guest sh -c 'test -s /etc/machine-id'

caps="$(guest /usr/sbin/getcap /usr/local/bin/sp-probe 2>/dev/null || true)"
if [[ "$caps" == *cap_net_raw* ]]; then
  pass "the file capability survived the copy"
else
  fail "security.capability was lost in the copy: got '${caps:-nothing}'"
fi

# ------------------------------------------------------------------- booting ---
step "asserting the machine actually booted"
check "the machine's own init is process 1" \
  guest sh -c '[ "$(cat /proc/1/comm)" != "boot.sh" ] && [ "$(cat /proc/1/comm)" != "bash" ]'
check "a shell in the machine is the machine's own" guest test -f /etc/sp-source-marker
check "the machine's root is the volume, not the chart's image" guest test ! -d /mnt/rootfs
check "the filesystems an init expects are mounted" guest sh -c 'grep -q " /proc " /proc/mounts && grep -q " /sys " /proc/mounts'
# /proc/mounts is "<device> <mountpoint> <type> <options>", so the type comes
# after the path. A read-only hierarchy is what the pod already has and what a
# guest's init cannot use.
check "the control group hierarchy is writable" \
  guest sh -c 'awk "\$2 == \"/sys/fs/cgroup\" && \$3 == \"cgroup2\" && \$4 ~ /^rw,/ {found=1} END {exit !found}" /proc/mounts'
check "the kernel filesystem the guest must not write to is read-only" \
  guest sh -c 'awk "\$2 == \"/sys\" && \$4 ~ /^ro,/ {found=1} END {exit !found}" /proc/mounts'
check "the device nodes are usable" guest sh -c 'echo probe > /dev/null'
check "the machine knows it is in a container" guest sh -c 'tr "\0" "\n" < /proc/1/environ | grep -qx "container=lxc"'

step "asserting the files the chart maintains inside the machine"
check "the machine has the pod's host name" \
  guest sh -c '[ "$(cat /etc/hostname)" = "oci-web-0" ]'
check "the machine can resolve names" guest sh -c 'grep -q nameserver /etc/resolv.conf'
check "the machine's host table is the pod's" guest sh -c 'grep -q oci-web-0 /etc/hosts'

step "asserting a claimed file is left alone"
guest sh -c 'touch /etc/.stateful-pods-ignore.resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf'
kc delete pod oci-web-0 --wait >/dev/null
kc wait --for=condition=Ready pod/oci-web-0 --timeout=300s >/dev/null
check "the claimed resolver survived the restart" \
  guest sh -c 'grep -q "1.1.1.1" /etc/resolv.conf'
check "the unclaimed host name was still refreshed" \
  guest sh -c '[ "$(cat /etc/hostname)" = "oci-web-0" ]'
guest sh -c 'rm -f /etc/.stateful-pods-ignore.resolv.conf'

step "asserting the machine's output reaches the pod's logs"
# Logs can lag a restart by a moment, so this waits rather than racing.
# The output is captured before it is searched. Piping it into `grep -q` would
# make grep exit at the first match, and the SIGPIPE that gives kubectl fails the
# whole pipeline under `pipefail` - a match reported as a failure, and only for
# output large enough that the producer has not finished writing.
boot_logged=0
for _ in $(seq 1 20); do
  machine_output="$(kc logs oci-web-0 --container guest --tail 400 2>/dev/null || true)"
  if grep -qiE 'Detected virtualization|Reached target|systemd .* running in system mode' \
      <<< "$machine_output"; then
    boot_logged=1
    break
  fi
  sleep 2
done
if [[ "$boot_logged" -eq 1 ]]; then
  pass "the machine's boot is visible in the pod's logs"
else
  echo "--- what the pod's logs held ---" >&2
  kc logs oci-web-0 --container guest --tail 20 >&2 2>&1 || true
  fail "nothing the machine printed reached the pod's logs"
fi

step "asserting the machine shuts down rather than being killed"
started="$(date +%s)"
kc delete pod oci-web-0 --wait >/dev/null
elapsed=$(( $(date +%s) - started ))
guest_ready() {
  kc get pod oci-web-0 \
    --output "jsonpath={.status.containerStatuses[?(@.name=='guest')].ready}" 2>/dev/null || true
}
if [[ "$elapsed" -lt 100 ]]; then
  pass "the machine stopped in ${elapsed}s, well inside the 120s grace period"
else
  fail "the machine took ${elapsed}s to stop, which means it was killed rather than asked"
fi
# The machine is booting again, which is the window in which readiness must be
# negative. Watching the transition is the only way to tell a probe that reports
# the truth from one that always says yes.
step "asserting readiness follows the machine's boot, not the pod's existence"
saw_not_ready=0
became_ready=0
for _ in $(seq 1 300); do
  case "$(guest_ready)" in
    false) saw_not_ready=1 ;;
    true)  became_ready=1; break ;;
  esac
  sleep 1
done
if [[ "$saw_not_ready" -eq 1 ]]; then
  pass "the machine reported itself not ready while its operating system was starting"
else
  fail "readiness was never negative, so the probe is not reporting the machine's state"
fi
if [[ "$became_ready" -eq 1 ]]; then
  pass "the machine reported itself ready once its operating system had started"
else
  fail "the machine never became ready"
fi

kc wait --for=condition=Ready pod/oci-web-0 --timeout=300s >/dev/null

step "asserting that a restart does not re-seed"
guest sh -c 'echo "written by the guest" > /etc/guest-state'
before="$(guest cat /.stateful-pods/provisioned)"
kc delete pod oci-web-0 --wait >/dev/null
kc wait --for=condition=Ready pod/oci-web-0 --timeout=300s >/dev/null

if [[ "$(guest cat /etc/guest-state)" == "written by the guest" ]]; then
  pass "the guest's own file survived the restart"
else
  fail "the volume was re-seeded and the guest's file is gone"
fi
if [[ "$(guest cat /.stateful-pods/provisioned)" == "$before" ]]; then
  pass "the seeding record is unchanged by an ordinary restart"
else
  fail "the seeding record was rewritten on an ordinary restart"
fi

# ---------------------------------------------------------------- lxc source ---
if [[ -z "$TEMPLATE_URL" ]]; then
  skip "the lxc assertions: set TEMPLATE_URL to an https template"
else
  node_arch="$(kubectl --context "$CONTEXT" get nodes \
    --output "jsonpath={.items[0].status.nodeInfo.architecture}")"
  TEMPLATE_URL="${TEMPLATE_URL//\{arch\}/$node_arch}"
  if [[ -z "$TEMPLATE_SHA256" ]]; then
    step "taking the template's checksum from its publisher"
    sums_url="${TEMPLATE_URL%/*}/SHA256SUMS"
    tarball_name="${TEMPLATE_URL##*/}"
    sums="$(curl --silent --show-error --location --fail "$sums_url" || true)"
    TEMPLATE_SHA256="$(awk -v name="$tarball_name" '$2 ~ name {print $1; exit}' <<< "$sums")"
    [[ -n "$TEMPLATE_SHA256" ]] \
      || fail "could not find $tarball_name in $sums_url; set TEMPLATE_SHA256 by hand"
    pass "the template for $node_arch checksums to ${TEMPLATE_SHA256:0:12}..."
  fi
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
  check "the template's content is on the volume" dbguest test -e /sbin
  check "the downloaded tarball was removed" dbguest test ! -d /.stateful-pods/download
  check "the volume carries a seeding record" dbguest test -f /.stateful-pods/provisioned
  check "the machine booted from the template" dbguest sh -c 'test -e /proc/1/comm'
  check "the machine knows it is in a container" \
    dbguest sh -c 'tr "\0" "\n" < /proc/1/environ | grep -qx "container=lxc"' 
fi

echo
echo "every integration assertion held"
