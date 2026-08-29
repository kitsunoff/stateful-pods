## 1. Shell test harness and the toolbox image

- [x] 1.1 Add `shellcheck` and a `bats` suite to the repository with a `make shell-lint` and `make shell-test` target, wired into `make all` and CI; verify both targets pass on an empty suite and fail on a deliberately broken script
- [x] 1.2 Write the `Containerfile` for the toolbox image — busybox base plus GNU `tar`, `xz`, `zstd`, `gzip` and `bash` — and verify by building it locally and running `tar --version`, `zstd --version` and `bash --version` inside it
- [x] 1.3 Write a test that asserts the built image can unpack a `.tar.zst` archive preserving a `security.capability` attribute, and verify it fails against a busybox-only image
- [x] 1.4 Add a CI job that builds the image for `linux/amd64` and `linux/arm64` on every pull request without pushing; verify the job produces both architectures
- [x] 1.5 Add the publish path to CI — push to the registry on a tag only — and verify the workflow parses and the push step is skipped for a pull request
- [x] 1.6 Publish the first image build and record its digest; verify the digest resolves to a manifest list carrying both architectures

## 2. The seeding state machine

Tests come first in every pair below — write the failing test, then make it pass.

- [x] 2.1 Write the `bats` suite for the four volume states (marked; interrupted; empty and unmarked; non-empty and unmarked), asserting the action each one produces; verify it fails before any script exists
- [x] 2.2 Implement the state decision as a script in the chart's script directory, reading only the volume and the environment; verify 2.1 passes
- [x] 2.3 Write and satisfy the test that a non-empty, unmarked volume fails with a message saying the contents were not created by the chart and that nothing was touched; verify the volume is unchanged after the failure
- [x] 2.4 Write and satisfy the test that an interrupted attempt (`seeding` present, marker absent) wipes everything except `.stateful-pods/` and seeds again; verify a file left by the previous attempt is gone afterwards

## 3. Seeding an OCI source

- [x] 3.1 Write the `bats` suite for the archiver probe: GNU `tar` with extended-attribute support passes, a busybox `tar` fails naming the `lxc` source kind as the alternative; verify both cases
- [x] 3.2 Implement the OCI seed script in POSIX `sh`, including the probe; verify it runs under `dash` as well as `bash` and that `shellcheck` accepts it with the `sh` dialect
- [x] 3.3 Implement the copy with Proxmox's `COMMON_TAR_FLAGS` and `--exclude=./dev/*`; verify a test asserts that a file carrying `security.capability` in the source keeps it on the target and that no device node is copied
- [x] 3.4 Write and satisfy the test that `/proc`, `/sys` and the mounted volume itself are excluded from the copy without being named, through `--one-file-system`; verify by seeding from a source with those paths mounted
- [x] 3.5 Write and satisfy the test that the runtime directories exist and are empty on the seeded volume; verify each of `/dev`, `/proc`, `/sys`, `/run` and `/tmp`
- [x] 3.6 Write and satisfy the test that a full volume reports the out-of-space failure naming the volume and the source, and leaves no marker; verify against a small loopback filesystem

## 4. Seeding an LXC template

- [x] 4.1 Write the `bats` suite for the checksum gate: a matching digest proceeds, a mismatch fails naming that the bytes are not the ones the machine asked for and unpacks nothing; verify both cases
- [x] 4.2 Write the `bats` suite for the archive inspection — no `sbin` entry, fewer than ten members, a multi-volume member — asserting each is rejected before extraction begins; verify with fixture archives built in the test
- [x] 4.3 Implement the LXC seed script: download to `.stateful-pods/download/`, verify, inspect, extract with the same archive flags, delete the tarball; verify 4.1 and 4.2 pass
- [x] 4.4 Write and satisfy the test that an unreachable URL fails naming the URL and the transport error, and that no guest-visible content is written; verify with a URL that cannot resolve
- [x] 4.5 Write and satisfy the test that `.tar.zst`, `.tar.xz` and `.tar.gz` templates all extract; verify each format with a fixture archive

## 5. The marker and machine identity

- [x] 5.1 Write the `bats` suite for the marker: written only after seeding succeeds, carrying the resolved source, the timestamp, the chart version, the machine's namespace, release and machine name, and a schema version; verify it fails before implementation
- [x] 5.2 Implement the `prepare` script writing the marker and removing the `seeding` file; verify 5.1 passes and that the marker is absent when the seed step failed
- [x] 5.3 Write and satisfy the test that `/etc/machine-id` is left present and empty and that a stale `/var/lib/dbus/machine-id` is removed; verify both files after seeding
- [x] 5.4 Write and satisfy the `bats` suite for clone detection: a marker naming a different namespace, release or machine name clears the identity and rewrites the marker, while a matching one changes nothing; verify each of the three fields independently
- [x] 5.5 Write and satisfy the test that a detected clone is not re-seeded and loses nothing beyond the machine identity; verify a file written by the original guest is still present afterwards

## 6. Rendering the init containers

- [x] 6.1 Write the unittest suite asserting a machine renders exactly two init containers named `seed` and `prepare`, in that order, both mounting the rootfs volume at `/mnt/rootfs`; verify it fails before implementation
- [x] 6.2 Write the unittest suite asserting the `seed` container's image is the machine's `source.reference` for an `oci` source and the chart's image for an `lxc` source, while `prepare` is always the chart's image; verify it fails before implementation
- [x] 6.3 Render the scripts into a ConfigMap named for the machine and mount it into both init containers; verify a unittest asserts every script the containers invoke is a key of that ConfigMap
- [x] 6.4 Implement the init containers, passing every value through environment variables and mounted files and never interpolating a value into script text; verify a unittest asserts that a machine name containing shell metacharacters appears only in an environment variable
- [x] 6.5 Write and satisfy the unittest suite for the init containers' security context: no added capability, not privileged, no privilege escalation, running as the container's root user, in both security modes; verify each assertion fails if the corresponding field is introduced
- [x] 6.6 Update the `machine-topology` assertions that forbid init containers and any source-derived image, so that an `oci` source is permitted exactly on the `seed` container and nowhere else; verify the guest container's image is still asserted to be the chart's image for both source kinds
- [x] 6.7 Write and satisfy the unittest suite asserting the guest container is the only container carrying the mode's privilege, for both `userns` and `privileged`; verify by asserting on every container in the pod

## 7. Chart inputs, defaults and documentation

- [x] 7.1 Replace the `shim.image` placeholder default with the digest recorded in 1.6 and remove the placeholder assertions written to force this; verify a unittest asserts the default is a digest reference rather than a tag
- [x] 7.2 Update `values.yaml` comments to describe what seeding does, that it happens once, and that a changed source is ignored afterwards; verify `make docs` passes and every key still carries an adjacent comment
- [x] 7.3 Document the source prerequisites in the chart README — an `oci` source needs a shell and GNU `tar` with extended-attribute support, an Alpine source must use the `lxc` kind, and the volume must have room for the compressed template on top of the unpacked result; verify by review against the failure messages the scripts emit
- [x] 7.4 Update `NOTES.txt` to say that the volume is seeded from the machine's source on first start and that the machine still does not boot; verify a unittest asserts both statements

## 8. Verification

- [x] 8.1 Add a `kind` integration job that installs the chart with an `oci` source in `privileged` mode and asserts the volume is seeded, the marker is present and a capability attribute survived; verify the job fails if the copy flags are removed
- [x] 8.2 Extend the integration job to a small `lxc` template source and assert the same; verify both source kinds are covered by a single job run
- [x] 8.3 Add the integration assertion that a restart does not re-seed: write a file into the volume, restart the pod, and verify the file is still there and the marker is unchanged
- [x] 8.4 Validate the rendered manifests for both example values files against the Kubernetes API schemas with the init containers present; verify `make conform` passes
- [x] 8.5 Cross-check every scenario in `specs/rootfs-seeding/spec.md`, `specs/machine-identity/spec.md`, `specs/shim-image/spec.md` and the two delta specs against the test suites, and extend the coverage table in the chart README; verify every scenario has at least one corresponding test
