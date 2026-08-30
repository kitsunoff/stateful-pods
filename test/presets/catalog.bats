#!/usr/bin/env bats
#
# What the check between the two catalogs must refuse.
#
# `charts/stateful-pods/presets.yaml` is written by a bot and `images/presets/presets.list`
# is written by hand, and the two have to agree about more than a name. An entry
# that stopped being a digest would make a machine's source mean different
# content later, invisibly; an entry naming a repository that is not the preset's
# package resolves for as long as the wrong image happens to exist. Neither is
# something a rendering test can see.

bats_require_minimum_version 1.5.0

CHECK="hack/check-presets.sh"

setup() {
  CATALOG="$BATS_TEST_TMPDIR/presets.yaml"
  PRESET_LIST="$BATS_TEST_TMPDIR/presets.list"
  cp charts/stateful-pods/presets.yaml "$CATALOG"
  cp images/presets/presets.list "$PRESET_LIST"
}

check() {
  run --separate-stderr "$CHECK" "$CATALOG" "$PRESET_LIST"
}

# Against the files where they live, rather than the copies the refusals below
# work on. The check packages the chart beside the catalog it was given, so a
# copy in a temporary directory is a chart that does not package - which would
# fail this for a reason that has nothing to do with what it asserts, the day
# helm appears in the image this suite runs in.
@test "the pair this project ships agrees with itself" {
  run --separate-stderr "$CHECK"
  [ "$status" -eq 0 ]
}

# The package is the fifth field, and a line that lost it would leave every entry
# checked against `stateful-pods-` with nothing after it - a check that passes by
# accident rather than one that fails.
@test "a preset line missing its package is refused" {
  printf 'fedora-42;fedora;42;default\n' >> "$PRESET_LIST"
  check
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a preset line"* ]]
  [[ "$stderr" == *"preset;distro;release;variant;package"* ]]
}

@test "a preset line with a field too many is refused" {
  printf 'fedora-42;fedora;42;default;fedora;extra\n' >> "$PRESET_LIST"
  check
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"not a preset line"* ]]
}

# The package is not the preset's name, so this is the one relationship a reader
# cannot check by eye against the entry alone.
#
# The wrong repository here is the one a preset used to publish into before it
# moved to the cloud variant. That package still exists and still holds the
# builds a released chart resolves to, so an entry left pointing at it resolves,
# pulls, and seeds a machine with a root filesystem that has no cloud-init in it.
# Nothing downstream would report that; this is where it is caught.
#
# Debian rather than Ubuntu, because Ubuntu has not moved to the cloud variant
# yet - its variantless package is the one it correctly publishes into, so it
# would not be wrong.
@test "an entry resolving to a repository that is not the preset's package is refused" {
  local digest="sha256:0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
  printf 'debian-trixie: ghcr.io/kitsunoff/stateful-pods-debian@%s\n' "$digest" \
    > "$BATS_TEST_TMPDIR/replacement"
  grep --invert-match '^debian-trixie: ' "$CATALOG" > "$BATS_TEST_TMPDIR/rest"
  cat "$BATS_TEST_TMPDIR/rest" "$BATS_TEST_TMPDIR/replacement" > "$CATALOG"
  check
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"is not named stateful-pods-debian-cloud"* ]]
}

@test "an entry pinned by tag rather than by digest is refused" {
  printf 'void-current: ghcr.io/kitsunoff/stateful-pods-void:current\n' >> "$CATALOG"
  check
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"is not pinned by digest"* ]]
}

# A name with no package is a name this project does not build. It has to be
# reported for what it is: the lookup that answers "which package" returns
# nothing here, and falling off the end of it under errexit would end the run
# without a word instead.
@test "an entry for a preset nobody builds is reported rather than ending the run" {
  local digest="sha256:0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
  printf 'fedora-42: ghcr.io/kitsunoff/stateful-pods-fedora@%s\n' "$digest" >> "$CATALOG"
  check
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"fedora-42 is not a preset this project builds"* ]]
  # The run carried on past it: the presets that are built are still checked,
  # and the one that is missing from the catalog is still reported.
  [[ "$stderr" != *"fedora-42 is built but absent"* ]]
}
