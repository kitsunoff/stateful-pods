#!/usr/bin/env bash
#
# Points a catalog entry at a reference, and says whether it changed anything.
#
# Small on purpose. The daily workflow does the interesting parts - reading the
# upstream, deciding what has fallen behind, publishing, opening the pull request
# - and this is the one step that edits a file the chart ships, so it is the one
# step worth having on its own where it can be read and tested.
#
# It refuses a reference that is not pinned by digest, and it refuses to invent
# an entry that does not already exist. A bump is a change to what an existing
# name resolves to; adding a preset is a person's decision and involves a line in
# images/presets/presets.list that this cannot write for them.
set -o errexit
set -o nounset
set -o pipefail

CATALOG="charts/stateful-pods/presets.yaml"

die() {
  echo "preset-bump: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: hack/preset-bump.sh [--catalog FILE] PRESET REFERENCE

Points PRESET's catalog entry at REFERENCE, which must be pinned by digest.

Exit codes:
  0  the entry was updated
  1  something is wrong: an unknown preset, or a reference that is not pinned
  2  the entry already names that reference; nothing was written
USAGE
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --catalog) CATALOG="$2"; shift 2 ;;
      --help) usage; return 0 ;;
      --*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done

  [[ $# -eq 2 ]] || { usage >&2; return 1; }
  local preset="$1" reference="$2"

  [[ -f "$CATALOG" ]] || die "the catalog is missing: $CATALOG"

  # Pinned by digest, or it is not a bump this project makes. A tag that came to
  # mean different content later would change a machine's origin without anything
  # in its values changing.
  [[ "$reference" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] ||
    die "$reference is not pinned by digest"

  local current
  current="$(sed -n "s|^${preset}: \\(.*\\)$|\\1|p" "$CATALOG")"
  [[ -n "$current" ]] ||
    die "$preset has no entry in $CATALOG. A bump changes what an existing name resolves to; adding a preset is a decision, and needs a line in images/presets/presets.list too."

  if [[ "$current" == "$reference" ]]; then
    echo "$preset already resolves to $reference"
    return 2
  fi

  # A line rewrite rather than a YAML round trip, so that the file's comments -
  # which are most of it, and explain why every entry is a digest - survive.
  local temporary
  temporary="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$preset: "* ]]; then
      printf '%s: %s\n' "$preset" "$reference"
    else
      printf '%s\n' "$line"
    fi
  done < "$CATALOG" > "$temporary"
  mv "$temporary" "$CATALOG"

  echo "$preset: $current -> $reference"
}

main "$@"
