# KimiQuotaBar 项目指南

> 本文档面向 AI 编程助手。读者被假设为完全不了解本项目。

## 项目概述

KimiQuotaBar 是一个 macOS 菜单栏应用（Menu Bar App），通过自托管的 llm-gateway 对外只读接口（`/v1/providers*`）实时显示 LLM 供应商的用量信息（订阅窗口 / 按量余额），llm-gateway 是**唯一信息源**（历史版本直连 Kimi/OpenCode Go/Command Code 的 manager 已删除）。它以 `LSUIElement`（accessory）模式运行，不在 Dock 中显示图标，只在系统菜单栏显示一个状态图标和下拉菜单。

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
├── GatewayManager.swift       # AppConfig 配置模型 + llm-gateway 用量查询（/v1/providers*，Bearer API Key）
├── SettingsWindowController.swift # 设置窗口（SwiftUI 表单，配置读写）
├── LaunchAtLoginManager.swift # 开机自启动（SMAppService）封装
├── assets/AppIcon.png         # 应用图标源文件
├── README.md                  # 面向用户的说明文档（安装、配置、故障排除）
├── LICENSE                    # MIT 许可证
├── CONTRIBUTING.md            # 贡献指南（代码风格、提交规范、发版流程）
├── CHANGELOG.md               # 版本变更记录
└── docs/superpowers/          # 历史实现计划与设计文档
```

### 源文件职责

| 文件 | 主要职责 |
|------|----------|
| `KimiQuotaBarApp.swift` | `App` 入口、`NSApplicationDelegate`、单实例检测、构建 `NSMenu` 菜单栏、绘制状态栏图标、错误详情弹窗 |
| `GatewayManager.swift` | `AppConfig`（`~/.config/kimiquotabar/config.json`，仅 `gateway` 段）；调用 `GET <网关>/v1/providers`（列表）与 `GET /v1/providers/{id}/usage`（用量，`Authorization: Bearer <api_key>`）；解析统一信封（code/msg/data）与 OpenAI 风格鉴权错误；手动刷新带 `?refresh=1` 绕过网关 10 分钟缓存 |
| `SettingsWindowController.swift` | 设置窗口（`SettingsWindowController` 管理 NSWindow + NSHostingView，`SettingsView` 为 SwiftUI 表单）：网关地址 / API Key（掩码可切换明文）/ 展示供应商勾选（最多三个，打开时自动加载列表）/ 菜单栏数字（先选供应商，窗口下拉按该供应商实际可用窗口动态填充——选中后拉取其用量，订阅制列出 available 窗口、按量为「主余额」）；固定尺寸 460×560，上部字段固定、中部供应商列表占满横向且仅此处滚动、底部按钮经 Spacer 固定在窗口底部；保存时清除历史信息源字段（kimi/opencode_go/command_code/quota_provider），写回 config.json 并发 `.configDidSave` 通知自动刷新 |
| `LaunchAtLoginManager.swift` | 基于 `SMAppService.mainApp` 注册/注销登录项，查询当前登录项状态 |

## 技术栈与运行时架构

- **启动流程**: `KimiQuotaBarApp.init()` 将应用设为 accessory 模式 → `AppDelegate.applicationDidFinishLaunching` 进行单实例检测 → 创建 `NSStatusItem` → 初始化 `GatewayManager` 并首次刷新 → 启动 5 分钟定时器。
- **数据刷新**: `GatewayManager.refresh(force:)` 先取供应商列表解析名称，再并发拉取各已选供应商用量；完成后通过 `onUpdate` 回调通知 `AppDelegate` 重建菜单。防重入（`isRefreshing`）+ 配置快照校验（请求期间配置变更则丢弃结果）。
- **状态栏显示**: 应用不使用系统字体标题，而是在 `NSImage` 上绘制「供应商名 + 数字」生成位图：数字来源由 `gateway.status_bar` 指定（供应商 + 窗口，或按量供应商的主余额），缺省自动取第一个有可展示订阅窗口的已选供应商的最大窗口（月 > 周 > 日 > 5h）；百分比/金额均只保留一位小数；头部供应商名多单词时取各单词首字母大写缩写（如 Kimi For Coding → KFC），单词名（含中文名）超宽时逐字截断；无配置/无数据时显示「--」。
- **菜单内容**: 顶部为开机自启动开关（原生勾选样式）；下方按已选供应商分区块（最多三个，按 `gateway.provider_ids` 顺序），每区块：标题行「<名称> 用量 · 套餐」（右侧尾随弱化的「更新 HH:mm」，不单独占行）、可选错误行、订阅窗口进度条行（仅 `available` 窗口；窗口 label 仅在同供应商存在多种不同标注时逐行展示，单套餐不重复）+「已用 X / Y 单位 · M月d日 HH:mm 重置」同一行（已用居左、重置右对齐尾随，重置按网关返回时区渲染）或按量余额行（label: 金额 币种）。信息行使用 `MenuInfoView`（支持右侧尾随文本；弱化行 18pt 紧凑行高）、额度行使用 `QuotaBarView`（20pt）、错误行使用 `ErrorRowView`（红点 + 固定宽度短文案，点击弹窗展示完整错误）自定义视图，统一 12pt 左右边距（`MenuRowLayout`）。进度条颜色与网关网页用量卡一致（剩余 >50% 绿、>20% 黄、≤20% 红），百分比支持小数；标签列至少 56pt，长标签（如积分池标注）自适应加宽，进度条与信息行随菜单宽度横向撑满。刷新失败时保留旧数据，仅追加红点错误行。底部「设置」菜单项（无省略号）打开设置窗口。
- **配置来源**: `~/.config/kimiquotabar/config.json` 的 `gateway` 段（`url` / `api_key` / `provider_ids` / `status_bar`）；`AppConfig.load()` 每次刷新重读文件，改配置后无需重启。保存时合并保留文件中表单未覆盖的字段，并清除历史直连信息源字段。

## 构建与运行

### 前置要求

- macOS 13.0+
- Xcode 或 Swift 5.9+ 工具链
- 可访问的 llm-gateway 实例及其 `lg-` API Key

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
- **数据模型**: 使用 `Codable` 解析 JSON，字段类型与网关 API 保持一致（百分比/金额为 `Double`，可选字段可缺省或为 null）。
- **错误处理**: 网关业务错误优先取信封 `msg`；鉴权错误（401/OpenAI 风格信封）取 `error.message`；网络层错误封装为 `GatewayError`。
- **菜单组织**: 使用 `NSMenuItem.separator()` 分隔不同功能区域，禁用态菜单项通过 `isEnabled = false` 实现。

## 测试策略

- 当前项目**没有自动化单元测试或 UI 测试**。
- 验证依赖手动流程：
  1. `make clean && make package` 成功生成 `.build/KimiQuotaBar.app`。
  2. `swift build` 无编译错误。
  3. 启动应用后菜单栏出现图标。
  4. 在设置窗口填写网关地址与 API Key、勾选供应商并保存后，菜单正确显示用量信息。
  5. 再次 `open .build/KimiQuotaBar.app` 不会启动第二个实例（单实例检测）。
  6. 点击「开机自启动」可正确注册/注销登录项。

## 部署与分发

- 当前通过 `make install` 将 `.app` 复制到 `/Applications/KimiQuotaBar.app`。
- 由于使用临时签名（`codesign -s -`），如需分发给其他用户，需使用有效的 Apple Developer ID 重新签名并公证。
- 开机自启动功能要求应用通常需要位于 `/Applications`，否则 `SMAppService` 注册可能失败。

## 安全与隐私注意事项

- **API Key 管理**: 应用从 `~/.config/kimiquotabar/config.json` 的 `gateway.api_key` 读取 API Key，**不会**将 Key 写入应用 Bundle 或共享存储。该配置文件以明文保存 API Key，注意提醒用户保护该文件权限。
- **网络请求**: 仅向配置的 `gateway.url` 下 `/v1/providers` 与 `/v1/providers/{id}/usage` 发起请求，附带 `Authorization: Bearer <api_key>`。
- **沙盒与权限**: 当前未启用 App Sandbox，未声明特殊权限；作为菜单栏 accessory 应用运行。
- **登录项**: 使用系统标准 `SMAppService` API，注册时会触发用户授权弹窗。

## 给 AI 助手的常见提示

- 修改 `Package.swift` 时，记得将新增的非 Swift 资源或文档目录加入 `exclude`，避免被当作源文件编译。
- 新增源文件后，需要同步更新 `Package.swift` 中 `executableTarget` 的 `sources` 列表。
- 菜单栏文案和错误提示保持中文。
- 涉及 UI 的代码请在 `@MainActor` 上下文中执行，避免运行时崩溃。
- 打包相关的改动需要同时验证 `make package` 的输出结构。
- 调试钩子：`KQB_OPEN_SETTINGS=1 swift run`（或直接运行二进制）启动后自动打开设置窗口，供 UI 自动化/截图验证设置页。
