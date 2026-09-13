#!/usr/bin/env bats
#
# Programming a machine's network namespace so that its outbound traffic meets
# the policy its values describe.
#
# The proxy decides TCP; this decides everything else, and it is what makes
# `deny` mean deny. The cases worth having are the ones that would leave a
# policy looking applied and not applied: redirecting to a proxy that is not
# listening yet, dropping the resolver every name-based rule depends on, or
# leaving UDP open under a default that says it is closed.
#
# iptables and curl are stubbed. What is asserted is which rules this library
# programs, in which order, because that is the whole of its behaviour.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    EGRESS_DIR="$(mktemp -d)"
    CONTROL="$(mktemp -d)"
    BIN="$(mktemp -d)"
    export SP_MACHINE=web
    export SP_EGRESS_DIR="$EGRESS_DIR"
    export SP_EGRESS_PROXY_PORT=15001
    export SP_EGRESS_ADMIN_PORT=15000
    export SP_EGRESS_PROXY_USER=1337
    export SP_EGRESS_DEFAULT=deny
    export SP_EGRESS_PROXY_ATTEMPTS=3
    export SP_TEST_CONTROL="$CONTROL"
    printf '0\n' > "$CONTROL/ready-after"
    printf '0\n' > "$CONTROL/curl-calls"
    : > "$CONTROL/rules"
    : > "$CONTROL/rules6"
    printf '0\n' > "$CONTROL/iptables-fail-at"
    given_stubs
    PATH="$BIN:$PATH"
    export PATH
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-state.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-seed.sh"
    # shellcheck disable=SC1090
    . "$SCRIPTS/lib-egress.sh"
}

teardown() { rm -rf "$EGRESS_DIR" "$CONTROL" "$BIN"; }

given_stubs() {
    cat > "$BIN/iptables" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SP_TEST_CONTROL/rules"
fail_at="$(cat "$SP_TEST_CONTROL/iptables-fail-at")"
if [ "$fail_at" != "0" ] && [ "$(wc -l < "$SP_TEST_CONTROL/rules")" = "$fail_at" ]; then
    echo "iptables: refused" >&2
    exit 1
fi
STUB
    cat > "$BIN/ip6tables" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SP_TEST_CONTROL/rules6"
STUB
    # The proxy answers /ready only after the configured number of attempts, so
    # that the wait is exercised rather than stubbed away.
    cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
calls="$(cat "$SP_TEST_CONTROL/curl-calls")"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$SP_TEST_CONTROL/curl-calls"
printf 'curl %s\n' "$*" >> "$SP_TEST_CONTROL/rules"
after="$(cat "$SP_TEST_CONTROL/ready-after")"
[ "$calls" -gt "$after" ] || exit 22
STUB
    chmod 0755 "$BIN/iptables" "$BIN/ip6tables" "$BIN/curl"
}

rules() { cat "$CONTROL/rules"; }
resolvers() { awk '/^nameserver/ && $2 !~ /:/ {print $2}' /etc/resolv.conf; }

# ------------------------------------------------------------------ the wait ---

# Kubernetes starts a sidecar and waits for it before the next init container,
# but "started" is not "listening". Traffic redirected to a port nothing is bound
# to is traffic refused, so the machine's very first connections would fail for a
# reason nothing in its policy describes.
@test "it waits for the proxy to answer before redirecting anything to it" {
    printf '2\n' > "$CONTROL/ready-after"
    run sp_egress_apply
    [ "$status" -eq 0 ]
    [ "$(cat "$CONTROL/curl-calls")" -eq 3 ]
    first_rule="$(grep -n -v '^curl ' "$CONTROL/rules" | head -n 1 | cut -d: -f1)"
    last_curl="$(grep -n '^curl ' "$CONTROL/rules" | tail -n 1 | cut -d: -f1)"
    [ "$first_rule" -gt "$last_curl" ]
}

@test "a proxy that never answers stops the machine, and says where to look" {
    printf '99\n' > "$CONTROL/ready-after"
    run sp_egress_apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"--container envoy"* ]]
    # Nothing was programmed, so the namespace is not half a policy.
    ! grep -q -v '^curl ' "$CONTROL/rules"
}

# -------------------------------------------------------------- the redirect ---

@test "it redirects the machine's outbound TCP into the proxy" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-t nat -A SP_EGRESS -p tcp -j REDIRECT --to-ports 15001' "$CONTROL/rules"
    grep -q -- '-t nat -A OUTPUT -p tcp -j SP_EGRESS' "$CONTROL/rules"
}

@test "it exempts the proxy's own traffic, or the proxy would redirect to itself" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    exempt="$(grep -n -- '--uid-owner 1337 -j RETURN' "$CONTROL/rules" | cut -d: -f1)"
    redirect="$(grep -n -- '-j REDIRECT' "$CONTROL/rules" | cut -d: -f1)"
    [ -n "$exempt" ]
    [ "$exempt" -lt "$redirect" ]
}

@test "it leaves the loopback address alone" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-d 127.0.0.0/8 -j RETURN' "$CONTROL/rules"
}

# ------------------------------------------------ what the proxy cannot see ---

@test "a default of deny drops everything the proxy does not decide" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '-A OUTPUT -j DROP' "$CONTROL/rules")" -eq 1 ]
    # TCP is accepted here because the proxy has already decided it: the
    # redirect is in the nat table, which runs first.
    grep -q -- '-A OUTPUT -p tcp -j ACCEPT' "$CONTROL/rules"
}

@test "the drop is the last rule, or everything after it would be unreachable" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    drop="$(grep -n -- '-A OUTPUT -j DROP' "$CONTROL/rules" | cut -d: -f1)"
    last="$(grep -c -v '^$' "$CONTROL/rules")"
    [ "$drop" -eq "$last" ]
}

# The resolver is allowed automatically and is not a rule anyone writes. A
# machine that cannot resolve a name cannot reach deb.debian.org however many
# rules name it, so a policy that dropped DNS would be one whose every
# name-based rule silently failed.
@test "the pod's own resolver is allowed without a rule" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    for nameserver in $(resolvers); do
        grep -q -- "-A OUTPUT -p udp -d $nameserver --dport 53 -j ACCEPT" "$CONTROL/rules"
    done
    [ -n "$(resolvers)" ]
}

@test "the resolver is allowed before the drop" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    allow="$(grep -n -- '--dport 53 -j ACCEPT' "$CONTROL/rules" | head -n 1 | cut -d: -f1)"
    drop="$(grep -n -- '-A OUTPUT -j DROP' "$CONTROL/rules" | cut -d: -f1)"
    [ "$allow" -lt "$drop" ]
}

@test "the rules the chart rendered for UDP are applied" {
    printf '10.0.0.0/8 123\n10.96.0.10/32 53\n' > "$EGRESS_DIR/udp-allow"
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-A OUTPUT -p udp -d 10.0.0.0/8 --dport 123 -j ACCEPT' "$CONTROL/rules"
    grep -q -- '-A OUTPUT -p udp -d 10.96.0.10/32 --dport 53 -j ACCEPT' "$CONTROL/rules"
}

@test "IPv6 is dropped, because it is not proxied and cannot be the way out" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-A OUTPUT -j DROP' "$CONTROL/rules6"
}

# --------------------------------------------------------------- the default ---

@test "a default of allow filters nothing beyond the redirect" {
    export SP_EGRESS_DEFAULT=allow
    run sp_egress_apply
    [ "$status" -eq 0 ]
    ! grep -q -- '-A OUTPUT -j DROP' "$CONTROL/rules"
    ! grep -q -- '-A OUTPUT -j DROP' "$CONTROL/rules6"
    grep -q -- '-j REDIRECT --to-ports 15001' "$CONTROL/rules"
}

@test "a default this image does not implement stops the machine" {
    export SP_EGRESS_DEFAULT=audit
    run sp_egress_apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"audit is not an egress default"* ]]
}

# ------------------------------------------------------------- the failures ---

# A namespace programmed half way is a machine with a policy nobody can
# describe, so a refused rule stops the machine rather than being logged.
@test "a rule the node refuses stops the machine, naming the rule" {
    printf '3\n' > "$CONTROL/iptables-fail-at"
    run sp_egress_apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not apply an egress rule"* ]]
    [[ "$output" == *"NET_ADMIN"* ]]
}
