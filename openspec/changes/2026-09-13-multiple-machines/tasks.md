## 1. The chart

- [ ] 1.1 Add a `helm unittest` suite rendering a release with two machines, asserting that every
  object name is distinct, that each machine's inputs reach only its own objects, that two machines
  may each declare a volume called `data`, and that an object is rendered only for the machine that
  asked for it; verify it fails against the unmodified chart
- [ ] 1.2 Remove the count refusal from the structural validation stage
- [ ] 1.3 Update the suites that asserted the refusal to assert what they were really about
- [ ] 1.4 Verify `make test` and `make conform` are green

## 2. The plugin

- [ ] 2.1 Add cases to the `delete` suite: the other machines are named, the release's name is what
  confirms, the machine's name does not, and a lone machine is unchanged
- [ ] 2.2 Add cases to the `create` suite: a release holding another machine is refused, the message
  names it and shows what to run instead, and an update of the same machine still works
- [ ] 2.3 Implement both, reading the release's machines by label rather than from its values
- [ ] 2.4 Verify `make plugin-test MACHINE_BASH=/bin/bash` is green on bash 3.2

## 3. Documentation

- [ ] 3.1 `values.yaml`, both READMEs and the plugin's own help say what machines in a release share
- [ ] 3.2 Remove the limitation from the project README; run `make docs`

## 4. On a cluster

- [ ] 4.1 Extend `hack/integration-test.sh`: a release with two machines, both booting, each with
  its own volume and its own content, and one restarted without disturbing the other
- [ ] 4.2 Run `make all` and `make integration-test`; verify both are green
