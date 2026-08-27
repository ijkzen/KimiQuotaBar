# KimiQuotaBar

[![Build](https://github.com/ijkzen/KimiQuotaBar/actions/workflows/build.yml/badge.svg)](https://github.com/ijkzen/KimiQuotaBar/actions/workflows/build.yml)

一个 macOS 菜单栏应用，实时显示 **Kimi Code** 的剩余额度，并可选显示 **OpenCode Go** 或 **Command Code** 的额度（二选一，由配置切换）。

以 `LSUIElement`（accessory）模式运行：不占用 Dock，只在系统菜单栏显示一个状态图标和下拉菜单。

## 功能

- 菜单栏图标显示 **KIMI** 与七天额度剩余百分比
- 下拉菜单显示：
  - **Kimi Code**：本周剩余百分比、5 小时滑动窗口剩余百分比、额度重置时间
  - **OpenCode Go**（可选）：5 小时 / 每周 / 每月剩余百分比、重置时间、Zen 余额
  - **Command Code**（可选）：5 小时窗口 / 本周剩余（含重置时间）、本月剩余、本期已用金额、月度额度池、月重置时间
- 每 5 分钟自动刷新，点击菜单栏图标可手动刷新
- 刷新失败时保留旧数据，仅追加一行红点错误提示；OpenCode Go 失败后 3 秒自动重试一次
- 设置窗口：图形化编辑配置文件，保存后自动刷新额度
- 开机自启动（`SMAppService`）
- 单实例运行

## 安装

### 前置要求

- macOS 13.0+
- Swift 5.9+（Xcode 或 Command Line Tools）
- 有效的 Kimi Code API Key
- （可选）OpenCode Go 订阅 + CookieCloud，或 Command Code API Key

### 下载

从 [GitHub Releases](https://github.com/ijkzen/KimiQuotaBar/releases) 下载最新版的 `.dmg`，打开后将应用拖入「应用程序」文件夹。

> 注意：发布包使用临时签名，首次打开时如被 Gatekeeper 拦截，请在「系统设置 → 隐私与安全性」中允许运行。

### 从源码构建

```bash
git clone https://github.com/ijkzen/KimiQuotaBar.git
cd KimiQuotaBar

make build     # 编译
make package   # 打包成 .build/KimiQuotaBar.app
make install   # 安装到 /Applications（可能需要 sudo）
```

## 配置

应用从 `~/.config/kimiquotabar/config.json` 读取配置。**每次刷新都会重读配置文件**，修改后点击菜单中的「立即刷新」即可生效，无需重启应用。

### 最小配置（仅 Kimi Code）

```json
{
  "kimi": {
    "api_key": "your_kimi_api_key"
  }
}
```

API Key 也可通过环境变量 `KIMI_API_KEY` 提供（兜底，优先级低于配置文件）。

### 配置 OpenCode Go（可选）

OpenCode Go 没有公开的额度查询 API，额度数据内嵌在 dashboard 页面的 SSR 数据中，访问需要 `opencode.ai` 的 `auth` cookie（HttpOnly）。应用通过 [CookieCloud](https://github.com/easychen/CookieCloud) 同步获取该 cookie。

1. 在浏览器安装 CookieCloud 插件，连接你的 CookieCloud 服务器并同步 cookie（需已登录 [opencode.ai](https://opencode.ai)）。
2. 从 opencode.ai 的 dashboard URL 中获取工作区 ID（形如 `wrk_...`）。
3. 在 `config.json` 中加入 `opencode_go` 段落：

```json
{
  "kimi": {
    "api_key": "your_kimi_api_key"
  },
  "opencode_go": {
    "workspace_id": "wrk_xxxxxxxxxxxxxxxxxxxxxxxxxx",
    "cookiecloud": {
      "host": "https://your-cookiecloud-server",
      "uuid": "your_uuid",
      "password": "your_password"
    }
  }
}
```

### 配置 Command Code（可选）

Command Code 使用未文档化的 `/alpha/*` 私有 API，需要 Command Code API Key：

```json
{
  "kimi": {
    "api_key": "your_kimi_api_key"
  },
  "command_code": {
    "api_key": "your_command_code_key"
  }
}
```

### 切换次要额度显示

`quota_provider` 顶层字段决定菜单栏中次要额度区块显示哪个提供方：

```json
{
  "quota_provider": "opencode_go"   // 或 "command_code"，默认 "opencode_go"
}
```

配置了对应的 API Key 但未设置 `quota_provider` 时，默认显示 OpenCode Go。

## 使用

1. 运行应用后，菜单栏出现 **KIMI** 与剩余百分比图标
2. 点击图标查看详细额度信息，点击「立即刷新」手动更新
3. 点击「设置」打开设置窗口，可编辑全部配置字段（API Key 等敏感字段默认掩码，可切换明文）；保存后自动刷新额度
4. 点击「开机自启动」注册登录项（系统会弹出授权确认）
5. 点击「退出」关闭应用

## 额度说明

**Kimi Code** 使用两种额度限制：

- **7 天周期额度**：每周可用的总请求次数
- **5 小时滑动窗口**：每 5 小时内可用的请求次数

状态栏图标始终显示 **7 天周期额度** 的剩余百分比，不随 `quota_provider` 切换改变。

## 故障排除

### 显示「未找到 API Key」

确保已在 `~/.config/kimiquotabar/config.json` 中配置 `kimi.api_key`，或设置环境变量 `KIMI_API_KEY`。

### 显示「Invalid Authentication」

Kimi API Key 已过期或无效，请检查并更新。

### 显示「解析失败」

API 响应结构偶尔会变化。应用已尽量将非必要字段设为可选，若仍出现解析错误，请点击「立即刷新」或重启应用。点击红点错误行可查看完整错误详情。

### OpenCode Go 一直显示失败

- 确认 CookieCloud 服务器可达，且浏览器端已同步最新 cookie
- 确认 `workspace_id` 正确
- CookieCloud 请求为直连模式，不经过系统代理；如服务器在局域网内请确认网络互通

## 隐私与安全

- API Key 只保存在你的 `~/.config/kimiquotabar/config.json`（明文）或环境变量中，应用不会将其写入 Bundle 或上传到任何地方。
- 请保护该配置文件的权限（建议 `chmod 600`），其中包含 CookieCloud 凭据，可解密出同步的所有 cookie。
- 网络请求只发送给：`api.kimi.com`、你配置的 CookieCloud 服务器、`opencode.ai`、`api.commandcode.ai`。

## 技术栈

- Swift 5.9
- SwiftUI + AppKit（`NSStatusBar`）
- Swift Package Manager
- GitHub Actions（构建 + 发版）

## 贡献

欢迎提交 Issue 和 Pull Request，请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
