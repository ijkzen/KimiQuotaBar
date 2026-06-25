# KimiQuotaBar 应用图标实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 KimiQuotaBar 的 `.app` Bundle 添加 Kimi 官方圆角矩形图标，使其在 Finder、Dock 和关于窗口中正确显示。

**Architecture:** 将官方 PNG 源文件下载到 `assets/AppIcon.png`，在 `make package` 时用 `sips` + `iconutil` 生成标准 macOS `.icns` 文件，复制到 `.app/Contents/Resources/`，并通过 `Info.plist` 的 `CFBundleIconFile` 声明。

**Tech Stack:** Makefile, `sips`, `iconutil`, `PlistBuddy`, `codesign`.

---

## File Structure

| 文件 | 变更 | 职责 |
|------|------|------|
| `assets/AppIcon.png` | 新建 | Kimi 官方圆角矩形图标源文件 |
| `Makefile` | 修改 | 新增 `.icns` 生成、Resources 复制、Info.plist 图标声明 |
| `Package.swift` | 无变化 | `assets` 目录与 `Makefile`、`README.md`、`docs` 一起已被 `exclude` 排除，不会被当作 Swift 源文件编译 |

---

### Task 1: 下载 Kimi 官方图标源文件

**Files:**
- Create: `assets/AppIcon.png`

- [ ] **Step 1: 创建 assets 目录并下载图标**

Run:
```bash
mkdir -p assets
curl -L -o assets/AppIcon.png "https://kimi-web-img.moonshot.cn/prod-data/online-image/search-upload/e7271e9f5bf57036fef6953a9893ff68.png"
```

- [ ] **Step 2: 验证下载成功**

Run:
```bash
file assets/AppIcon.png
```
Expected: `assets/AppIcon.png: PNG image data, ...`

- [ ] **Step 3: 提交**

```bash
git add assets/AppIcon.png
git commit -m "assets: add Kimi official rounded corner icon source"
```

---

### Task 2: 修改 Makefile 生成并打包 .icns 图标

**Files:**
- Modify: `Makefile:15-29`（`package` 目标）

- [ ] **Step 1: 更新 package 目标**

将现有的 `package` 目标替换为以下内容：

```makefile
package: build
	@echo "Packaging KimiQuotaBar.app..."
	@rm -rf .build/KimiQuotaBar.app
	@mkdir -p .build/KimiQuotaBar.app/Contents/MacOS
	@mkdir -p .build/KimiQuotaBar.app/Contents/Resources
	@cp .build/debug/KimiQuotaBar .build/KimiQuotaBar.app/Contents/MacOS/
	@/usr/libexec/PlistBuddy -c "Clear dict" \
		-c "Add :CFBundleExecutable string KimiQuotaBar" \
		-c "Add :CFBundleIdentifier string com.ijkzen.KimiQuotaBar" \
		-c "Add :CFBundleName string KimiQuotaBar" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleShortVersionString string 1.0" \
		-c "Add :CFBundleIconFile string AppIcon" \
		-c "Add :LSUIElement bool true" \
		.build/KimiQuotaBar.app/Contents/Info.plist >/dev/null
	@rm -rf .build/AppIcon.iconset
	@mkdir -p .build/AppIcon.iconset
	@sips -z 16 16 assets/AppIcon.png --out .build/AppIcon.iconset/icon_16x16.png >/dev/null
	@sips -z 32 32 assets/AppIcon.png --out .build/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	@sips -z 32 32 assets/AppIcon.png --out .build/AppIcon.iconset/icon_32x32.png >/dev/null
	@sips -z 64 64 assets/AppIcon.png --out .build/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	@sips -z 128 128 assets/AppIcon.png --out .build/AppIcon.iconset/icon_128x128.png >/dev/null
	@sips -z 256 256 assets/AppIcon.png --out .build/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	@sips -z 256 256 assets/AppIcon.png --out .build/AppIcon.iconset/icon_256x256.png >/dev/null
	@sips -z 512 512 assets/AppIcon.png --out .build/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	@sips -z 512 512 assets/AppIcon.png --out .build/AppIcon.iconset/icon_512x512.png >/dev/null
	@sips -z 1024 1024 assets/AppIcon.png --out .build/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	@iconutil -c icns -o .build/KimiQuotaBar.app/Contents/Resources/AppIcon.icns .build/AppIcon.iconset >/dev/null
	@rm -rf .build/AppIcon.iconset
	@codesign --force --deep --sign - .build/KimiQuotaBar.app >/dev/null 2>&1 || true
	@echo "Created .build/KimiQuotaBar.app"
```

- [ ] **Step 2: 验证 Makefile 语法**

Run:
```bash
make -n package
```
Expected: 命令序列打印出来，没有 `Makefile:...` 语法错误。

- [ ] **Step 3: 运行 package 目标**

Run:
```bash
make clean && make package
```
Expected:
- `Building for debugging... Build complete!`
- `Packaging KimiQuotaBar.app...`
- `Created .build/KimiQuotaBar.app`
- `.build/KimiQuotaBar.app/Contents/Resources/AppIcon.icns` 存在

验证命令：
```bash
ls -la .build/KimiQuotaBar.app/Contents/Resources/AppIcon.icns
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" .build/KimiQuotaBar.app/Contents/Info.plist
```
Expected:
- `AppIcon.icns` 文件存在
- `CFBundleIconFile` 输出 `AppIcon`

- [ ] **Step 4: 提交**

```bash
git add Makefile
git commit -m "build: generate AppIcon.icns and bundle into .app"
```

---

### Task 3: 安装并验证图标显示

**Files:**
- 无文件变更

- [ ] **Step 1: 安装到 /Applications**

Run:
```bash
make install
```
Expected: `ditto .build/KimiQuotaBar.app /Applications/KimiQuotaBar.app`

- [ ] **Step 2: 验证 Resources 和 plist**

Run:
```bash
ls -la /Applications/KimiQuotaBar.app/Contents/Resources/AppIcon.icns
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" /Applications/KimiQuotaBar.app/Contents/Info.plist
```
Expected:
- `AppIcon.icns` 存在
- 输出 `AppIcon`

- [ ] **Step 3: 刷新 Finder 图标缓存**

Run:
```bash
touch /Applications/KimiQuotaBar.app
```

- [ ] **Step 4: 在 Finder 中查看**

打开 Finder 的 `/Applications` 文件夹，确认 `KimiQuotaBar.app` 显示 Kimi 圆角矩形图标，而不是默认的通用可执行文件图标。

- [ ] **Step 5: 清理测试进程（如果启动了应用）**

```bash
pkill -f "/Applications/KimiQuotaBar.app" || true
```

- [ ] **Step 6: 提交验证结果**

```bash
git commit --allow-empty -m "test: app icon displays correctly in Finder"
```

---

## Self-Review

**1. Spec coverage：**

| 设计决策 | 对应任务 |
|----------|----------|
| 下载官方圆角 PNG 到 `assets/AppIcon.png` | Task 1 |
| 用 `sips` + `iconutil` 生成 `.icns` | Task 2 |
| 复制 `.icns` 到 `.app/Contents/Resources/` | Task 2 |
| 在 `Info.plist` 声明 `CFBundleIconFile` | Task 2 |
| 重新签名 `.app` | Task 2 |
| 安装并验证 Finder 中显示 | Task 3 |

无遗漏。

**2. Placeholder scan：**

- 无 "TBD"/"TODO"。
- 每个命令都包含预期输出。

**3. Type consistency：**

- `CFBundleIconFile` 值为 `AppIcon`，与 `AppIcon.icns` 文件名一致（macOS 自动匹配 `.icns` 扩展名）。
- `assets/AppIcon.png` 源文件路径在所有步骤中一致。

无不一致。
