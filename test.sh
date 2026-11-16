#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH=/tmp/codex-quota-swift-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-quota-swift-module-cache
# Protocol fixtures use system Python. Warm its imports before starting timed
# tests: cold interpreter startup on a fresh CI Mac can exceed the fixture budget.
/usr/bin/python3 -c 'import json, os, sys, time'
swift_options=(--scratch-path .build --cache-path /tmp/codex-quota-swiftpm/cache
    --config-path /tmp/codex-quota-swiftpm/config --security-path /tmp/codex-quota-swiftpm/security
    --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH")
if [[ "${1:-}" == --ci ]]; then
    swift build --build-tests "${swift_options[@]}"
    bin_dir=$(swift build --show-bin-path "${swift_options[@]}")
    # Stream XCTest output through a terminal so a stalled test remains identifiable.
    /usr/bin/script -q /dev/null /usr/bin/xcrun xctest "$bin_dir/CodexRingPackageTests.xctest" </dev/null
else
    swift test "${swift_options[@]}" "$@"
fi
