# Contributing to CodexRing

欢迎提交问题、翻译和 Pull Request。CodexRing 是社区项目，与 OpenAI 无隶属关系。

## 开发

需要 macOS、Xcode Command Line Tools 和 Swift 5.9 或更新版本。

```sh
git clone https://github.com/freezezhang/codex-ring.git
cd codex-ring
zsh test.sh
python3 scripts/check-privacy.py
zsh build.sh
```

自动测试使用本地假数据，不需要提交账号、API Key 或登录文件。默认测试会短暂创建并关闭测试自己的设置窗口。真实窗口跟随检查见 README 的测试部分。

- 从最新 `main` 创建功能分支，保持改动范围明确。
- 为逻辑或生命周期变化补充有意义的回归测试；说明复现方式、结果及未验证的平台。
- UI 文案使用 `L10n`，同步维护所有语言。设置界面约定见 [AGENTS.md](AGENTS.md)。
- 不提交构建产物、账户截图、原始额度响应、Cookie、日志、钥匙串内容或本机绝对路径。
- 使用 GitHub 提供的 noreply 邮箱提交；请在自己的克隆中配置，不要覆盖全局身份。
- 公开 Issue 中只使用虚构示例。发现凭据泄漏时先撤销或轮换凭据，再按 [SECURITY.md](SECURITY.md) 私下报告。

提交贡献即表示你有权提交这些内容，并同意按项目 [MIT 许可证](LICENSE) 提供贡献。第三方代码必须保留其版权和许可证，更新 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
