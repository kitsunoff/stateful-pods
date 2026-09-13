## 1. The input contract and its refusals

- [x] 1.1 Add `helm unittest` cases for every refusal in the `values-validation` delta — a network
  block that is not a map, a port collection that is not a map, a port entry that is not a map, a
  name the API would reject, a missing or non-integer number, a number outside 1–65535, an
  unknown protocol, an unknown key under a port entry and under the network block, an unknown
  ingress posture, and a duplicated number-and-protocol pair — and verify each one fails against
  the unmodified chart for the right reason
- [x] 1.2 Add the resolution helper to `_helpers.tpl`: for one machine, emit the declared ports in
  a normalised form with the protocol defaulted, deterministically ordered
- [x] 1.3 Implement the validation the cases from 1.1 demand, accumulating into the existing
  semantic stage; verify `make test` is green and every message names the machine and the input

## 2. The objects

- [x] 2.1 Add `helm unittest` cases asserting that declared ports appear on the guest container and
  on the headless Service under the same names, that the same number on two protocols renders
  twice, that no other container carries a port list, and that a machine declaring nothing renders
  no port list anywhere; verify they fail against the unmodified chart
- [x] 2.2 Render the ports on the guest container in `statefulset.yaml` and on the Service in
  `service.yaml`
- [x] 2.3 Add `helm unittest` cases for the policy: rendered only when asked, named for the
  machine, selecting the machine's own labels, governing ingress only, one entry per declared port,
  and admitting nothing when the posture is asked for with no ports declared
- [x] 2.4 Add `templates/network-policy.yaml`; verify `make test` and `make conform` are green at
  both the development version and the chart's floor

## 3. Documentation

- [x] 3.1 Document the block in `values.yaml` at the point of use, including what a container port
  list is and is not, and what a NetworkPolicy depends on; run `make docs`
- [x] 3.2 Add an example under `charts/stateful-pods/examples/` declaring ports and asking for them
  to be enforced, and confirm `make lint` and `make conform` cover it
- [x] 3.3 Extend `NOTES.txt` to report the declared ports, the DNS name each is reachable at, and
  the warning when the posture admits nothing
- [x] 3.4 Update the chart README and the project README

## 4. On a cluster

- [x] 4.1 Extend `hack/integration-test.sh`: a machine declaring ports renders them on the pod and
  on the Service, and a machine that asks for enforcement renders the policy and still becomes
  ready
- [x] 4.2 Run `make all` and `make integration-test`; verify both are green
