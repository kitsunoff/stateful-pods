#!/usr/bin/env bash
#
# What a cluster's own seccomp configuration does to a machine.
#
# This is a second cluster rather than an assertion in the main integration
# suite, because the thing under test is the cluster: its kubelet runs with
# seccompDefault, which gives the container runtime's default profile to every
# container that names none. That profile does not permit pivot_root, so before
# this chart declared a filter, a `userns` machine on such a cluster seeded its
# volume over several minutes and then died at the root change - and did so on
# some clusters and not others, which is the part that made it hard to see.
#
# The defect is shown twice, at two different distances.
#
# A probe container isolates the mechanism: it reports one `name=value` line per
# system call, where EPERM means a filter stopped the call and any other errno
# means the call reached the kernel. It is granted the capabilities those calls
# need, because otherwise the capability check returns EPERM too and every
# assertion here would hold for the wrong reason.
#
# A real machine then shows the consequence: the chart's own boot script, on the
# volume it seeded itself, failing at `pivot_root` and saying so. That machine is
# rendered in `userns` mode - the mode the defect belongs to - with `hostUsers`
# removed, because a kind node is itself a container and a user namespace nested
# inside one does not work here. What is left is what matters: an unprivileged
# guest holding CAP_SYS_ADMIN, which is the posture whose root change the default
# profile withholds.
#
# The last section then asserts the other side of it: that a machine in the
# `privileged` mode now runs under the profile its values name. It did not use
# to. The mode rendered a privileged container, and a privileged container is
# given no profile at all - which is one of the two reasons the mode stopped
# being rendered that way.
#
# Nearly every command below is single-quoted on purpose: it is expanded by a
# shell in another container, not by this one.
# shellcheck disable=SC2016
set -o errexit
set -o nounset
set -o pipefail

CLUSTER="${SECCOMP_CLUSTER:-stateful-pods-seccomp-test}"
CONTEXT="kind-${CLUSTER}"
NAMESPACE="${SECCOMP_NAMESPACE:-stateful-pods-seccomp-$(date +%s)}"
CHART="${CHART:-charts/stateful-pods}"
SHIM_IMAGE="${SHIM_IMAGE:-stateful-pods-shim:dev}"
SOURCE_IMAGE="${SOURCE_IMAGE:-stateful-pods-test-source:integration}"
PROBE_IMAGE="${PROBE_IMAGE:-stateful-pods-seccomp-probe:integration}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

# The profile this repository ships, and the path a machine names it by. The
# kubelet resolves a localhostProfile under its own seccomp directory, so the
# file goes to <that directory>/<that path>.
PROFILE_FILE="${CHART}/profiles/stateful-pods-machine.json"
PROFILE_PATH="profiles/stateful-pods-machine.json"
KUBELET_SECCOMP_DIR="/var/lib/kubelet/seccomp"

REGISTRY_IN_CLUSTER="registry.${NAMESPACE}.svc.cluster.local:5000"
REGISTRY_PORT="${SECCOMP_REGISTRY_PORT:-5001}"
REGISTRY_LOCAL="localhost:${REGISTRY_PORT}"
PORT_FORWARD_PID=""
KIND_CONFIG=""
RAW_MANIFEST=""
MACHINE_MANIFEST=""
DEFECTIVE_MANIFEST=""

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

# check <description> <command...>
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

kc() { kubectl --context "$CONTEXT" --namespace "$NAMESPACE" "$@"; }

# wait_ready <pod>
# A StatefulSet recreates a pod that was deleted, but not in the same instant.
# `kubectl wait` landing in that gap fails with NotFound rather than waiting, so
# the pod is waited into existence first and only then waited on.
wait_ready() {
  local pod="$1"
  for _ in $(seq 1 60); do
    kc get "pod/$pod" >/dev/null 2>&1 && break
    sleep 2
  done
  kc wait --for=condition=Ready "pod/$pod" --timeout=300s >/dev/null
}

on_exit() {
  local code=$?
  if [[ "$code" -ne 0 ]]; then
    echo "--- pods ---" >&2
    kc get pods >&2 2>&1 || true
  fi
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  # Short flag on purpose, against this repository's usual rule: BSD rm rejects
  # --force, so the long form makes this cleanup silently do nothing on a Mac.
  rm -f "$KIND_CONFIG" "$RAW_MANIFEST" "$MACHINE_MANIFEST" "$DEFECTIVE_MANIFEST" 2>/dev/null || true
  if [[ "$KEEP_CLUSTER" == "1" ]]; then
    echo "cluster $CLUSTER kept; this run's namespace is $NAMESPACE"
    echo "remove the cluster with: kind delete cluster --name $CLUSTER"
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap on_exit EXIT

# probe <name> <extra pod spec yaml, indented under securityContext's container>
# Runs the probe once and prints its output. The pod is granted the capabilities
# the probed calls need, so that EPERM can only come from a syscall filter.
run_probe() {
  local name="$1" security_context="$2"
  kc delete pod "$name" --ignore-not-found --wait >/dev/null 2>&1 || true
  cat <<EOF | kc apply --filename - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: $PROBE_IMAGE
      imagePullPolicy: Never
      securityContext:
        capabilities:
          add:
            - SYS_ADMIN
            - SYS_MODULE
            - SYS_BOOT
            - DAC_READ_SEARCH
$security_context
EOF
  kc wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=180s >/dev/null \
    || fail "the probe pod $name never completed"
  kc logs "$name"
}

# probed <output> <name> - the value the probe reported for one call
probed() { awk -F= -v key="$2" '$1 == key {print $2}' <<< "$1"; }

# expect <output> <call> <value> <description>
expect() {
  local got
  got="$(probed "$1" "$2")"
  if [[ "$got" == "$3" ]]; then
    pass "$4"
  else
    fail "$4 (the probe reported $2=${got:-nothing}, expected $3)"
  fi
}

# expect_not <output> <call> <value> <description> [hint]
# The hint is printed only on failure, where a second plausible cause exists and
# the bare errno would point at the wrong one.
expect_not() {
  local got
  got="$(probed "$1" "$2")"
  if [[ -n "$got" && "$got" != "$3" ]]; then
    pass "$4"
  else
    fail "$4 (the probe reported $2=${got:-nothing}, which must not be $3)${5:+ - $5}"
  fi
}

step "building the images"
docker build --tag "$SHIM_IMAGE" --file images/shim/Containerfile images/shim >/dev/null
docker build --tag "$SOURCE_IMAGE" --file test/integration/Containerfile.source test/integration >/dev/null
docker build --tag "$PROBE_IMAGE" --file test/integration/Containerfile.seccomp-probe \
  test/integration >/dev/null
docker pull --quiet "$REGISTRY_IMAGE" >/dev/null

step "creating a cluster whose kubelet filters by default"
# seccompDefault in the kubelet's own configuration rather than --seccomp-default
# on its command line: the flag has to be spelled differently for each kubeadm
# API version, and this field has been stable since it went beta.
KIND_CONFIG="$(mktemp)"
cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        seccompDefault: true
EOF
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG" --wait 120s

node="$(kubectl --context "$CONTEXT" get nodes --output "jsonpath={.items[0].metadata.name}")"
if docker exec "$node" grep --quiet '^seccompDefault: true$' /var/lib/kubelet/config.yaml; then
  pass "the cluster's kubelet applies a default filter to pods that declare none"
else
  fail "the cluster was created without seccompDefault, so nothing below would mean anything"
fi

step "placing the shipped profile on the node"
# The second of the three ways profiles/README.md documents: whatever provisions
# a node puts the file there. A DaemonSet would work too and is a privileged
# workload; this is the same file landing in the same place, without one.
docker exec "$node" mkdir -p "$KUBELET_SECCOMP_DIR/$(dirname "$PROFILE_PATH")"
docker cp "$PROFILE_FILE" "$node:$KUBELET_SECCOMP_DIR/$PROFILE_PATH"
check "the profile is on the node where the kubelet resolves it" \
  docker exec "$node" test -f "$KUBELET_SECCOMP_DIR/$PROFILE_PATH"

kind load docker-image "$SHIM_IMAGE" --name "$CLUSTER"
kind load docker-image "$PROBE_IMAGE" --name "$CLUSTER"
kind load docker-image "$REGISTRY_IMAGE" --name "$CLUSTER"
kubectl --context "$CONTEXT" create namespace "$NAMESPACE" --dry-run=client --output yaml \
  | kubectl --context "$CONTEXT" apply --filename - >/dev/null

step "starting a registry the machine can fetch its source from"
sed "s|image: registry:2$|image: $REGISTRY_IMAGE|" test/integration/registry.yaml \
  | kc apply --filename - >/dev/null
kc rollout status deployment/registry --timeout=180s >/dev/null
kubectl --context "$CONTEXT" --namespace "$NAMESPACE" \
  port-forward service/registry "${REGISTRY_PORT}:5000" >/dev/null 2>&1 &
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
docker tag "$SOURCE_IMAGE" "$REGISTRY_LOCAL/${SOURCE_IMAGE}"
docker push --quiet "$REGISTRY_LOCAL/${SOURCE_IMAGE}" >/dev/null
SOURCE_REFERENCE="$REGISTRY_IN_CLUSTER/${SOURCE_IMAGE}"

# --------------------------------------------------------------- the defect ---
step "what a container that declares no filter is given"
inherited="$(run_probe inherited-filter "")"
expect "$inherited" seccomp_mode 2 \
  "a container that names no profile is given the runtime's default one"
expect "$inherited" pivot_root EPERM \
  "the default profile refuses the root change the guest container performs"
expect "$inherited" getpid ok \
  "the default profile is a filter and not a wall"

step "what a container that declares Unconfined is given, which is what the chart renders"
declared="$(cat <<'EOF'
        seccompProfile:
          type: Unconfined
EOF
)"
unconfined="$(run_probe declared-unconfined "$declared")"
expect "$unconfined" seccomp_mode 0 \
  "a container that declares Unconfined is given no filter, whatever the kubelet is configured to do"
expect "$unconfined" pivot_root ENOENT \
  "the root change reaches the kernel, which is what lets a machine start"

# ------------------------------------------- the defect, with a real machine ---
step "rendering the machine the defect belongs to"
# `userns` is the mode whose guest is unprivileged and holds CAP_SYS_ADMIN, and
# it is the mode the runtime's default profile breaks. hostUsers is removed
# because a kind node cannot nest a user namespace; nothing else about the guest
# changes, and what remains is the container the default profile would stop.
RAW_MANIFEST="$(mktemp)"
MACHINE_MANIFEST="$(mktemp)"
DEFECTIVE_MANIFEST="$(mktemp)"
helm template defect "$CHART" \
  --namespace "$NAMESPACE" --kube-version 1.33.0 \
  --values test/integration/oci.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --set "machines.web.source.reference=$SOURCE_REFERENCE" \
  --set "machines.web.security.mode=userns" > "$RAW_MANIFEST"
# Checked, for the same reason the removal below is: a sed that matched nothing
# would leave a pod kind cannot start, and the section would fail for a reason
# that has nothing to do with the filter.
[[ "$(grep --count '^      hostUsers: false$' "$RAW_MANIFEST" || true)" -eq 1 ]] \
  || fail "the userns render no longer carries hostUsers, so there is nothing here to remove"
sed -e '/^      hostUsers: false$/d' "$RAW_MANIFEST" > "$MACHINE_MANIFEST"

# The same machine as the chart rendered it before this change: the guest's
# declared filter taken away, so the kubelet supplies one. The two lines go
# together and only where the value is the guest's, which is checked rather than
# assumed - a sed that quietly matched nothing would turn this whole section into
# an assertion that passes for no reason.
sed -e '/^ *seccompProfile:$/{N;/type: "Unconfined"/d;}' \
  "$MACHINE_MANIFEST" > "$DEFECTIVE_MANIFEST"
# Four filters left, and none of them the guest's: the four preparation steps
# declare RuntimeDefault, and the guest is the only container in this manifest
# that declares Unconfined. Checked by shape rather than by counting the word,
# because the guest declares an access-control profile that is Unconfined as
# well.
#
# The number is spelled out rather than derived, so that a step added without a
# declared filter fails here instead of being absorbed into the count.
[[ "$(grep --count '^ *seccompProfile:$' "$DEFECTIVE_MANIFEST" || true)" -eq 4 ]] \
  || fail "removing the guest's filter removed the wrong number of filters"
if grep --after-context=1 '^ *seccompProfile:$' "$DEFECTIVE_MANIFEST" | grep --quiet 'Unconfined'; then
  fail "the guest's declared filter was not removed, so the defect case is not the defect"
fi
# That access-control profile stays. It is not what is under test here, and on a
# node where AppArmor is supported, taking it away would stop this machine at the
# first mount instead of at the root change - the wrong failure entirely.
grep --quiet 'appArmorProfile:' "$DEFECTIVE_MANIFEST" \
  || fail "the guest's access-control profile was removed too, which would fail the machine for another reason"
pass "the machine renders in both shapes: one declaring its filter and one leaving it to the cluster"

step "starting the machine that leaves its filter to the cluster"
kc apply --filename "$DEFECTIVE_MANIFEST" >/dev/null
failed_at_root_change=0
for _ in $(seq 1 90); do
  if [[ "$(kc get pod defect-web-0 --output \
      "jsonpath={.status.containerStatuses[?(@.name=='guest')].ready}" 2>/dev/null)" == "true" ]]; then
    fail "the machine started, so this cluster does not reproduce the defect"
  fi
  if kc logs defect-web-0 --container guest --tail 40 2>/dev/null \
      | grep --quiet "could not make /mnt/rootfs the machine's root"; then
    failed_at_root_change=1
    break
  fi
  sleep 5
done
[[ "$failed_at_root_change" -eq 1 ]] \
  || fail "the machine neither started nor failed at the root change within the time allowed"
pass "the machine seeded its volume and then failed at the root change"
if kc logs defect-web-0 --container guest --tail 40 2>/dev/null | grep --quiet "pivot_root"; then
  pass "the failure names pivot_root, which is the call the default profile withholds"
else
  fail "the machine failed for some other reason than the root change"
fi

step "declaring the filter on the same machine, on the same volume"
kc apply --filename "$MACHINE_MANIFEST" >/dev/null
kc delete pod defect-web-0 --wait >/dev/null 2>&1 || true
wait_ready defect-web-0 \
  || fail "the machine did not start once its filter was declared"
pass "the same machine, on the volume it had already seeded, started once it declared its filter"
check "its own init is process 1" \
  kc exec defect-web-0 --container guest -- \
    sh -c '[ "$(cat /proc/1/comm)" != "boot.sh" ] && [ "$(cat /proc/1/comm)" != "bash" ]'
check "its root is the volume, so the root change happened" \
  kc exec defect-web-0 --container guest -- test ! -d /mnt/rootfs
# Taken down before the machine whose shutdown is timed below is installed. One
# kind node runs both otherwise, and a shutdown measured against a 120s grace
# period is exactly the assertion that gets flaky under load.
kc delete --filename "$MACHINE_MANIFEST" --wait >/dev/null

# ------------------------------------------------------ the machine, on it ---

step "installing a machine on the cluster that filters by default"
helm --kube-context "$CONTEXT" upgrade --install oci "$CHART" \
  --namespace "$NAMESPACE" \
  --values test/integration/oci.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --set "machines.web.source.reference=$SOURCE_REFERENCE" \
  --wait --timeout 5m >/dev/null
wait_ready oci-web-0
pass "the machine started on a cluster whose kubelet filters by default"

guest() { kc exec oci-web-0 --container guest -- "$@"; }
check "the machine's own init is process 1" \
  guest sh -c '[ "$(cat /proc/1/comm)" != "boot.sh" ] && [ "$(cat /proc/1/comm)" != "bash" ]'
check "the machine's root is the volume, so the root change happened" \
  guest test ! -d /mnt/rootfs

step "asserting the machine can make the call the shipped profile denies, before it names one"
# The first half of a pair. A forced unmount needs CAP_SYS_ADMIN, which this mode
# grants, so once the machine names the profile the only thing left that can stop
# the call is the filter. Without this half, the assertion after the upgrade would
# hold just as well if the machine had lost the capability instead.
forced_unmount() {
  local path="$1"
  guest sh -c "mkdir -p $path && mount -t tmpfs none $path && umount --force $path"
}
if forced_unmount /mnt/sp-force-allowed >/dev/null 2>&1; then
  pass "unconfined, the machine forces a mount away, which is the call the profile will deny"
else
  fail "the machine could not force a mount away even unconfined, so denying it later would prove nothing"
fi

step "asserting the filter each container declared is the one the chart chose"
guest_filter="$(kc get pod oci-web-0 --output \
  "jsonpath={.spec.containers[?(@.name=='guest')].securityContext.seccompProfile.type}")"
[[ "$guest_filter" == "Unconfined" ]] \
  || fail "the guest declared '${guest_filter:-nothing}' rather than Unconfined"
pass "the guest declared Unconfined"
init_filters="$(kc get pod oci-web-0 --output \
  "jsonpath={.spec.initContainers[*].securityContext.seccompProfile.type}")"
[[ "$init_filters" == "RuntimeDefault RuntimeDefault RuntimeDefault" ]] \
  || fail "the preparation steps declared '${init_filters:-nothing}'"
pass "every preparation step declared the runtime's default filter"
# They ran to completion under it, which is the assertion that the default
# profile withholds nothing an unpack, a write or an HTTPS fetch needs.
init_exits="$(kc get pod oci-web-0 --output \
  "jsonpath={.status.initContainerStatuses[*].state.terminated.exitCode}")"
[[ "$init_exits" == "0 0 0" ]] \
  || fail "a preparation step under the default filter exited with '${init_exits:-nothing}'"
pass "every preparation step succeeded under the runtime's default filter"

# --------------------------------------------------- the profile it ships ---
step "what the shipped profile denies"
named="$(cat <<EOF
        seccompProfile:
          type: Localhost
          localhostProfile: $PROFILE_PATH
EOF
)"
confined="$(run_probe named-profile "$named")"
expect "$confined" seccomp_mode 2 \
  "the shipped profile is valid, and the kubelet loaded it"
# Each denial is paired with the same call made under no profile at all. Without
# that pair the assertion above could hold because the call is refused for some
# other reason entirely, and would keep holding if the profile stopped being
# applied.
for call in kexec_load open_by_handle_at init_module finit_module delete_module; do
  expect "$confined" "$call" EPERM "the shipped profile denies $call"
  expect_not "$unconfined" "$call" EPERM \
    "$call is not denied without the profile, so the assertion above can fail" \
    "a node with kernel.modules_disabled or kernel.kexec_load_disabled set refuses these calls in the kernel, which is indistinguishable from a filter here"
done
expect "$confined" umount2_force EPERM "the shipped profile denies a forced unmount"
expect "$confined" umount2_plain ENOENT \
  "it denies the forced unmount by its argument, leaving an ordinary unmount alone"
expect "$confined" getpid ok "everything the profile does not name is allowed"
expect "$confined" pivot_root ENOENT \
  "the root change is permitted, which is what makes this profile usable by a machine"

# ------------------------------------------- a machine that names it ---
step "upgrading the machine to name the shipped profile"
helm --kube-context "$CONTEXT" upgrade oci "$CHART" \
  --namespace "$NAMESPACE" \
  --values test/integration/oci.yaml \
  --set "shim.image=$SHIM_IMAGE" \
  --set "machines.web.source.reference=$SOURCE_REFERENCE" \
  --set "machines.web.security.seccompProfile.type=Localhost" \
  --set "machines.web.security.seccompProfile.localhostProfile=$PROFILE_PATH" \
  --wait --timeout 5m >/dev/null
wait_ready oci-web-0
pass "the machine came back up naming the profile"
named_filter="$(kc get pod oci-web-0 --output \
  "jsonpath={.spec.containers[?(@.name=='guest')].securityContext.seccompProfile.localhostProfile}")"
[[ "$named_filter" == "$PROFILE_PATH" ]] \
  || fail "the guest named '${named_filter:-nothing}' rather than $PROFILE_PATH"
pass "the guest names the profile the machine asked for"

# The machine here runs `privileged`, because that is the only mode a kind node
# supports. This assertion used to say the opposite: the mode rendered a
# privileged container, containerd drops the profile a privileged container names
# before it builds one, and the machine ran unfiltered despite naming a profile.
# The mode renders a capability set now, so there is nothing left telling the
# runtime to withhold the filter, and the reference the machine sends is the
# filter it gets. That is half the reason the mode was changed, and this is where
# it is checked.
step "asserting the machine runs under the filter it named"
machine_mode="$(guest sh -c 'awk "/^Seccomp:/ {print \$2}" /proc/1/status' | tr -d '\r')"
if [[ "$machine_mode" == "2" ]]; then
  pass "the machine's own init reports a loaded filter, which a privileged container never got"
else
  fail "the machine reports seccomp mode ${machine_mode:-nothing}; one naming a profile must report 2"
fi

# The second half of the pair made before the upgrade, on the same machine and
# the same volume. The capability has not changed; only the profile has.
if forced_unmount /mnt/sp-force-denied >/dev/null 2>&1; then
  fail "the machine forced a mount away under a profile that denies it, so the filter is not reaching it"
else
  pass "the same forced unmount is refused under the profile, by the filter and not by the capability set"
fi
# An ordinary unmount is what the profile leaves alone, so it is also the cleanup.
guest sh -c 'umount /mnt/sp-force-denied' >/dev/null 2>&1 || true

step "asserting the machine still shuts down rather than being killed"
started="$(date +%s)"
kc delete pod oci-web-0 --wait >/dev/null
elapsed=$(( $(date +%s) - started ))
if [[ "$elapsed" -lt 100 ]]; then
  pass "the machine stopped in ${elapsed}s, well inside the 120s grace period"
else
  fail "the machine took ${elapsed}s to stop, which means it was killed rather than asked"
fi
wait_ready oci-web-0
pass "the machine booted again under the same values"

echo
echo "every seccomp assertion held"
