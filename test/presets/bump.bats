#!/usr/bin/env bats
#
# The one step of the daily bump that edits a file the chart ships.
#
# What it must not do is more interesting than what it does. A catalog entry that
# stopped being a digest would make a machine's source mean different content
# later, invisibly, and an entry invented for a preset nobody builds would resolve
# until the day it did not.

bats_require_minimum_version 1.5.0

BUMP="hack/preset-bump.sh"
PINNED="ghcr.io/kitsunoff/stateful-pods-debian-trixie@sha256:1eef004a4aea2e838a185c57c1390667f0a4b79b31bb8e329e6ffb4b98fee33c"
NEWER="ghcr.io/kitsunoff/stateful-pods-debian-trixie@sha256:0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"

setup() {
  CATALOG="$BATS_TEST_TMPDIR/presets.yaml"
  cp charts/stateful-pods/presets.yaml "$CATALOG"
}

# --separate-stderr, because the refusals are the interesting cases and they are
# what this writes to stderr.
bump() {
  run --separate-stderr "$BUMP" --catalog "$CATALOG" "$@"
}

entry() {
  sed -n "s|^$1: \(.*\)$|\1|p" "$CATALOG"
}

@test "a bump points the entry at the new reference" {
  bump debian-trixie "$NEWER"
  [ "$status" -eq 0 ]
  [ "$(entry debian-trixie)" = "$NEWER" ]
}

@test "a bump leaves every other entry alone" {
  local before
  before="$(entry ubuntu-noble)"
  bump debian-trixie "$NEWER"
  [ "$status" -eq 0 ]
  [ "$(entry ubuntu-noble)" = "$before" ]
}

# The file is mostly comments, and they are what explain why every entry is a
# digest. A YAML round trip would drop them and the next reader would not know.
@test "a bump keeps the comments that explain the file" {
  local before
  before="$(grep --count '^#' "$CATALOG")"
  bump debian-trixie "$NEWER"
  [ "$status" -eq 0 ]
  [ "$(grep --count '^#' "$CATALOG")" -eq "$before" ]
}

@test "an unchanged reference reports itself and writes nothing" {
  bump debian-trixie "$PINNED"
  [ "$status" -eq 2 ]
  run diff "$CATALOG" charts/stateful-pods/presets.yaml
  [ "$status" -eq 0 ]
}

@test "a reference that is not pinned by digest is refused" {
  bump debian-trixie ghcr.io/kitsunoff/stateful-pods-debian-trixie:trixie-20260830_0524
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not pinned by digest"* ]]
  [ "$(entry debian-trixie)" = "$PINNED" ]
}

@test "a preset with no entry is refused rather than invented" {
  bump debian-forky "$NEWER"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"has no entry"* ]]
  [[ "$stderr" == *"presets.list"* ]]
}

# The catalog the chart ships has to stay something check-presets.sh accepts,
# and a bump is the only thing that routinely writes to it.
@test "the catalog still passes its own checks after a bump" {
  bump debian-trixie "$NEWER"
  [ "$status" -eq 0 ]
  run hack/check-presets.sh "$CATALOG" images/presets/presets.list
  [ "$status" -eq 0 ]
}
