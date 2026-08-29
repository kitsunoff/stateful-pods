## Context

See `proposal.md` — Why. The state this design starts from:

- `charts/stateful-pods/scripts/*.sh` is rendered into a per-machine ConfigMap by
  `templates/scripts-configmap.yaml` and mounted at `/scripts` in all four containers.
- The `seed` init container runs the machine's own source image when the source kind is `oci`, and
  the shim image otherwise. Every other container runs the shim.
- `lib-seed.sh` already decides what to do from the volume's state before it calls the fill, and
  `lib-oci.sh` and `lib-state.sh` are written in POSIX sh solely because they were sourced inside a
  foreign image.
- `ready.sh` and `stop.sh` are copied onto the volume during boot, because they run after the root
  change where neither `/scripts` nor the shim's userland is reachable. That stays true and is
  unaffected by where they come from.
- The shim image is `alpine:3.22` plus bash and the archivers, pinned by digest in `values.yaml` and
  published from `images/shim` by a tag build.

## Goals / Non-Goals

**Goals:**

- One artifact carries the chart's logic and the tools that logic calls.
- A machine's source is read once, by the chart's own image, and never again.
- The seeding path is the same shape for both source kinds: one shim container, one state decision,
  one archive flag set, one fill that differs only in where the bytes come from.
- No credential ever becomes a chart value.

**Non-Goals:**

- Changing the environment contract between the chart and the scripts (`SP_*`, `/mnt/rootfs`). It
  stays exactly as it is, so the diff is about delivery and the OCI fill, not about the interface.
- Rewriting the POSIX-sh libraries in bash. The constraint that forced them is gone; acting on it
  now would bury this change's real diff under a dialect change.
- Any node-level cache of image layers.

## Decisions

### The scripts live at a fixed path in the image, and move to the image's build context

Baked in at `/usr/local/lib/stateful-pods/`, copied from `images/shim/scripts/`. Every container
command becomes an absolute path there; the `scripts` volume and its four mounts disappear from the
pod spec along with the ConfigMap template.

The move in the repository is what keeps the image's build context self-contained: the build stays
`docker build images/shim`, with no repository-root context and no build-time dependency on a
directory the chart also ships. Leaving the scripts under `charts/` would leave a directory in the
chart that the chart no longer uses, which is exactly the confusion this change exists to remove.

The cost is that every `shellcheck source=` directive and every bats suite's `SCRIPTS` path changes.
That is mechanical, and `make shell-lint` and `make shell-test` catch anything missed.

Nothing inside the scripts needs to learn the new path. Each entry point derives its own directory
from `$0` and passes it on — `boot.sh` hands `SP_SCRIPT_DIR` to `sp_install_runtime_helpers`, which
takes it as an argument rather than hard-coding one. Those lines keep working unchanged and should
be left alone.

Alternative rejected: a `scripts` `emptyDir` populated by an extra init container. That is what would
have been necessary to keep the source image as the OCI seeder, and it keeps every cost of that
arrangement while adding a container to every pod.

### `crane export` performs the OCI fill, streamed straight into tar

```sh
crane export --platform "linux/$arch" "$SP_SOURCE_REFERENCE" - \
  | tar -C "$SP_ROOTFS" -x $SP_TAR_FLAGS
```

`crane export` resolves the reference, applies the layers in order — including whiteouts — and
writes the flattened filesystem as a tar stream. Piping it into the same GNU tar the LXC path
already uses means the extraction side of both kinds is one code path with one flag set, and that
the properties the project cares about (`--numeric-owner`, `--acls`, `--xattrs`,
`security.capability`, sparseness) are asserted once for both.

Streaming also means peak disk usage is the size of the finished rootfs. Nothing is staged.

`SP_TAR_FLAGS` is currently defined twice, and the `lib-oci.sh` copy carries `--one-file-system`,
which is a creation flag that was meaningful when that library made an archive from a live
filesystem. Both definitions collapse into one in `lib-seed.sh`.

Failures must not be swallowed by the pipe: the fill runs under `pipefail` and checks the status of
both sides, because tar exiting cleanly on a truncated stream would otherwise look like a successful
seed.

Alternative considered: `skopeo copy` into an OCI layout followed by `umoci unpack`. Two tools, an
intermediate copy of the whole image staged on the volume before anything is unpacked, and an
extraction path that is `umoci`'s rather than the one already covered by the project's tests. Its
advantage is that whiteout and attribute handling are `umoci`'s well-trodden problem rather than a
property this project has to verify. It is the fallback if the verification below fails.

### The node's architecture is selected explicitly

`crane` defaults to `linux/amd64` regardless of where it runs. The container runtime used to make
this choice invisibly and correctly, so doing the pull ourselves turns a non-decision into a silent
failure mode: an amd64 rootfs on an arm64 node seeds perfectly and cannot execute its own init.

The seeding step maps the machine architecture reported by the kernel onto an OCI platform
(`x86_64` → `linux/amd64`, `aarch64` → `linux/arm64`) and passes it explicitly. An architecture the
map does not cover is a failure naming what was found, not a guess — the two the project builds and
tests for are the two it claims.

A reference that offers no build for that platform fails with `crane`'s own message, which names the
platform, wrapped so that it also names the machine and the reference.

### Credentials arrive as a projected Secret, not as values

`machines.<name>.source.pullSecretName` names a `kubernetes.io/dockerconfigjson` Secret in the
release's namespace. The seed container mounts it read-only at a fixed directory, projecting the
Secret's `.dockerconfigjson` key to the file name `config.json`, and sets `DOCKER_CONFIG` to that
directory. `crane` then finds it the way every Docker client does.

Only the seed container gets the mount. `prepare`, `customize` and `guest` have no reason to see it,
and the guest container is the one a user execs into. Concretely, the volume, the mount and
`DOCKER_CONFIG` belong to the seed container's own block in `statefulset.yaml` — not to
`stateful-pods.machine.seedEnv`, which every container shares.

Two consequences worth stating plainly, both documented in `values.yaml`:

- The ServiceAccount's `imagePullSecrets` are not consulted for this fetch, because the kubelet is
  not the one fetching. A machine with a private source must name its Secret.
- A docker configuration that delegates to a credential helper (`credsStore`, `credHelpers`) will
  not work: no helper binary exists in the shim, and adding one would mean shipping a cloud
  provider's SDK. A Secret carrying a static `auths` entry is what is supported.

The chart cannot see the Secret's contents at render time, so validation is limited to the name and
the source kind. An authentication failure is a runtime failure, and its message names the reference
and the Secret without echoing anything from inside it.

### The test suites need a registry, because `kind load` stops helping

This is the least obvious consequence of the change and the one most likely to derail an
implementation that does not expect it. Both suites currently rely on an image being present in a
local container store:

- `hack/image-test.sh` builds fixture archives and unpacks them, entirely offline.
- `hack/integration-test.sh` builds `test/integration/Containerfile.source` and `kind load`s it into
  the cluster's containerd, where the kubelet finds it.

A `crane` running inside a pod talks to a registry. It cannot see containerd's image store, so a
`kind load`ed image is invisible to it and the seed fails on a reference that resolves nowhere. Both
suites need a registry instead:

- **`hack/image-test.sh`**: run a `registry:2` container, construct the fixture images with `crane`
  itself — `crane append` builds an image from a layer tarball with no daemon and no builder, so a
  layer carrying `security.capability` and a second layer carrying a `.wh.` whiteout entry are both
  just tarballs made with the GNU tar already in the image — push, then `crane export` and assert.
  The whole test stays offline apart from the registry container beside it.
- **`hack/integration-test.sh`**: the source image has to be pushed to a registry the *pod* can
  reach, which means an in-cluster Service rather than a host-side `localhost:5000`.

TLS is the wrinkle. go-containerregistry chooses `http` rather than `https` for a registry whose
host is `localhost` or ends in `.local`, which an in-cluster name like
`registry.<namespace>.svc.cluster.local:5000` satisfies — so an insecure test registry may work with
no flag and no certificate, and the chart never needs an "insecure registry" input. Verify that
before building the test around it; if it does not hold, serve the test registry over TLS with a
certificate baked into the test's own fixture rather than adding an input to the chart to work
around a test.

### No compatibility handshake between chart and image

The chart's default `shim.image` is pinned by digest and released together with the chart, which is
what makes them one version in practice. A user who overrides `shim.image` with a mismatched build
gets a container whose command does not exist, and the kubelet reports the path it could not
execute — which is already a message that names the cause.

A version file in the image compared against a value from the chart would add a second thing to keep
in step in order to improve a message that is not misleading. It can be added later if a real
mismatch ever proves confusing; it cannot be removed later.

### `seed-oci.sh` becomes an ordinary bash script

Nothing about it runs in a foreign userland any more, so it becomes the mirror image of
`seed-lxc.sh`. `lib-state.sh` and `lib-seed.sh` keep their `sh` dialect for now (see Non-Goals);
`ready.sh` and `stop.sh` keep theirs permanently, because they genuinely do run inside the machine.

## Risks / Trade-offs

- **`crane export` might not preserve `security.capability` through the flatten** → This is the one
  assumption the whole approach rests on, so it is verified before any chart code is written, by
  extending `hack/image-test.sh` with an image whose file carries a capability. If it does not hold,
  the fill switches to `skopeo` + `umoci` and nothing else in this design changes. The property is
  also asserted end to end by the existing integration check on `getcap`.
- **Whiteouts are now our concern** → `crane export` applies them, and the integration test gains a
  source image whose later layer deletes a file an earlier one added, so "the union of the layers"
  cannot pass silently.
- **The shim image grows by roughly 30 MB** → It is pulled once per node and is already the image of
  every container in the pod, so the cost is one-off and bounded, against removing a full pull of
  the source image on every reschedule.
- **A private source needs a Secret that a `ServiceAccount` used to provide** → Breaking for a
  machine with a private OCI source, called out in the proposal and in `values.yaml`. The failure is
  a clear authentication error at seeding time, before anything is written.
- **The chart's default image digest is stale between merge and release** → Sequenced in the
  migration plan below; `make integration-test` builds and loads the image it tests against, so the
  suite never passes on a stale default by accident.
- **`helm upgrade` deletes the per-machine ConfigMap** → It is release-owned and nothing else
  references it. No volume is touched and no machine is re-seeded, because the seeding decision
  reads the volume's own record.

## Migration Plan

1. Verify the capability and whiteout properties of `crane export` in `hack/image-test.sh`. If they
   do not hold, switch the fill to `skopeo` + `umoci` before continuing.
2. Move the scripts, build the image with them, and land the chart change. `values.yaml` still
   points at the previous digest at this point, so the chart is installable only with an explicit
   `shim.image` override — which is what CI and `make integration-test` already do.
3. Cut the release tag. CI publishes the image built from `images/shim`.
4. Bump the default `shim.image` digest in `values.yaml` to the published image, as the release
   commit for the chart version that carries this change.

Rollback is a `helm rollback`: the previous chart revision re-renders the ConfigMap and pins the
previous image digest, and the two match each other. No machine's volume is affected by either
direction, because a seeded volume is never re-seeded.

### Implementation order

Task group 1 is a gate, not a step: it decides which tool the fill uses, and groups 3 and 6 are
written against that answer. Nothing else should start until it is settled.

After that, group 2 (the image) and group 3 (the scripts) touch `images/shim/` only, and group 4
touches `charts/stateful-pods/` only, so those two lines of work do not collide. Group 5 spans both
and has to follow them. Group 6 needs the image, the scripts and the chart all in place, and group 7
needs everything.

## Open Questions

- Whether to drop the POSIX-sh dialect in `lib-state.sh` and `lib-seed.sh` now that nothing sources
  them from a foreign image. Deferred deliberately: it changes no behaviour and would obscure this
  change's diff.
- Whether credential helpers are ever worth supporting for a private source, or whether a static
  `auths` entry is the whole story. Deferrable — it can only add an accepted Secret shape, never
  remove one.
