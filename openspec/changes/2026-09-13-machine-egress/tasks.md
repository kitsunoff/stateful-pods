## 1. The input contract and its refusals

- [ ] 1.1 Add `helm unittest` cases for every refusal in the `values-validation` delta; verify each
  fails against the unmodified chart for the right reason
- [ ] 1.2 Add the resolution helper to `_helpers.tpl`, emitting the policy normalised and in the
  order it was written
- [ ] 1.3 Implement the validation, accumulating into the existing semantic stage

## 2. The proxy and its configuration

- [ ] 2.1 Add `envoy.image` to `values.yaml`, pinned by digest, documented as the first image this
  chart runs that it did not build
- [ ] 2.2 Add `templates/egress-config.yaml`: one listener, one filter chain per rule, a catch-all
  that matches the default, and an access log on every one of them
- [ ] 2.3 Add `helm unittest` cases asserting the chains a policy renders, that a duplicate cannot
  be produced, and that the catch-all follows the default

## 3. The pod

- [ ] 3.1 Add `helm unittest` cases asserting the proxy container, the preparation step that
  programs the namespace, the capability it holds and the guest does not, the ordering, and the
  annotation that replaces the machine when the policy changes
- [ ] 3.2 Render them in `statefulset.yaml`
- [ ] 3.3 Verify `make test` and `make conform` are green at both the development version and the
  chart's floor

## 4. The image

- [ ] 4.1 Add `iptables` and `ip6tables` to `images/shim/Containerfile`, and extend
  `hack/image-test.sh` to assert both
- [ ] 4.2 Add `images/shim/scripts/lib-egress.sh` and `egress-setup.sh`
- [ ] 4.3 Add a `bats` suite: that it waits for the proxy before redirecting anything, that the
  redirect exempts the proxy's own user, that a default of deny drops what the proxy cannot see,
  that the pod's resolver is allowed without a rule, and that a failure to apply a rule stops the
  machine; verify `make shell-test` is green
- [ ] 4.4 Run `make image-test`; verify it is green

## 5. Documentation

- [ ] 5.1 Document the block in `values.yaml` at the point of use, including what each rule form can
  and cannot see, what the capability costs, where the log is, and the two holes; run `make docs`
- [ ] 5.2 Add an example under `charts/stateful-pods/examples/`
- [ ] 5.3 Extend `NOTES.txt`: the policy in force, where its log is, and what is not proxied
- [ ] 5.4 Update the chart README and the project README

## 6. On a cluster

- [ ] 6.1 Extend `hack/integration-test.sh`: a machine under a policy reaches what a rule allows,
  is refused what none allows, still resolves names, and says so in the proxy's log; the guest holds
  no network administration capability; and the step that programmed the namespace has exited
- [ ] 6.2 Run `make all`, `make image-test` and `make integration-test`; verify all are green
