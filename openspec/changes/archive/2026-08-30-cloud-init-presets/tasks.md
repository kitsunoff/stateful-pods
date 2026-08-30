## 1. Establish what the upstream actually publishes

- [x] 1.1 Read `meta/1.0/index-system` and record, per preset, which variants exist for both
  architectures. Treat a distribution with no cloud variant as a finding rather than an obstacle.
- [x] 1.2 Download a cloud and a default root filesystem and compare them: size, what cloud-init
  state the cloud one carries, and whether anything about it would surprise a pet machine.
- [x] 1.3 Record the outcome in design.md, including the per-distribution recommendation and the
  reason Alpine's `tinycloud` is not taken.

## 2. The catalog names the cloud variant and a package that cannot collide

- [x] 2.1 Test first, in `test/presets/verification.bats`: a preset resolves into the package its
  catalog line names including the variant, and the variant a preset names is the one looked up in
  the upstream index rather than a fixed `default`.
- [x] 2.2 Change the variant and the package of `debian-trixie`, `ubuntu-noble` and `alpine-3.24` in
  `images/presets/presets.list`, and leave `void-current` on `default`.
- [x] 2.3 Replace the header's account of why the variant is `default` everywhere with why it is
  not, name Void as the exception the upstream forces, and say why the variant is in the package
  rather than in the tag.
- [x] 2.4 Confirm no script needed editing: the build, the daily bump, the retention job and
  `hack/check-presets.sh` all read these fields already.

## 3. The verification the presets rest on still fails closed

- [x] 3.1 Run the whole `test/presets` suite and confirm every refusal is unchanged: a bad
  signature, a stripped signature, a checksum mismatch, an uncovered archive, an unparsable index,
  an unknown preset, an incomplete upstream, a key file that is not the pinned one.
- [x] 3.2 Confirm the signature path is exercised against the cloud archives specifically, not only
  against the fixtures.

## 4. Publish the presets and point the catalog at them

- [x] 4.1 Publish every preset from the branch with the existing `workflow_dispatch` on
  `preset-publish.yaml`, dispatching individually where the upstream is mid-rebuild on one.
- [x] 4.2 Bump `charts/stateful-pods/presets.yaml` to the published digests with
  `hack/preset-bump.sh`, and leave `void-current` alone.
- [x] 4.3 Run `make presets` and confirm the two catalogs agree in both directions.

## 5. Say what a user gets

- [x] 5.0 Record that `ubuntu-noble` is waiting on its upstream's architectures to agree, in the
  catalog, both READMEs and the change, and that moving it is a deliberate edit rather than
  something the daily bump will do.

- [x] 5.1 Update `README.md` and `charts/stateful-pods/README.md`: the new package names, which
  preset can serve which provisioning backend, and what a preset now costs in size.
- [x] 5.2 State the interim behaviour — cloud-init present and inert until the provisioning change
  lands — where a user reading about presets would look for it.
- [x] 5.3 Record the three orphaned packages and why they are not deleted.

## 6. Verify it as a user would

- [x] 6.1 Install the chart on kind from a preset source and confirm the machine boots.
- [x] 6.2 Confirm cloud-init is actually inside the running machine: the program, the units and
  `/etc/cloud`.
- [x] 6.3 Confirm what cloud-init does on a first boot with no seed: that it finds no datasource,
  leaves no failed unit, and does not hold the boot up. Report the answer whatever it is, because
  the next change is built on top of it.
