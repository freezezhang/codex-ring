#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
export CLANG_MODULE_CACHE_PATH=/tmp/codex-quota-swift-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-quota-swift-module-cache
app_version=$(zsh scripts/release-version.sh)
build_number="${CODEXRING_BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 -- "CODEXRING_BUILD_NUMBER must be a positive integer."
    exit 1
fi
target_arch="${2:-$(uname -m)}"
case "$target_arch" in
    x86_64|arm64) ;;
    *) print -u2 -- "Unsupported architecture: $target_arch"; exit 1 ;;
esac
build_scratch=$(mktemp -d /tmp/codexring-release.XXXXXX)
trap 'rm -rf "$build_scratch"' EXIT
build_options=(-c release --product CodexRing --triple "${target_arch}-apple-macosx13.0"
    --scratch-path "$build_scratch" --cache-path /tmp/codex-quota-swiftpm/cache
    --config-path /tmp/codex-quota-swiftpm/config --security-path /tmp/codex-quota-swiftpm/security
    --manifest-cache local -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/CodexRing"
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=/CodexRing")
swift build "${build_options[@]}"
bin_dir=$(swift build "${build_options[@]}" --show-bin-path)
app_dir="${1:-$PWD/build/CodexRing.app}"
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/make-icon.swift "$PWD/assets"
iconutil -c icns "$PWD/assets/AppIcon.iconset" -o "$PWD/assets/AppIcon.icns"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$bin_dir/CodexRing" "$app_dir/Contents/MacOS/CodexRing"
sparkle_framework="$bin_dir/Sparkle.framework"
test -d "$sparkle_framework"
rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
xcrun strip -S "$app_dir/Contents/MacOS/CodexRing"
cp "$PWD/assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
# macOS 26 puts a stock background behind legacy icons. Supply a native icon
# stack on current toolchains and retain the ICNS resource as a fallback.
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
icon_name_plist=""
if (( ${sdk_version%%.*} >= 26 )) && xcrun --find actool >/dev/null 2>&1; then
    icon_project="$build_scratch/AppIcon.icon"
    icon_output="$build_scratch/compiled-icon"
    mkdir -p "$icon_project/Assets" "$icon_output"
    cp "$PWD/assets/AppIcon.icon.json" "$icon_project/icon.json"
    cp "$PWD/assets/AppIcon.png" "$icon_project/Assets/CodexRing.png"
    if ! xcrun --sdk macosx actool --compile "$icon_output" --platform macosx \
        --minimum-deployment-target 13.0 --app-icon AppIcon \
        --output-partial-info-plist "$icon_output/Info.plist" "$icon_project" \
        > "$icon_output/actool.log" 2>&1; then
        cat "$icon_output/actool.log" >&2
        exit 1
    fi
    cp "$icon_output/Assets.car" "$app_dir/Contents/Resources/Assets.car"
    icon_name_plist='<key>CFBundleIconName</key><string>AppIcon</string>'
else
    rm -f "$app_dir/Contents/Resources/Assets.car"
fi
# Older snapshots load their menu template from a PNG; it now contains our own mark.
if [[ -f "$PWD/assets/ChatGPTMenuIcon.png" ]]; then
    cp "$PWD/assets/ChatGPTMenuIcon.png" "$app_dir/Contents/Resources/ChatGPTMenuIcon.png"
else
    rm -f "$app_dir/Contents/Resources/ChatGPTMenuIcon.png"
fi
cp "$PWD/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PWD/LICENSE" "$app_dir/Contents/Resources/LICENSE"
# Every registered language ships as Sources/QuotaCore/Resources/<code>.lproj.
development_region=$(sed -n 's/.*defaultLocalization: *"\([^"]*\)".*/\1/p' Package.swift)
# Pre-localization versions have no resource bundle or defaultLocalization.
localization_dirs=("$PWD"/Sources/QuotaCore/Resources/*.lproj(N))
if (( ${#localization_dirs[@]} > 0 )); then
    [[ -n "$development_region" ]] || { print -u2 -- "Package.swift must set defaultLocalization."; exit 1; }
else
    development_region="en"
fi
localizations=""
for localization_dir in "$PWD"/Sources/QuotaCore/Resources/*.lproj(N); do
    localization="${localization_dir:t:r}"
    rm -rf "$app_dir/Contents/Resources/$localization.lproj"
    cp -R "$localization_dir" "$app_dir/Contents/Resources/$localization.lproj"
    localizations+="<string>$localization</string>"
done
if (( ${#localization_dirs[@]} > 0 )); then
    [[ -f "$app_dir/Contents/Resources/$development_region.lproj/Localizable.strings" ]] || {
        print -u2 -- "Missing $development_region.lproj/Localizable.strings."; exit 1;
    }
fi
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>$development_region</string>
<key>CFBundleLocalizations</key><array>$localizations</array>
<key>CFBundleExecutable</key><string>CodexRing</string>
<key>CFBundleIdentifier</key><string>local.freeze.codex-quota-ring</string>
<key>CFBundleName</key><string>CodexRing</string>
<key>CFBundleDisplayName</key><string>CodexRing</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
$icon_name_plist
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleShortVersionString</key><string>$app_version</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${CODEXRING_SPARKLE_PUBLIC_KEY:-}" ]]; then
    if [[ ! "$CODEXRING_SPARKLE_PUBLIC_KEY" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
        print -u2 -- "CODEXRING_SPARKLE_PUBLIC_KEY must be a base64 Ed25519 public key."
        exit 1
    fi
    feed_url="${CODEXRING_UPDATE_FEED_URL:-https://github.com/freezezhang/codex-ring/releases/latest/download/appcast.xml}"
    plist="$app_dir/Contents/Info.plist"
    plutil -insert SUFeedURL -string "$feed_url" "$plist"
    plutil -insert SUPublicEDKey -string "$CODEXRING_SPARKLE_PUBLIC_KEY" "$plist"
    plutil -insert SUEnableAutomaticChecks -bool NO "$plist"
    plutil -insert SUScheduledCheckInterval -integer 3600 "$plist"
    plutil -insert SUAutomaticallyUpdate -bool NO "$plist"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
    plutil -insert SURequireSignedFeed -bool YES "$plist"
    if [[ "$feed_url" == http://127.0.0.1:* ]]; then
        plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$plist"
    fi
fi
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
python3 scripts/check-privacy.py "$app_dir"
printf '%s\n' "Built $app_dir ($app_version, $target_arch; not launched or installed)."
