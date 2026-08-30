# Decides what a retention run removes. A pure function, so that the one decision
# that can destroy a published image is one a test can put fixtures in front of.
#
# Input:
#   {
#     "keep": 5,
#     "versions": [ { "id": 1, "digest": "sha256:...", "tags": ["trixie-20260829_0524"] } ],
#     "children": { "sha256:<index>": [ "sha256:<child>", ... ] }
#   }
#
# Output: the same decision, spelled out - which builds stay, which go, which
# digests are protected, and the versions to delete in the order to delete them.
#
# The hazard this exists to avoid is specific. A multi-architecture image is a
# tagged index whose per-architecture manifests are package versions in their own
# right, and the obvious retention step - "remove untagged versions" - deletes
# those out from under every tag that is being kept. So nothing here works from
# whether a version is tagged. It works from which build a version belongs to,
# and it protects, unconditionally, every digest any retained build still points
# at. Two builds sharing an identical manifest is not unusual - an upstream that
# rebuilds and produces the same bytes for one architecture is a normal Tuesday -
# and that shared manifest belongs to the retained build as much as to the one
# going away.
#
# Indexes are deleted before the manifests they point at, never after, so that a
# run interrupted half way leaves a resolvable image rather than an index whose
# children are gone.

def build_pattern: "^(?<release>[^-]+)-(?<date>[0-9]{8}_[0-9]{4})(-(?<arch>.+))?$";

# The build a tag belongs to: the release and the upstream date, without the
# architecture suffix a per-architecture tag carries.
def build_of(tag): tag | capture(build_pattern) | .release + "-" + .date;

def date_of(key): key | capture("(?<d>[0-9]{8}_[0-9]{4})") | .d;

. as $input
| (($input.children // {})) as $children
| ($input.keep) as $keep

# A tag nobody can parse is a tag nobody may delete. Ordering by build date is
# the whole basis of the decision, so a tag whose date cannot be read makes the
# ordering a guess - and a guess here removes someone's operating system.
| ([$input.versions[].tags[]? | select(test(build_pattern) | not)] | unique) as $unparsable
| if ($unparsable | length) > 0 then
    { error: "tags that do not name a build", unparsable: $unparsable }
  else

  ($input.versions | map(. + { builds: ([.tags[]? | build_of(.)] | unique) })) as $versions
  | ([$versions[].builds[]] | unique | sort_by(date_of(.)) | reverse) as $ordered
  | ($ordered[0:$keep]) as $retained_builds
  | ($ordered[$keep:]) as $removed_builds

  # Everything a retained build still needs: the retained versions themselves and
  # every manifest their indexes point at.
  | ([$versions[] | select(.builds | any(. as $b | $retained_builds | index($b)))]) as $retained_versions
  | ([$retained_versions[] | .digest, (($children[.digest] // [])[])] | unique) as $protected

  | ([$versions[] | select(.builds | any(. as $b | $removed_builds | index($b)))]) as $removed_tagged
  | ([$removed_tagged[] | ($children[.digest] // [])[]] | unique) as $orphaned

  # An untagged version is only ever removed as a child of an index that is being
  # removed. One that belongs to nothing this run understands is left alone: not
  # knowing what something is has never been a reason to delete it.
  | ([$versions[] | select((.builds | length) == 0 and (.digest | IN($orphaned[])))]) as $removed_untagged

  | (($removed_tagged + $removed_untagged)
     | unique_by(.id)
     | map(select(.digest | IN($protected[]) | not))) as $doomed

  | {
      retained_builds: $retained_builds,
      removed_builds: $removed_builds,
      protected: $protected,
      delete: (
        [$doomed[] | . as $v | select($children | has($v.digest)) | {id, digest, tags, kind: "index"}]
        + [$doomed[] | . as $v | select($children | has($v.digest) | not) | {id, digest, tags, kind: "manifest"}]
      )
    }
  end
