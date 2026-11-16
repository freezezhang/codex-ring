# Contributing to CodexRing

[简体中文](CONTRIBUTING.zh-CN.md)

Bug reports, translations, and pull requests are welcome. CodexRing is an independent community project.

## Development

You need macOS, the Xcode Command Line Tools, and Swift 5.9 or later.

```sh
git clone https://github.com/freezezhang/codex-ring.git
cd codex-ring
zsh test.sh
python3 scripts/check-privacy.py
zsh build.sh
```

The automated tests use synthetic data and briefly open and close their own settings windows. See the [testing guide](docs/development.en.md#testing) to verify native window following and the usage overlay.

- Start from the latest `main` and keep each pull request focused. GitHub checks privacy and runs the Swift suite on Intel and Apple silicon.
- Add regression coverage for changes to behavior or lifecycle. Include reproduction steps, test results, and any platforms or scenarios left untested.
- Use `L10n` for UI strings and update each supported language. Follow the [settings conventions](docs/development.en.md#settings-conventions).
- Keep build outputs, account screenshots, raw quota responses, cookies, logs, keychain content, and absolute local paths out of commits. Configure your GitHub noreply email in your local clone.
- Use synthetic examples in public issues. Revoke or rotate exposed credentials, then follow the [security policy](SECURITY.md) to report privately.

By contributing, you confirm you have the right to submit the changes and agree to distribute them under the project's [MIT license](LICENSE). For third-party material, retain the original notices and update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
