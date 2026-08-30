#!/usr/bin/env bats
#
# What the preset build must refuse.
#
# The success path is exercised by publishing: a preset that did not build is a
# preset nobody can pull, and that failure is loud. The failures below are the
# quiet ones. Each of them would produce an image that looks entirely correct -
# right name, right size, right architecture - and whose contents nobody
# established. That is the only thing that makes a preset worth more than an
# `lxc` source with a checksum the user found themselves, so it is what has
# tests.
#
# Every case here runs against the key this repository pins, using a real
# upstream checksum list and its real detached signature as the fixture. A
# fixture signed by a key invented for the test would prove that gpgv runs, not
# that this build trusts the right signer.
#
# The registry these run against is a port nothing listens on. If the build ever
# reached the packaging step the failure would be a connection error, so the
# assertions on the message are also assertions that nothing was packaged.

# --separate-stderr, so that a refusal written to stderr is not read as output.
bats_require_minimum_version 1.5.0

BUILD="hack/preset-build.sh"
NOWHERE="localhost:1/unused-"
FIXTURES="test/presets/fixtures"

# The build the fixture checksum list attests to.
FIXTURE_DATE="20260829_05:24"
FIXTURE_SHA256="c2eed8f2bf4fe70287ba9244161f30aefdb86328f5759d7efcdbf2b8a92288d6"

setup() {
  MIRROR="$BATS_TEST_TMPDIR/mirror"
  mkdir --parents "$MIRROR/meta/1.0"
}

# Adds one build of debian trixie per named architecture to the index, and lays
# down a directory for each with the real signed checksum list and whatever
# archive bytes the caller wants.
#
# Usage: mirror_build_append <date> <archive-content> <arch>...
mirror_build_append() {
  local date="$1" content="$2"
  shift 2
  local arch dir
  for arch in "$@"; do
    printf 'debian;trixie;%s;default;%s;/images/debian/trixie/%s/default/%s/\n' \
      "$arch" "$date" "$arch" "$date" >> "$MIRROR/meta/1.0/index-system"
    dir="$MIRROR/images/debian/trixie/$arch/default/$date"
    mkdir --parents "$dir"
    cp "$FIXTURES/SHA256SUMS" "$FIXTURES/SHA256SUMS.asc" "$dir/"
    printf '%s' "$content" > "$dir/rootfs.tar.xz"
  done
}

# The same, from an empty index.
mirror_build() {
  : > "$MIRROR/meta/1.0/index-system"
  mirror_build_append "$@"
}

build() {
  run "$BUILD" --mirror "file://$MIRROR" --repository "$NOWHERE" "$@"
}

@test "the pinned fingerprint and the committed key are the same key" {
  run "$BUILD" --check-key
  [ "$status" -eq 0 ]
  [[ "$output" == *"E7FB0CAEC8173D669066514CBAEFF88C22F6E216"* ]]
}

@test "a checksum list that does not verify against the pinned key stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  # One byte of the signed text, which is all a signature is for.
  local arch
  for arch in arm64 amd64; do
    sed 's/^c2ee/c2ef/' "$FIXTURES/SHA256SUMS" \
      > "$MIRROR/images/debian/trixie/$arch/default/$FIXTURE_DATE/SHA256SUMS"
  done

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature"* ]]
  [[ "$output" == *"E7FB0CAEC8173D669066514CBAEFF88C22F6E216"* ]]
  [[ "$output" != *"connect"* ]]
}

@test "a signature stripped out entirely stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  local arch
  for arch in arm64 amd64; do
    printf 'not a signature\n' \
      > "$MIRROR/images/debian/trixie/$arch/default/$FIXTURE_DATE/SHA256SUMS.asc"
  done

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature"* ]]
}

@test "a checksum list the upstream never served stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  rm --force "$MIRROR"/images/debian/trixie/*/default/"$FIXTURE_DATE"/SHA256SUMS.asc

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA256SUMS.asc"* ]]
}

@test "an archive that does not match the verified checksum stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"rootfs.tar.xz"* ]]
  # Both checksums, so that the reader can see which one is the surprise.
  [[ "$output" == *"$FIXTURE_SHA256"* ]]
  [[ "$output" != *"connect"* ]]
}

@test "an archive the checksum list does not cover stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  local arch
  for arch in arm64 amd64; do
    grep --invert-match 'rootfs.tar.xz' "$FIXTURES/SHA256SUMS" \
      > "$MIRROR/images/debian/trixie/$arch/default/$FIXTURE_DATE/SHA256SUMS"
  done

  # The list no longer verifies, because removing a line changed the signed
  # bytes. That is the honest outcome and the one the build must report.
  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"signature"* ]]
}

@test "an index line that cannot be parsed stops the build" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  printf 'debian;trixie;arm64;default\n' >> "$MIRROR/meta/1.0/index-system"

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"index-system"* ]]
  [[ "$output" == *"debian;trixie;arm64;default"* ]]
}

@test "a release offered for only one architecture is refused, naming the platform" {
  mirror_build "$FIXTURE_DATE" "not the archive" amd64

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"linux/arm64"* ]]
}

@test "architectures that disagree on the newest build are not published as one" {
  # amd64 has moved ahead and arm64 has not. The upstream lists one build per
  # architecture, so this is two dates rather than an extra line, and the two are
  # no longer the same build of trixie: one tag cannot honestly name both.
  local ahead="20260830_05:24"
  mirror_build "$FIXTURE_DATE" "not the archive" arm64
  mirror_build_append "$ahead" "not the archive" amd64

  build debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"$ahead"* ]]
  [[ "$output" == *"$FIXTURE_DATE"* ]]
}

@test "a preset the catalog does not list is refused, listing the ones it does" {
  build debian-forky
  [ "$status" -ne 0 ]
  [[ "$output" == *"debian-forky"* ]]
  [[ "$output" == *"debian-trixie"* ]]
  [[ "$output" == *"void-current"* ]]
}

@test "resolving reports the build every architecture agrees on, and fetches nothing" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64

  build --resolve-only debian-trixie
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian-trixie"* ]]
  [[ "$output" == *"$FIXTURE_DATE"* ]]
}

# The repository is named for the distribution and the tag for the release.
@test "a preset resolves into the package named in the catalog, tagged with its release" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64

  build --resolve-only debian-trixie
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r _ _ reference <<< "$output"
  [ "$reference" = "${NOWHERE}debian:trixie-20260829_0524" ]
}

# The package is a field in the catalog rather than a rule about anything, and
# `void-current` is the preset that makes the point: the upstream calls the
# distribution `voidlinux`, a person calls the preset `void-current`, and the
# package is `stateful-pods-void`. Neither of the other two names would give
# that, so this is the assertion that the field is being read.
@test "the package comes from the catalog, not from the upstream's name for the distribution" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  local arch
  for arch in amd64 arm64; do
    printf 'voidlinux;current;%s;default;%s;/images/voidlinux/current/%s/default/%s/\n' \
      "$arch" "$FIXTURE_DATE" "$arch" "$FIXTURE_DATE" >> "$MIRROR/meta/1.0/index-system"
  done

  # Resolving reads the index and stops, so this needs no archive for a
  # distribution the fixture does not carry one for.
  build --resolve-only void-current
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r _ _ reference <<< "$output"
  [ "$reference" = "${NOWHERE}void:current-20260829_0524" ]
}

@test "a key file that is not the pinned key stops the build before anything is fetched" {
  # The build resolves its key relative to itself, so a tree with a different key
  # in it is the only way to ask this question - and the only way it can be asked
  # by accident, which is the case that matters.
  local tree="$BATS_TEST_TMPDIR/tree"
  mkdir --parents "$tree"
  cp --recursive hack images test "$tree/"

  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir --parents "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key \
    'Not The Upstream <nobody@example.invalid>' default default never
  gpg --batch --quiet --armor --export 'nobody@example.invalid' \
    > "$tree/images/presets/signing-key.asc"

  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64
  run "$tree/hack/preset-build.sh" --mirror "file://$MIRROR" \
    --repository "$NOWHERE" debian-trixie
  [ "$status" -ne 0 ]
  [[ "$output" == *"E7FB0CAEC8173D669066514CBAEFF88C22F6E216"* ]]
  [[ "$output" == *"signing-key.asc"* ]]
}

# The result is the contract. `hack/integration-test.sh` and both publishing
# workflows read this stdout as tab-separated fields, so a line of narration on
# the same channel becomes a reference someone tries to resolve - which is
# exactly what happened the first time this ran end to end.
@test "the build narrates on stderr and keeps stdout to its result" {
  mirror_build "$FIXTURE_DATE" "not the archive" arm64 amd64

  run --separate-stderr "$BUILD" --mirror "file://$MIRROR" \
    --repository "$NOWHERE" --resolve-only debian-trixie
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | tr --delete --complement '\t' | wc --chars)" -eq 2 ]
    [[ "$line" != "==>"* ]]
  done <<< "$output"
}
