#!/usr/bin/env bash
#
# Keeps the five most recent builds of each preset and removes the older ones.
#
# Removing a build is safe for machines because a machine reads its source once,
# when its volume is seeded, and never again. A running machine seeded from a
# removed build is unaffected even when it is rescheduled; only a new
# installation naming that build would fail. That is only true since the seeding
# step stopped fetching the source on every start, which is why this job could
# not have existed before.
#
# It is safe for the registry because of the planner it calls, and for no other
# reason. A multi-architecture image is a tagged index whose per-architecture
# manifests are package versions of their own, so the obvious implementation -
# an action set to remove untagged versions - deletes the architectures out from
# under every tag being kept. `hack/preset-retention.jq` decides instead from
# which build a version belongs to, and protects every digest a retained build
# still points at.
#
# Two things follow from a preset's package being named for its distribution and
# its tags for its release. A package can hold more than one release, so the unit
# of retention is a release rather than a package - five builds of Noble, not
# five builds of Ubuntu - and this runs once per preset over a package it shares.
# And each release publishes a rolling tag that follows its newest build, which
# is a name people use directly and which shares a digest with a dated tag; it is
# never counted as a build and is never deleted. Both are decided in the planner,
# where the fixtures are.
#
# The deleting path takes no injectable input. The plan is computed from the
# registry and from the packages API, both read live, and `--plan` is a separate
# mode that reads a document on standard input and deletes nothing. A test can
# put any fixture it likes in front of the decision without there being a way to
# put a fixture in front of the deletion.
#
# Short flags on `rm` for the reason hack/seccomp-test.sh gives: BSD rm rejects
# the long forms and this runs on a developer's machine too.
set -o errexit
set -o nounset
set -o pipefail

KEEP=5
OWNER=""
DRY_RUN=0
# A blast radius, enforced by the planner so that it is reachable by the same
# fixtures as every other part of the decision. Raising it is a deliberate act on
# a run someone is watching.
MAX_DELETIONS=8
PLAN_ONLY=0
REGISTRY="ghcr.io"
PLATFORMS="linux/amd64,linux/arm64"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname -- "$SCRIPT_DIR")"
CATALOG_FILE="$ROOT_DIR/images/presets/presets.list"
PLANNER="$SCRIPT_DIR/preset-retention.jq"

die() {
  echo "preset-retention: $*" >&2
  exit 1
}

note() {
  echo "==> $*"
}

usage() {
  cat <<'USAGE'
Usage: hack/preset-retention.sh [options] [preset...]

Options:
  --owner NAME   The user the packages belong to. Taken from the git remote when
                 not given. A user, specifically: the endpoints here are
                 /users/{owner} and /user, and an organisation's packages live
                 under /orgs/{org}, which nothing here reaches for yet.
  --keep N       How many builds of each preset to keep. Defaults to 5.
  --dry-run      Work out what would be removed and report it, delete nothing.
  --max-deletions N
                 Refuse to delete more than this many versions of one preset in
                 a single run. Defaults to 8.
  --plan         Read a planning document on standard input, write the plan to
                 standard output, and stop. Touches no registry and no package.
  --help         This.

With no preset named, every preset in the catalog is considered.
USAGE
}

# --- the plan -----------------------------------------------------------------

plan_from_stdin() {
  jq --from-file "$PLANNER"
}

# --- talking to the registry and the packages API -----------------------------

package_versions() {
  local package="$1"
  gh api --paginate "/users/$OWNER/packages/container/$package/versions?per_page=100" \
    --jq '[.[] | {id: .id, digest: .name, tags: (.metadata.container.tags // [])}]' |
    jq --slurp 'add // []'
}

# The children of every tagged index, so that the planner knows what a retained
# build still points at. Read from the registry rather than inferred from tag
# names: what an index references is the registry's answer to give.
index_children() {
  local repository="$1" versions="$2"
  local digest manifest media children="{}"
  while IFS= read -r digest; do
    [[ -n "$digest" ]] || continue
    # A read that fails is not evidence that this is a leaf. Treating it as one
    # would drop an index out of the children map, and the planner protects
    # exactly what that map says a retained build points at - so the failure
    # would be in the direction that deletes things.
    manifest="$(crane manifest "$repository@$digest" 2>&1)" ||
      die "could not read $repository@$digest from the registry, so what a retained build points at is unknown. Nothing was deleted. The registry said: $manifest"
    media="$(jq --raw-output '.mediaType // ""' <<< "$manifest")"
    if [[ "$media" != *"index"* && "$media" != *"manifest.list"* ]]; then
      continue
    fi
    children="$(jq --argjson existing "$children" --arg digest "$digest" \
      '$existing + {($digest): [.manifests[].digest]}' <<< "$manifest")"
  done < <(jq --raw-output '.[] | select((.tags | length) > 0) | .digest' <<< "$versions")
  printf '%s\n' "$children"
}

delete_version() {
  local package="$1" id="$2"
  gh api --method DELETE "/user/packages/container/$package/versions/$id" >/dev/null
}

# --- the check that matters ---------------------------------------------------

# A retained tag that no longer resolves for every architecture is the exact
# damage a naive retention step does, and it is invisible until someone installs
# a machine. So it is asserted after every run rather than reasoned about.
#
# After, necessarily: there is nothing to check until the deletions have
# happened. That makes a failure here a report rather than a rescue, which is
# why the planner is where the care is and this is where the proof is.
verify_retained() {
  local repository="$1" plan="$2"
  local reference platform failures=0
  local -a platform_list=()
  IFS=',' read -r -a platform_list <<< "$PLATFORMS"
  # The release's rolling tag alongside the builds. It is a reference people use
  # directly, it shares a digest with a dated tag so a deletion takes both names,
  # and it is the one thing here that a run is allowed to have moved - so it is
  # checked by the same code rather than reasoned about.
  while IFS= read -r reference; do
    [[ -n "$reference" ]] || continue
    for platform in "${platform_list[@]}"; do
      if ! crane manifest --platform "$platform" "$repository:$reference" >/dev/null 2>&1; then
        echo "FAIL: $repository:$reference no longer resolves for $platform" >&2
        failures=$((failures + 1))
      fi
    done
  done < <(jq --raw-output '.retained_builds[], .release' <<< "$plan")

  if [[ "$failures" -gt 0 ]]; then
    die "$failures retained reference(s) are incomplete after this run"
  fi
  note "every retained build and the rolling tag still resolve for every platform"
}

# --- one preset ---------------------------------------------------------------

retain_preset() {
  local preset="$1"
  local fields release family
  fields="$(catalog_lookup "$preset")"
  read -r release family <<< "$fields"
  # The catalog's field is the distribution - `ubuntu` - and the package is that
  # with the project's prefix. Composed once, here, because everything below
  # names a package: the versions endpoint, the deletion endpoint and the
  # repository. Carrying the bare field around and prefixing it at each use is
  # how one of those came to be missed.
  local package="stateful-pods-$family"
  local repository="$REGISTRY/$OWNER/$package"

  # Every release published into this repository, not only this one. A package is
  # named for a distribution and a tag for a release, so a second release of the
  # same distribution lands here too - and its rolling tag would otherwise be a
  # tag the planner cannot classify, which stops the run.
  local releases
  releases="$(package_releases "$family")"

  local versions children plan
  versions="$(package_versions "$package")"
  if [[ "$(jq 'length' <<< "$versions")" == "0" ]]; then
    note "$preset: no versions published, nothing to do"
    return 0
  fi

  children="$(index_children "$repository" "$versions")"
  # A dry run wants the whole plan however large it is; that is the point of
  # looking. Only a run that would act is held to the limit.
  local limit="$MAX_DELETIONS"
  [[ "$DRY_RUN" == "1" ]] && limit=null
  plan="$(jq --null-input --argjson keep "$KEEP" --argjson versions "$versions" \
    --argjson children "$children" --argjson maxDeletions "$limit" \
    --arg release "$release" --argjson releases "$releases" \
    '{keep: $keep, max_deletions: $maxDeletions, release: $release,
      releases: $releases, versions: $versions, children: $children}' |
    plan_from_stdin)"

  if [[ "$(jq --raw-output 'has("error")' <<< "$plan")" == "true" ]]; then
    case "$(jq --raw-output '.error' <<< "$plan")" in
      "tags that do not name a build")
        die "$(printf '%s\n' \
          "$preset: there are tags here that do not name a build:" \
          "$(jq --raw-output '.unparsable[] | "  " + .' <<< "$plan")" \
          "Ordering by build date is the whole basis of this decision, so a tag whose" \
          "date cannot be read makes it a guess. Nothing was deleted." \
          "If one of them is a bare release name, it is the rolling tag of a release that" \
          "has been removed from images/presets/presets.list while this package went on" \
          "holding others. Restore the line, or remove the tag.")"
        ;;
      "no release to retain")
        die "$(printf '%s\n' \
          "$preset: no release was given to retain, so there is no scope for the plan." \
          "Every build in $package would fall outside the retained set." \
          "Nothing was deleted. The release comes from images/presets/presets.list.")"
        ;;
      *)
        die "$(printf '%s\n' \
          "$preset: the plan removes $(jq --raw-output '.would_delete' <<< "$plan") versions, over the limit of $(jq --raw-output '.max_deletions' <<< "$plan")." \
          "A day's retention removes one build, which is three versions. A number" \
          "this size means something other than a day has passed - a backlog worth" \
          "looking at, or a plan worth doubting. Nothing was deleted." \
          "Run with --dry-run to see it, or --max-deletions if it is what you meant.")"
        ;;
    esac
  fi

  local removed keeping
  keeping="$(jq --raw-output '.retained_builds | length' <<< "$plan")"
  removed="$(jq --raw-output '.delete | length' <<< "$plan")"
  note "$preset: keeping $keeping build(s) of $release, protecting the $release tag, removing $removed version(s)"

  if [[ "$removed" == "0" ]]; then
    return 0
  fi

  jq --raw-output '.delete[] | "    \(.kind) \(.digest) \(.tags | join(","))"' <<< "$plan"

  if [[ "$DRY_RUN" == "1" ]]; then
    note "$preset: dry run, nothing was deleted"
    return 0
  fi

  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    delete_version "$package" "$id"
  done < <(jq --raw-output '.delete[].id' <<< "$plan")

  verify_retained "$repository" "$plan"
}

# --- entry point --------------------------------------------------------------

catalog_names() {
  local name rest
  while IFS=';' read -r name rest || [[ -n "$name" ]]; do
    [[ "$name" == \#* || -z "$name" || -z "$rest" ]] && continue
    printf '%s\n' "$name"
  done < "$CATALOG_FILE"
}

# Echoes "release package" for a preset, or fails.
catalog_lookup() {
  local want="$1" name release package
  # The distribution and the variant identify the upstream build and are the
  # build's business, not this one's, so they are read into the throwaway.
  while IFS=';' read -r name _ release _ package || [[ -n "$name" ]]; do
    [[ "$name" == \#* || -z "$package" ]] && continue
    if [[ "$name" == "$want" ]]; then
      printf '%s %s\n' "$release" "$package"
      return 0
    fi
  done < "$CATALOG_FILE"

  die "\"$want\" is not a preset this project publishes; presets are listed in $CATALOG_FILE"
}

# Every release published into one package, as a JSON array. The planner needs
# them to tell a rolling tag from a tag it cannot read, and it refuses to plan
# rather than guess - so a release missing from here would stop the run, not
# silently widen it.
package_releases() {
  local want="$1" name release package
  {
    while IFS=';' read -r name _ release _ package || [[ -n "$name" ]]; do
      [[ "$name" == \#* || -z "$package" ]] && continue
      # An `if` rather than an `&&`, because a while loop's status is its last
      # body command's and the last line here is ordinarily the one that did not
      # match. Under errexit that made the assignment this feeds fail, and the
      # run ended without a word.
      if [[ "$package" == "$want" ]]; then
        printf '%s\n' "$release"
      fi
    done < "$CATALOG_FILE"
  } | jq --raw-input --slurp 'split("\n") | map(select(length > 0))'
}

remote_owner() {
  local url owner
  url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)"
  url="${url%.git}"
  [[ -n "$url" ]] || return 0
  owner="${url%/*}"
  owner="${owner##*[:/]}"
  [[ "$owner" == "$url" ]] || printf '%s\n' "$owner"
}

main() {
  local -a presets=()
  local name

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) OWNER="$2"; shift 2 ;;
      --keep) KEEP="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --max-deletions) MAX_DELETIONS="$2"; shift 2 ;;
      --plan) PLAN_ONLY=1; shift ;;
      --help) usage; return 0 ;;
      --*) die "unknown option: $1" ;;
      *) presets+=("$1"); shift ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || die "jq is needed and was not found"
  [[ -f "$PLANNER" ]] || die "the planner is missing: $PLANNER"

  if [[ "$PLAN_ONLY" == "1" ]]; then
    plan_from_stdin
    return 0
  fi

  [[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep takes a number, not $KEEP"
  [[ "$KEEP" -ge 1 ]] || die "--keep must be at least 1; keeping nothing is not retention"
  [[ "$MAX_DELETIONS" =~ ^[0-9]+$ ]] || die "--max-deletions takes a number, not $MAX_DELETIONS"

  local tool
  for tool in crane gh; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is needed and was not found"
  done

  [[ -n "$OWNER" ]] || OWNER="$(remote_owner)"
  [[ -n "$OWNER" ]] || die "could not work out the package owner from the git remote; pass --owner"

  if [[ "${#presets[@]}" -eq 0 ]]; then
    # A read loop rather than mapfile, which is bash 4 and this repository's
    # macOS bash is 3.2. The same reason the flags above are the short ones.
    while IFS= read -r name; do
      [[ -n "$name" ]] && presets+=("$name")
    done < <(catalog_names)
  fi
  [[ "${#presets[@]}" -gt 0 ]] || die "the catalog at $CATALOG_FILE lists no presets"

  local preset
  for preset in "${presets[@]}"; do
    retain_preset "$preset"
  done
}

main "$@"
