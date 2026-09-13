## ADDED Requirements

### Requirement: A machine with an egress policy carries a proxy and the step that programs its namespace

Where a machine declares an egress policy, the chart SHALL render one ConfigMap holding the proxy's
configuration, one long-running proxy container in the machine's own pod, and one preparation step
that programs the pod's network namespace and exits.

The proxy is in the machine's pod and not beside it because it must share the machine's network
namespace: a redirect is a rule in that namespace, and a proxy in another pod would be a proxy the
redirect could not reach.

#### Scenario: The objects are rendered together

- **WHEN** a machine declares an egress policy
- **THEN** a ConfigMap named for the machine, a proxy container that keeps running, and a
  preparation step that programs the namespace are all rendered

#### Scenario: Nothing is rendered without a policy

- **WHEN** a machine declares no egress policy
- **THEN** none of them is rendered, and the pod is what it was

### Requirement: A change to an egress policy replaces the machine

The chart SHALL replace a machine's pod when its egress policy changes.

The policy is a ConfigMap, and a ConfigMap whose content changes restarts nothing on its own: the
proxy would go on enforcing the policy it was started with, and the values would describe something
the machine is not doing. Unlike provisioning material, the whole of an egress policy is visible to
the chart, so the digest that triggers the replacement is exact.

#### Scenario: A changed policy takes effect

- **WHEN** a machine's egress policy changes and the release is upgraded
- **THEN** the machine's pod is replaced and the proxy starts with the new policy

#### Scenario: An unrelated change does not replace the machine

- **WHEN** a release is upgraded and the machine's egress policy is unchanged
- **THEN** the digest that governs the replacement is unchanged
