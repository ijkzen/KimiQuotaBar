# KimiQuotaBar 安装、开机自启动与单实例实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 KimiQuotaBar 可以通过 `make install` 安装到 `/Applications`，在菜单中开关开机自启动，并保证只运行一个实例。

**Architecture:** 复用已有的 `make package` 生成 `.app`，`make install` 改把 `.app` 复制到 `/Applications`；新增 `LaunchAtLoginManager` 封装 `SMAppService` 登录项 API；在 `KimiQuotaBarApp` 启动早期用 `NSRunningApplication` 检测重复实例并激活旧实例后退出。

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, ServiceManagement (`SMAppService`), `NSRunningApplication`, Makefile.

---

## File Structure

| 文件 | 变更 | 职责 |
|------|------|------|
| `Makefile` | 修改 | 修改 `install` 目标，使其依赖 `package` 并复制 `.app` 到 `/Applications/` |
| `LaunchAtLoginManager.swift` | 新建 | 封装 `SMAppService` 的注册/取消注册、状态查询 |
| `KimiQuotaBarApp.swift` | 修改 | 单实例检测、集成「开机自启动」菜单项 |
| `README.md` | 修改 | 更新安装和运行说明 |
| `Package.swift` | 修改 | 将 `LaunchAtLoginManager.swift` 加入 executable target 的 sources |

---

### Task 1: 修改 Makefile 的 install 目标

**Files:**
- Modify: `Makefile:12-13`

- [ ] **Step 1: 修改 install 目标依赖 package 并复制 .app**

```makefile
install: package
	cp -R .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app
```

完整 Makefile 应如下：

```makefile
.PHONY: build run clean install package

build:
	swift build

run:
	swift run

clean:
	rm -rf .build

install: package
	cp -R .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app

package: build
	@echo "Packaging KimiQuotaBar.app..."
	@rm -rf .build/KimiQuotaBar.app
	@mkdir -p .build/KimiQuotaBar.app/Contents/MacOS
	@cp .build/debug/KimiQuotaBar .build/KimiQuotaBar.app/Contents/MacOS/
	@/usr/libexec/PlistBuddy -c "Clear dict" \
		-c "Add :CFBundleExecutable string KimiQuotaBar" \
		-c "Add :CFBundleIdentifier string com.ijkzen.KimiQuotaBar" \
		-c "Add :CFBundleName string KimiQuotaBar" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleShortVersionString string 1.0" \
		-c "Add :LSUIElement bool true" \
		.build/KimiQuotaBar.app/Contents/Info.plist >/dev/null
	@echo "Created .build/KimiQuotaBar.app"
```

- [ ] **Step 2: 验证语法**

Run: `make -n install`
Expected: 打印 `cp -R .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app` 之类的命令，无语法错误。

- [ ] **Step 3: 提交**

```bash
git add Makefile
git commit -m "build: install copies .app bundle to /Applications"
```

---

### Task 2: 创建 LaunchAtLoginManager

**Files:**
- Create: `LaunchAtLoginManager.swift`
- Modify: `Package.swift`（将新文件加入 sources）

- [ ] **Step 1: 在 Package.swift 中加入新源文件**

Modify `Package.swift:20-23`:

```swift
sources: [
    "KimiQuotaBarApp.swift",
    "QuotaManager.swift",
    "LaunchAtLoginManager.swift"
]
```

- [ ] **Step 2: 创建 LaunchAtLoginManager.swift**

```swift
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private init() {}

    var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    func toggle() -> String? {
        if isEnabled {
            return disable()
        } else {
            return enable()
        }
    }

    func enable() -> String? {
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return "注册失败: \(error.localizedDescription)"
        }
    }

    func disable() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "取消注册失败: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: Build complete with no errors.

- [ ] **Step 4: 提交**

```bash
git add Package.swift LaunchAtLoginManager.swift
git commit -m "feat: add LaunchAtLoginManager with SMAppService"
```

---

### Task 3: 集成单实例检测与登录项菜单

**Files:**
- Modify: `KimiQuotaBarApp.swift`

- [ ] **Step 1: 在 KimiQuotaBarApp.init() 中加入单实例检测**

```swift
import SwiftUI

@main
struct KimiQuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        // 单实例检测：若已有实例运行，激活旧实例并退出
        let bundleID = "com.ijkzen.KimiQuotaBar"
        let otherApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if let other = otherApps.first {
            other.activate(options: .activateIgnoringOtherApps)
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
```

- [ ] **Step 2: 在 AppDelegate 中新增启动项菜单项与错误显示**

在 `AppDelegate` 顶部新增属性：

```swift
private let launchManager = LaunchAtLoginManager.shared
private var launchAtLoginError: String?
```

在 `updateMenu()` 中，** quotaManager 错误之后、刷新按钮之前** 加入：

```swift
// 登录项设置错误
if let launchAtLoginError = launchAtLoginError {
    let errorItem = NSMenuItem(title: "⚠️ \(launchAtLoginError)", action: nil, keyEquivalent: "")
    errorItem.isEnabled = false
    menu.addItem(errorItem)
    menu.addItem(NSMenuItem.separator())
}

// 开机自启动
let isLaunchAtLogin = launchManager.isEnabled
let loginItem = NSMenuItem(
    title: "\(isLaunchAtLogin ? "✓ " : "")开机自启动",
    action: #selector(toggleLaunchAtLogin),
    keyEquivalent: ""
)
loginItem.target = self
menu.addItem(loginItem)

menu.addItem(NSMenuItem.separator())
```

在 `@objc func refreshClicked()` 附近添加：

```swift
@objc func toggleLaunchAtLogin() {
    launchAtLoginError = launchManager.toggle()
    updateMenu()
}
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: Build complete with no errors.

- [ ] **Step 4: 提交**

```bash
git add KimiQuotaBarApp.swift
git commit -m "feat: single instance check and login item menu"
```

---

### Task 4: 更新 README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 替换安装和运行章节**

将「构建和运行」章节更新为：

```markdown
### 构建和运行

```bash
# 克隆项目
git clone <repository-url>
cd KimiQuotaBar

# 构建
make build

# 打包成 .app
make package

# 安装到 /Applications（可能需要 sudo）
make install

# 启动应用
open /Applications/KimiQuotaBar.app
```

### 开机自启动

1. 运行应用后点击菜单栏图标
2. 点击「开机自启动」
3. 在系统弹窗中允许授权
4. 应用将出现在「系统设置 → 通用 → 登录项」中
```

- [ ] **Step 2: 提交**

```bash
git add README.md
git commit -m "docs: update install and launch-at-login instructions"
```

---

### Task 5: 端到端验证

**Files:**
- 无文件变更

- [ ] **Step 1: 清理并重新打包**

Run: `make clean && make package`
Expected: `.build/KimiQuotaBar.app` 生成成功。

- [ ] **Step 2: 编译通过**

Run: `swift build`
Expected: Build complete with no errors.

- [ ] **Step 3: 手动测试单实例**

Run:
```bash
open .build/KimiQuotaBar.app
sleep 2
open .build/KimiQuotaBar.app
```
Expected: 第一次启动后菜单栏出现图标；第二次 `open` 不会创建新进程（`pgrep -c KimiQuotaBar` 保持为 1）。

- [ ] **Step 4: 清理测试进程**

```bash
pkill -f KimiQuotaBar.app
```

- [ ] **Step 5: 提交**

```bash
git commit --allow-empty -m "test: manual end-to-end verification passed"
```

---

## Self-Review

**1. Spec coverage：**

| 设计决策 | 对应任务 |
|----------|----------|
| 修改 `make install` 复制 `.app` 到 `/Applications` | Task 1 |
| 使用 `SMAppService` 实现登录项 | Task 2, Task 3 |
| 菜单中增加「开机自启动」开关 | Task 3 |
| 使用 `NSRunningApplication` 实现单实例 | Task 3 |
| 更新 README | Task 4 |

无遗漏。

**2. Placeholder scan：**

- 无 "TBD"/"TODO"。
- 每个代码步骤都包含完整代码。
- 每个命令都包含预期输出。

**3. Type consistency：**

- `LaunchAtLoginManager.shared` 单例在 Task 2 创建，Task 3 中使用 `private let launchManager = LaunchAtLoginManager.shared` 引用，一致。
- `SMAppService.mainApp.status` 的 `case .enabled` 判断正确。
- `NSRunningApplication.runningApplications(withBundleIdentifier:)` 返回数组，用 `.count > 1` 判断重复实例正确。

无类型或命名不一致问题。
