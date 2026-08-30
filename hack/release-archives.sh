#!/usr/bin/env bash
#
# Builds what a tag publishes for the kubectl plugin: one archive, a checksum
# beside it, and a krew manifest rendered against both.
#
# One archive rather than one per platform. The plugin is a shell script, so
# there is nothing per architecture about it, and publishing four byte-identical
# tarballs with four identical checksums would look like a guarantee it is not
# making. The manifest names the platforms instead, which is where the claim
# belongs.
#
# The version has to be given, and has to be the plugin's own and the chart's.
# `create` defaults its chart reference to the plugin's version, so a plugin
# published under a tag that disagrees with either would install as one version
# and ask a registry for a chart at another. This is the last place that can be
# caught.
set -o errexit
set -o nounset
set -o pipefail

VERSION=""
OUTPUT="dist"
PLUGIN="cmd/kubectl-machine"
MANIFEST="krew/machine.yaml"
CHART="charts/stateful-pods/Chart.yaml"
LICENCE=""

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: hack/release-archives.sh --version <version> [--output <dir>]

  --version <version>   the version being released, without a leading v
  --output <dir>        where to write the archive, the checksums and the
                        manifest (default: dist)
  --plugin <path>       the plugin to package (default: $PLUGIN)
  --licence <path>      a licence file to put in the archive beside it
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)
      [[ "$#" -ge 2 ]] || die "--version needs a value"
      VERSION="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || die "--output needs a value"
      OUTPUT="$2"
      shift 2
      ;;
    --plugin)
      [[ "$#" -ge 2 ]] || die "--plugin needs a value"
      PLUGIN="$2"
      shift 2
      ;;
    --licence | --license)
      [[ "$#" -ge 2 ]] || die "--licence needs a value"
      LICENCE="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$VERSION" ]] || {
  usage >&2
  die "--version is required: this builds a release, and a release has a version"
}
VERSION="${VERSION#v}"
[[ -f "$PLUGIN" ]] || die "there is no plugin at $PLUGIN"
[[ -f "$MANIFEST" ]] || die "there is no krew manifest at $MANIFEST"

plugin_version="$(sed -n 's/^SP_VERSION="\(.*\)"$/\1/p' "$PLUGIN")"
[[ -n "$plugin_version" ]] || die "$PLUGIN declares no SP_VERSION"
[[ "$plugin_version" == "$VERSION" ]] ||
  die "the plugin says it is $plugin_version and this release is $VERSION.
The plugin's version is what it asks a registry for a chart at, so the two cannot
disagree. Set SP_VERSION in $PLUGIN, or tag the version it already claims."

chart_version="$(sed -n 's/^version: //p' "$CHART")"
[[ -n "$chart_version" ]] || die "$CHART declares no version"
[[ "$chart_version" == "$VERSION" ]] ||
  die "the chart says it is $chart_version and this release is $VERSION.
The plugin installs the chart at its own version, so a release publishes both or
neither. Set version in $CHART, or tag the version it already claims."

TAG="v$VERSION"
ARCHIVE_NAME="kubectl-machine_${TAG}.tar.gz"

mkdir -p "$OUTPUT"
staging="$OUTPUT/.staging"
rm -rf "$staging"
mkdir -p "$staging"

install -m 0755 "$PLUGIN" "$staging/kubectl-machine"

if [[ -n "$LICENCE" ]]; then
  [[ -f "$LICENCE" ]] || die "there is no licence file at $LICENCE"
  install -m 0644 "$LICENCE" "$staging/LICENSE"
elif [[ -f LICENSE ]]; then
  install -m 0644 LICENSE "$staging/LICENSE"
else
  # Said on every build rather than passed over: the upstream krew index requires
  # a licence in the archive, so this is what stands between the manifest in this
  # repository and a submission to that index.
  echo "warning: this repository has no LICENSE, so the archive ships without one" >&2
  echo "warning: the upstream krew index requires one before a plugin can be submitted" >&2
fi

tar --create --gzip --file "$OUTPUT/$ARCHIVE_NAME" --directory "$staging" .
rm -rf "$staging"

# Computed from the archive that was just written, and never from anywhere else.
# A published digest that does not match what it is published with is worse than
# no digest, because it is believed.
digest="$(cd "$OUTPUT" && sha256sum "$ARCHIVE_NAME" | cut -d' ' -f1)"
(cd "$OUTPUT" && sha256sum "$ARCHIVE_NAME" > SHA256SUMS)

sed \
  -e "s|__TAG__|$TAG|g" \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__SHA256__|$digest|g" \
  "$MANIFEST" > "$OUTPUT/machine.yaml"

if grep --quiet '__' "$OUTPUT/machine.yaml"; then
  die "the rendered manifest still has a placeholder in it:
$(grep '__' "$OUTPUT/machine.yaml")"
fi

echo "==> $OUTPUT/$ARCHIVE_NAME"
echo "==> $OUTPUT/SHA256SUMS ($digest)"
echo "==> $OUTPUT/machine.yaml (krew manifest for $TAG)"
