#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_version="${1:-${CODEXRING_VERSION:-$(cat VERSION)}}"
app_version="${app_version#v}"
if [[ ! "$app_version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
    print -u2 -- "Invalid version: use vMAJOR.MINOR.PATCH (for example v0.1.1)."
    exit 1
fi
print -r -- "$app_version"
