# CodexRing 开发说明

[English](development.en.md)

用户操作、下载和界面介绍见 [中文 README](../README.zh-CN.md)。

## 构建

```sh
zsh build.sh
```

生成 `build/CodexRing.app`，包括从图标原件生成的标准 macOS 图标，并进行本地 ad-hoc 签名。构建不会自动启动或安装应用。也可指定输出位置：

```sh
zsh build.sh "$PWD/build/0.1.0/CodexRing.app"
```

第二个参数可指定 `x86_64` 或 `arm64`，默认使用当前机器架构。版本默认读取 `VERSION`；发布时由标签覆盖：

```sh
CODEXRING_VERSION=0.1.1 zsh build.sh "$PWD/build/arm64/CodexRing.app" arm64
```

图标原件是 `assets/AppIcon-source.png`。`scripts/make-icon.swift` 从该图生成 16–1024 像素 PNG 和 ICNS。使用 Xcode 26 或更新版本构建时，另外编译 macOS 原生图标资源，避免 macOS 26 给冰蓝图标套上默认底板。

## 本地化

支持 English、简体中文、繁體中文、日本語和 한국어。设置 → 通用 → **语言 → 界面语言** 可选“跟随系统”或指定语言，默认跟随系统：按 macOS 首选语言顺序匹配已支持的语言（`zh-CN`、`zh-SG` 归入简体中文，`zh-TW`、`zh-HK`、`zh-MO` 归入繁体中文，`ja-JP` 与 `ko-KR` 分别匹配日语和韩语），都不支持时使用英文。选择会保存，切换后设置、菜单、菜单栏面板、悬停提示、无障碍标签和之后发出的通知立即更新，无需重启；macOS 提供的系统窗口、权限弹窗及已经发出的通知保持原语言。日期仍统一为北京时间 `yyyy.MM.dd HH:mm`。

文案位于 `Sources/QuotaCore/Resources/<语言代码>.lproj/Localizable.strings`，代码只通过 `L10n.string` / `L10n.format` 引用语义键。参数写作 `%@` 或 `%1$@`（语序不同时用编号），字面百分号写作 `%%`。

新增一种语言只需两步：

1. 复制 `en.lproj` 为 `<语言代码>.lproj`（如 `fr.lproj`），翻译所有值，保留全部键和占位符。
2. 在 `Sources/QuotaCore/Localization.swift` 的 `AppLanguage.supported` 中登记一行，例如 `AppLanguage(code:"fr",displayName:"Français")`；显示名使用该语言自身的写法。需要把其他系统语言标签归入该语言时，可填写 `systemAliases`。

设置选项、系统语言匹配、英文回退和 `build.sh` 打包的 `CFBundleLocalizations` 均由注册表和 `.lproj` 目录生成，无需改其他代码。`supported` 的第一项是回退语言，须与 `Package.swift` 的 `defaultLocalization` 一致。`LocalizationTests` 会检查各语言键集和占位符一致、源码引用的键都存在且没有未使用的键、注册表与 `.lproj` 目录一致，以及源码中没有硬编码中文文案。

## 测试

```sh
zsh test.sh
```

自动测试覆盖额度解析、周期能力、重置卡、统一日期、悬停提示、中心数字选择与持久化、调试隔离及边界、Codex 跟随开关与旧设置迁移、其他桌面隐藏、多窗口选择、相对位置及独立自由位置、全屏状态切换、全屏与普通最大化识别、跨屏定位、协议错误和超时、阈值、拖动几何、菜单顺序及浅深色离屏绘图。协议测试使用隔离的本地假服务器，不需要账户登录，不查询真实额度。

可选跟随集成检查：运行单元测试后执行 `zsh scripts/check-codex-follow.sh`。它使用真正的跟随实现、辅助功能读取和独立临时偏好，创建自己的测试窗口验证开关、移动、最大化、原生全屏、最小化、恢复及关闭；不操作真实 Codex、不查询额度、不修改用户偏好。默认检查需要测试进程已有辅助功能权限，不会替用户授予权限。传入 `--basic-follow` 可强制禁用 AX 读取，验证基本跟随路径，包括移动、缩放、全屏、最小化隐藏、恢复和关闭。

覆盖模式原生检查：先运行 `zsh test.sh`，再运行 `zsh scripts/check-usage-overlay.sh`。检查独立测试窗口中的控件定位、窗口及控件移动、悬停拦截及点击转发、控件消失和恢复、权限撤销和恢复、关闭覆盖后大小及位置恢复。仅使用测试进程已有的辅助功能权限。

可选原生窗口集成检查：启动 CodexRing 并关闭“跟随 Codex”后运行 `swift scripts/check-fullscreen.swift`。它创建自己的临时窗口、进入并退出原生全屏，检查圆圈确实位于全屏显示器且退出后恢复原先可见状态及位置；完成后自动关闭测试窗口。若原绑定桌面在另一显示器的非活动空间，测试前后都不显示圆圈是正确行为。此检查会切换到测试窗口，不包含在默认单元测试中。启动 CodexRing 时附加 `--space-diagnostics` 可将自身窗口状态及全屏识别依据输出到标准错误，便于排查。

拖动手感、贴边恢复、系统主题切换、普通最大化、原生全屏及桌面切换仍需在目标机器手动验收；离屏测试不等同于这些界面项目通过。验收：普通桌面 1 启动并固定圆圈，切到普通桌面 2 后应不显示，切回后位置保持；在其他应用进入全屏后检查圆圈、设置及调试窗口，退出全屏后确认原桌面位置；分别检查展开、贴边隐藏、跨屏、刷新期间的行为。

### 最低 macOS 版本验收

打包检查会分别确认 Info.plist 及各架构的 Mach-O 最低目标均为 macOS 13.0。GitHub 托管的原生测试目前运行在 macOS 26。实际安装和启动需在有图形会话的 macOS 13 设备或虚拟机上验收。

1. 下载候选版的对应架构或通用 ZIP，对照 `SHA256SUMS.txt`。
2. 退出测试设备上运行的 CodexRing，解压后复制到「应用程序」。对 Developer ID 签名的版本先执行 `spctl --assess --type execute --verbose=2 /Applications/CodexRing.app`，再从访达打开。
3. 检查菜单栏图标和圆环能显示，用量面板和设置能打开和关闭，修改一项设置后退出并重开，核对设置是否保留。
4. 如果有兼容该系统的官方 Codex，验证刷新与窗口跟随。记录 macOS 构建号、芯片架构、CodexRing 版本、ZIP 的 SHA-256 和未覆盖项目。

## 自动发布

推送 `v主版本.次版本.修订版本` 格式的标签即可自动创建 GitHub Release，例如：

```sh
git tag -a v0.1.1 -m "CodexRing v0.1.1"
git push origin v0.1.1
```

标签必须指向 `main` 上已验证的提交。标签决定应用版本号及下载文件名。`VERSION` 提供本地构建及手动工作流的默认版本。

GitHub 在 Intel 和 Apple 芯片的 macOS 26 环境运行测试并构建，再合成通用包。配置 Apple 凭证并启用公证后，三个安装包会经 Developer ID 签名，启用 Hardened Runtime，分别提交 Apple 公证，附上公证票据并通过 Gatekeeper 校验。启用前继续以 ad-hoc 签名发布，Release 说明会标明签名方式。发布任务先上传三个 ZIP 和校验文件到草稿，再下载复核，最后公开。启用 GitHub 不可变发布后，新发布的附件和标签会锁定。已发布的安装包需要修正时，使用新的版本号和标签。

推送 `main` 或打开 PR 时运行 Swift 测试和隐私检查。在 Actions 手动运行 **Build and release** 可得到 ad-hoc 签名的 `test-packages`。在 `main` 勾选 **Sign and notarize a test build from main** 可验证 Apple 签名流程并下载 `release-packages`。这两种手动运行都只产出构建文件。

Apple 签名使用 GitHub Actions 的 `apple-signing` 环境，限定 `main` 和 `v*` 发布标签。按[签名凭证说明](development.en.md#apple-credentials)配置五项环境密钥。手动签名验证通过后，将仓库 Actions 变量 `APPLE_NOTARIZE_RELEASES` 设为 `true`。启用后若凭证缺失或公证失败，标签运行会在公开前停止。
