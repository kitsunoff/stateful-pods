## Context

See `proposal.md` — Why. Two constraints shape everything below.

The first is structural. `charts/stateful-pods/values.yaml` pins `shim.image` by digest, on purpose:
a machine is a pet whose disk must be reproducible, and a tag that comes to mean different content
makes its own boot path unreproducible. The scripts the chart's containers run live inside that
image. So the chart and the image are a matched pair, and the pair is ordered — a digest can only be
written down after the image it names has been pushed. The digest in `values.yaml` today was written
in the first chart commit and predates the change that moved the scripts into the image by four pull
requests, so it names an image that does not contain `seed-oci.sh`, `prepare.sh`, `customize.sh` or
`boot.sh`. A default install renders four containers whose commands do not exist.

The second is operational and temporary. GitHub Actions on this account will not start jobs: every
run since the billing failure completes in three to five seconds with zero steps and the annotation
*"The job was not started because recent account payments have failed or your spending limit needs
to be increased."* Verified again at the start of this change. The release is the tag build, so no
tag can be cut until that is fixed. This design therefore has to be executable by someone else,
later, from what is written down.

## Goals / Non-Goals

**Goals:**

- Settle the order the first two tags go in, and record why the first cannot be the installable one.
- Leave the repository in a state where cutting the release is a sequence of named commands rather
  than a set of judgements to re-make.
- Fix the release-quality defects that are cheap and provable locally, given that CI cannot check
  anything.

**Non-Goals:**

- Redesigning when CI publishes. The pipeline is verified here, not rebuilt.
- Publishing anything by hand. Building and pushing the shim from this machine would produce exactly
  the artefact the release is supposed to produce, from an unrecorded builder, and would defeat the
  point of the release going through CI.
- Making the published packages public. GitHub exposes no API for package visibility.

## Decisions

### The first release is two tags, and `v0.1.0` is the bootstrap

**Decision.** `v0.1.0` mints the shim image. Its digest is then read out of the registry and
committed to `values.yaml`. `v0.1.1` is the first chart that installs and boots with no `--set`.

The ordering is forced, and it is worth showing why rather than asserting it. Within the pipeline as
written, a tag runs `chart`, `plugin`, `image` and `integration`, and `chart` publishes the chart on
any tag. So on the first tag the chart is published no matter what, and on the first tag no correct
digest can exist yet — the image that would carry one is being built by the same run. There is no
ordering of a single tag in which the chart publishes a digest of an image that tag produces.

Three alternatives were considered and rejected.

*Substituting the digest at package time* — rejected outright, and not on balance. It would make the
published chart differ from the chart in git, so nobody could reproduce the artefact from the source
that claims to be it. Reproducibility is the entire reason the value is a digest rather than a tag.

*A prerelease bootstrap* (`v0.1.0-rc.1` mints the image, `v0.1.0` is the first real release) is the
more elegant shape, and was the working plan for a while. It is rejected on cost. Both
`hack/release-archives.sh` and the `chart` job require the tag, `Chart.yaml`'s `version` and the
plugin's `SP_VERSION` to be the same string, so cutting an rc means moving all three to
`0.1.0-rc.1` and then back to `0.1.0` — two extra version-bump commits — and the `release` job would
publish an rc as the repository's latest release unless it were also taught `--prerelease`. That is
three edits to the release path, none of which any suite covers and none of which CI can run. Buying
a prettier version number with unverifiable changes to the release path is the wrong trade while
Actions is down.

*Giving the shim image its own tag trigger* (`shim-v*` publishes the image, `v*` publishes the chart)
is the design that actually matches the model `values.yaml` already describes — "a fix to a script is
an image release plus the digest below". It is the right long-term answer and it is rejected only for
now: it needs the tag-conditional steps in `chart` and `release` narrowed from `refs/tags/` to
`refs/tags/v`, a second trigger, and the image's version derived from a prefixed tag. Six edits to
the publishing path, verifiable only by CI. Filed as an issue instead.

So the honest outcome is the plain one: `v0.1.0` is a real tag that publishes a real shim image and a
chart that still needs `--set shim.image=...`, exactly as `charts/stateful-pods/README.md` already
documents; `v0.1.1` is the first release anyone should install. `RELEASE.md` says so in those words,
and the `v0.1.0` release notes say it too, so nobody has to infer it from a version number.

### The `image` job waits for the suites; the `chart` job already does

`release` carries a comment explaining why it waits — publishing an archive out of a build that went
red puts a broken plugin behind a checksum. The argument transfers to `image` unchanged and was not
applied to it. On a tag `image` publishes concurrently with everything else, gated only by its own
`make image-test`, so a red `make test`, `make conform` or `integration` leaves an image already
pushed and immutable at that tag. It is the half of the matched pair with no gate, which matters
more here than usual because the other half pins it by digest.

`needs: [chart, plugin]`, matching `release`. This does serialise the image build behind the chart
job on pull requests, which lengthens feedback — accepted, because the alternative is splitting the
publish into a fourth job, which is more workflow surface to get wrong while nothing can run it.

`chart` keeps no `needs` and that is correct, not an oversight: every suite it depends on runs as an
earlier step *inside* it, and a failed step aborts the job before the publish. `integration`
publishes nothing.

### A malformed checksum is refused by its form, not by its type

The obvious reading of the float bug is that a `| toString` is missing. It is not — `_helpers.tpl`
already has one, and the value still renders as `1.23...e+61`, because YAML resolved the scalar to a
float long before any template function saw it. `toString` then stringifies the float faithfully.

So the check has to be on the resulting string's shape: exactly sixty-four characters of `0-9a-f`.
One rule catches the float, the truncated paste, the uppercase digest that could never equal the
lowercase one `sha256sum` prints, and the full `sha256sum` line pasted with its filename. Anchoring
on the shape rather than on the YAML type also means the rule keeps working if a future Helm or Go
YAML version resolves the scalar differently.

### The LXC unpack borrows the OCI path's exclusions, as a word list

`lib-oci.sh` builds `--exclude` arguments from `SP_RUNTIME_DIRS` because `mknod(2)` is checked
against the *initial* user namespace, so a machine in `userns` mode can never create a device node
and `tar` fails the whole seed over content `sp_ensure_runtime_dirs` wipes and recreates a moment
later anyway. `lib-lxc.sh` unpacks without them, and an LXC template is far likelier than a
`crane export` stream to ship real device nodes under `./dev` — Proxmox templates routinely do.

`lib-oci.sh` is `# shellcheck shell=bash` and uses an array. `lib-lxc.sh` is `# shellcheck shell=sh`,
which has no arrays, so the exclusions are built as a space-separated word list and expanded
unquoted, the way `$SP_TAR_FLAGS` already is in that file. Promoting the file to bash to gain arrays
would be a larger change than the fix.

### The research documents are annotated, not corrected

`docs/research/05-open-questions.md` §3 describes a privilege ladder whose third rung is
"`privileged` — works everywhere, gives up almost all isolation", and
`docs/research/03-mapping-and-architecture.md` §3.6 says to "fall back to `privileged: true`". The
chart has rendered no blanket privileged flag since `bounded-privileged-mode`; the mode is
`drop: [ALL]` plus a named list. The first is under a **Decided.** heading, which makes it read as
current.

These files are the research that preceded the chart, and `docs/research/README.md` frames them that
way. Rewriting them to match today's chart would destroy the record of what was believed when the
decisions were taken, which is the only reason to keep them. So each stale section gets a
superseded-by line pointing at the spec that now governs, and the text below it is left alone.

## Risks / Trade-offs

- **CI cannot verify any of this** → every target CI would run is run locally at the final commit,
  with the tool versions CI pins, and the report says which ran and which could not. The two changes
  no local suite covers — `needs:` on a job, and `.helmignore`'s effect on a tag build — are the two
  smallest and most inspectable in the change.
- **`v0.1.0` publishes a chart that needs `--set`** → it is documented as the bootstrap in
  `RELEASE.md` and in its own release notes, and `v0.1.1` follows immediately. The alternative
  shapes cost unverifiable edits to the release path; see the decision above.
- **A form check on `sha256` could refuse a value that used to render** → it could, and that is the
  point: every value it refuses is a value that fails later, after a download. No example, no test
  fixture and no documented value in the repository is affected; all are already quoted lowercase
  hex.
- **The LXC exclusions change what lands on the volume** → only in the runtime directories, which
  `sp_ensure_runtime_dirs` wipes and recreates immediately after the fill returns, for both source
  kinds. The content excluded is content the LXC path currently pays an `EPERM` for and then throws
  away.
- **Alpine 3.24 breaks the shim and must not be merged** → found while reviewing the open Dependabot
  pull requests, and it is not a test artefact. Alpine 3.24 ships crane 0.21, which drops
  go-containerregistry's rule that a registry whose name ends in `.local` is spoken to over plain
  HTTP. That rule is what lets a machine seed from an in-cluster
  `<service>.<namespace>.svc.cluster.local` registry with no insecure-registry input in the chart,
  and `hack/image-test.sh` and `hack/integration-test.sh` both rest on it. Reproduced against both
  bases. The bump is closed rather than merged, and the underlying problem — that the project is
  pinned to Alpine 3.22 until it has an answer for insecure registries — is filed.

## Migration Plan

`RELEASE.md` holds the executable version. In outline, and only once Actions runs again:

1. Confirm a workflow run reaches its steps. Until then, stop here.
2. Tag `v0.1.0`. This publishes the shim image, the plugin archive with its checksum and krew
   manifest, and a chart that still needs `--set shim.image=...`.
3. Read the digest the run published, from the registry rather than from a local build.
4. Commit that digest to `values.yaml`, drop the two `--set shim.image` caveats from
   `charts/stateful-pods/README.md`, and move `Chart.yaml`'s `version`, its `appVersion` and the
   plugin's `SP_VERSION` to `0.1.1`.
5. Tag `v0.1.1`. This is the first release to install unaided.

Rollback is deletion of a tag and its release before anyone depends on it; a published chart version
is never rewritten, only superseded.

## Open Questions

None that change the specs, the approach or the tasks. Two decisions belong to the account owner
rather than to this change: whether the published packages are made public, which has no API and
must be done by hand, and whether the preset retention workflow is given the token it needs to
delete anything. Both are filed.
