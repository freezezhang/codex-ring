# Security policy

[简体中文](SECURITY.zh-CN.md)

Security fixes target the latest stable release. Check whether the issue still occurs on that version before reporting it.

## Report privately

Use GitHub's [private vulnerability reporting form](https://github.com/freezezhang/codex-ring/security/advisories/new). Include the affected CodexRing and macOS versions, sanitized steps to reproduce, and the expected and observed behavior. Keep API keys, cookies, login tokens, account email addresses, and full local paths out of public issues, pull requests, and screenshots.

If the private form is unavailable, open an issue requesting a private channel and omit the vulnerability details. Revoke or rotate any exposed credentials with the issuing service.

## Data handling

- CodexRing queries the official Codex App Server on your Mac for quota and account display fields. CodexRing itself leaves Codex login token files to Codex.
- The optional OpenAI API feature reads the Admin API key stored in macOS Keychain and sends it to the official Costs API. Preferences and logs exclude the key.
- The account email, plan, and latest usage snapshot live in memory. Appearance, position, API query configuration, and alert deduplication state are stored locally.
- The Accessibility overlay is off by default. When enabled, it reads the labels and positions of the usage controls and activates the matching control when you click the ring.
- CodexRing runs without its own telemetry service. The official Codex components and OpenAI API follow their respective data handling policies.

See the [README](README.md#data-and-permissions) for the complete overview.

## Release and privacy checks

Builds use temporary directories, map compiler paths, strip debug symbols, and scan the packaged app. The privacy check looks for common credential formats, personal email addresses, and local home directory paths. Review screenshots, logs, and artifact metadata before publication to catch information outside those patterns.
