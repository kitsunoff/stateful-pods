# Decides what a retention run removes. A pure function, so that the one decision
# that can destroy a published image is one a test can put fixtures in front of.
#
# Input:
#   {
#     "keep": 5,
#     "max_deletions": 8,
#     "release": "trixie",
#     "releases": ["trixie"],
#     "versions": [ { "id": 1, "digest": "sha256:...", "tags": ["trixie-20260829_0524"] } ],
#     "children": { "sha256:<index>": [ "sha256:<child>", ... ] }
#   }
#
# `release` is the release this run is retaining and `releases` is every release
# published into the same repository. A preset's package is named for its
# distribution and its tags for its release, so two releases of one distribution
# share a repository and a run sees both. The plan is scoped to one of them:
# keeping five means five builds of Noble, not five builds of Ubuntu, and without
# that the first day six Noble builds existed would take every Jammy build with
# it. `releases` is also how the rolling tags are recognised - see below.
#
# `max_deletions` is a blast radius, and it is decided here rather than by the
# caller so that it is reachable by the same fixtures as everything else. A day's
# retention removes one build, which is three versions; a plan much larger than
# that is not describing a day, and the difference between a bug and a routine
# Tuesday should not be measured in how many published images survive it. Null
# means no limit.
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
# There is a second thing that must survive every run: the rolling tag. Each
# release publishes one - `trixie`, `noble` - pointing at its newest build, and
# it is the name a person types. It carries no date, so it can play no part in
# the ordering, and it shares a digest with that build's dated tag, so it is the
# same package version under two names and deleting the version deletes both.
# Every version carrying one is protected whatever build it names: normally that
# is the newest build and is retained anyway, and the case this exists for is a
# rolling tag left behind by a run that died between the two pushes, pointing at
# a build old enough to fall past the limit.
#
# Indexes are deleted before the manifests they point at, never after, so that a
# run interrupted half way leaves a resolvable image rather than an index whose
# children are gone.

def build_pattern: "^(?<release>[^-]+)-(?<date>[0-9]{8}_[0-9]{4})(-(?<arch>.+))?$";

# The tag that names a build itself, rather than one of its architectures.
def index_pattern: "^[^-]+-[0-9]{8}_[0-9]{4}$";

# The build a tag belongs to: the release and the upstream date, without the
# architecture suffix a per-architecture tag carries.
def build_of(tag): tag | capture(build_pattern) | .release + "-" + .date;

def release_of(tag): tag | capture(build_pattern) | .release;

def date_of(key): key | capture("(?<d>[0-9]{8}_[0-9]{4})") | .d;

. as $input
| (($input.children // {})) as $children
| ($input.keep) as $keep
| ($input.release // "") as $release

# The run's own release is always among the rolling tags, whatever the caller
# said. A rolling tag this run did not recognise would be reported as a tag that
# does not name a build and stop the run, which is safe; one it recognised but
# was not told to protect would not be, so the two lists are merged here rather
# than trusted to arrive consistent.
| ((($input.releases // []) + [$release]) | unique) as $rolling

# The release is the whole scope of the decision. Without it every build in the
# repository falls outside the retained set and the plan is "delete everything",
# which is the one direction an absent input must never take this.
| if $release == "" then
    { error: "no release to retain" }
  else

  # A tag nobody can parse is a tag nobody may delete. Ordering by build date is
  # the whole basis of the decision, so a tag whose date cannot be read makes the
  # ordering a guess - and a guess here removes someone's operating system. A
  # rolling tag is not one of those: it is named, it is expected, and it is
  # protected rather than ordered.
  ([$input.versions[].tags[]?
    | select(. as $tag | ($rolling | index($tag)) | not)
    | select(test(build_pattern) | not)] | unique) as $unparsable
  | if ($unparsable | length) > 0 then
      { error: "tags that do not name a build", unparsable: $unparsable }
    else

    ($input.versions | map(. + {
       builds: ([.tags[]? | select(test(build_pattern)) | build_of(.)] | unique),
       rolling: ([.tags[]? | select(. as $tag | $rolling | index($tag))] | length > 0)
     })) as $versions

    # A build is a build because its index exists, not because something carries
    # a tag shaped like one. A preset is published architecture by architecture
    # and combined into an index last, so a run that died in between leaves a
    # tagged per-architecture manifest that no index references - and GHCR cannot
    # untag without deleting, so it stays there. Counting that as a build would
    # cost a real one its place among the five, and would then send the
    # after-the-fact check looking for an index tag that was never pushed.
    | ([$versions[].tags[]?
        | select(test(index_pattern))
        | select(release_of(.) == $release)] | unique) as $build_tags
    | ($build_tags | sort_by(date_of(.)) | reverse) as $ordered
    | ($ordered[0:$keep]) as $retained_builds
    | ($ordered[$keep:]) as $removed_builds

    | ([$versions[] | select(.builds | any(. as $b | $retained_builds | index($b)))]) as $retained_versions

    # Everything this run has no business touching: a version carrying a rolling
    # tag, and a version belonging to a release that is not the one being
    # retained. Both are protected the same way a retained build is - by digest,
    # and along with everything their indexes point at.
    | ([$versions[]
        | select(.rolling or (.builds | any(release_of(.) != $release)))]) as $reserved_versions

    # Everything a retained build, a rolling tag or another release still needs.
    | ([($retained_versions + $reserved_versions)[]
        | .digest, (($children[.digest] // [])[])] | unique) as $protected

    | ([$versions[] | select(.builds | any(. as $b | $removed_builds | index($b)))]) as $removed_tagged
    # Versions belonging to no build this run recognises - the orphan above among
    # them - fall through every list below and are neither protected nor removed.
    | ([$removed_tagged[] | ($children[.digest] // [])[]] | unique) as $orphaned

    # An untagged version is only ever removed as a child of an index that is
    # being removed. One that belongs to nothing this run understands is left
    # alone: not knowing what something is has never been a reason to delete it.
    | ([$versions[] | select((.builds | length) == 0 and (.digest | IN($orphaned[])))]) as $removed_untagged

    | (($removed_tagged + $removed_untagged)
       | unique_by(.id)
       | map(select(.digest | IN($protected[]) | not))) as $doomed

    # Indexes before the manifests they point at, never after, so that a run
    # interrupted half way leaves a resolvable image rather than an index whose
    # children are gone.
    | ([$doomed[] | . as $v | select($children | has($v.digest)) | {id, digest, tags, kind: "index"}]
       + [$doomed[] | . as $v | select($children | has($v.digest) | not) | {id, digest, tags, kind: "manifest"}]
      ) as $delete

    | if ($input.max_deletions != null) and (($delete | length) > $input.max_deletions) then
        { error: "the plan is larger than a run may remove",
          would_delete: ($delete | length),
          max_deletions: $input.max_deletions,
          removed_builds: $removed_builds }
      else
        { release: $release,
          rolling_tags: $rolling,
          retained_builds: $retained_builds,
          removed_builds: $removed_builds,
          protected: $protected,
          delete: $delete }
      end
    end
  end
