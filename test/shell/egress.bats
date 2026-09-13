#!/usr/bin/env bats
#
# Programming a machine's network namespace so that its outbound traffic meets
# the policy its values describe.
#
# The proxy decides TCP; this decides everything else, and it is what makes
# `deny` mean deny. The cases worth having are the ones that would leave a
# policy looking applied and not applied: redirecting to a proxy that is not
# listening yet, dropping the resolver every name-based rule depends on, sending
# a truncated DNS answer's retry into a proxy that has no rule for it, or failing
# for good the second time the step runs.
#
# iptables is stubbed. What is asserted is which rules this library programs, in
# which order, because that is the whole of its behaviour. The wait for the proxy
# is not stubbed: it opens a connection, so the suite makes something listen.

setup() {
    SCRIPTS="${BATS_TEST_DIRNAME}/../../images/shim/scripts"
    EGRESS_DIR="$(mktemp -d)"
    CONTROL="$(mktemp -d)"
    BIN="$(mktemp -d)"
    LISTENER=""
    export SP_MACHINE=web
    export SP_EGRESS_DIR="$EGRESS_DIR"
    export SP_EGRESS_PROXY_USER=1337
    export SP_EGRESS_DEFAULT=deny
    export SP_EGRESS_PROXY_ATTEMPTS=2
    export SP_TEST_CONTROL="$CONTROL"
    : > "$CONTROL/rules"
    : > "$CONTROL/rules6"
    : > "$CONTROL/chains"
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
    given_a_listening_proxy
}

teardown() {
    [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null || true
    rm -rf "$EGRESS_DIR" "$CONTROL" "$BIN"
}

# Something on the port the redirect points at. The wait is a connection, so a
# stub would be testing the stub; this is the smallest real listener there is.
#
# `-k` keeps it listening after the first connection, which the cases that run
# the step twice need: a listener that served one connection and exited would
# make the second run fail for a reason that has nothing to do with what it is
# testing.
given_a_listening_proxy() {
    local port=15001
    while true; do
        nc -l -k -p "$port" >/dev/null 2>&1 &
        LISTENER=$!
        sleep 0.2
        if kill -0 "$LISTENER" 2>/dev/null; then break; fi
        port=$((port + 1))
        [ "$port" -lt 15100 ] || return 1
    done
    export SP_EGRESS_PROXY_PORT="$port"
}

given_stubs() {
    cat > "$BIN/iptables" <<'STUB'
#!/usr/bin/env bash
argv="$*"
printf '%s\n' "$argv" >> "$SP_TEST_CONTROL/rules"
case "$argv" in
    *" -N "*)
        # A chain can be created once. The second attempt is what a restarted
        # step meets, and it has to be survivable.
        chain="${argv##* -N }"
        if grep -q -x "$chain" "$SP_TEST_CONTROL/chains" 2>/dev/null; then
            echo "iptables: Chain already exists." >&2
            exit 1
        fi
        printf '%s\n' "$chain" >> "$SP_TEST_CONTROL/chains"
        ;;
    *" -C "*)
        # Nothing is ever already there, unless a previous run put it there.
        grep -q -x -- "${argv/ -C / -A }" "$SP_TEST_CONTROL/applied" 2>/dev/null || exit 1
        ;;
    *" -A "*)
        printf '%s\n' "$argv" >> "$SP_TEST_CONTROL/applied"
        ;;
esac
fail_at="$(cat "$SP_TEST_CONTROL/iptables-fail-at")"
if [ "$fail_at" != "0" ] && [ "$(wc -l < "$SP_TEST_CONTROL/rules")" = "$fail_at" ]; then
    echo "iptables: refused" >&2
    exit 1
fi
STUB
    cat > "$BIN/ip6tables" <<'STUB'
#!/usr/bin/env bash
argv="$*"
printf '%s\n' "$argv" >> "$SP_TEST_CONTROL/rules6"
case "$argv" in
    *" -N "*)
        chain="${argv##* -N }"
        if grep -q -x "6$chain" "$SP_TEST_CONTROL/chains" 2>/dev/null; then
            echo "ip6tables: Chain already exists." >&2
            exit 1
        fi
        printf '6%s\n' "$chain" >> "$SP_TEST_CONTROL/chains"
        ;;
    *" -C "*) exit 1 ;;
esac
STUB
    chmod 0755 "$BIN/iptables" "$BIN/ip6tables"
}

rules() { cat "$CONTROL/rules"; }
resolvers() { awk '/^nameserver/ && $2 !~ /:/ {print $2}' /etc/resolv.conf; }

# ------------------------------------------------------------------ the wait ---

# Kubernetes starts a sidecar and waits for it before the next init container,
# but "started" is not "listening". Traffic redirected to a port nothing is bound
# to is traffic refused, so the machine's very first connections would fail for a
# reason nothing in its policy describes.
@test "it waits for the proxy to be listening before redirecting anything to it" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-j REDIRECT' "$CONTROL/rules"
}

@test "a proxy that is not listening stops the machine, and says where to look" {
    export SP_EGRESS_PROXY_PORT=15199
    run sp_egress_apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"--container envoy"* ]]
    # Nothing was programmed, so the namespace is not half a policy.
    [ ! -s "$CONTROL/rules" ]
}

@test "it asks the proxy nothing but whether it is listening" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    # No administration interface is contacted, because there is none: one on
    # the loopback address would be reachable from inside the machine.
    ! grep -q '15000' "$CONTROL/rules"
}

# -------------------------------------------------------------- the redirect ---

@test "it redirects the machine's outbound TCP into the proxy" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- "-t nat -A SP_EGRESS -p tcp -j REDIRECT --to-ports $SP_EGRESS_PROXY_PORT" "$CONTROL/rules"
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

# A resolver retries over TCP whenever an answer does not fit in a datagram. A
# redirected DNS/TCP connection matches no rule, so without this a policy would
# work for short answers and fail for long ones - which is the worst shape a
# failure can have, and exactly the silent kind this capability exists to stop.
@test "DNS over TCP to the pod's resolver is kept out of the redirect" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    for nameserver in $(resolvers); do
        exempt="$(grep -n -- "-t nat -A SP_EGRESS -p tcp -d $nameserver --dport 53 -j RETURN" \
          "$CONTROL/rules" | cut -d: -f1)"
        [ -n "$exempt" ]
        redirect="$(grep -n -- '-j REDIRECT' "$CONTROL/rules" | cut -d: -f1)"
        [ "$exempt" -lt "$redirect" ]
    done
    [ -n "$(resolvers)" ]
}

# ------------------------------------------------ what the proxy cannot see ---

@test "a default of deny drops everything the proxy does not decide" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '-A SP_EGRESS -j DROP' "$CONTROL/rules")" -eq 1 ]
    # TCP is accepted here because the nat table has already decided it.
    grep -q -- '-A SP_EGRESS -p tcp -j ACCEPT' "$CONTROL/rules"
    grep -q -- '-A OUTPUT -j SP_EGRESS' "$CONTROL/rules"
}

@test "the drop is the last rule in the chain, or the rest would be unreachable" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    drop="$(grep -n -- '-A SP_EGRESS -j DROP' "$CONTROL/rules" | cut -d: -f1)"
    last_accept="$(grep -n -- '-A SP_EGRESS .*-j ACCEPT' "$CONTROL/rules" | tail -n 1 | cut -d: -f1)"
    [ "$drop" -gt "$last_accept" ]
}

@test "the pod's own resolver is allowed without a rule" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    for nameserver in $(resolvers); do
        grep -q -- "-A SP_EGRESS -p udp -d $nameserver --dport 53 -j ACCEPT" "$CONTROL/rules"
    done
    [ -n "$(resolvers)" ]
}

@test "the rules the chart rendered for UDP are applied" {
    printf '10.0.0.0/8 123\n10.96.0.10/32 53\n' > "$EGRESS_DIR/udp-allow"
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-A SP_EGRESS -p udp -d 10.0.0.0/8 --dport 123 -j ACCEPT' "$CONTROL/rules"
    grep -q -- '-A SP_EGRESS -p udp -d 10.96.0.10/32 --dport 53 -j ACCEPT' "$CONTROL/rules"
}

@test "IPv6 is dropped, because it is not proxied and cannot be the way out" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    grep -q -- '-A SP_EGRESS -j DROP' "$CONTROL/rules6"
    grep -q -- '-A OUTPUT -j SP_EGRESS' "$CONTROL/rules6"
}

# --------------------------------------------------------------- the default ---

@test "a default of allow filters nothing beyond the redirect" {
    export SP_EGRESS_DEFAULT=allow
    run sp_egress_apply
    [ "$status" -eq 0 ]
    ! grep -q -- '-j DROP' "$CONTROL/rules"
    ! grep -q -- '-j DROP' "$CONTROL/rules6"
    grep -q -- '-j REDIRECT' "$CONTROL/rules"
}

@test "a default this image does not implement stops the machine" {
    export SP_EGRESS_DEFAULT=audit
    run sp_egress_apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"audit is not an egress default"* ]]
}

# ------------------------------------------------------------ running twice ---

# A pod's network namespace outlives a restart of the container that programmed
# it. A step that could only ever create its chain would fail for good the second
# time it ran - and the second time is exactly when something has already gone
# wrong once.
@test "it can be run twice, because a restarted step meets its own chain" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    run sp_egress_apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"has been emptied"* ]]
}

@test "running twice does not double the jump from OUTPUT" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    run sp_egress_apply
    [ "$status" -eq 0 ]
    [ "$(grep -c -- '-t nat -A OUTPUT -p tcp -j SP_EGRESS' "$CONTROL/rules")" -eq 1 ]
}

@test "it waits for the namespace's lock rather than exiting when someone holds it" {
    run sp_egress_apply
    [ "$status" -eq 0 ]
    ! grep -q -v -- '--wait' "$CONTROL/rules"
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
