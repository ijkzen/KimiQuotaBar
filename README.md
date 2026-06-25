# KimiQuotaBar

一个 macOS 菜单栏应用，实时显示 Kimi Code API 的剩余额度。

## 功能

- 菜单栏显示 **KIMI** 与七天额度剩余百分比
- 下拉菜单显示：
  - 本周剩余百分比
  - 5 小时滑动窗口剩余百分比
  - 额度重置时间
- 每 5 分钟自动刷新
- 点击菜单栏图标可手动刷新
- 开机自启动
- 单实例运行

## 安装

### 前置要求

- macOS 13.0+
- Swift 5.9+
- 有效的 Kimi Code API Key

### 配置 API Key

应用会自动从以下位置读取 API Key：

1. 环境变量 `KIMI_API_KEY`
2. `~/.hermes/.env` 文件中的 `KIMI_API_KEY=your_key_here`

### 构建和运行

```bash
# 克隆项目
git clone https://github.com/ijkzen/KimiQuotaBar.git
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

### 作为 Agent 应用运行

为了不在 Dock 中显示图标，应用已经配置为 Agent 模式。运行时会自动隐藏在菜单栏。

## 使用

1. 运行应用后，菜单栏会出现 **KIMI** 与剩余百分比
2. 点击图标查看详细额度信息
3. 点击「立即刷新」手动更新
4. 点击「退出」关闭应用

## 额度说明

Kimi Code 使用两种额度限制：

- **7 天周期额度**：每周可用的总请求次数
- **5 小时滑动窗口**：每 5 小时内可用的请求次数

状态栏始终显示 **7 天周期额度** 的剩余百分比。菜单中会分别显示两者百分比。

## 故障排除

### 显示 "未找到 KIMI_API_KEY"

确保已设置 API Key：
```bash
export KIMI_API_KEY="your_api_key_here"
```

或创建 `~/.hermes/.env` 文件：
```
KIMI_API_KEY=your_api_key_here
```

### 显示 "Invalid Authentication"

API Key 可能已过期或无效，请检查并更新。

### 显示 "解析失败"

API 响应结构偶尔会发生变化。应用已尽量将非必要字段设为可选，若仍出现解析错误，请尝试点击「立即刷新」或重启应用。

## 技术栈

- Swift 5.9
- SwiftUI
- AppKit (NSStatusBar)

## 许可证

MIT
