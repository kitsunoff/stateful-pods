## Context

`machines.<name>.network` says which ports a machine serves and, optionally, asks the cluster to
admit traffic to those and no others. Nothing says anything about the other direction.

A machine is not an application. It has a package manager, a shell, a cron table and whatever its
script installed, and every one of those reaches the network the pod can reach — the cluster's
services, its own neighbours, and the internet. The thing an operator wants to write down is almost
never an address: it is *this machine may talk to the Debian mirror and to our database, and to
nothing else*.

## Goals

- A machine states what it may reach, in the terms the statement is actually made in — a name for a
  mirror, an address for a database.
- `deny` denies. What the proxy cannot see is not quietly exempt from the policy.
- A refusal is legible: something says which connection was refused and what it asked for.
- A machine that declares no egress policy renders exactly what it rendered before.

## Non-goals

See the proposal: no TLS interception, no IPv6 proxying, no policy over the steps that seed a
machine.

## Decisions

### Envoy, in the pod, with the machine's TCP redirected into it

The rule an operator writes is `deb.debian.org`, and a name is not something a packet filter or a
NetworkPolicy can match: it resolves to a rotating set of CDN addresses, and resolving it at render
time would pin a policy to whatever the answer was that afternoon.

What can match it is the name the machine itself puts in the TLS handshake — the SNI — and reading
that means something has to sit in the connection. Envoy is that, as a sidecar in the machine's own
pod, sharing its network namespace, with outbound TCP redirected to it by an `iptables` `REDIRECT`
rule. This is the shape Istio uses for the same problem, minus the control plane: the configuration
is a ConfigMap the chart renders, and there is nothing to run beside the machine.

It is also the first container this chart renders from an image it did not build. `values.yaml` says
so at `envoy.image`, pinned by digest like `shim.image` and for the same reason.

### Where in the boot sequence, and why it can only be there

```text
  seed · prepare · customize · provision     ordinary init containers, no policy yet
  envoy                                      a sidecar: starts here, outlives the machine
  egress                                     installs the redirect, then exits
  guest                                      the machine
```

Three constraints fix this ordering and there is no other arrangement that satisfies them:

- **The redirect must be installed after seeding.** Seeding fetches a root filesystem from a
  registry; a policy applied before it would have to contain a rule for the chart's own source, and
  a chart that made its own construction subject to a user's policy would be one that fails to
  install for a reason the user did not write.
- **Envoy must be running before the redirect exists.** Traffic redirected to a port nothing is
  listening on is traffic refused, and a machine whose sidecar was still starting would fail its own
  first connections.
- **Envoy must outlive the machine's startup and keep running.** That is what a sidecar is: an init
  container with `restartPolicy: Always`, which Kubernetes starts in order, waits for, and leaves
  running. It needs Kubernetes 1.29; this chart's floor is 1.30, so it costs nothing.

### What each rule form can see, stated as a property of the connection

| Form | What it matches | What it cannot see |
| --- | --- | --- |
| `cidrs` + `ports` | the connection's original destination | anything about the request |
| `serverNames` | the name in the TLS handshake, undecrypted | the path, the method, the response |
| `http` | the authority and path of a **plaintext** request | anything on a TLS connection |
| `protocol: UDP` + `cidrs` + `ports` | the packet's destination | anything else |

The important honesty is on `serverNames`. **It is a claim the machine makes about itself.** A
process inside the machine can open a TLS connection to any address and put any name in the
handshake, and the proxy will believe it; a `cidrs` rule beside it is stronger, because an address is
not something the machine gets to assert.

Neither bounds a program that has root inside the machine, and the documentation says so rather than
implying otherwise. The proxy is exempted from the redirect by the user it runs as, and nothing in a
shared network namespace can tell that user's traffic from a process inside the machine running as
the same user — so a machine's own root steps around the whole policy with one `setpriv`, `cidrs`
rules included. That is the shape every sidecar proxy has. What the policy is worth is what it is: a
machine's package manager, its cron table and its first-boot script go where the rules say, and a
mistake in any of them is caught. Saying that in `values.yaml` is worth more than the feature is.

`http` is plaintext only, and that is not a limitation to be worked around later. Matching a path on
an HTTPS connection means terminating TLS in the sidecar and installing a certificate authority
inside the machine, which is a different product.

### `deny` denies, including what Envoy cannot proxy

Envoy is given TCP. If that were the whole of it, `default: deny` would be a policy a machine could
step around with a UDP socket — and a policy that covers half of what its name claims is worse than
one that says which half.

So the same init container that installs the redirect also installs, when the default is `deny`:

- every `protocol: UDP` rule, as an accept;
- the pod's own resolvers, as an accept, read from the `/etc/resolv.conf` the kubelet wrote;
- a drop for everything else that is not TCP.

The resolver is automatic and is not a rule anyone writes. A machine that cannot resolve a name
cannot reach `deb.debian.org` however many rules name it, so a policy that dropped DNS would be one
whose every name-based rule silently failed. That is stated at the input rather than left to be
discovered.

IPv6 is dropped under `deny` and untouched under `allow`, and the values say so. Proxying it would
mean a second listener, a second set of rules and a second thing to test on a cluster that has
IPv6 at all; a rule that silently matched nothing would be worse than a documented edge.

### The configuration Envoy is given

One listener on 15001 with the `original_dst` and `tls_inspector` listener filters, so that a
redirected connection still knows where it was going and whether it began with a TLS handshake.
Then one filter chain per rule:

- `serverNames` → `filter_chain_match` on `server_names` and the port, to a `tcp_proxy` whose cluster
  is `ORIGINAL_DST`: Envoy forwards to wherever the connection was going, having only read the
  handshake.
- `cidrs` → `filter_chain_match` on `prefix_ranges` and the port, likewise.
- `http` → one chain per port, carrying an HTTP connection manager whose routes are every `http`
  rule for that port, with a `403` for everything they do not match.

and one catch-all chain at the end: to the same passthrough cluster when the default is `allow`, and
to a cluster with no endpoints when it is `deny`. The blackhole is a cluster rather than an absent
filter chain, so that a refusal appears in the access log as a refusal rather than as Envoy having
nothing to say.

Every chain writes an access log line to standard output, so `kubectl logs <pod> --container envoy`
answers "why can this machine not reach X" without anything being turned on first. That is the
whole debugging story and it is the reason the log is not optional.

The chart guarantees at render time that no two chains carry the same match, because Envoy rejects a
configuration with a duplicate and a rejected configuration is a sidecar that crash-loops behind a
machine that appears healthy.

### What this costs a machine that uses it

A second container, an `iptables`-capable init container, and every outbound TCP connection passing
through a proxy in the same network namespace. The init container is granted `NET_ADMIN` and
`NET_RAW`, which the guest container is deliberately not — those capabilities belong to the step
that programs the namespace, not to the machine living in it, and `values.yaml` says which container
holds what.
