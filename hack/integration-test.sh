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
# An oci source is fetched by the chart's own image from a registry, so the test
# runs one inside the cluster and pushes to it through a port forward. `kind
# load` puts an image where containerd can see it and where a registry client in
# a pod cannot, so it is no longer enough on its own - it is kept only for the
# release that exercises the upgrade from the previous chart revision, which
# still runs an oci source as a container image.
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
ALPINE_SOURCE_IMAGE="${ALPINE_SOURCE_IMAGE:-stateful-pods-test-alpine:integration}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

# The chart revision to upgrade from, for the one assertion that is about the
# migration rather than about the chart: that the per-machine ConfigMap the
# previous revision rendered disappears without touching a seeded volume. It
# skips itself once that revision no longer renders one, which is what it should
# do after this change has been on the default branch for a release.
PREVIOUS_CHART_REF="${PREVIOUS_CHART_REF:-origin/main}"

# Where the pod fetches an oci source from. An in-cluster Service name, because
# a registry client inside a pod cannot read the node's image store: `kind load`
# puts an image exactly where crane cannot see it. The name ends in `.local`, so
# go-containerregistry speaks plain HTTP to it and neither the chart nor this
# test needs a certificate or an insecure-registry option.
REGISTRY_IN_CLUSTER="registry.${NAMESPACE}.svc.cluster.local:5000"
# The same registry seen from this host, through a port forward. A registry
# stores by repository path and not by the host it was reached on, so an image
# pushed here is the image pulled there.
REGISTRY_LOCAL="localhost:${REGISTRY_PORT:-5000}"
PORT_FORWARD_PID=""
PREVIOUS_CHART_WORKTREE=""
# A copy of the chart whose catalog points at this cluster's registry, so that a
# preset resolves to something the cluster can actually pull.
PRESET_CHART_DIR=""

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

# The release a preset publishes under, which is also its rolling tag. Read out
# of the catalog rather than derived: the package, the preset name and the
# upstream's own name for the distribution are three different strings, and this
# is the one file that relates them.
preset_release() {
  local want="$1" name release
  while IFS=';' read -r name _ release _ _ || [[ -n "$name" ]]; do
    if [[ "$name" == "$want" ]]; then
      printf '%s\n' "$release"
      return 0
    fi
  done < images/presets/presets.list
  return 0
}

# wait_ready <pod>
# A StatefulSet recreates a pod that was deleted, but not in the same instant.
# `kubectl wait` landing in that gap fails with NotFound rather than waiting, so
# the pod is waited into existence first and only then waited on.
#
# The same helper is in hack/seccomp-test.sh, on purpose: each script stands on
# its own and is run on its own, and a shared file between two suites that build
# different clusters would be a third thing to keep in step with both.
wait_ready() {
  local pod="$1"
  for _ in $(seq 1 60); do
    kc get "pod/$pod" >/dev/null 2>&1 && break
    sleep 2
  done
  kc wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null
}

# assert_default_filter <pod>
# The steps that run before the guest declare the runtime's default syscall
# filter, and a pod that is Ready is a pod whose preparation steps succeeded
# under it. Asserted on every source kind, because what they do differs: one
# unpacks a flattened image fetched over HTTPS from a registry, the other a
# template tarball fetched over HTTPS from a web server.
assert_default_filter() {
  local pod="$1" filters
  filters="$(kc get pod "$pod" --output \
    "jsonpath={.spec.initContainers[*].securityContext.seccompProfile.type}")"
  if [[ "$filters" == "RuntimeDefault RuntimeDefault RuntimeDefault" ]]; then
    pass "$pod: every preparation step ran under the runtime's default filter"
  else
    fail "$pod: the preparation steps declared '${filters:-nothing}'"
  fi
}

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
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  if [[ -n "$PREVIOUS_CHART_WORKTREE" ]]; then
    git worktree remove --force "$PREVIOUS_CHART_WORKTREE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PRESET_CHART_DIR" ]]; then
    rm -rf "$PRESET_CHART_DIR" 2>/dev/null || true
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
docker build --tag "$ALPINE_SOURCE_IMAGE" --file test/integration/Containerfile.alpine-source \
  test/integration >/dev/null
docker pull --quiet "$REGISTRY_IMAGE" >/dev/null

step "creating the cluster $CLUSTER"
existing_clusters="$(kind get clusters 2>/dev/null || true)"
if ! grep --quiet --line-regexp "$CLUSTER" <<< "$existing_clusters"; then
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kind load docker-image "$SHIM_IMAGE" --name "$CLUSTER"
kind load docker-image "$REGISTRY_IMAGE" --name "$CLUSTER"
# The source image is loaded onto the node as well, for the upgrade assertion
# alone: the previous chart revision runs an oci source as a container image, so
# that release needs it where the kubelet looks. Every other release fetches it
# from the registry below, which is the only place the current chart looks.
kind load docker-image "$SOURCE_IMAGE" --name "$CLUSTER"
kubectl --context "$CONTEXT" create namespace "$NAMESPACE" --dry-run=client --output yaml \
  | kubectl --context "$CONTEXT" apply --filename - >/dev/null

step "starting a registry the pod can reach"
# The manifest names the default; kind loaded whatever REGISTRY_IMAGE names, so
# the two are kept in step here rather than drifting in two places.
sed "s|image: registry:2$|image: $REGISTRY_IMAGE|" test/integration/registry.yaml \
  | kc apply --filename - >/dev/null
kc rollout status deployment/registry --timeout=180s >/dev/null
kubectl --context "$CONTEXT" --namespace "$NAMESPACE" \
  port-forward service/registry "${REGISTRY_PORT:-5000}:5000" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
registry_reachable=0
for _ in $(seq 1 30); do
  if curl --silent --show-error --fail "http://$REGISTRY_LOCAL/v2/" >/dev/null 2>&1; then
    registry_reachable=1
    break
  fi
  sleep 1
done
[[ "$registry_reachable" -eq 1 ]] || fail "the in-cluster registry never became reachable"
pass "the in-cluster registry is reachable through a port forward"

SOURCE_REFERENCE="$REGISTRY_IN_CLUSTER/${SOURCE_IMAGE}"
ALPINE_SOURCE_REFERENCE="$REGISTRY_IN_CLUSTER/${ALPINE_SOURCE_IMAGE}"
step "pushing the source images to it"
docker tag "$SOURCE_IMAGE" "$REGISTRY_LOCAL/${SOURCE_IMAGE}"
docker tag "$ALPINE_SOURCE_IMAGE" "$REGISTRY_LOCAL/${ALPINE_SOURCE_IMAGE}"
docker push --quiet "$REGISTRY_LOCAL/${SOURCE_IMAGE}" >/dev/null
docker push --quiet "$REGISTRY_LOCAL/${ALPINE_SOURCE_IMAGE}" >/dev/null

# ---------------------------------------------------------------- oci source ---
step "installing a machine with an oci source"
helm --kube-context "$CONTEXT" upgrade --install oci "$CHART" \
  --namespace "$NAMESPACE" \
  --values test/integration/oci.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --set "machines.web.source.reference=$SOURCE_REFERENCE" \
  --wait --timeout 5m >/dev/null
wait_ready oci-web-0

assert_default_filter oci-web-0

step "asserting the machine's source is nowhere in its pod"
images="$(kc get pod oci-web-0 --output \
  "jsonpath={.spec.initContainers[*].image} {.spec.containers[*].image}")"
if grep --quiet -- "$SOURCE_REFERENCE" <<< "$images"; then
  fail "a container in the pod runs the machine's source: $images"
else
  pass "no container in the pod runs the machine's source"
fi
check "the release renders no ConfigMap of scripts" \
  bash -c "! kubectl --context '$CONTEXT' --namespace '$NAMESPACE' get configmap oci-web"

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

# The container runtime used to pick the right variant of a multi-architecture
# image invisibly. The chart makes that choice itself now, and getting it wrong
# seeds a rootfs that unpacks perfectly and cannot execute its own init - a
# failure that surfaces at boot, far from its cause.
node_architecture="$(kubectl --context "$CONTEXT" get nodes \
  --output "jsonpath={.items[0].status.nodeInfo.architecture}")"
case "$node_architecture" in
  amd64) expected_elf_machine="3e" ;;
  arm64) expected_elf_machine="b7" ;;
  *)     expected_elf_machine="" ;;
esac
if [[ -z "$expected_elf_machine" ]]; then
  skip "the architecture assertion: no ELF machine is claimed for $node_architecture"
else
  # Byte 18 of an ELF header is e_machine, which is what an operating system
  # built for the wrong architecture gets wrong.
  elf_machine="$(guest od -An -t x1 -j 18 -N 1 /bin/true | tr -d ' \n')"
  if [[ "$elf_machine" == "$expected_elf_machine" ]]; then
    pass "the seeded root filesystem is built for the node's own $node_architecture"
  else
    fail "the volume holds binaries for ELF machine 0x$elf_machine, but the node is $node_architecture"
  fi
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

step "asserting the machine holds the capability set its mode names, and nothing beyond it"
# The bounding set of the machine's own init. Nothing inside the machine can
# exceed it, so this is a statement about every process the machine will ever run
# and not about the shell this exec started. `capsh` is in the source image
# because it installs libcap2-bin for the file-capability assertion above, and it
# is called by path for the same reason `getcap` is.
# Both substitutions end in `|| true` so that a failure here is reported by the
# check below rather than ending the run with errexit and no message at all.
bounding="$(guest sh -c 'awk "/^CapBnd:/ {print \$2}" /proc/1/status' | tr -d '\r' || true)"
granted="$(guest /usr/sbin/capsh --decode="$bounding" | sed 's/^[^=]*=//' | tr ',' '\n' | tr -d '\r' || true)"
[[ -n "$granted" ]] \
  || fail "could not read the machine's bounding capability set (CapBnd was '${bounding:-nothing}')"

held() { grep --quiet --line-regexp --fixed-strings "$1" <<< "$granted"; }

# What the mode is defined by granting. Without these an operating system does
# not run: SYS_ADMIN is the mount and the root change, and the rest are what a
# daemon dropping privilege or binding a low port needs.
for capability in cap_sys_admin cap_chown cap_setuid cap_setgid cap_mknod cap_net_bind_service; do
  if held "$capability"; then
    pass "the machine holds $capability, which the mode names"
  else
    fail "the machine does not hold $capability, so the mode's set is too narrow to run an operating system"
  fi
done

# What the mode is defined by *not* granting, and what each would let a machine
# do. The first five are the ones the reference implementation has always refused
# a privileged container; the last two are the escape primitives the syscall
# filter in profiles/ exists to close, and they are absent permanently.
assert_given_up() {
  if held "$1"; then
    fail "the machine holds $1, so it can still $2 - which this mode gives up"
  else
    pass "the machine cannot $2: $1 is not in its bounding set"
  fi
}
assert_given_up cap_sys_module "load or unload a kernel module"
assert_given_up cap_sys_rawio "perform raw I/O"
assert_given_up cap_sys_time "set the node's clock"
assert_given_up cap_mac_admin "alter the node's mandatory access control"
assert_given_up cap_mac_override "override the node's mandatory access control"
assert_given_up cap_dac_read_search "reach a file outside its root by handle"
assert_given_up cap_sys_boot "replace the running kernel"

step "asserting the machine cannot reach the node's own devices"
# The sharpest form of what the mode gave up. A machine still holds CAP_MKNOD, so
# it creates the node for one of the node's block devices exactly as before - and
# opening it is what the device cgroup now refuses. Under the blanket privileged
# flag the same two commands read the node's disk.
check "no block device of the node's is present in the machine" \
  guest sh -c '! ls -l /dev | grep -q "^b"'
# The node is made in /dev, which the mount plan mounts without nodev. On a nodev
# filesystem - /tmp and /run, in this machine - the open fails whatever the device
# cgroup allows, so probing there would hold under the old posture too and prove
# nothing about this one. Asserted rather than assumed, because the mount plan
# could change.
check "the machine's /dev is not mounted nodev, so the probe below means what it says" \
  guest sh -c 'awk "\$2 == \"/dev\" && \$4 ~ /nodev/ {found=1} END {exit found}" /proc/mounts'
# The two refusals are told apart by their errno, and only one of them is this
# mode's doing: nodev gives EACCES, "Permission denied"; the device cgroup gives
# EPERM, "Operation not permitted". Matching the exact one is also what stops a
# node with no such device from passing this for saying "No such device".
device_error="$(guest sh -c 'mknod /dev/sp-node b 7 0 && dd if=/dev/sp-node of=/dev/null bs=512 count=1' 2>&1 || true)"
if grep --quiet 'Operation not permitted' <<< "$device_error"; then
  pass "the machine cannot open one of the node's block devices, even through a node it made itself"
elif grep --quiet 'records out' <<< "$device_error"; then
  fail "the machine read one of the node's block devices, which this mode is meant to have given up"
else
  fail "the machine was refused the node's block device for another reason: ${device_error:-nothing}"
fi

step "asserting the files the chart maintains inside the machine"
check "the machine has the pod's host name" \
  guest sh -c '[ "$(cat /etc/hostname)" = "oci-web-0" ]'
check "the machine can resolve names" guest sh -c 'grep -q nameserver /etc/resolv.conf'
check "the machine's host table is the pod's" guest sh -c 'grep -q oci-web-0 /etc/hosts'

step "asserting a claimed file is left alone"
guest sh -c 'touch /etc/.stateful-pods-ignore.resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf'
kc delete pod oci-web-0 --wait >/dev/null
wait_ready oci-web-0
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

wait_ready oci-web-0

step "asserting that a restart does not re-seed"
guest sh -c 'echo "written by the guest" > /etc/guest-state'
before="$(guest cat /.stateful-pods/provisioned)"
kc delete pod oci-web-0 --wait >/dev/null
wait_ready oci-web-0

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

# ------------------------------------------------------- a source with no shell ---
step "installing a machine whose source carries no shell and no GNU tar"
helm --kube-context "$CONTEXT" upgrade --install alpine "$CHART" \
  --namespace "$NAMESPACE" \
  --values test/integration/oci-alpine.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --set "machines.tiny.source.reference=$ALPINE_SOURCE_REFERENCE" \
  --wait --timeout 5m >/dev/null
wait_ready alpine-tiny-0

assert_default_filter alpine-tiny-0

step "asserting the machine the old seeding path refused"
tiny() { kc exec alpine-tiny-0 --container guest -- "$@"; }
check "the volume carries a seeding record" tiny test -f /.stateful-pods/provisioned
check "the source image's content is on the volume" tiny test -f /etc/sp-alpine-marker
# The two properties that made this image unusable as a source before: the old
# seeding step executed inside it and copied it out with its own archiver.
check "the source really provides no bash" tiny sh -c 'test ! -e /bin/bash'
check "the source's own tar really is busybox" \
  tiny sh -c 'tar --version 2>&1 | grep -q busybox'
check "the machine's own init is process 1" \
  tiny sh -c '[ "$(cat /proc/1/comm)" != "boot.sh" ] && [ "$(cat /proc/1/comm)" != "bash" ]'
check "the machine has the pod's host name" \
  tiny sh -c '[ "$(cat /etc/hostname)" = "alpine-tiny-0" ]'

# ------------------------------------------------------------- preset source ---
# The first machines here that name a distribution rather than a reference.
#
# Two presets rather than four, and these two on purpose. Debian and Ubuntu take
# the same path through the chart and the same path through the seeding step as
# the oci machine above already does - a GNU-tar systemd root filesystem from a
# registry - and each is another 100 MB of download and another 700 MB on the
# node for no path that is not already covered.
#
# Alpine and Void are the ones that are new, though not for the same reason the
# proposal expected. Alpine provides only busybox tar, which is the case the
# seeding step refused outright until it stopped using the source's own
# archiver. Void turns out to ship GNU tar 1.35 - so its interest is its init,
# which is runit: the only machine anywhere in this suite that boots something
# other than systemd or busybox init.
#
# The catalog is rewritten to point at the in-cluster registry. What is being
# asserted is that a name resolves and that what it resolves to boots; that this
# project's published references resolve is asserted where they are published.
#
# This runs before the section that takes the registry away, and has to: that
# section deletes the registry pod, and the port forward opened once at the top
# of this file dies with it and is never reopened.
if ! command -v crane >/dev/null 2>&1; then
  skip "the preset assertions: crane is needed to build a preset and was not found"
else
  node_arch="$(kubectl --context "$CONTEXT" get nodes \
    --output "jsonpath={.items[0].status.nodeInfo.architecture}")"
  PRESET_CHART_DIR="$(mktemp -d)"
  cp -R "$CHART" "$PRESET_CHART_DIR/stateful-pods"
  preset_chart="$PRESET_CHART_DIR/stateful-pods"
  preset_catalog="$preset_chart/presets.yaml"

  step "building the presets this cluster will use, for $node_arch"
  # One architecture, because the cluster has one. The published presets cover
  # every architecture the project builds for; that is asserted when they are
  # published, and building both here would double a large download to prove
  # something no node in this cluster can execute.
  built="$(./hack/preset-build.sh \
    --repository "$REGISTRY_LOCAL/stateful-pods-" \
    --platforms "linux/$node_arch" \
    alpine-3.24 void-current)" \
    || fail "the preset build did not complete"

  while IFS=$'\t' read -r preset build reference; do
    [[ -n "$preset" ]] || continue
    pass "$preset: built from the $build upstream build"
    # The same image, named as the cluster reaches it. A registry stores by
    # repository path rather than by the host it was reached on, so the digest
    # is the digest either way - but only if the path is the same one. It is
    # taken off the reference the build reported rather than composed from the
    # preset's name: a preset publishes into a package named for its
    # distribution, so `alpine-3.24` lands in `stateful-pods-alpine` and a path
    # rebuilt from the name would name a repository that does not exist.
    in_cluster="$REGISTRY_IN_CLUSTER/${reference#*/}"
    ./hack/preset-bump.sh --catalog "$preset_catalog" "$preset" "$in_cluster" >/dev/null \
      || fail "$preset: could not point the test catalog at $in_cluster"
  done <<< "$built"

  # The release's own tag is the name a person pulls, and it is the only
  # reference the build moves rather than creates. Everything else here is
  # asserted against what the build reported; this is asserted against the
  # registry, because "the tag followed" is a claim about the registry.
  step "asserting each release tag names the build just published"
  while IFS=$'\t' read -r preset build reference; do
    [[ -n "$preset" ]] || continue
    rolling_tag="$(preset_release "$preset")"
    [[ -n "$rolling_tag" ]] || fail "$preset: no line in images/presets/presets.list"
    repository="${reference%@*}"
    rolling="$(crane digest "$repository:$rolling_tag")" \
      || fail "$preset: $repository:$rolling_tag does not resolve"
    if [[ "$rolling" == "${reference##*@}" ]]; then
      pass "$preset: $repository:$rolling_tag is the build just published"
    else
      fail "$preset: $repository:$rolling_tag is $rolling, not ${reference##*@}"
    fi
  done <<< "$built"

  # A run that dies between the index push and the rolling tag leaves the tag on
  # whatever it named before. Nothing here can produce that state honestly, so it
  # is produced by hand - and the next build has to put it back, without
  # republishing the dated tag it correctly leaves alone. That repair is the
  # whole reason the already-published path sets the tag at all, and it is a line
  # that can be deleted without any other assertion here noticing.
  step "moving a release tag off its build, the way an interrupted run would"
  alpine_release="$(preset_release alpine-3.24)"
  # `|| true` on both, because the guard below is the diagnostic. Under errexit
  # and pipefail a grep that matches nothing takes the script out before the
  # message written for exactly that case can be printed.
  alpine_reference="$(grep --max-count 1 '^alpine-3.24	' <<< "$built" | cut --fields 3 || true)"
  [[ -n "$alpine_reference" ]] || fail "the build reported no reference for alpine-3.24"
  alpine_repository="${alpine_reference%@*}"
  stray_tag="$(crane ls "$alpine_repository" | grep --max-count 1 -- "-$node_arch\$" || true)"
  [[ -n "$stray_tag" ]] || fail "the alpine preset published no per-architecture tag to point at"
  crane tag "$alpine_repository:$stray_tag" "$alpine_release" \
    || fail "could not move $alpine_repository:$alpine_release onto $stray_tag"
  check "the release tag now names something other than the build" \
    test "$(crane digest "$alpine_repository:$alpine_release")" != "${alpine_reference##*@}"

  # A published tag is never republished, which is the promise that makes a
  # machine's origin reproducible. The build says so; this is where a registry
  # exists to check it against.
  step "asserting a published build is not republished"
  rebuilt="$(./hack/preset-build.sh \
    --repository "$REGISTRY_LOCAL/stateful-pods-" \
    --platforms "linux/$node_arch" \
    alpine-3.24 void-current 2>"$PRESET_CHART_DIR/rebuild.log")" \
    || fail "the second preset build did not complete"
  if [[ "$rebuilt" == "$built" ]]; then
    pass "a second build resolves both presets to the digests already published"
  else
    fail "a second build changed what a published tag resolves to"
  fi
  check "the second build said it was leaving the published tags alone" \
    grep --quiet "is already published, leaving it alone" "$PRESET_CHART_DIR/rebuild.log"
  check "the second build put the release tag back on its build" \
    test "$(crane digest "$alpine_repository:$alpine_release")" = "${alpine_reference##*@}"

  for preset in alpine-3.24 void-current; do
    release="preset-${preset%%-*}"
    pod="$release-os-0"

    step "installing a machine that names the $preset preset"
    helm --kube-context "$CONTEXT" upgrade --install "$release" "$preset_chart" \
      --namespace "$NAMESPACE" \
      --values test/integration/preset.yaml \
      --set "shim.image=$SHIM_IMAGE" \
      --set "machines.os.source.name=$preset" \
      --wait --timeout 10m >/dev/null
    wait_ready "$pod"

    assert_default_filter "$pod"

    step "asserting the $preset machine"
    osguest() { kc exec "$pod" --container guest -- "$@"; }

    check "the volume carries a seeding record" osguest test -f /.stateful-pods/provisioned
    # Without this the record holds a digest and nothing else, and which preset
    # the machine was made from stops being answerable once that reference ages
    # out of the catalog.
    check "the record names the preset the machine was made from" \
      osguest sh -c "grep -q '\"preset\": \"$preset\"' /.stateful-pods/provisioned"
    check "the record still names the oci kind the scripts were given" \
      osguest sh -c "grep -q '\"kind\": \"oci\"' /.stateful-pods/provisioned"

    # The architecture assertion, and the reason it is this one: a root
    # filesystem built for another architecture seeds without a single error and
    # then cannot execute anything in itself. A machine whose own init is
    # process 1 has already executed the rootfs, so reaching here is the proof.
    # The ELF header is read as well, so that a failure says which architecture
    # arrived rather than only that nothing ran.
    check "the machine's own init is process 1, not the chart's" \
      osguest sh -c '[ "$(cat /proc/1/comm)" != "boot.sh" ] && [ "$(cat /proc/1/comm)" != "bash" ]'
    case "$node_arch" in
      amd64) want_machine="3e00" ;;
      arm64) want_machine="b700" ;;
      *) want_machine="" ;;
    esac
    if [[ -z "$want_machine" ]]; then
      skip "$preset: no ELF machine type known for $node_arch"
    else
      got_machine="$(osguest sh -c \
        'dd if=/bin/sh bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d " \n"' || true)"
      if [[ "$got_machine" == "$want_machine" ]]; then
        pass "the rootfs was built for the node's own architecture ($node_arch)"
      else
        fail "the rootfs reports ELF machine '${got_machine:-nothing}', not $want_machine for $node_arch"
      fi
    fi

    # What each of these two is here to prove, which is not the same thing.
    case "$preset" in
      alpine-3.24)
        check "the source really provides only busybox tar" \
          osguest sh -c 'tar --version 2>&1 | grep -q busybox'
        ;;
      void-current)
        check "the machine booted an init that is neither systemd nor busybox" \
          osguest sh -c '[ "$(cat /proc/1/comm)" = "runit" ]'
        ;;
    esac
    check "the machine has the pod's host name" \
      osguest sh -c "[ \"\$(cat /etc/hostname)\" = \"$pod\" ]"
  done
fi

# ------------------------------------------------- the source after seeding ---
# A machine's source is a seed, not a runtime dependency. Taking the registry
# away is the only way to prove that: a machine that still reached for its
# source on every start would depend for its whole life on a reference someone
# else controls, and would pay for a full transfer of its operating system every
# time it was rescheduled.
step "taking the registry away and restarting both seeded machines"
kc scale deployment/registry --replicas=0 >/dev/null
kc wait --for=delete pod --selector app=registry --timeout=120s >/dev/null
kc delete pod oci-web-0 alpine-tiny-0 --wait >/dev/null
if wait_ready oci-web-0 \
   && wait_ready alpine-tiny-0; then
  pass "both machines came back up with no registry to reach"
else
  fail "a seeded machine could not start once its source was unreachable"
fi
check "the guest's own file survived the registry going away" \
  guest sh -c '[ "$(cat /etc/guest-state)" = "written by the guest" ]'
kc scale deployment/registry --replicas=1 >/dev/null

# ------------------------------------------------------------- the upgrade ---
# The one assertion here that is about the migration rather than about the
# chart: the per-machine ConfigMap the previous revision rendered is
# release-owned, so `helm upgrade` deletes it, and no machine's volume is
# touched by that. It retires itself once the previous revision no longer
# renders a ConfigMap.
step "upgrading a machine installed by the previous chart revision"
previous_sha="$(git rev-parse --verify --quiet "$PREVIOUS_CHART_REF^{commit}" || true)"
if [[ -z "$previous_sha" ]]; then
  skip "the upgrade assertion: $PREVIOUS_CHART_REF does not resolve"
elif ! git cat-file -e "$previous_sha:charts/stateful-pods/templates/scripts-configmap.yaml" 2>/dev/null; then
  skip "the upgrade assertion: $PREVIOUS_CHART_REF renders no ConfigMap to migrate from"
else
  PREVIOUS_CHART_WORKTREE="$(mktemp -d)"
  git worktree add --detach --force "$PREVIOUS_CHART_WORKTREE" "$previous_sha" >/dev/null 2>&1 \
    || fail "could not check out $PREVIOUS_CHART_REF ($previous_sha) to upgrade from"
  helm --kube-context "$CONTEXT" upgrade --install migrated \
    "$PREVIOUS_CHART_WORKTREE/charts/stateful-pods" \
    --namespace "$NAMESPACE" \
    --values test/integration/oci.yaml \
    --set "shim.image=$SHIM_IMAGE" \
    --wait --timeout 5m >/dev/null
  wait_ready migrated-web-0
  check "the previous revision rendered a ConfigMap of scripts" kc get configmap migrated-web
  kc exec migrated-web-0 --container guest -- \
    sh -c 'echo "written before the upgrade" > /etc/before-upgrade' >/dev/null

  helm --kube-context "$CONTEXT" upgrade migrated "$CHART" \
    --namespace "$NAMESPACE" \
    --values test/integration/oci.yaml \
    --set "shim.image=$SHIM_IMAGE" \
    --set "machines.web.source.reference=$SOURCE_REFERENCE" \
    --wait --timeout 5m >/dev/null
  wait_ready migrated-web-0
  check "the upgrade removed the ConfigMap" \
    bash -c "! kubectl --context '$CONTEXT' --namespace '$NAMESPACE' get configmap migrated-web"
  check "the machine's own file survived the upgrade" \
    kc exec migrated-web-0 --container guest -- \
      sh -c '[ "$(cat /etc/before-upgrade)" = "written before the upgrade" ]'
  check "the volume was not re-seeded by the upgrade" \
    kc exec migrated-web-0 --container guest -- test -f /.stateful-pods/provisioned
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
  wait_ready lxc-db-0

  assert_default_filter lxc-db-0

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
