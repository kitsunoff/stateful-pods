## Context

The chart renders one StatefulSet, one headless Service and one rootfs claim per machine. Neither
the guest container nor the Service has ever carried a port, for the good reason that the chart had
nothing to put there: a machine's services are the machine's own business and the chart does not
read its `/etc`.

What changed is that the next two capabilities both need a place for network inputs to live —
egress policy, and eventually anything else the cluster rather than the guest decides — and a port
list is the smallest one of those that is useful on its own.

## Goals

- A machine states which ports it serves, in one place, in a shape that reads the same as the rest
  of the values.
- That statement is rendered into every object the cluster already reads a port list from, so that
  declaring it once makes the machine legible to `kubectl`, to DNS and to whatever watches pods.
- A machine can ask for the statement to be enforced, and what enforcement costs is stated where
  the input is.

## Non-goals

- Deciding which peers may reach a machine. See the proposal.
- Reaching a machine from outside the cluster.
- Any input that would configure the machine's own interface. The pod's addressing belongs to the
  CNI, which `values.yaml` has said since the first release and goes on saying.

## Decisions

### The block is `network`, and ports are under it

`machines.<name>.network.ports` rather than `machines.<name>.ports`. The egress policy lands in the
same block in the following change, and a machine's values should not grow two sibling top-level
keys that are both about the network. It costs one level of nesting now and renames nothing later.

`values.yaml` already carries a section headed *Deliberately not chart inputs* whose first entry is
that per-guest network configuration — the Proxmox `ipconfig0`, bridge and VLAN options — has no
equivalent here. A block called `network` risks reading as the arrival of exactly that, so the
comment on it opens by saying what it is not: it describes what the cluster is told about the
machine, never what the machine's own interface is configured with.

### A map keyed by name, not a list

```yaml
network:
  ports:
    ssh:
      port: 22
    http:
      port: 80
      protocol: TCP
```

Every other collection in these values is a map keyed by the name of the thing — `machines`
itself, the provisioning inputs — and a port's name is not decoration: it is what the Service's SRV
record is published under and what appears in `kubectl describe pod`. A list of maps each carrying
a `name` field would be the same information with a worse merge behaviour under Helm's `--set` and
under a GitOps overlay, where a list is replaced wholesale and a map is merged key by key.

The key is the name. Kubernetes calls this an `IANA_SVC_NAME` and validates it strictly — at most
fifteen characters, lowercase alphanumerics and hyphens, at least one letter, no leading, trailing
or doubled hyphen — and a name that breaks any of those is rejected by the API server, which
surfaces as a StatefulSet that never creates a pod. The chart checks it while it renders instead,
and the message quotes the rule rather than the regular expression.

### Rendered into the container and into the Service, and both are declarations

A container's `ports` opens nothing and closes nothing: the pod's network namespace is reachable on
every port something in it listens on, whatever the field says. It is documentation the cluster can
read, and that is worth having — but it would be dishonest to present it as access control, so the
values comment says outright that this field is informational and names the input that is not.

The Service's ports are not purely informational: a headless Service publishes an SRV record per
named port, which is how a client discovers where a machine's service is without the port being
written down in two places.

`targetPort` is set to the same number rather than to the port's name. A named target resolves
through the container's port list, which means a machine whose service is declared correctly and
whose container port list was somehow not rendered would resolve to nothing; the number cannot fail
that way, and there is no port remapping here to justify the indirection.

### Enforcement is opt-in, and its cost is stated

`network.ingress` takes `any` (the default) or `declared`. `declared` renders a NetworkPolicy whose
`podSelector` is the machine's own selector labels, with `policyTypes: [Ingress]` and one `ports`
entry per declared port and no `from`, so traffic from anywhere is admitted to those ports and
nothing is admitted to any other.

Opt-in, because the alternative is a chart that cuts a running pet off from the network during a
routine upgrade — the machine is reachable on port 5432 today, the chart starts rendering a policy
tomorrow, and a database nobody declared a port for stops answering. A machine's isolation is the
same class of decision as `security.mode`, which this chart has always refused to guess.

Two costs are stated at the input:

- **A NetworkPolicy is enforced by the CNI and by nothing else.** On a cluster whose CNI implements
  none — kindnet, flannel without a policy agent — the object is accepted by the API server and
  enforces nothing at all. The chart cannot detect that, and a value whose effect silently depends
  on the cluster is exactly the kind this project documents loudly rather than hides.
- **`declared` with no ports declared admits nothing**, which is a legitimate thing to ask for and
  an easy thing to do by accident. `NOTES.txt` says so when it happens.

Egress is left entirely alone: `policyTypes` names `Ingress` only, so a machine that selects
`declared` can still reach DNS, its package mirror and everything else. A policy that named both
would deny all egress the moment it was applied, which is the same trap in the other direction.

The readiness probe is unaffected in any case. It is an `exec` probe, so the kubelet runs it
through the container runtime and not over the network, and no ingress policy can interfere with
it. That is worth stating because an HTTP probe under a default-deny ingress policy is one of the
most common ways a NetworkPolicy takes a workload down, and this chart is immune to it by a choice
made for an unrelated reason.

### Duplicates are refused while rendering

Two entries naming the same number and protocol render two container ports the API server rejects
as duplicates, and two Service ports likewise. The chart refuses that itself, naming both entries,
because the alternative is a manifest that renders cleanly and is rejected on apply with a message
about a field index.

Two entries naming the same number with *different* protocols are legal and useful — a DNS server
on 53 TCP and 53 UDP — and are accepted.
