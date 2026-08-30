#!/usr/bin/env bash
#
# Runs shellcheck over every shell script in the repository. The dialect comes
# from each file's own shebang, which is what keeps the POSIX-only scripts honest:
# the helpers that run inside a machine after the root change may not assume bash,
# and shellcheck is what enforces that.
set -o errexit
set -o nounset
set -o pipefail

# A read loop rather than mapfile, which is bash 4 and this repository's macOS
# bash is 3.2. The rest of the tooling already avoids it for that reason; this
# one file did not, so the lint that guards the scripts was the only thing in
# here that could not run on the platform the scripts claim to support.
scripts=()
while IFS= read -r script; do
  [[ -n "$script" ]] && scripts+=("$script")
done < <(
  find hack images charts test -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null | sort
)

if [[ "${#scripts[@]}" -eq 0 ]]; then
  echo "no shell scripts found" >&2
  exit 1
fi

printf '==> shellcheck %s\n' "${scripts[@]}"
shellcheck --external-sources --check-sourced "${scripts[@]}"
echo "shellcheck passed (${#scripts[@]} scripts)"
