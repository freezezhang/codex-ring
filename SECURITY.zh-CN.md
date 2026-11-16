# 安全政策

[English](SECURITY.md)

优先为最新稳定版本修复安全问题；请先确认最新版本是否仍存在问题。

## 私下报告

请使用仓库的 [Report a vulnerability](https://github.com/freezezhang/codex-ring/security/advisories/new) 私密报告入口。不要在公开 Issue、PR 或截图中发布 API Key、Cookie、登录令牌、账户邮箱或完整本地路径。若私密入口暂不可用，可在普通 Issue 中仅请求一个私密沟通渠道，不附漏洞细节或敏感数据。

报告应包括：受影响版本、操作系统、经过脱敏的复现步骤、预期与实际行为。若凭据已经暴露，请先在相应服务撤销或轮换；删除 Git 提交不能使凭据失效。

## 数据边界

- CodexRing 通过本机官方 Codex App Server 查询额度及账户显示信息，不读取或保存 Codex 的登录令牌文件。
- 可选 OpenAI API 功能会读取用户保存在 macOS 钥匙串中的 Admin API Key，并将其用于官方 Costs API 请求。应用不将它保存到偏好或日志中。
- 账户邮箱、套餐和最近一次用量快照在内存中使用；外观、位置、API 查询配置和提醒去重信息保存在本机。详见 [中文 README](README.zh-CN.md)。
- 辅助功能覆盖默认关闭。启用后读取控件标签与位置，仅在用户点击圆环时触发匹配的用量控件。
- 项目没有自建遥测服务。官方 Codex 组件和 OpenAI API 适用其各自的数据处理规则。

## 发布与隐私检查

构建使用临时目录及编译路径映射，去除调试符号中的本机路径，并检查最终应用。`scripts/check-privacy.py` 检查常见凭据格式、个人邮箱及用户目录路径；它不能证明不存在所有类型的敏感信息，发布前仍需人工审查截图、日志及元数据。
