#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH=/tmp/codex-quota-swift-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-quota-swift-module-cache
# Protocol fixtures use system Python. Warm its imports before starting timed
# tests: cold interpreter startup on a fresh CI Mac can exceed the fixture budget.
/usr/bin/python3 -c 'import json, os, sys, time'
swift test --scratch-path .build --cache-path /tmp/codex-quota-swiftpm/cache --config-path /tmp/codex-quota-swiftpm/config --security-path /tmp/codex-quota-swiftpm/security --manifest-cache local -Xswiftc -module-cache-path -Xswiftc /tmp/codex-quota-swift-module-cache "$@"
