# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。发布说明由 CI 自动生成，此处按版本维护人工整理的变更摘要。

## [Unreleased]

### 新增

- LICENSE（MIT）、CONTRIBUTING.md、CHANGELOG.md 等开源项目文档
- README 全面更新：补充 Command Code 配置、quota_provider 切换、设置窗口、隐私说明等

## [v0.1.1] - 2026-08-27

### 新增

- 设置窗口：SwiftUI 动态表单，覆盖 config.json 全部可配置字段，敏感字段默认掩码可切换明文
- 保存配置后自动刷新全部额度（`.configDidSave` 通知）

## [v0.1.0] - 2026-08-27

### 新增

- Command Code 额度显示（`/alpha/*` 私有 API）与 `quota_provider` 切换
- 菜单显示 5 小时窗口 / 本周各窗口剩余与重置时间
- Kimi API Key 从 `~/.config/kimiquotabar/config.json` 的 `kimi.api_key` 读取（环境变量兜底）
- 长错误文本改为红点行 + 点击弹窗查看完整错误
- 每次刷新重读配置文件，修改后无需重启

### 修复

- 额度耗尽时缺失 `remaining` 字段导致的解析失败

### 变更

- 发布物从 zip 改为 DMG（拖拽安装布局）
- GitHub Actions 自动发版流程（提交日志分组 + Release Notes 段落）

[Unreleased]: https://github.com/ijkzen/KimiQuotaBar/compare/v0.1.1...HEAD
[v0.1.1]: https://github.com/ijkzen/KimiQuotaBar/compare/v0.1.0...v0.1.1
[v0.1.0]: https://github.com/ijkzen/KimiQuotaBar/releases/tag/v0.1.0
