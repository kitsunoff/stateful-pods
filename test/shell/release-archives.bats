#!/usr/bin/env bats
#
# What a tag build produces for the plugin: an archive, a checksum beside it, and
# a krew manifest pointing at both.
#
# The checksum is the part worth testing. A published digest that does not match
# the archive it is published with is worse than no digest at all, because it is
# believed - so it is computed here from the archive that was actually written,
# and the manifest is checked to carry that same value.

bats_require_minimum_version 1.5.0

SCRIPT="hack/release-archives.sh"

setup() {
    OUT="$BATS_TEST_TMPDIR/dist"
    VERSION="$(sed -n 's/^version: //p' charts/stateful-pods/Chart.yaml)"
}

release() {
    run --separate-stderr "$SCRIPT" --version "$VERSION" --output "$OUT" "$@"
}

archive() { printf '%s/kubectl-machine_v%s.tar.gz' "$OUT" "$VERSION"; }

@test "the archive carries the plugin, under the name kubectl finds it by" {
    release
    [ "$status" -eq 0 ]
    [ -f "$(archive)" ]
    tar --list --file "$(archive)" | grep --quiet '^\./kubectl-machine$\|^kubectl-machine$'
}

@test "the plugin comes out of the archive executable" {
    release
    [ "$status" -eq 0 ]
    tar --extract --file "$(archive)" --directory "$BATS_TEST_TMPDIR"
    [ -x "$BATS_TEST_TMPDIR/kubectl-machine" ]
}

@test "the published checksum is the checksum of the published archive" {
    release
    [ "$status" -eq 0 ]
    [ -f "$OUT/SHA256SUMS" ]
    ( cd "$OUT" && sha256sum --check SHA256SUMS )
}

@test "the manifest carries the same checksum as the archive" {
    release
    [ "$status" -eq 0 ]
    local digest
    digest="$(sha256sum "$(archive)" | cut -d' ' -f1)"
    grep --quiet "sha256: $digest" "$OUT/machine.yaml"
}

@test "the manifest is rendered at the version that was asked for" {
    release
    [ "$status" -eq 0 ]
    grep --quiet "version: v$VERSION" "$OUT/machine.yaml"
    ! grep --quiet '__' "$OUT/machine.yaml"
}

@test "the manifest names the platforms the plugin supports, and no others" {
    release
    [ "$status" -eq 0 ]
    grep --quiet 'darwin' "$OUT/machine.yaml"
    grep --quiet 'linux' "$OUT/machine.yaml"
    ! grep --quiet 'windows' "$OUT/machine.yaml"
}

@test "the manifest points at a release asset for the tag it was built for" {
    release
    [ "$status" -eq 0 ]
    grep --quiet "releases/download/v$VERSION/kubectl-machine_v$VERSION.tar.gz" "$OUT/machine.yaml"
}

# A plugin whose version has drifted from the tag would install as one version and
# ask a registry for a chart at another. The build is where that has to stop.
@test "a version that is not the plugin's own is refused" {
    run --separate-stderr "$SCRIPT" --version 9.9.9 --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"9.9.9"* ]]
    [ ! -f "$OUT/machine.yaml" ]
}

@test "a version that is not the chart's is refused too" {
    # The plugin's version is edited to disagree with the chart's, which is the
    # drift this guard exists for.
    local copy="$BATS_TEST_TMPDIR/kubectl-machine"
    sed 's/^SP_VERSION=.*/SP_VERSION="9.9.9"/' cmd/kubectl-machine > "$copy"
    run --separate-stderr "$SCRIPT" --version 9.9.9 --output "$OUT" --plugin "$copy"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"chart"* ]]
}

@test "no version at all is refused" {
    run --separate-stderr "$SCRIPT" --output "$OUT"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"--version"* ]]
}

# The repository ships no licence, and the upstream krew index requires one in
# the archive. That is a gap in the repository rather than in this script, so it
# is said out loud on every build instead of being silently fine.
@test "a missing licence is reported rather than passed over" {
    release
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"LICENSE"* ]]
}

@test "a licence that is there is put in the archive" {
    local licence="$BATS_TEST_TMPDIR/LICENSE"
    printf 'a licence\n' > "$licence"
    release --licence "$licence"
    [ "$status" -eq 0 ]
    tar --list --file "$(archive)" | grep --quiet 'LICENSE'
}
