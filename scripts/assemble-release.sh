#!/bin/zsh
# Combine the two tested native ZIPs without losing executable bits or signatures.
set -euo pipefail
cd "${0:A:h:h}"
release_version=$(zsh scripts/release-version.sh "${1:?Provide a release version}")
input_dir="${2:?Provide the directory containing both native ZIPs}"
output_dir="${3:?Provide an output directory}"
input_dir="${input_dir:A}"
output_dir="${output_dir:A}"
mkdir -p "$output_dir"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

for target_arch in x86_64 arm64; do
    archive_name="CodexRing-$release_version-macOS-$target_arch.zip"
    ditto -x -k "$input_dir/$archive_name" "$work_dir/$target_arch"
    app_path="$work_dir/$target_arch/CodexRing.app"
    codesign --verify --deep --strict "$app_path"
    test "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" = "$release_version"
    test "$(lipo -archs "$app_path/Contents/MacOS/CodexRing")" = "$target_arch"
    test -x "$app_path/Contents/MacOS/CodexRing"
    if [[ "$input_dir" != "$output_dir" ]]; then
        cp "$input_dir/$archive_name" "$output_dir/$archive_name"
    fi
done
cmp "$work_dir/x86_64/CodexRing.app/Contents/Info.plist" "$work_dir/arm64/CodexRing.app/Contents/Info.plist"
universal_app="$work_dir/universal/CodexRing.app"
ditto "$work_dir/x86_64/CodexRing.app" "$universal_app"
lipo -create "$work_dir/x86_64/CodexRing.app/Contents/MacOS/CodexRing" \
    "$work_dir/arm64/CodexRing.app/Contents/MacOS/CodexRing" \
    -output "$universal_app/Contents/MacOS/CodexRing"
codesign --force --sign - "$universal_app"
codesign --verify --deep --strict "$universal_app"
lipo "$universal_app/Contents/MacOS/CodexRing" -verify_arch x86_64 arm64
ditto -c -k --sequesterRsrc --keepParent "$universal_app" "$output_dir/CodexRing-$release_version-macOS-universal.zip"
cd "$output_dir"
for target_arch in x86_64 arm64 universal; do
    archive_name="CodexRing-$release_version-macOS-$target_arch.zip"
    unzip -tq "$archive_name"
    ditto -x -k "$archive_name" "$work_dir/verify-$target_arch"
    app_path="$work_dir/verify-$target_arch/CodexRing.app"
    codesign --verify --deep --strict "$app_path"
    test "$(plutil -extract LSMinimumSystemVersion raw "$app_path/Contents/Info.plist")" = 13.0
    for arch in $(lipo -archs "$app_path/Contents/MacOS/CodexRing"); do
        minimum=$(xcrun vtool -arch "$arch" -show-build "$app_path/Contents/MacOS/CodexRing" | awk '$1 == "minos" {print $2}')
        test "$minimum" = 13.0
    done
done
shasum -a 256 "CodexRing-$release_version-macOS-"{x86_64,arm64,universal}.zip > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
