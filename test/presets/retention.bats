#!/usr/bin/env bats
#
# What a retention run may and may not delete.
#
# This is the one decision in the project that can destroy something already
# published, and the failure is silent: a retained tag whose architectures were
# swept away still exists, still resolves as an index, and fails only when
# somebody installs a machine from it. So the decision is a pure function and it
# is tested against fixtures rather than against a registry.
#
# The shape of the fixtures is the shape the live registry actually has. It was
# read off a real package before any of this was written: a multi-architecture
# preset is one tagged index plus per-architecture manifests that are package
# versions in their own right, which is exactly what "delete untagged versions"
# eats.

# --separate-stderr, so that a jq diagnostic cannot end up parsed as the plan.
bats_require_minimum_version 1.5.0

RETENTION="hack/preset-retention.sh"

plan() {
  run --separate-stderr "$RETENTION" --plan
}

# A registry holding `count` builds of trixie. Each build is an index and two
# per-architecture manifests. The arm64 manifest is deliberately identical
# across every build, because an upstream that rebuilds and produces the same
# bytes for one architecture is ordinary, and a manifest shared between a build
# that is going and a build that is staying is the case that breaks this.
fixture() {
  local count="$1" keep="$2"
  local day version_json="" children_json="" id=100
  local shared="sha256:aaaa"

  for ((day = 1; day <= count; day++)); do
    local date
    date="$(printf '202601%02d_0500' "$day")"
    local index="sha256:idx$day" amd="sha256:amd$day"
    version_json+="{\"id\": $((id++)), \"digest\": \"$index\", \"tags\": [\"trixie-$date\"]},"
    version_json+="{\"id\": $((id++)), \"digest\": \"$amd\", \"tags\": [\"trixie-$date-amd64\"]},"
    children_json+="\"$index\": [\"$amd\", \"$shared\"],"
  done
  # The shared arm64 manifest, tagged once per build it belongs to.
  local tags=""
  for ((day = 1; day <= count; day++)); do
    tags+="\"trixie-$(printf '202601%02d_0500' "$day")-arm64\","
  done
  version_json+="{\"id\": 999, \"digest\": \"$shared\", \"tags\": [${tags%,}]}"

  printf '{"keep": %s, "versions": [%s], "children": {%s}}' \
    "$keep" "$version_json" "${children_json%,}"
}

# The same registry, with a limit on how much one run may remove.
fixture_with_limit() {
  jq --argjson max "$3" '. + {max_deletions: $max}' <<< "$(fixture "$1" "$2")"
}

deleted_digests() {
  jq --raw-output '.delete[].digest' <<< "$output" | sort | tr '\n' ' '
}

@test "fewer builds than the limit deletes nothing" {
  plan <<< "$(fixture 3 5)"
  [ "$status" -eq 0 ]
  [ "$(jq '.delete | length' <<< "$output")" -eq 0 ]
  [ "$(jq '.retained_builds | length' <<< "$output")" -eq 3 ]
}

@test "exactly the limit deletes nothing" {
  plan <<< "$(fixture 5 5)"
  [ "$status" -eq 0 ]
  [ "$(jq '.delete | length' <<< "$output")" -eq 0 ]
}

@test "the five newest builds are kept and the older ones go" {
  plan <<< "$(fixture 7 5)"
  [ "$status" -eq 0 ]
  [ "$(jq --raw-output '.retained_builds | sort | join(" ")' <<< "$output")" \
    = "trixie-20260103_0500 trixie-20260104_0500 trixie-20260105_0500 trixie-20260106_0500 trixie-20260107_0500" ]
  [ "$(jq --raw-output '.removed_builds | sort | join(" ")' <<< "$output")" \
    = "trixie-20260101_0500 trixie-20260102_0500" ]
}

# The whole point. A naive run deletes sha256:aaaa because it is a child, or
# because some other build's tag on it is going away, and every retained build
# loses its arm64.
@test "a manifest a retained build still points at is never deleted" {
  plan <<< "$(fixture 7 5)"
  [ "$status" -eq 0 ]
  [ "$(deleted_digests)" = "sha256:amd1 sha256:amd2 sha256:idx1 sha256:idx2 " ]
  [[ "$(jq --raw-output '.protected | join(" ")' <<< "$output")" == *"sha256:aaaa"* ]]
}

@test "an index is deleted before the manifests it points at" {
  plan <<< "$(fixture 7 5)"
  [ "$status" -eq 0 ]
  # Everything of kind index comes first, so an interrupted run leaves an
  # orphaned manifest rather than an index whose children are gone.
  [ "$(jq --raw-output '[.delete[].kind] | join(" ")' <<< "$output")" \
    = "index index manifest manifest" ]
}

@test "every retained build keeps a complete set of children" {
  plan <<< "$(fixture 7 5)"
  [ "$status" -eq 0 ]
  # For each retained build, neither of its two children may appear in the
  # deletion list. This is the assertion that would have caught a "delete
  # untagged" step.
  run --separate-stderr bash -c "
    jq --exit-status '
      . as \$plan
      | [\$plan.delete[].digest] as \$gone
      | [\$plan.retained_builds[]
         | (. | capture(\"trixie-202601(?<d>[0-9]{2})_0500\") | .d | ltrimstr(\"0\"))
         | [\"sha256:idx\" + ., \"sha256:amd\" + ., \"sha256:aaaa\"]]
      | flatten
      | all(IN(\$gone[]) | not)
    ' <<< '$output'"
  [ "$status" -eq 0 ]
}

@test "an untagged manifest no removed index points at is left alone" {
  plan <<< '{
    "keep": 1,
    "versions": [
      {"id": 1, "digest": "sha256:new", "tags": ["trixie-20260102_0500"]},
      {"id": 2, "digest": "sha256:old", "tags": ["trixie-20260101_0500"]},
      {"id": 3, "digest": "sha256:stranger", "tags": []}
    ],
    "children": {"sha256:new": [], "sha256:old": []}
  }'
  [ "$status" -eq 0 ]
  [ "$(deleted_digests)" = "sha256:old " ]
}

@test "an untagged child of a removed index is removed with it" {
  plan <<< '{
    "keep": 1,
    "versions": [
      {"id": 1, "digest": "sha256:new", "tags": ["trixie-20260102_0500"]},
      {"id": 2, "digest": "sha256:old", "tags": ["trixie-20260101_0500"]},
      {"id": 3, "digest": "sha256:oldchild", "tags": []}
    ],
    "children": {"sha256:new": [], "sha256:old": ["sha256:oldchild"]}
  }'
  [ "$status" -eq 0 ]
  [ "$(deleted_digests)" = "sha256:old sha256:oldchild " ]
}

# Ordering by build date is the whole basis of the decision. A tag whose date
# cannot be read makes the ordering a guess, and a guess here removes someone's
# operating system.
@test "a tag that does not name a build stops the run, deleting nothing" {
  plan <<< '{
    "keep": 1,
    "versions": [
      {"id": 1, "digest": "sha256:a", "tags": ["trixie-20260102_0500"]},
      {"id": 2, "digest": "sha256:b", "tags": ["latest"]}
    ],
    "children": {}
  }'
  [ "$status" -eq 0 ]
  [ "$(jq --raw-output '.error' <<< "$output")" = "tags that do not name a build" ]
  [ "$(jq --raw-output '.unparsable | join(" ")' <<< "$output")" = "latest" ]
  [ "$(jq 'has("delete")' <<< "$output")" = "false" ]
}

@test "the newest build is decided by the upstream date, not by the order listed" {
  plan <<< '{
    "keep": 1,
    "versions": [
      {"id": 1, "digest": "sha256:old", "tags": ["trixie-20260101_0500"]},
      {"id": 2, "digest": "sha256:new", "tags": ["trixie-20260131_0500"]},
      {"id": 3, "digest": "sha256:mid", "tags": ["trixie-20260115_0500"]}
    ],
    "children": {}
  }'
  [ "$status" -eq 0 ]
  [ "$(jq --raw-output '.retained_builds | join(" ")' <<< "$output")" = "trixie-20260131_0500" ]
}

@test "keeping nothing is refused rather than obeyed" {
  run "$RETENTION" --keep 0 --owner nobody
  [ "$status" -ne 0 ]
  [[ "$output" == *"keeping nothing is not retention"* ]]
}

# A destructive job that runs on a schedule needs a number past which it stops
# and asks. The difference between a bug and a routine day should not be measured
# in how many published images survive it.
@test "a plan larger than a run may remove is refused, with nothing to delete" {
  # Seven builds keeping one removes six builds: six indexes and six unique
  # amd64 manifests, which is well past a day's worth.
  plan <<< "$(fixture_with_limit 7 1 4)"
  [ "$status" -eq 0 ]
  [ "$(jq --raw-output '.error' <<< "$output")" = "the plan is larger than a run may remove" ]
  [ "$(jq --raw-output '.max_deletions' <<< "$output")" = "4" ]
  [ "$(jq --raw-output '.would_delete' <<< "$output")" -gt 4 ]
  # No list to act on, so a caller that ignored the error still deletes nothing.
  [ "$(jq 'has("delete")' <<< "$output")" = "false" ]
}

@test "a plan inside the limit is returned as usual" {
  plan <<< "$(fixture_with_limit 7 5 8)"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("error")' <<< "$output")" = "false" ]
  [ "$(jq '.delete | length' <<< "$output")" -eq 4 ]
}

@test "no limit means no limit" {
  plan <<< "$(fixture 7 1)"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("error")' <<< "$output")" = "false" ]
  [ "$(jq '.delete | length' <<< "$output")" -eq 12 ]
}

@test "the flag itself is checked before anything is read" {
  run "$RETENTION" --max-deletions notanumber --owner nobody
  [ "$status" -ne 0 ]
  [[ "$output" == *"--max-deletions takes a number"* ]]
}
