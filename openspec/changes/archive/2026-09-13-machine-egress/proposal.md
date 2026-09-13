## Why

A machine is a whole operating system with a package manager, a shell and somebody's script on it,
and it reaches the entire network the pod can reach. Nothing in the chart says otherwise, and the
`network` block that arrived with the declared ports says what may come *in* while saying nothing
about what may go *out*.

Outbound is the direction that matters more here. A machine installs packages from a mirror, pulls
an image, calls a webhook — and the same machine, misconfigured or compromised, reaches every
service in the cluster and everything on the internet. A Proxmox container has the same problem and
the same non-answer: the firewall is somewhere else, maintained by somebody else, in terms that have
nothing to do with the container.

A NetworkPolicy would cover part of it. It cannot cover the part people actually write down: *this
machine may reach the Debian mirror*, which is a name, not a set of addresses, and not one that
stays the same.

## What Changes

- **A machine declares what it may reach**, at `machines.<name>.network.egress`, as an ordered set
  of rules and an explicit `default` of `deny` or `allow`.
- **A rule matches at layer 4 or at layer 7**, and says which:
  - `cidrs` and `ports` — an address range and a port, which is layer 4 and is what a policy about
    another workload's address looks like.
  - `serverNames` — the name the machine asks for in the TLS handshake, matched **without
    decrypting anything**. This is the rule for "the Debian mirror" and it is the one most policies
    are actually made of.
  - `http` — an authority and a path prefix, for **plaintext HTTP only**, where there is a request
    to match on.
  - `protocol: UDP` for the layer-4 form, which is enforced by packet filter rather than by proxy.
- **The enforcement is Envoy**, as a sidecar in the machine's own pod, with the machine's outbound
  TCP redirected into it by a packet-filter rule installed after the machine's root filesystem has
  been prepared and before the machine starts. Everything Envoy decides is in its access log, so a
  refused connection says what it asked for.
- **`deny` means deny**, including what Envoy cannot proxy: UDP that no rule allows is dropped, and
  so is everything that is neither TCP nor UDP. The one exception is the pod's own resolver, which
  is allowed automatically, because a machine that cannot resolve a name cannot honour a rule
  written as a name.
- **A second image joins the chart**: `envoy.image`, pinned by digest beside `shim.image`. It is the
  first container this chart runs that it did not build, and the values say so.
- **`values.yaml`, both READMEs and `NOTES.txt`** document what each rule form can and cannot see,
  and state plainly that a `serverNames` rule is a claim the machine makes about itself.

Non-goals, named so they are not mistaken for omissions:

- **Decrypting TLS.** Matching an HTTPS request's path would mean terminating TLS in the sidecar and
  putting a certificate authority inside every machine. That is a different product, and a machine
  whose operator installed a CA to read its own traffic has a larger decision to make than a Helm
  value.
- **Inbound policy beyond the declared ports.** `network.ingress` already exists and stays what it
  is.
- **IPv6 egress through the proxy.** Under `deny` it is dropped; under `allow` it is untouched. A
  dual-stack machine that needs a named IPv6 destination is not something this change serves, and
  saying so is better than a rule that silently matches nothing.
- **Policy over the steps that build a machine.** Seeding fetches a root filesystem from a registry
  and runs before any of this is installed. The policy governs the machine, not its construction,
  and a chart that made its own seeding subject to a user's rule would need a rule for itself.
