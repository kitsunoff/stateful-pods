## Why

A machine is a whole operating system with services on it, and the chart has never had a way to say
which ones. The headless Service carries no ports, so nothing appears in DNS beyond the A record;
the guest container declares none, so `kubectl get pod` and every dashboard built on it show a
machine with nothing on it; and nothing anywhere says which ports a machine is meant to serve, so
there is nothing a cluster could be asked to enforce.

The consequence today is that a machine is reachable on every port it happens to be listening on,
including the ones its distribution started without being asked to. That is the Proxmox default as
well — a container is on the bridge and the firewall is somewhere else — and it is the part of the
Proxmox model worth improving on rather than reproducing, because here the answer can be declared
beside the machine instead of in another system.

## What Changes

- **A machine declares the ports it serves**, at `machines.<name>.network.ports`, keyed by the
  name each port is known by. Each entry names a `port` and optionally a `protocol` of `TCP`, `UDP`
  or `SCTP`, defaulting to `TCP`.
- **The declaration is rendered where the cluster already looks for one**: as the guest container's
  `ports`, so that a machine's services are visible on the pod, and as the headless Service's
  `ports`, so that each one gets an SRV record under the name it was declared with.
- **A machine may ask that only those ports be reachable**, with
  `machines.<name>.network.ingress: declared`. That renders a NetworkPolicy admitting traffic to
  the declared ports and to nothing else. The default is `any`, which renders no policy and changes
  nothing: a chart that started restricting a running machine's traffic on upgrade would be a chart
  that cuts a pet off from the network on a version bump.
- **`values.yaml`, the chart README, the project README and `NOTES.txt`** document the block, and
  state plainly that a NetworkPolicy is enforced by the cluster's CNI and does nothing whatsoever
  where the CNI does not implement one.

Non-goals, named so they are not mistaken for omissions:

- **Egress policy.** `network.egress` is the next change and is deliberately not squeezed into this
  one. The block is named `network` rather than `ports` so that it arrives beside this without
  renaming anything.
- **A ClusterIP or LoadBalancer Service.** A machine is a pet addressed by its own name, not a
  member of a pool; the headless Service is the right object and gains ports here. Publishing a
  machine outside the cluster is the cluster's ingress story and not a per-machine input.
- **`hostPort`.** It pins a machine to one node's port space and fails the second machine that
  wants the same port, which is a scheduling surprise rather than a network input.
- **Sources.** The policy this change renders restricts which *ports* are reachable and never which
  peers may reach them. A `from` selector is a policy about other workloads, and expressing it in
  the machine's own values would put half of a cluster's policy in each machine.
