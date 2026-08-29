## Why

Every container the chart runs reads its script from a ConfigMap the chart renders. That was the
right call for exactly one reason: the seeding step for an `oci` source executes inside the
machine's own source image — a foreign image this project does not build — and mounting is the only
way to get code into one.

That single constraint is what this change removes. Once the chart pulls and unpacks an OCI source
itself, nothing runs in a foreign image any more, and the ConfigMap has nothing left to justify it:
the scripts belong to the image that runs them, versioned with the tools they call.

Running the source image as an init container is also expensive in a way that is easy to miss. The
step runs on every pod start, so the source has to stay resolvable and present for the life of the
machine — a machine seeded a year ago still depends on a tag someone else controls. A pod
rescheduled onto a fresh node pulls an entire operating system image again in order to run a script
that immediately exits with "already seeded". And while the pod exists the kubelet keeps that image
on the node's disk, because a terminated init container still references it.

## What Changes

- **The scripts move into the shim image.** They are baked in at a fixed path under
  `/usr/local/lib/stateful-pods`, and the per-machine ConfigMap template is deleted. In the
  repository they move from `charts/stateful-pods/scripts/` to `images/shim/scripts/`, which is the
  image's build context.
- **The chart pulls an OCI source itself.** The seeding step runs from the shim image for both
  source kinds and fetches the source with `crane`, streaming the flattened image straight into the
  volume through the same GNU tar invocation the LXC path already uses. The source image is never a
  container image in the pod.
- **The registry is contacted only when there is something to seed.** The volume's state is read
  before anything touches the network, so every start after the first makes no registry request at
  all. A source reference that stops resolving after seeding no longer affects the machine.
- **The seeded filesystem matches the node's architecture.** The container runtime used to choose
  the right variant of a multi-architecture image on the chart's behalf. Doing the pull ourselves
  makes that an explicit decision, and getting it wrong seeds a rootfs that unpacks perfectly and
  cannot execute.
- **A new input for private sources**: `machines.<name>.source.pullSecretName` names a
  `kubernetes.io/dockerconfigjson` Secret in the release's namespace, mounted into the seeding step
  alone. It belongs to kind `oci`; supplying it on an `lxc` source is rejected like every other
  cross-kind field. Nothing is inherited from the ServiceAccount's `imagePullSecrets`, because the
  kubelet no longer performs this pull.
- **Any OCI image can be a source.** The requirement that a source image provide `/bin/sh` and GNU
  tar with extended-attribute support disappears along with the probe that enforced it, because
  nothing from the source is executed. Alpine-, busybox- and distroless-based images become usable
  sources.
- **BREAKING for a user-supplied shim.** A `shim.image` override now has to be an image built from
  this repository's `images/shim` context at a compatible version. Previously any image carrying
  bash and the archivers would do, because the logic arrived from the chart.
- **The chart and its image are released together.** A fix to a script is an image release plus the
  digest bump in `values.yaml`, not a `helm upgrade` on its own.

Non-goals:

- A node-level cache of source image layers shared between machines. It would mean a `hostPath`, and
  it buys nothing: after the first seeding there is no pull left to cache.
- A compatibility handshake between the chart and the shim image beyond the pinned default digest. A
  mismatched image fails at the first container that cannot find its script, which names the path.
- Any change to how an LXC template is fetched, verified or unpacked.

## Capabilities

### New Capabilities

None. This change alters how existing capabilities are met, and adds no new area of behaviour.

### Modified Capabilities

- `shim-image`: the image now carries the logic as well as the tools, so "one image serves every
  container the chart runs" loses its OCI exception, and the image must be able to fetch an image
  from a registry rather than only to unpack an archive it was handed.
- `rootfs-seeding`: an OCI source is fetched and unpacked by the chart's own image instead of being
  copied from inside the source image; the requirement that the source image provide a faithful
  archiver is gone; the registry is contacted only when seeding will actually happen; the seeded
  filesystem must match the node's architecture; a private source is reached with credentials the
  machine names.
- `machine-topology`: no container in a machine's pod runs the machine's source as its image — the
  exception carved out for the seeding step no longer exists.
- `values-validation`: the new `source.pullSecretName` input is accepted for `oci` and rejected for
  `lxc`, like every other kind-specific field.

## Impact

- **Chart**: `templates/scripts-configmap.yaml` is deleted; the StatefulSet loses the `scripts`
  volume and its four mounts, and every command becomes an absolute path inside the image; the seed
  init container's image is the shim for both kinds; `values.yaml` documents the new input and the
  stronger meaning of a `shim.image` override.
- **Image**: `images/shim/Containerfile` gains `crane` and copies the scripts in; the shim grows by
  roughly 30 MB.
- **Scripts**: `lib-oci.sh` is rewritten around `crane` and stops probing the source image;
  `seed-oci.sh` becomes a bash script like its LXC counterpart, since it no longer runs in a foreign
  userland; the POSIX-sh constraint on `lib-state.sh` and `lib-seed.sh` is lifted but not acted on.
- **Tests**: every bats suite's `SCRIPTS` path changes; the helm-unittest suites that assert the
  ConfigMap and the `/scripts` mounts are rewritten; `hack/shell-lint.sh` and the image build in CI
  learn the new location; the integration test gains an Alpine-based source, which is the case that
  was impossible before.
- **Verification risk to settle first**: that `crane export` preserves `security.capability` through
  the flatten. The project already asserts this property in `hack/image-test.sh` and in the
  integration test, and the fallback if it does not hold is `skopeo` plus `umoci`.
- **Operational**: the per-machine ConfigMap disappears on the first `helm upgrade`. No machine's
  volume is touched, and no machine is re-seeded.
