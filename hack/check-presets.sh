#!/usr/bin/env bash
#
# Checks the catalog the chart ships against the list of presets this project
# builds.
#
# The catalog is written by a bot, which is exactly why it is checked. A bump
# that landed a tag instead of a digest would make a machine's source mean
# different content later without anything in the user's values changing, and it
# would do it invisibly - the reference would still resolve, and the machine
# would still come up. That is the failure this exists to catch, and it is not
# one a rendering test can see.
#
# The two files also have to agree in both directions. A catalog entry for a
# preset nobody builds is a name that stops resolving the day its last build ages
# out of retention; a preset that is built and not in the catalog is work nobody
# can use.
set -o errexit
set -o nounset
set -o pipefail

CATALOG="${1:-charts/stateful-pods/presets.yaml}"
PRESET_LIST="${2:-images/presets/presets.list}"
status=0

fail() {
  echo "FAIL: $1" >&2
  status=1
}

for file in "$CATALOG" "$PRESET_LIST"; do
  [[ -f "$file" ]] || { echo "FAIL: $file does not exist" >&2; exit 1; }
done

# What the project builds.
# The remaining fields identify the upstream build and are the build's business,
# not this check's: read into one variable so that a line with the wrong number
# of fields is still recognisably malformed.
built=""
while IFS=';' read -r name upstream || [[ -n "$name" ]]; do
  [[ "$name" == \#* || -z "$name" ]] && continue
  if [[ "$upstream" != *';'*';'* ]]; then
    fail "$PRESET_LIST: not a preset line: $name;$upstream"
    continue
  fi
  built+="$name"$'\n'
done < "$PRESET_LIST"

# What the chart offers.
catalogued=""
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  if ! [[ "$line" =~ ^([a-z0-9][a-z0-9.-]*):[[:space:]]+(.+)$ ]]; then
    fail "$CATALOG:$line_number: not a preset entry: $line"
    continue
  fi
  name="${BASH_REMATCH[1]}"
  reference="${BASH_REMATCH[2]}"
  catalogued+="$name"$'\n'

  # Pinned by digest, not by tag. A machine is a pet whose disk has to be
  # reproducible, and this is the property that makes it so.
  if ! [[ "$reference" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
    fail "$CATALOG:$line_number: $name is not pinned by digest: $reference"
    continue
  fi

  # The repository names the preset, so that a reference read on its own says
  # what it is and a mismatched entry cannot hide behind a valid digest.
  repository="${reference%@*}"
  if [[ "${repository##*/}" != "stateful-pods-$name" ]]; then
    fail "$CATALOG:$line_number: $name resolves to $repository, which is not named stateful-pods-$name"
  fi

  if ! grep --quiet --line-regexp --fixed-strings "$name" <<< "$built"; then
    fail "$CATALOG:$line_number: $name is not a preset this project builds; add it to $PRESET_LIST or remove the entry"
  fi
done < "$CATALOG"

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! grep --quiet --line-regexp --fixed-strings "$name" <<< "$catalogued"; then
    fail "$PRESET_LIST: $name is built but absent from $CATALOG, so nothing can name it"
  fi
done <<< "$built"

# The table has to travel with the chart, not just sit beside it in a checkout.
# That is the whole reason it is a chart-root file read through `.Files` rather
# than a values file, and it is the one property a rendering test from the source
# tree cannot see - a values file would pass that test and fail this one.
if command -v helm >/dev/null 2>&1; then
  package_dir="$(mktemp -d)"
  trap 'rm -rf "$package_dir"' EXIT
  chart_dir="$(dirname "$CATALOG")"
  first_preset=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    first_preset="$name"
    break
  done <<< "$catalogued"

  if ! helm package "$chart_dir" --destination "$package_dir" >/dev/null 2>&1; then
    fail "the chart does not package, so whether the catalog travels with it cannot be established"
  else
    packaged="$(find "$package_dir" -name '*.tgz' -maxdepth 1 | head -1)"
    rendered="$(helm template check "$packaged" \
      --set "shim.image=example.invalid/shim:test" \
      --set "machines.probe.source.kind=preset" \
      --set "machines.probe.source.name=$first_preset" \
      --set "machines.probe.rootfs.size=1Gi" \
      --set "machines.probe.security.mode=userns" \
      --kube-version 1.33.0 2>&1)" || rendered=""
    expected="$(grep --fixed-strings -- "$first_preset: " "$CATALOG" | sed "s|^$first_preset: ||")"
    if [[ -n "$expected" ]] && grep --quiet --fixed-strings -- "$expected" <<< "$rendered"; then
      echo "the catalog travels with the chart: $first_preset resolves from a package"
    else
      fail "rendering $first_preset from a packaged chart did not produce $expected"
    fi
  fi
else
  echo "note: helm was not found, so the packaged-chart check was skipped" >&2
fi

if [[ "$status" -eq 0 ]]; then
  echo "preset catalog checks passed"
fi
exit "$status"
