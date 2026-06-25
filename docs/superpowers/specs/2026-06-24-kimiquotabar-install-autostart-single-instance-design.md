# KimiQuotaBar 安装、开机自启动与单实例设计

## 背景

KimiQuotaBar 是一个 macOS 菜单栏应用，用于实时显示 Kimi Code API 的剩余额度。当前已经具备基础的菜单栏展示、额度刷新和 `.app` Bundle 打包能力。为了提升日常使用体验，需要实现以下三个能力：

1. 一键安装到 `/Applications` 文件夹。
2. 通过菜单开关将应用添加到系统登录项（开机自启动）。
3. 保证同一时刻只有一个应用实例在运行。

## 设计决策

### 1. 安装到 /Applications

- 修改 `Makefile` 中的 `install` 目标，使其依赖 `package` 目标，确保先构建出 `.app` Bundle，再复制到 `/Applications/`。
- 不再将裸可执行文件复制到 `/usr/local/bin/`，因为菜单栏应用的标准形态是 `.app` Bundle。
- 若 `/Applications/` 需要管理员权限，`cp -R` 会失败并提示用户运行 `sudo make install`。

```makefile
install: package
	cp -R .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app
```

### 2. 开机自启动

- 使用 macOS 13+ 提供的 `SMAppService` API，将主应用本身注册为登录项。
- 新增 `LaunchAtLoginManager` 类，封装注册/取消注册逻辑，并提供当前状态查询。
- 在菜单栏菜单中新增「开机自启动」选项，带勾选标记，点击即可切换。
- 每次打开菜单时，从 `SMAppService.mainApp.status` 刷新勾选状态，确保与系统设置保持一致。
- 注册失败时（常见原因：应用不在 `/Applications`），在菜单中显示错误信息。

### 3. 单实例运行

- 在应用启动早期（`KimiQuotaBarApp.init()`）通过 `NSRunningApplication.runningApplications(withBundleIdentifier:)` 检查是否已有同 Bundle ID 的实例在运行。
- 若检测到已有实例：
  1. 调用 `other.activate(options: .activateIgnoringOtherApps)` 激活旧实例。
  2. 调用 `NSApplication.shared.terminate(nil)` 让新实例立即退出。
- 该方案无需文件锁或进程间通信，实现简单且符合 macOS 标准行为。

### 4. 菜单结构

更新后的菜单栏菜单结构如下：

```
Kimi Code 额度
──────────────
7天额度: <remaining> / <limit>
5h窗口: <remaining> / <limit>
重置: <time>
会员: <level>
──────────────
✓ 开机自启动
🔄 立即刷新
──────────────
退出
```

### 5. 错误处理

- **登录项注册失败**：在菜单中显示「⚠️ 开机自启动设置失败: <原因>」，常见原因包括应用未安装在 `/Applications` 或用户拒绝系统弹窗。
- **安装失败**：`make install` 失败时终端会直接输出 `cp` 错误，用户可根据提示使用 `sudo`。
- **单实例检测异常**：若 `NSRunningApplication` 检测异常，允许应用继续启动，避免彻底无法使用。

### 6. 权限与限制

- `SMAppService` 会触发系统弹窗请求用户授权，用户需在「系统设置 → 通用 → 登录项」中允许。
- 登录项注册通常要求应用位于 `/Applications`，因此建议先执行 `make install` 再开启「开机自启动」。
- 本功能仅支持 macOS 13+，与项目现有的 `platforms: [.macOS(.v13)]` 一致。

## 验收标准

- `make install` 成功将 `KimiQuotaBar.app` 复制到 `/Applications/`。
- 应用菜单中出现「开机自启动」选项，点击后系统弹窗请求授权。
- 授权后，应用出现在系统设置的登录项列表中，重启系统后自动启动。
- 当应用已运行时，再次双击 `.app` 或执行 `open /Applications/KimiQuotaBar.app` 不会启动第二个实例，原有实例被激活。
