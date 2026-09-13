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

# Where the chart writes the rules this script enforces itself, one per line.
SP_EGRESS_DIR_DEFAULT="/etc/stateful-pods/egress"

# The chain the redirect lives in, named so that it can be read and so that
# nothing here touches a rule somebody else put in OUTPUT.
SP_EGRESS_CHAIN="SP_EGRESS"

# sp_egress_ipv4 <args...>
# Every rule is applied with a message of its own when it fails, because a
# partially programmed namespace is a machine with a policy nobody can describe.
sp_egress_ipv4() {
    iptables "$@" \
        || sp_die "machine ${SP_MACHINE:-?}: could not apply an egress rule ($*). The machine has not been started, and its namespace may be half programmed. This container holds NET_ADMIN and nothing else does, so this is a node or a runtime that refuses the capability rather than a value that is wrong."
}

sp_egress_ipv6() {
    ip6tables "$@" \
        || sp_die "machine ${SP_MACHINE:-?}: could not apply an IPv6 egress rule ($*). The machine has not been started."
}

# The redirect: the machine's outbound TCP, into the proxy.
#
# The proxy's own connections are exempted by the user it runs as, which is what
# keeps them from being redirected back into itself. A process inside the machine
# running as that same user would be exempted too - the number is the chart's,
# it is stated in values.yaml, and it is the reason the layer-4 half of a policy
# is worth having: that half is enforced here, where a process's own identity is
# not what decides.
sp_egress_redirect() {
    sp_egress_ipv4 -t nat -N "$SP_EGRESS_CHAIN"
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" \
        -m owner --uid-owner "$SP_EGRESS_PROXY_USER" -j RETURN
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" -d 127.0.0.0/8 -j RETURN
    sp_egress_ipv4 -t nat -A "$SP_EGRESS_CHAIN" \
        -p tcp -j REDIRECT --to-ports "$SP_EGRESS_PROXY_PORT"
    sp_egress_ipv4 -t nat -A OUTPUT -p tcp -j "$SP_EGRESS_CHAIN"
    sp_log "machine ${SP_MACHINE:-?}: outbound TCP is redirected to the proxy on port $SP_EGRESS_PROXY_PORT"
}

# The resolvers the kubelet gave this pod.
#
# Allowed automatically and not as a rule anyone writes. A machine that cannot
# resolve a name cannot reach deb.debian.org however many rules name it, so a
# policy that dropped DNS would be one whose every name-based rule silently
# failed - which is the class of outcome this whole capability exists to prevent.
sp_egress_allow_resolvers() {
    _sp_found=0
    while read -r _sp_keyword _sp_address _sp_rest; do
        [ "$_sp_keyword" = "nameserver" ] || continue
        case "$_sp_address" in
            *:*) continue ;;
        esac
        sp_egress_ipv4 -A OUTPUT -p udp -d "$_sp_address" --dport 53 -j ACCEPT
        _sp_found=$((_sp_found + 1))
        sp_log "machine ${SP_MACHINE:-?}: the resolver at $_sp_address is allowed, because a rule written as a name needs one"
    done < /etc/resolv.conf
    if [ "$_sp_found" -eq 0 ]; then
        sp_log "machine ${SP_MACHINE:-?}: this pod has no IPv4 resolver in /etc/resolv.conf, so none was allowed. Every rule written as a name will fail to match."
    fi
}

# The rules the chart rendered for what the proxy cannot see: one "<cidr> <port>"
# per line.
sp_egress_allow_udp() {
    _sp_file="${SP_EGRESS_DIR:-$SP_EGRESS_DIR_DEFAULT}/udp-allow"
    [ -f "$_sp_file" ] || return 0
    while read -r _sp_cidr _sp_port _sp_rest; do
        [ -n "$_sp_cidr" ] || continue
        sp_egress_ipv4 -A OUTPUT -p udp -d "$_sp_cidr" --dport "$_sp_port" -j ACCEPT
        sp_log "machine ${SP_MACHINE:-?}: UDP to $_sp_cidr port $_sp_port is allowed"
    done < "$_sp_file"
}

# What `deny` has to cover that a proxy cannot.
#
# TCP is accepted here because the proxy has already decided it - the redirect
# above happens in the nat table, before this one, so by the time a packet
# reaches here it is either the proxy's or on its way to the proxy.
sp_egress_deny_the_rest() {
    sp_egress_ipv4 -A OUTPUT -o lo -j ACCEPT
    sp_egress_ipv4 -A OUTPUT -p tcp -j ACCEPT
    sp_egress_ipv4 -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    sp_egress_allow_resolvers
    sp_egress_allow_udp
    sp_egress_ipv4 -A OUTPUT -j DROP

    # IPv6 is not proxied, so under a default of deny it is dropped rather than
    # left as the one way out of a policy. values.yaml says so at the input.
    if ip6tables -L OUTPUT >/dev/null 2>&1; then
        sp_egress_ipv6 -A OUTPUT -o lo -j ACCEPT
        sp_egress_ipv6 -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        sp_egress_ipv6 -A OUTPUT -j DROP
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
# The proxy's administration endpoint answers /ready once its listeners are up.
# It is bound to the loopback address, which this container shares because it
# shares the pod's network namespace - and which is why this wait is here rather
# than in a probe the kubelet would run from outside.
sp_egress_wait_for_proxy() {
    _sp_attempt=0
    while [ "$_sp_attempt" -lt "${SP_EGRESS_PROXY_ATTEMPTS:-60}" ]; do
        if curl --silent --show-error --fail --max-time 2 \
            "http://127.0.0.1:${SP_EGRESS_ADMIN_PORT:-15000}/ready" >/dev/null 2>&1; then
            sp_log "machine ${SP_MACHINE:-?}: the egress proxy is listening, so the redirect has somewhere to go"
            return 0
        fi
        _sp_attempt=$((_sp_attempt + 1))
        sleep 1
    done
    sp_die "machine ${SP_MACHINE:-?}: the egress proxy did not become ready within ${SP_EGRESS_PROXY_ATTEMPTS:-60} seconds, so nothing was redirected to it and the machine has not been started. Read its own output: kubectl logs <pod> --container envoy. A proxy that will not start is almost always a configuration it refused, and it says which line."
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
