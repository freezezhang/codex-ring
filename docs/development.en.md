# CodexRing developer guide

[简体中文](development.md) · [User guide](../README.md)

## Build

Install the Xcode Command Line Tools and Swift 5.9 or later on macOS.

```sh
zsh build.sh
```

This creates a locally ad hoc signed app in `build/CodexRing.app`. To choose an output path or target architecture, pass them to the script. Supported architectures are `x86_64` and `arm64`. The default architecture is the host's, and the default version comes from `VERSION`.

```sh
CODEXRING_VERSION=0.8.0 zsh build.sh "$PWD/build/arm64/CodexRing.app" arm64
```

`scripts/make-icon.swift` generates the PNG sizes and ICNS from `assets/AppIcon-source.png`. Xcode 26 or later also builds the native icon asset for macOS 26. The ICNS remains in the bundle for earlier versions.

## Localization

CodexRing ships English, Simplified Chinese, Traditional Chinese, Japanese, and Korean. The app follows the system language by default and falls back to English. The selected language applies immediately to the menu, settings, quota panel, tooltips, accessibility labels, and subsequent notifications. System permission prompts follow macOS. Dates use Beijing time and the `yyyy.MM.dd HH:mm` format.

1. Copy `Sources/QuotaCore/Resources/en.lproj` to the new language's `.lproj` directory. Translate the values, preserving the keys and placeholders. Use numbered placeholders such as `%1$@` when the word order changes, and `%%` for a literal percent in a format string.
2. Add the language to `AppLanguage.supported` in `Sources/QuotaCore/Localization.swift`. Use the language's own name and add system language aliases if needed.

Call `L10n.string` or `L10n.format` for new strings. The registry's first language must match `defaultLocalization` in `Package.swift`. `LocalizationTests` check keys, placeholders, source references, and the registry.

### Settings conventions

Use hover help or accessibility help for explanations. Show necessary permissions, errors, and runtime status in concise, regular-sized rows. Permission settings use a switch followed by a status row and settings button indented by 16 points. When CodexRing detects that an update may have invalidated Accessibility authorization, keep the localized reauthorization reminder visible between the status row and the button. See [AGENTS.md](../AGENTS.md).

## Testing

```sh
zsh test.sh
python3 -m unittest discover -s Tests/Privacy
python3 scripts/check-privacy.py
```

The Swift suite covers quota parsing and presentation, reset cards, settings and localization, window-follow geometry and visibility, rendering, protocol timeouts, and lifecycle regressions. It uses a local App Server fixture and temporary preferences. GitHub runs the Swift suite on native Intel and Apple silicon macOS 26 runners for pull requests and `main`, alongside the repository privacy check.

Optional native tests after the Swift suite:

- `zsh scripts/check-codex-follow.sh` creates a test window and checks follow behavior as it moves, resizes, maximizes, enters full screen, minimizes, restores, and closes. Use `--basic-follow` to exercise the path without Accessibility. The script uses isolated preferences and does not query live quotas.
- `zsh scripts/check-usage-overlay.sh` checks positioning, hover and click forwarding, disappearance and recovery, permission changes, and restoration after the overlay is disabled. It uses a test window and the permissions that the test process already has.
- Run `swift scripts/check-fullscreen.swift` with CodexRing open and Follow Codex disabled. It creates a temporary window and checks ring placement across full-screen transitions. Add `--space-diagnostics` to a CodexRing launch to log window and Space detection to standard error.

For manual UI validation, check dragging and edge docking, theme changes, switching Spaces, maximized and full-screen windows, and crossing displays. Inspect the UI before and after a refresh and after switching back to the Space where the ring is pinned.

### Minimum macOS smoke test

The package checks verify the macOS 13.0 target in both the application plist and all executable slices. Runtime validation requires a Mac or VM running macOS 13 with a graphical session. Native GitHub-hosted tests currently run on macOS 26.

1. Download the native or universal ZIP from the candidate's Actions run. Compare its SHA-256 with `SHA256SUMS.txt`.
2. On a test device with no other CodexRing instance running, unzip the app and copy it to Applications. For a Developer ID build, verify `spctl --assess --type execute --verbose=2 /Applications/CodexRing.app` and open it in Finder.
3. Confirm the menu bar item and floating ring appear. Open and close the quota panel and settings, switch a setting, quit, and relaunch to confirm the setting persisted.
4. If a compatible official Codex build is available for that OS, check Refresh and follow behavior. Record the tested macOS build, architecture, CodexRing version, archive SHA-256, and any skipped cases in the release verification record.

## Releases

Push an unused stable tag such as `v0.8.0` pointing to a tested commit on `main`. The tag sets the bundle version and ZIP names. `VERSION` supplies the default for local builds and manual workflow runs.

```sh
git tag -a v0.8.0 -m "CodexRing v0.8.0"
git push origin v0.8.0
```

The release workflow tests and builds on both architectures, assembles Intel, Apple silicon, and universal packages, and verifies their contents. The signing job applies Developer ID and hardened runtime, submits each ZIP to Apple's notary service, staples the ticket to the app, and verifies the final ZIP and Gatekeeper assessment. The publish job uploads the three ZIPs and checksums to a draft, downloads and verifies them, then publishes. GitHub locks assets and their tag for releases published with release immutability enabled. Correct a published package with a new version and tag.

Run **Build and release** from Actions to produce ad hoc `test-packages` without publishing. Run the workflow on `main` with **Sign and notarize a test build from main** selected to validate signing and download the signed `release-packages` without creating a GitHub Release.

### Apple credentials

Use the GitHub Actions `apple-signing` environment. Restrict it to the `main` branch and release tags matching `v*`. Store these as environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of an exported Developer ID Application `.p12` containing its private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_NOTARY_KEY_BASE64` | Base64 of the App Store Connect team API key's `.p8` file |
| `APPLE_NOTARY_KEY_ID` | ID of that API key |
| `APPLE_NOTARY_ISSUER_ID` | Issuer ID from App Store Connect |

Only the signing step receives these secrets. A tagged build with missing or rejected signing credentials fails before publishing. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
