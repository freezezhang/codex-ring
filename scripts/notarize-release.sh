#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

release_version=$(zsh scripts/release-version.sh "${1:?Provide the release version}")
input_dir="${2:?Provide the assembled packages directory}"
output_dir="${3:?Provide an empty directory for notarized packages}"
input_dir="${input_dir:A}"
output_dir="${output_dir:A}"
if [[ "$input_dir" == "$output_dir" || -n "$(ls -A "$output_dir" 2>/dev/null)" ]]; then
    print -u2 -- "Provide a separate, empty output directory."
    exit 1
fi

: "${APPLE_CERTIFICATE_BASE64:?Set the Developer ID Application certificate secret}"
: "${APPLE_CERTIFICATE_PASSWORD:?Set the certificate export password secret}"
: "${APPLE_NOTARY_KEY_BASE64:?Set the App Store Connect API key secret}"
: "${APPLE_NOTARY_KEY_ID:?Set the App Store Connect API key ID secret}"
: "${APPLE_NOTARY_ISSUER_ID:?Set the App Store Connect issuer ID secret}"

umask 077
work_dir=$(mktemp -d)
keychain="$work_dir/signing.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$work_dir"' EXIT
certificate="$work_dir/developer-id.p12"
notary_key="$work_dir/notary-key.p8"
print -rn -- "$APPLE_CERTIFICATE_BASE64" | /usr/bin/base64 -D > "$certificate"
print -rn -- "$APPLE_NOTARY_KEY_BASE64" | /usr/bin/base64 -D > "$notary_key"
unset APPLE_CERTIFICATE_BASE64 APPLE_NOTARY_KEY_BASE64

keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
rm -f "$certificate"
unset APPLE_CERTIFICATE_PASSWORD
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null

identity=$(security find-identity -v -p codesigning "$keychain" |
    awk '/"Developer ID Application: / {print $2; count++} END {if (count != 1) exit 1}') || {
    print -u2 -- "The signing keychain must contain exactly one valid Developer ID Application identity."
    exit 1
}
notary_arguments=(--key "$notary_key" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")

(cd "$input_dir" && shasum -a 256 -c SHA256SUMS.txt)
signed_dir="$work_dir/signed"
mkdir "$signed_dir"
for target_arch in x86_64 arm64 universal; do
    archive_name="CodexRing-$release_version-macOS-$target_arch.zip"
    app_path="$work_dir/$target_arch/CodexRing.app"
    ditto -x -k "$input_dir/$archive_name" "$work_dir/$target_arch"
    codesign --force --sign "$identity" --keychain "$keychain" --options runtime --timestamp "$app_path"
    codesign --verify --deep --strict "$app_path"

    submission="$work_dir/$archive_name"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission"
    result="$work_dir/$target_arch.json"
    print -- "Submitting $archive_name to the Apple notary service."
    if ! xcrun notarytool submit "$submission" "${notary_arguments[@]}" --wait --timeout 10m --output-format json > "$result"; then
        if ! plutil -extract status raw "$result" >/dev/null 2>&1; then
            print -u2 -- "Could not complete notarization for $archive_name."
            exit 1
        fi
    fi
    status=$(plutil -extract status raw "$result")
    submission_id=$(plutil -extract id raw "$result")
    if [[ "$status" != Accepted ]]; then
        print -u2 -- "Notarization returned $status for $archive_name (submission $submission_id)."
        xcrun notarytool log "$submission_id" "${notary_arguments[@]}" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$app_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$signed_dir/$archive_name"
    unzip -tq "$signed_dir/$archive_name"
    ditto -x -k "$signed_dir/$archive_name" "$work_dir/verify-$target_arch"
    verified_app="$work_dir/verify-$target_arch/CodexRing.app"
    codesign --verify --deep --strict "$verified_app"
    xcrun stapler validate "$verified_app"
    spctl --assess --type execute --verbose=2 "$verified_app"
done

(cd "$signed_dir" && shasum -a 256 "CodexRing-$release_version-macOS-"{x86_64,arm64,universal}.zip > SHA256SUMS.txt)
mkdir -p "$output_dir"
cp "$signed_dir"/*.zip "$signed_dir/SHA256SUMS.txt" "$output_dir"
(cd "$output_dir" && shasum -a 256 -c SHA256SUMS.txt)
