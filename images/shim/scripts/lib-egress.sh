# shellcheck shell=bash
#
# The packet-filter half of a machine's egress policy.
#
# The proxy beside the machine decides every TCP connection, and this is what
# makes the machine's TCP arrive at the proxy in the first place. It is also
# what makes `deny` mean deny: Envoy is given TCP and nothing else, so a policy
# that stopped here would be one a machine could step around with a UDP socket.
#
# Nothing here interpolates a value into a shell command. Every address and port
# reaches iptables as an argument, read from a file the chart rendered or from
# the environment, so a value in a values file is never parsed as shell.
#
# Everything is programmed into chains of this file's own, created-or-emptied
# rather than created. A pod's network namespace outlives a restart of the
# container that programmed it, so a step that could only ever create would fail
# for good the second time it ran - and the second time is exactly when something
# has already gone wrong once.

# Where the chart writes the rules this script enforces itself, one per line.
SP_EGRESS_DIR_DEFAULT="/etc/stateful-pods/egress"

# The chains the policy lives in, named so that they can be read and so that
# nothing here touches a rule somebody else put in OUTPUT.
SP_EGRESS_CHAIN="SP_EGRESS"

# How long to wait for the namespace's xtables lock. Without it a concurrent
# holder makes iptables exit rather than queue, and this runs while the kubelet
# and the CNI may be touching the same namespace.
SP_EGRESS_LOCK_WAIT="${SP_EGRESS_LOCK_WAIT:-10}"

# sp_egress_ipv4 <args...>
# Every rule is applied with a message of its own when it fails, because a
# partially programmed namespace is a machine with a policy nobody can describe.
sp_egress_ipv4() {
    iptables --wait "$SP_EGRESS_LOCK_WAIT" "$@" \
        || sp_die "machine ${SP_MACHINE:-?}: could not apply an egress rule ($*). The machine has not been started. This container holds NET_ADMIN and nothing else does, so this is a node or a runtime that refuses the capability, or a kernel without the module the rule needs."
}

sp_egress_ipv6() {
    ip6tables --wait "$SP_EGRESS_LOCK_WAIT" "$@" \
        || sp_die "machine ${SP_MACHINE:-?}: could not apply an IPv6 egress rule ($*). The machine has not been started."
}

# sp_egress_chain <iptables command> <table>
# The chain, empty, whether or not it was there before.
sp_egress_chain() {
    if ! "$1" --wait "$SP_EGRESS_LOCK_WAIT" -t "$2" -N "$SP_EGRESS_CHAIN" 2>/dev/null; then
        "$1" --wait "$SP_EGRESS_LOCK_WAIT" -t "$2" -F "$SP_EGRESS_CHAIN" \
            || sp_die "machine ${SP_MACHINE:-?}: the $2 chain $SP_EGRESS_CHAIN exists and could not be emptied. The machine has not been started."
        sp_log "machine ${SP_MACHINE:-?}: the $2 chain $SP_EGRESS_CHAIN was already there and has been emptied; this namespace has been programmed before"
    fi
}

# sp_egress_jump <iptables command> <table> <match args...>
# One jump from OUTPUT into our chain, added only if it is not already there.
sp_egress_jump() {
    _sp_command="$1"
    _sp_table="$2"
    shift 2
    if ! "$_sp_command" --wait "$SP_EGRESS_LOCK_WAIT" -t "$_sp_table" \
        -C OUTPUT "$@" -j "$SP_EGRESS_CHAIN" 2>/dev/null; then
        "$_sp_command" --wait "$SP_EGRESS_LOCK_WAIT" -t "$_sp_table" \
            -A OUTPUT "$@" -j "$SP_EGRESS_CHAIN" \
            || sp_die "machine ${SP_MACHINE:-?}: could not send this namespace's outbound traffic into $SP_EGRESS_CHAIN. The machine has not been started."
    fi
}

# The IPv4 resolvers the kubelet gave this pod.
#
# They matter twice, which is why they are read in one place. A rule written as a
# name needs a resolver, so a policy that dropped DNS would be one whose every
# name-based rule silently failed - which is the class of outcome this whole
# capability exists to prevent.
sp_egress_resolvers() {
    while read -r _sp_keyword _sp_address _sp_rest; do
        [ "$_sp_keyword" = "nameserver" ] || continue
        case "$_sp_address" in
            *:*) continue ;;
        esac
        printf '%s\n' "$_sp_address"
    done < /etc/resolv.conf
}

# The redirect: the machine's outbound TCP, into the proxy.
#
# DNS over TCP is kept out of it. A resolver falls back to TCP whenever an answer
# does not fit in a UDP datagram, and a redirected DNS/TCP connection matches no
# rule - a policy would then work for short answers and fail for long ones, which
# is the worst shape a failure can have.
#
# The proxy's own connections are exempted by the user it runs as. That is also
# the policy's boundary, and values.yaml names it: nothing in a shared network
# namespace can tell the proxy's traffic from a process inside the machine
# running as the same user, so a machine's own root steps around every rule with
# one setpriv. The policy governs the machine's software, not its root.
sp_egress_redirect() {
    sp_egress_chain iptables nat
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" \
        -m owner --uid-owner "$SP_EGRESS_PROXY_USER" -j RETURN
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" -d 127.0.0.0/8 -j RETURN
    for _sp_resolver in $(sp_egress_resolvers); do
        sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" \
            -p tcp -d "$_sp_resolver" --dport 53 -j RETURN
        sp_log "machine ${SP_MACHINE:-?}: DNS over TCP to $_sp_resolver goes straight out, because a truncated answer is retried that way"
    done
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" \
        -p tcp -j REDIRECT --to-ports "$SP_EGRESS_PROXY_PORT"
    sp_egress_jump iptables nat -p tcp
    sp_log "machine ${SP_MACHINE:-?}: outbound TCP is redirected to the proxy on port $SP_EGRESS_PROXY_PORT"
}

# The rules the chart rendered for what the proxy cannot see: one "<cidr> <port>"
# per line.
sp_egress_allow_udp() {
    _sp_file="${SP_EGRESS_DIR:-$SP_EGRESS_DIR_DEFAULT}/udp-allow"
    [ -f "$_sp_file" ] || return 0
    while read -r _sp_cidr _sp_port _sp_rest; do
        [ -n "$_sp_cidr" ] || continue
        sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" \
            -p udp -d "$_sp_cidr" --dport "$_sp_port" -j ACCEPT
        sp_log "machine ${SP_MACHINE:-?}: UDP to $_sp_cidr port $_sp_port is allowed"
    done < "$_sp_file"
}

# What `deny` has to cover that a proxy cannot.
#
# TCP is accepted here because the table above has already decided it: a packet
# reaching this point is either on its way to the proxy, or the proxy's own, or
# DNS over TCP that was deliberately let past.
sp_egress_deny_the_rest() {
    sp_egress_chain iptables filter
    sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" -o lo -j ACCEPT
    sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" -p tcp -j ACCEPT
    sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    _sp_found=0
    for _sp_resolver in $(sp_egress_resolvers); do
        sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" \
            -p udp -d "$_sp_resolver" --dport 53 -j ACCEPT
        _sp_found=$((_sp_found + 1))
        sp_log "machine ${SP_MACHINE:-?}: the resolver at $_sp_resolver is allowed, because a rule written as a name needs one"
    done
    if [ "$_sp_found" -eq 0 ]; then
        sp_log "machine ${SP_MACHINE:-?}: this pod has no IPv4 resolver in /etc/resolv.conf, so none was allowed. Every rule written as a name will fail to match."
    fi
    sp_egress_allow_udp
    sp_egress_ipv4 -A "$SP_EGRESS_CHAIN" -j DROP
    sp_egress_jump iptables filter

    # IPv6 is not proxied, so under a default of deny it is dropped rather than
    # left as the one way out of a policy. values.yaml says so at the input.
    if ip6tables --wait "$SP_EGRESS_LOCK_WAIT" -L OUTPUT >/dev/null 2>&1; then
        sp_egress_chain ip6tables filter
        sp_egress_ipv6 -A "$SP_EGRESS_CHAIN" -o lo -j ACCEPT
        sp_egress_ipv6 -A "$SP_EGRESS_CHAIN" \
            -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        sp_egress_ipv6 -A "$SP_EGRESS_CHAIN" -j DROP
        sp_egress_jump ip6tables filter
        sp_log "machine ${SP_MACHINE:-?}: IPv6 egress is dropped; it is not proxied, and under a default of deny it cannot be the way out"
    else
        sp_log "machine ${SP_MACHINE:-?}: this node has no IPv6 filter table, so there was nothing to drop"
    fi
    sp_log "machine ${SP_MACHINE:-?}: everything the proxy cannot see is dropped, except the resolver and the rules that named it"
}

# That the proxy is actually listening before anything is redirected to it.
#
# Kubernetes starts a sidecar and waits for it before running the next init
# container, but "started" is not "listening": a container is started the moment
# its process exists. Traffic redirected to a port nothing is bound to is traffic
# refused, so the machine's very first connections would fail for a reason
# nothing in its policy describes.
#
# A connection to the proxy's own listener, and nothing more. The proxy has no
# administration interface at all - an endpoint on the loopback address would be
# reachable from inside the machine, where `/quitquitquit` would stop the policy
# and `/config_dump` would read it - so what is available to ask is whether the
# socket is bound, which is exactly the question.
sp_egress_wait_for_proxy() {
    _sp_attempt=0
    while [ "$_sp_attempt" -lt "${SP_EGRESS_PROXY_ATTEMPTS:-60}" ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$SP_EGRESS_PROXY_PORT") 2>/dev/null; then
            sp_log "machine ${SP_MACHINE:-?}: the egress proxy is listening, so the redirect has somewhere to go"
            return 0
        fi
        _sp_attempt=$((_sp_attempt + 1))
        sleep 1
    done
    sp_die "machine ${SP_MACHINE:-?}: the egress proxy is not listening on port $SP_EGRESS_PROXY_PORT after ${SP_EGRESS_PROXY_ATTEMPTS:-60} seconds, so nothing was redirected to it and the machine has not been started. Read its own output: kubectl logs <pod> --container envoy. A proxy that will not start is almost always a configuration it refused, and it says which line."
}

sp_egress_apply() {
    sp_egress_wait_for_proxy
    sp_egress_redirect
    case "${SP_EGRESS_DEFAULT:-deny}" in
        deny)
            sp_egress_deny_the_rest
            ;;
        allow)
            sp_log "machine ${SP_MACHINE:-?}: the default is allow, so nothing the proxy cannot see is filtered. The rules decide TCP and nothing else."
            ;;
        *)
            sp_die "machine ${SP_MACHINE:-?}: ${SP_EGRESS_DEFAULT:-} is not an egress default this image implements. The chart refuses an unknown one while it renders, so reaching here means the chart and this image are different versions of themselves."
            ;;
    esac
    return 0
}
