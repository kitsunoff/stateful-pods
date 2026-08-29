#!/usr/bin/env bash
#
# Runs shellcheck over every shell script in the repository. The dialect comes
# from each file's own shebang, which is what keeps the POSIX-only scripts honest:
# the seeding script that runs inside a machine's own source image may not assume
# bash, and shellcheck is what enforces that.
set -o errexit
set -o nounset
set -o pipefail

mapfile -t scripts < <(
  find hack images charts test -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null | sort
)

if [[ "${#scripts[@]}" -eq 0 ]]; then
  echo "no shell scripts found" >&2
  exit 1
fi

printf '==> shellcheck %s\n' "${scripts[@]}"
shellcheck --external-sources --check-sourced "${scripts[@]}"
echo "shellcheck passed (${#scripts[@]} scripts)"
