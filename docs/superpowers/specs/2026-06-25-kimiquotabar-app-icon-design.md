# KimiQuotaBar 应用图标设计

## 背景

KimiQuotaBar 是一个 macOS 菜单栏应用。当前 `.app` Bundle 没有自定义图标，在 Finder 的 `/Applications` 文件夹、Dock（如强制显示）以及「关于本应用」窗口中都会显示默认的通用可执行文件图标。为了提升识别度和视觉一致性，需要为应用添加一个自定义图标。

## 设计决策

### 图标来源

使用 Kimi 官方品牌指南（https://moonshotai.github.io/Branding-Guide/）中提供的「Rounded Corner Icon」作为应用图标。该图标是 Kimi 官方 App 风格图标，与品牌一致，且符合 macOS 应用图标的圆角矩形惯例。

图标源文件 URL：
```
https://kimi-web-img.moonshot.cn/prod-data/online-image/search-upload/e7271e9f5bf57036fef6953a9893ff68.png
```

### 实现方案

采用标准 macOS `.icns` 图标格式：

1. 将官方圆角 PNG 下载到项目 `assets/AppIcon.png`。
2. 在 `make package` 时：
   - 创建临时 `.iconset` 目录
   - 使用 `sips` 从源 PNG 生成 macOS 所需的全部尺寸：
     - 16x16, 16x16@2x
     - 32x32, 32x32@2x
     - 128x128, 128x128@2x
     - 256x256, 256x256@2x
     - 512x512, 512x512@2x
   - 使用 `iconutil -c icns` 生成 `AppIcon.icns`
   - 将 `AppIcon.icns` 复制到 `.build/KimiQuotaBar.app/Contents/Resources/`
3. 在 `Info.plist` 中添加 `CFBundleIconFile` 键，值为 `AppIcon`。
4. 重新签名 `.app` Bundle。

### 文件变更

| 文件 | 变更 |
|------|------|
| `assets/AppIcon.png` | 新增：存放 Kimi 官方圆角图标源文件 |
| `Makefile` | 修改：`package` 目标新增生成 `.icns` 并复制到 Resources 的步骤 |
| `Package.swift` | 修改：将 `"assets"` 加入 `exclude`，避免 Swift 构建报警 |

### 验收标准

- `make package` 成功生成 `.app` Bundle。
- `.app/Contents/Resources/AppIcon.icns` 存在。
- `Info.plist` 包含 `CFBundleIconFile` 且值为 `AppIcon`。
- 在 Finder 中查看 `/Applications/KimiQuotaBar.app` 显示 Kimi 图标而不是通用图标。
