#!/usr/bin/env bash
#
# Checks the documentation guarantees the values-validation capability makes about
# values.yaml: every input is commented at the point of use, the Proxmox options
# that have no equivalent are named with their reason, and the inputs the design
# rejected are absent rather than merely unimplemented.
set -o errexit
set -o nounset
set -o pipefail

VALUES="${1:-charts/stateful-pods/values.yaml}"
status=0

fail() {
  echo "FAIL: $1" >&2
  status=1
}

# Every key carries an adjacent comment.
previous=""
line_number=0
while IFS= read -r line; do
  line_number=$((line_number + 1))
  if [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*: ]]; then
    if [[ ! "$previous" =~ ^[[:space:]]*# ]]; then
      fail "$VALUES:$line_number: key is not preceded by a comment: ${line}"
    fi
  fi
  previous="$line"
done < "$VALUES"

# The Proxmox options that have no equivalent are named, with the reason.
require() {
  if ! grep --quiet --extended-regexp "$1" "$VALUES"; then
    fail "$VALUES: expected to explain $2"
  fi
}
require 'Per-guest network configuration' 'that per-guest network configuration is not a chart input'
require 'ipconfig0' 'the Proxmox network option it replaces'
require 'Per-guest DNS' 'that per-guest DNS configuration is not a chart input'
require 'nameserver' 'the Proxmox DNS option it replaces'

# Inputs the design rejected must not exist as inputs. Only commented mentions are
# allowed, so strip the comments before looking.
uncommented="$(sed 's/#.*//' "$VALUES")"
forbid() {
  if grep --quiet --extended-regexp "$1" <<< "$uncommented"; then
    fail "$VALUES: declares an input the design rejected: $2"
  fi
}
forbid '^[[:space:]]*replicas?[Cc]?o?u?n?t?[[:space:]]*:' 'a replica count'
forbid '^[[:space:]]*(init)[[:space:]]*:' 'an init-system selector'
forbid '(skipVerify|insecureSkipVerify|noVerify|skipChecksum|verify[[:space:]]*:)' 'a way to skip checksum verification'
forbid '^[[:space:]]*(username|password|registryToken|token|auth|dockerconfigjson)[[:space:]]*:' 'a registry credential as a value rather than a Secret reference'

if [[ "$status" -eq 0 ]]; then
  echo "values.yaml documentation checks passed"
fi
exit "$status"
