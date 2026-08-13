# KimiQuotaBar 项目指南

> 本文档面向 AI 编程助手。读者被假设为完全不了解本项目。

## 项目概述

KimiQuotaBar 是一个 macOS 菜单栏应用（Menu Bar App），用于实时显示 Kimi Code API 的剩余额度，同时可选支持 OpenCode Go 额度显示。它以 `LSUIElement`（accessory）模式运行，不在 Dock 中显示图标，只在系统菜单栏显示一个状态图标和下拉菜单。

- **目标平台**: macOS 13.0+
- **编程语言**: Swift 5.9+
- **UI 框架**: SwiftUI + AppKit (`NSStatusBar`)
- **包管理器**: Swift Package Manager (`Package.swift`)
- **构建工具**: `make` + `swift build`
- **Bundle ID**: `com.ijkzen.KimiQuotaBar`

## 项目结构

```
KimiQuotaBar/
├── Package.swift              # Swift Package Manager 配置
├── Makefile                   # 构建、打包、安装脚本
├── KimiQuotaBarApp.swift      # 应用入口、AppDelegate、菜单栏 UI
├── QuotaManager.swift         # Kimi API 请求、数据模型、API Key 读取
├── OpenCodeGoManager.swift    # OpenCode Go 额度查询、CookieCloud 解密、配置读取
├── LaunchAtLoginManager.swift # 开机自启动（SMAppService）封装
├── assets/AppIcon.png         # 应用图标源文件
├── README.md                  # 面向用户的说明文档
└── docs/superpowers/          # 历史实现计划与设计文档
```

### 源文件职责

| 文件 | 主要职责 |
|------|----------|
| `KimiQuotaBarApp.swift` | `App` 入口、`NSApplicationDelegate`、单实例检测、构建 `NSMenu` 菜单栏、绘制状态栏图标、错误详情弹窗 |
| `QuotaManager.swift` | 定义 `QuotaResponse` 等数据模型；调用 `https://api.kimi.com/coding/v1/usages`；从环境变量或 `~/.hermes/.env` 读取 `KIMI_API_KEY` |
| `OpenCodeGoManager.swift` | 读取 `~/.config/kimiquotabar/config.json`；从 CookieCloud 服务器下载并解密 `opencode.ai` 的 `auth` cookie；抓取 dashboard HTML 并解析 SSR 内嵌的用量与账单数据 |
| `LaunchAtLoginManager.swift` | 基于 `SMAppService.mainApp` 注册/注销登录项，查询当前登录项状态 |

## 技术栈与运行时架构

- **启动流程**: `KimiQuotaBarApp.init()` 将应用设为 accessory 模式 → `AppDelegate.applicationDidFinishLaunching` 进行单实例检测 → 创建 `NSStatusItem` → 初始化 `QuotaManager` 并首次刷新 → 启动 5 分钟定时器。
- **数据刷新**: `QuotaManager.refresh()` 发送 `URLRequest` 到 Kimi API，解码 JSON 后通过 `onUpdate` 回调通知 `AppDelegate` 重建菜单。
- **状态栏显示**: 应用不使用系统字体标题，而是在 `NSImage` 上绘制「KIMI」+ 剩余额度百分比，生成位图作为 `statusItem.button?.image`。
- **菜单内容**: 顶部为开机自启动开关（原生勾选样式）；下方为「Kimi Code 额度」和「OpenCode Go 额度」（可选）两个区块，标题与额度详情之间无分隔线；信息行（标题、重置、余额）使用 `MenuInfoView`、额度行使用 `QuotaBarView`、错误行使用 `ErrorRowView`（红点 + 固定宽度短文案，长错误文本不会撑宽菜单；点击该行先关闭下拉菜单，再以 `NSAlert` 弹窗展示完整错误）自定义视图，统一 12pt 左右边距（`MenuRowLayout`，原生 NSMenuItem 约 22pt 缩进无法修改，操作行保持原生）；每个额度以「标签 + 进度条 + 百分比数字」展示，剩余 ≤10% 红色、否则绿色。刷新失败时保留旧数据，仅追加一行红点错误提示；OpenCode Go 刷新失败后 3 秒自动重试一次。
- **API Key 来源**（按优先级）:
  1. 环境变量 `KIMI_API_KEY`
  2. `~/.hermes/.env` 文件中的 `KIMI_API_KEY=...`
- **OpenCode Go 额度**: 官方没有 JSON 额度 API，数据内嵌在 dashboard HTML 的 SSR 数据中。`GET https://opencode.ai/workspace/{id}/go` 内含 `rollingUsage`/`weeklyUsage`/`monthlyUsage`（各含 `usagePercent` 与 `resetInSec`）；`GET .../billing` 内含 `balance`/`monthlyLimit`/`monthlyUsage`（金额单位 1 USD = 1e8）。认证依赖 `opencode.ai` 的 HttpOnly `auth` cookie（失效时服务端 302 跳登录页），通过 CookieCloud 同步获取；解密算法为 CryptoJS 兼容格式：passphrase = md5hex(`uuid-password`) 前 16 字符，密文为 base64(`Salted__` + 8字节salt + AES-256-CBC密文)，key/iv 由 OpenSSL EVP_BytesToKey(MD5) 派生。配置位于 `~/.config/kimiquotabar/config.json` 的 `opencode_go` 段落；未配置时菜单不显示该区块。CookieCloud 请求使用独立的 `URLSession` 并清空 `connectionProxyDictionary` 直连（系统代理/SOCKS 对局域网地址转发不稳定，会导致假性 "offline" 错误）。

## 构建与运行

### 前置要求

- macOS 13.0+
- Xcode 或 Swift 5.9+ 工具链
- 有效的 Kimi Code API Key

### 常用命令

```bash
# 编译项目
make build
# 等价于: swift build

# 运行调试版本（菜单栏应用，不会出现在 Dock）
make run
# 等价于: swift run

# 打包成 .app Bundle（包含图标和 Info.plist）
make package

# 安装到 /Applications（可能需要 sudo）
make install

# 清理构建产物
make clean
```

### 打包说明

`make package` 会执行以下关键步骤：

1. 调用 `swift build` 生成可执行文件 `.build/debug/KimiQuotaBar`。
2. 创建 `.app` Bundle 目录结构 `Contents/MacOS` 和 `Contents/Resources`。
3. 使用 `PlistBuddy` 生成 `Info.plist`，关键字段包括：
   - `CFBundleIdentifier`: `com.ijkzen.KimiQuotaBar`
   - `LSUIElement`: `true`（不在 Dock 显示）
   - `CFBundleIconFile`: `AppIcon`
4. 使用 `sips` + `iconutil` 将 `assets/AppIcon.png` 转换为 `AppIcon.icns`，放入 `Resources`。
5. 使用 `codesign --force --deep --sign -` 对 `.app` 进行临时签名。

## 代码风格与约定

- **语言**: 源代码注释、菜单文案、错误提示均以中文为主。
- **并发**: UI 更新集中在 `@MainActor`；网络回调通过 `DispatchQueue.main.async` 切回主线程。
- **内存管理**: 网络请求和 `onUpdate` 闭包中使用 `[weak self]` 避免循环引用。
- **数据模型**: 使用 `Codable` 解析 JSON，字段类型尽量与 API 保持一致（例如额度字段为 `String`）。
- **错误处理**: API 错误优先解析 JSON 中的 `error.message`；解码失败时给出字段级中文提示。
- **菜单组织**: 使用 `NSMenuItem.separator()` 分隔不同功能区域，禁用态菜单项通过 `isEnabled = false` 实现。

## 测试策略

- 当前项目**没有自动化单元测试或 UI 测试**。
- 验证依赖手动流程：
  1. `make clean && make package` 成功生成 `.build/KimiQuotaBar.app`。
  2. `swift build` 无编译错误。
  3. 启动应用后菜单栏出现图标。
  4. 配置 `KIMI_API_KEY` 后点击「立即刷新」，菜单正确显示额度信息。
  5. 再次 `open .build/KimiQuotaBar.app` 不会启动第二个实例（单实例检测）。
  6. 点击「开机自启动」可正确注册/注销登录项。

## 部署与分发

- 当前通过 `make install` 将 `.app` 复制到 `/Applications/KimiQuotaBar.app`。
- 由于使用临时签名（`codesign -s -`），如需分发给其他用户，需使用有效的 Apple Developer ID 重新签名并公证。
- 开机自启动功能要求应用通常需要位于 `/Applications`，否则 `SMAppService` 注册可能失败。

## 安全与隐私注意事项

- **API Key 管理**: 应用从环境变量或 `~/.hermes/.env` 读取 `KIMI_API_KEY`，**不会**将 Key 写入应用 Bundle 或共享存储。修改后注意提醒用户保护该文件权限。
- **网络请求**: Kimi 额度仅向 `https://api.kimi.com/coding/v1/usages` 发起请求，附带 `Authorization: Bearer <KIMI_API_KEY>`；OpenCode Go 额度向用户配置的 CookieCloud 服务器（`GET /get/{uuid}`）和 `https://opencode.ai/workspace/{id}/go`、`/billing` 发起请求，附带 `Cookie: auth=<auth_cookie>`。
- **CookieCloud 凭据**: `~/.config/kimiquotabar/config.json` 以明文保存 CookieCloud 的 uuid/password（可解密出所有同步的 cookie），注意提醒用户保护该文件权限。
- **沙盒与权限**: 当前未启用 App Sandbox，未声明特殊权限；作为菜单栏 accessory 应用运行。
- **登录项**: 使用系统标准 `SMAppService` API，注册时会触发用户授权弹窗。

## 给 AI 助手的常见提示

- 修改 `Package.swift` 时，记得将新增的非 Swift 资源或文档目录加入 `exclude`，避免被当作源文件编译。
- 新增源文件后，需要同步更新 `Package.swift` 中 `executableTarget` 的 `sources` 列表。
- 菜单栏文案和错误提示保持中文。
- 涉及 UI 的代码请在 `@MainActor` 上下文中执行，避免运行时崩溃。
- 打包相关的改动需要同时验证 `make package` 的输出结构。
