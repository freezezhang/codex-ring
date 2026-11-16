#!/bin/zsh
# Opt-in native test: only its own fixture window is moved or fullscreened.
# Run `zsh test.sh` first to build QuotaCore and RingDrawing debug modules.
set -euo pipefail
cd "${0:A:h:h}"
check_dir=$(mktemp -d /tmp/codex-ring-usage-check.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
check_app="$check_dir/CodexRingOverlayCheck.app"
mkdir -p "$check_app/Contents/MacOS"
cp scripts/check-usage-overlay.swift "$check_dir/main.swift"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.freeze.codex-ring.overlay-check</string>
<key>CFBundleExecutable</key><string>CodexRingOverlayCheck</string>
<key>CFBundleName</key><string>CodexRingOverlayCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
app_sources=()
for source_file in Sources/QuotaRing/*.swift; do
    [[ "$source_file" == Sources/QuotaRing/main.swift ]] || app_sources+=("$source_file")
done
swiftc -module-cache-path /tmp/codex-quota-swift-module-cache -I .build/debug/Modules \
    "${app_sources[@]}" "$check_dir/main.swift" \
    .build/debug/QuotaCore.build/*.swift.o .build/debug/RingDrawing.build/*.swift.o \
    -o "$check_app/Contents/MacOS/CodexRingOverlayCheck"
codesign --force --sign - "$check_app"
"$check_app/Contents/MacOS/CodexRingOverlayCheck" "$@"
