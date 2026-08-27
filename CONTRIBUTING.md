# 贡献指南

欢迎为 KimiQuotaBar 贡献代码、Issue 或文档。在提交前请阅读以下内容。

## 开发环境

- macOS 13.0+
- Xcode 或 Swift 5.9+ 工具链

## 常用命令

```bash
make build     # 编译（swift build）
make run       # 运行调试版本（菜单栏应用，不出现在 Dock）
make package   # 打包 .app Bundle（含图标与 Info.plist）
make install   # 安装到 /Applications
make clean     # 清理构建产物
```

## 提交规范

- 提交信息使用 [Conventional Commits](https://www.conventionalcommits.org/) 风格，前缀建议：`feat:` / `fix:` / `refactor:` / `docs:` / `ci:` / `build:` / `chore:`。
- 提交信息与代码注释使用**中文**为主（与项目现有风格保持一致）。
- 改动涉及新功能时，同步更新 README 与 AGENTS.md（如有必要）。

## 代码风格

- 并发相关：UI 更新集中在 `@MainActor`，网络回调通过 `DispatchQueue.main.async` 切回主线程。
- 网络请求与 `onUpdate` 闭包中使用 `[weak self]` 避免循环引用。
- 数据模型使用 `Codable` 解析 JSON，字段类型尽量与 API 保持一致（例如额度字段为 `String`）。
- 错误处理：API 错误优先解析 JSON 中的 `error.message`；解码失败时给出字段级中文提示。
- 菜单栏文案与错误提示保持中文。

## 新增文件注意事项

- 新增 Swift 源文件后，需同步更新 `Package.swift` 中 `executableTarget` 的 `sources` 列表。
- 修改 `Package.swift` 时，记得将新增的非 Swift 资源或文档目录加入 `exclude`，避免被当作源文件编译。
- 打包相关的改动需要同时验证 `make package` 的输出结构。

## 验证

当前项目没有自动化测试，请至少完成以下手动验证：

1. `make clean && make package` 成功生成 `.build/KimiQuotaBar.app`。
2. `swift build` 无编译错误。
3. 启动应用后菜单栏出现图标。
4. 在 `~/.config/kimiquotabar/config.json` 配置 `kimi.api_key` 后点击「立即刷新」，菜单正确显示额度信息。
5. 再次 `open .build/KimiQuotaBar.app` 不会启动第二个实例（单实例检测）。
6. 点击「开机自启动」可正确注册/注销登录项。

## 发版

维护者打 `v*` Tag 并推送即可触发 [Release 工作流](.github/workflows/release.yml) 自动构建 DMG 并发布 GitHub Release：

- 发布说明自动生成：自上一版本以来的提交日志（按类型分组）+ Tag 消息中 `Release Notes` 段落的手动补充。
- 示例：

```bash
git tag -a v0.2.0 -m "v0.2.0

Release Notes
- 新增 XXX 功能
- 修复 XXX 问题"
git push origin v0.2.0
```
