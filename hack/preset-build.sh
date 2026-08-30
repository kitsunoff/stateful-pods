#!/usr/bin/env bash
#
# Turns an upstream LXC root filesystem into a preset image.
#
# A preset is the distribution's own archive with an OCI manifest wrapped around
# it. Nothing is built: the verified `rootfs.tar.xz` is decompressed and appended
# as the image's single layer, so the bytes that were verified are the bytes that
# are published. An extraction-based build was measured against this and drops
# the POSIX ACLs Debian and Ubuntu carry on /var/log/journal, which is why there
# is no Containerfile here.
#
# The order is the point. Nothing is fetched before the pinned key is confirmed,
# nothing is packaged before the signature over the checksum list verifies
# against that key, and nothing is pushed before the archive matches the verified
# checksum. Every one of those failures is a hard stop, because each of them
# produces an image that looks entirely correct and whose contents nobody
# established - and this image becomes a privileged machine's root filesystem.
#
# Both architectures are published as one index, so that a machine resolves its
# own architecture from the reference and the user never picks one. They must be
# the same upstream build: a tag that named two different days depending on which
# architecture you pulled would not be the immutable identity a machine's source
# has to have.
#
# The per-architecture manifests are tagged too, with the same build identity and
# the architecture appended. That is deliberate. An index's children are
# ordinarily untagged package versions, and "delete untagged" is the standard way
# a retention job destroys a tagged multi-architecture image. Tagging them does
# not make the retention job's reference counting unnecessary - two builds can
# still share an identical manifest - but it does mean the registry holds no
# untagged versions for anything to sweep away by accident.
#
# The parsing here is bash rather than awk, and the flags are the portable ones,
# because this runs on a CI runner where `awk` is mawk and on a developer's
# machine where `sed` is BSD. A build that works in one place and not the other
# is a build nobody can check before pushing.
#
# Usage:
#   hack/preset-build.sh [options] [preset...]
#
# With no preset named, every preset in the catalog is built.
set -o errexit
set -o nounset
set -o pipefail

# The key linuxcontainers.org signs its published checksums with, pinned here as
# well as committed at images/presets/signing-key.asc. Two places, on purpose: a
# build that only checked the signature against the key sitting next to it would
# establish that this repository is consistent with itself, which is not a
# security property. Replacing the key file alone stops the build.
#
# Confirmed out of band against keyserver.ubuntu.com and keys.openpgp.org, which
# agree on the key, its identity and its creation date. Changing this value is a
# decision a person makes and a reviewer sees, not a fix.
PINNED_KEY_FINGERPRINT="E7FB0CAEC8173D669066514CBAEFF88C22F6E216"

# The upstream is an override rather than a constant so that the verification can
# be tested against a mirror on the local filesystem. It is not a way to relax
# anything: a mirror serving different bytes fails the same signature check, which
# is the whole reason the check is against a pinned key rather than against
# whatever the server offers alongside them.
MIRROR="https://images.linuxcontainers.org"
PLATFORMS="linux/amd64,linux/arm64"
REPOSITORY=""
SOURCE_URL=""
RESOLVE_ONLY=0
CHECK_KEY=0
WORK_DIR=""
OWN_WORK_DIR=0

# Distinct from a plain failure so that a caller can tell "the upstream has not
# finished this build yet" from "something is wrong". The daily bump treats it as
# nothing to do today; a person running the build by hand sees why.
EXIT_UPSTREAM_NOT_READY=3

# Short flags on `rm` and `mkdir` throughout, against this repository's usual
# rule and for the reason hack/seccomp-test.sh gives: BSD rm and BSD mkdir reject
# the long forms, and this script runs on a developer's Mac as readily as on the
# runner. A cleanup that silently does nothing is worse than an ugly flag.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname -- "$SCRIPT_DIR")"
KEY_FILE="$ROOT_DIR/images/presets/signing-key.asc"
CATALOG_FILE="$ROOT_DIR/images/presets/presets.list"

die() {
  echo "preset-build: $*" >&2
  exit 1
}

not_ready() {
  echo "preset-build: $*" >&2
  exit "$EXIT_UPSTREAM_NOT_READY"
}

# Progress goes to stderr, because stdout is the result: one line per preset,
# tab separated, which the publishing workflow and the integration test both
# read. A script whose output another script consumes has no business narrating
# on the same channel.
note() {
  echo "==> $*" >&2
}

usage() {
  cat <<'USAGE'
Usage: hack/preset-build.sh [options] [preset...]

Options:
  --repository PREFIX  Repository prefix to publish under; the preset name is
                       appended. Defaults to ghcr.io/<owner>/stateful-pods-,
                       with the owner taken from the git remote.
  --mirror URL         Where to read the upstream index and archives from.
                       Defaults to https://images.linuxcontainers.org.
  --platforms LIST     Comma-separated platforms. Defaults to
                       linux/amd64,linux/arm64.
  --resolve-only       Report the upstream build each preset would be made from
                       and stop. Fetches no archive and publishes nothing.
  --check-key          Confirm the committed key is the pinned one, print the
                       fingerprint, and stop.
  --work-dir DIR       Where to download and decompress. Defaults to a
                       temporary directory that is removed on exit.
  --help               This.

Exit codes:
  0  every named preset was published, or was already published
  1  something is wrong: a bad signature, a checksum mismatch, an index that
     cannot be parsed, an unknown preset, or the wrong signing key
  3  the upstream is not ready: it offers no build of a preset's release for
     one of the platforms, or the platforms are on different builds
USAGE
}

# --- the pinned key -----------------------------------------------------------

# The fingerprint of the committed key, read without importing it: an import
# needs an agent, and needing a daemon to answer "which key is this" is a way for
# the answer to be unavailable rather than wrong.
committed_key_fingerprint() {
  [[ -f "$KEY_FILE" ]] || die "the pinned signing key is missing: $KEY_FILE"

  local field_type rest fingerprint=""
  while IFS=':' read -r field_type _ _ _ _ _ _ _ _ rest _; do
    if [[ "$field_type" == "fpr" ]]; then
      fingerprint="$rest"
      break
    fi
  done < <(gpg --show-keys --with-colons "$KEY_FILE" 2>/dev/null)

  [[ -n "$fingerprint" ]] || die "$KEY_FILE does not contain a readable public key"
  printf '%s\n' "$fingerprint"
}

assert_pinned_key() {
  local found
  found="$(committed_key_fingerprint)"
  if [[ "$found" != "$PINNED_KEY_FINGERPRINT" ]]; then
    die "$(printf '%s\n' \
      "images/presets/signing-key.asc is not the pinned key." \
      "  pinned in hack/preset-build.sh: $PINNED_KEY_FINGERPRINT" \
      "  found in signing-key.asc:       $found" \
      "Upstream rotating its signing key is a decision someone has to make and record." \
      "Establish the new key out of band, then change both places in one reviewed commit.")"
  fi
}

# A keyring gpgv can read. Built fresh each run from the committed key, so no
# state anywhere can carry a key this repository does not pin.
build_keyring() {
  local keyring="$WORK_DIR/pinned-key.gpg"
  gpg --dearmor < "$KEY_FILE" > "$keyring" 2>/dev/null ||
    die "could not read $KEY_FILE as an armoured public key"
  printf '%s\n' "$keyring"
}

# --- the catalog --------------------------------------------------------------

catalog_names() {
  local name rest
  while IFS=';' read -r name rest || [[ -n "$name" ]]; do
    [[ "$name" == \#* || -z "$name" || -z "$rest" ]] && continue
    printf '%s\n' "$name"
  done < "$CATALOG_FILE"
}

catalog_name_list() {
  local name list=""
  while IFS= read -r name; do
    list="${list:+$list, }$name"
  done < <(catalog_names)
  printf '%s\n' "$list"
}

# Echoes "distro release variant" for a preset, or fails listing what exists.
catalog_lookup() {
  local want="$1" name distro release variant
  while IFS=';' read -r name distro release variant || [[ -n "$name" ]]; do
    [[ "$name" == \#* || -z "$variant" ]] && continue
    if [[ "$name" == "$want" ]]; then
      printf '%s %s %s\n' "$distro" "$release" "$variant"
      return 0
    fi
  done < "$CATALOG_FILE"

  die "$(printf '%s\n' \
    "\"$want\" is not a preset this project publishes." \
    "  available: $(catalog_name_list)" \
    "Presets are listed in images/presets/presets.list.")"
}

# --- the upstream index -------------------------------------------------------

fetch_to() {
  curl --silent --show-error --location --fail --output "$2" "$1"
}

# Every line is checked, not only the ones this build cares about. The index is a
# scrape rather than an API, so a format change is a thing to stop on: parsing
# what still fits and ignoring the rest is how a build ends up publishing
# whatever it managed to read.
fetch_index() {
  local index="$WORK_DIR/index-system"
  fetch_to "$MIRROR/meta/1.0/index-system" "$index" ||
    die "could not read the upstream index at $MIRROR/meta/1.0/index-system"

  local line number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ -n "$line" ]] || continue
    if ! [[ "$line" =~ ^[^\;]+\;[^\;]+\;[^\;]+\;[^\;]+\;[0-9]{8}_[0-9]{2}:[0-9]{2}\;/[^\;]*$ ]]; then
      die "$(printf '%s\n' \
        "index-system line $number does not parse:" \
        "  $line" \
        "Expected distro;release;arch;variant;date;path with the date as YYYYMMDD_HH:MM." \
        "The index is a published text file rather than an API, so a change to its" \
        "format stops the build instead of being guessed at.")"
    fi
  done < "$index"

  printf '%s\n' "$index"
}

# The upstream lists exactly one build per distro, release, architecture and
# variant, so there is nothing to choose between: this is a lookup, not a search.
# Echoes "date path", or nothing.
index_lookup() {
  local index="$1" want_distro="$2" want_release="$3" want_arch="$4" want_variant="$5"
  local distro release arch variant date path
  while IFS=';' read -r distro release arch variant date path || [[ -n "$distro" ]]; do
    if [[ "$distro" == "$want_distro" && "$release" == "$want_release" &&
          "$arch" == "$want_arch" && "$variant" == "$want_variant" ]]; then
      printf '%s %s\n' "$date" "$path"
      return 0
    fi
  done < "$index"
}

# --- identity -----------------------------------------------------------------

# The upstream writes its build as 20260829_05:24. A colon is not a legal
# character in an OCI tag, so it comes out. Nothing else changes: the date stays
# readable and stays sortable, which is what the retention job orders by.
tag_date() {
  printf '%s\n' "${1//:/}"
}

# Who is publishing, so that a fork publishes to its own packages and labels its
# images with its own source rather than with this repository's.
#
# The repository prefix wins when it is given, because that is where the images
# are actually going and a source label naming somewhere else would be worse than
# no label. The git remote is the fallback, for a run that named no repository.
# Neither is fatal here: only publishing needs an owner, and the caller decides.
remote_owner() {
  local url owner
  url="$(git --git-dir "$ROOT_DIR/.git" config --get remote.origin.url 2>/dev/null || true)"
  url="${url%.git}"
  [[ -n "$url" ]] || return 0
  owner="${url%/*}"
  owner="${owner##*[:/]}"
  [[ "$owner" == "$url" ]] || printf '%s\n' "$owner"
}

# ghcr.io/kitsunoff/stateful-pods- -> kitsunoff
repository_owner() {
  local without_registry="${1#*/}"
  local owner="${without_registry%%/*}"
  [[ "$owner" == "$without_registry" ]] || printf '%s\n' "$owner"
}

# --- verification -------------------------------------------------------------

sha256_of() {
  local output
  output="$(sha256sum "$1")"
  printf '%s\n' "${output%% *}"
}

# Downloads one architecture's build and establishes what it is, in the only
# order in which the answer means anything: the signature over the checksum list
# first, then the archive against that list. Echoes the archive's checksum.
verify_archive() {
  local base="$1" directory="$2" keyring="$3"

  fetch_to "$base/SHA256SUMS" "$directory/SHA256SUMS" ||
    die "could not fetch the checksum list at $base/SHA256SUMS"
  fetch_to "$base/SHA256SUMS.asc" "$directory/SHA256SUMS.asc" ||
    die "$(printf '%s\n' \
      "could not fetch the signature at $base/SHA256SUMS.asc" \
      "The upstream publishes a detached signature beside every checksum list." \
      "A build with no signature to check is not a build this project publishes.")"

  if ! gpgv --keyring "$keyring" \
      "$directory/SHA256SUMS.asc" "$directory/SHA256SUMS" >"$directory/gpgv.log" 2>&1; then
    die "$(printf '%s\n' \
      "the signature over $base/SHA256SUMS does not verify." \
      "  expected signer: $PINNED_KEY_FINGERPRINT" \
      "  gpgv said:" \
      "$(sed 's/^/    /' "$directory/gpgv.log")" \
      "Nothing was packaged. Either the checksum list is not the upstream's, or" \
      "upstream has rotated its signing key - which is a decision to record, not" \
      "a failure to work around.")"
  fi

  local checksum name expected=""
  while read -r checksum name || [[ -n "$checksum" ]]; do
    if [[ "${name#\*}" == "rootfs.tar.xz" ]]; then
      expected="$checksum"
      break
    fi
  done < "$directory/SHA256SUMS"
  [[ -n "$expected" ]] ||
    die "the verified checksum list at $base/SHA256SUMS does not cover rootfs.tar.xz"

  fetch_to "$base/rootfs.tar.xz" "$directory/rootfs.tar.xz" ||
    die "could not fetch the root filesystem at $base/rootfs.tar.xz"

  local actual
  actual="$(sha256_of "$directory/rootfs.tar.xz")"
  if [[ "$actual" != "$expected" ]]; then
    die "$(printf '%s\n' \
      "$base/rootfs.tar.xz does not match the verified checksum." \
      "  signed checksum: $expected" \
      "  what was served: $actual" \
      "Nothing was packaged.")"
  fi

  printf '%s\n' "$expected"
}

# --- packaging ----------------------------------------------------------------

# The layer is the archive. crane appends it as-is and crane mutate sets the
# platform and the provenance afterwards; neither writes a command, an entry
# point or an environment, so a preset carries nothing this project decided.
package_arch() {
  local reference="$1" archive="$2" platform="$3" preset="$4"
  local upstream_url="$5" upstream_build="$6" upstream_sha256="$7" directory="$8"

  local tarball="$directory/rootfs.tar"
  xz --decompress --stdout "$archive" > "$tarball"

  crane append --oci-empty-base --new_layer "$tarball" --new_tag "$reference" >/dev/null
  crane mutate "$reference" --tag "$reference" \
    --set-platform "$platform" \
    --label "org.opencontainers.image.title=$preset" \
    --label "org.opencontainers.image.description=Unmodified $preset root filesystem from images.linuxcontainers.org, packaged for the stateful-pods chart" \
    --label "org.opencontainers.image.url=$upstream_url" \
    --label "org.opencontainers.image.version=$upstream_build" \
    --label "org.opencontainers.image.source=$SOURCE_URL" \
    --label "io.stateful-pods.preset.name=$preset" \
    --label "io.stateful-pods.preset.upstream.url=$upstream_url" \
    --label "io.stateful-pods.preset.upstream.build=$upstream_build" \
    --label "io.stateful-pods.preset.upstream.sha256=$upstream_sha256" \
    --label "io.stateful-pods.preset.upstream.key=$PINNED_KEY_FINGERPRINT" >/dev/null

  # What was verified is what is now published, proved rather than assumed. The
  # layer's diff_id is the SHA-256 of its uncompressed content, so this is a
  # byte-for-byte comparison against the archive the signature covered - every
  # extended attribute, mode and ordering decision included. An inventory of the
  # properties someone thought to check is what nearly let a dropped POSIX ACL
  # through when this build was designed.
  local published expected
  published="$(crane config "$reference" | jq --raw-output '.rootfs.diff_ids[0]')"
  expected="sha256:$(sha256_of "$tarball")"
  if [[ "$published" != "$expected" ]]; then
    die "$(printf '%s\n' \
      "$reference is not the archive it was built from." \
      "  published layer:  $published" \
      "  verified archive: $expected")"
  fi

  rm -f "$tarball"
}

# --- one preset ---------------------------------------------------------------

build_preset() {
  local preset="$1" index="$2" keyring="$3"

  local fields distro release variant
  fields="$(catalog_lookup "$preset")"
  read -r distro release variant <<< "$fields"

  local -a platform_list=()
  IFS=',' read -r -a platform_list <<< "$PLATFORMS"

  # Resolve every platform before touching any of them, so that an incomplete
  # upstream is reported as one thing rather than discovered half way through.
  local platform arch entry
  local -a arches=() dates=() paths=()
  for platform in "${platform_list[@]}"; do
    [[ "$platform" == linux/* ]] || die "only linux platforms are supported: $platform"
    arch="${platform#linux/}"
    entry="$(index_lookup "$index" "$distro" "$release" "$arch" "$variant")"
    if [[ -z "$entry" ]]; then
      not_ready "$(printf '%s\n' \
        "the upstream offers no $variant build of $distro $release for $platform." \
        "A preset covers every architecture this project supports or it is not" \
        "published: a root filesystem for the wrong architecture seeds without" \
        "error and produces a machine that cannot execute its own init.")"
    fi
    arches+=("$arch")
    dates+=("${entry%% *}")
    paths+=("${entry#* }")
  done

  local position reported build="${dates[0]}"
  for position in "${!dates[@]}"; do
    if [[ "${dates[$position]}" != "$build" ]]; then
      not_ready "$(printf '%s\n' \
        "the architectures of $preset are on different upstream builds:" \
        "$(for reported in "${!dates[@]}"; do
             printf '  %s: %s\n' "${arches[$reported]}" "${dates[$reported]}"
           done)" \
        "One tag cannot honestly name two different days. This is what a rebuild" \
        "in progress looks like; the next run will find them level.")"
    fi
  done

  local repository="$REPOSITORY$preset"
  local tag
  tag="$release-$(tag_date "$build")"

  if [[ "$RESOLVE_ONLY" == "1" ]]; then
    printf '%s\t%s\t%s\n' "$preset" "$build" "$repository:$tag"
    return 0
  fi

  # A published tag is immutable. Re-running a build for one that already exists
  # is a no-op rather than a push, so that a workflow re-run cannot change what a
  # reference already means.
  if crane manifest "$repository:$tag" >/dev/null 2>&1; then
    note "$preset: $repository:$tag is already published, leaving it alone"
    printf '%s\t%s\t%s@%s\n' "$preset" "$build" "$repository" "$(crane digest "$repository:$tag")"
    return 0
  fi

  local -a children=()
  local directory upstream_url checksum
  for position in "${!arches[@]}"; do
    arch="${arches[$position]}"
    directory="$WORK_DIR/$preset/$arch"
    mkdir -p "$directory"
    upstream_url="$MIRROR${paths[$position]%/}"

    note "$preset/$arch: verifying $upstream_url"
    checksum="$(verify_archive "$upstream_url" "$directory" "$keyring")"

    note "$preset/$arch: packaging $repository:$tag-$arch"
    package_arch "$repository:$tag-$arch" "$directory/rootfs.tar.xz" \
      "linux/$arch" "$preset" "$upstream_url" "$build" "$checksum" "$directory"
    children+=("--manifest" "$repository:$tag-$arch")
    rm -rf "$directory"
  done

  note "$preset: combining into $repository:$tag"
  crane index append "${children[@]}" --tag "$repository:$tag" >/dev/null

  printf '%s\t%s\t%s@%s\n' "$preset" "$build" "$repository" "$(crane digest "$repository:$tag")"
}

# --- entry point --------------------------------------------------------------

cleanup() {
  [[ "$OWN_WORK_DIR" == "1" ]] && rm -rf "$WORK_DIR"
  return 0
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is needed and was not found"
  done
}

main() {
  local -a presets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repository) REPOSITORY="$2"; shift 2 ;;
      --mirror) MIRROR="${2%/}"; shift 2 ;;
      --platforms) PLATFORMS="$2"; shift 2 ;;
      --resolve-only) RESOLVE_ONLY=1; shift ;;
      --check-key) CHECK_KEY=1; shift ;;
      --work-dir) WORK_DIR="$2"; shift 2 ;;
      --help) usage; return 0 ;;
      --*) die "unknown option: $1" ;;
      *) presets+=("$1"); shift ;;
    esac
  done

  require_tools gpg
  assert_pinned_key
  if [[ "$CHECK_KEY" == "1" ]]; then
    printf 'images/presets/signing-key.asc carries the pinned key %s\n' "$PINNED_KEY_FINGERPRINT"
    return 0
  fi

  require_tools curl
  # Resolving reads the index and stops. It verifies nothing and packages
  # nothing, so it does not get to demand the tools that would.
  [[ "$RESOLVE_ONLY" == "1" ]] || require_tools gpgv sed sha256sum crane jq xz

  if [[ "${#presets[@]}" -eq 0 ]]; then
    mapfile -t presets < <(catalog_names)
  fi
  [[ "${#presets[@]}" -gt 0 ]] || die "the catalog at $CATALOG_FILE lists no presets"

  local owner=""
  if [[ -n "$REPOSITORY" ]]; then
    owner="$(repository_owner "$REPOSITORY")"
  else
    owner="$(remote_owner)"
    [[ -n "$owner" ]] ||
      die "could not work out where to publish from the git remote; pass --repository"
    REPOSITORY="ghcr.io/$owner/stateful-pods-"
  fi
  SOURCE_URL="https://github.com/${owner:-kitsunoff}/stateful-pods"

  if [[ -z "$WORK_DIR" ]]; then
    # The archives are large and one of them is a root filesystem. Leaving them
    # behind on a shared runner is not a tidiness question.
    WORK_DIR="$(mktemp -d)"
    OWN_WORK_DIR=1
  fi
  trap cleanup EXIT

  # Every name is looked up before anything is fetched. A typo should not cost a
  # download, and it should not be reported after three presets have already been
  # published either.
  local preset
  for preset in "${presets[@]}"; do
    catalog_lookup "$preset" >/dev/null
  done

  local keyring index
  keyring="$(build_keyring)"
  index="$(fetch_index)"

  for preset in "${presets[@]}"; do
    build_preset "$preset" "$index" "$keyring"
  done
}

main "$@"
