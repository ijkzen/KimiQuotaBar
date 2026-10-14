# KimiQuotaBar

[![Build](https://github.com/ijkzen/KimiQuotaBar/actions/workflows/build.yml/badge.svg)](https://github.com/ijkzen/KimiQuotaBar/actions/workflows/build.yml)

一个 macOS 菜单栏应用，通过自托管的 [llm-gateway](https://github.com/ijkzen/llm-gateway) 实时显示 LLM 供应商的用量信息（订阅窗口 / 按量余额），展示样式与网关网页的用量卡片一致。

以 `LSUIElement`（accessory）模式运行：不占用 Dock，只在系统菜单栏显示一个状态图标和下拉菜单。

## 功能

- 菜单栏图标显示供应商名与剩余百分比/余额（只保留一位小数；默认取第一个有可展示订阅窗口的已选供应商的最大窗口，可在设置中指定供应商 + 窗口/主余额）
- 下拉菜单按供应商分区块展示（最多三个，可配置）：
  - **订阅制**：逐窗口进度条（占满菜单剩余宽度；剩余百分比，>50% 绿 / >20% 黄 / ≤20% 红）、已用/总量与窗口重置时间各占一行（重置时间按网关时区渲染）
  - **按量付费**：逐条余额（label + 金额 + 币种）
  - 区块标题右侧显示用量更新时间（不单独占行）
- 每 5 分钟自动刷新（走网关 10 分钟用量缓存），「立即刷新」强制网关回源抓取
- 刷新失败时保留旧数据，仅追加一行红点错误提示（点击查看详情）
- 设置窗口：图形化填写网关地址与 API Key，在线加载供应商列表并勾选（最多三个），保存后自动刷新；字段固定、供应商列表单独滚动、底部操作按钮固定
- 开机自启动（`SMAppService`）
- 单实例运行

## 安装

### 前置要求

- macOS 13.0+
- Swift 5.9+（Xcode 或 Command Line Tools）
- 一个可访问的 llm-gateway 实例及其 `lg-` API Key

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

```json
{
  "gateway": {
    "url": "https://gateway.ijkzen.cn",
    "api_key": "lg-your_gateway_api_key",
    "provider_ids": [1, 2, 3],
    "status_bar": {
      "provider_id": 1,
      "window": "weekly"
    }
  }
}
```

- `url`：网关地址（不含尾斜杠）。
- `api_key`：网关管理后台「API Keys」页生成的 `lg-` 密钥（与 `/v1/chat/completions` 转发同一套）。
- `provider_ids`：要展示的供应商 ID 列表，最多三个；ID 可在网关管理后台供应商列表查看，或通过 `GET /v1/providers` 查询。
- `status_bar`（可选）：菜单栏图标显示的数字来源。`provider_id` 指定供应商；`window` 可选 `five_hour`（5 小时）/ `daily`（今日）/ `weekly`（本周）/ `monthly`（本月）/ `balance`（按量供应商的主余额）/ `auto`（自动，缺省值）。不写 `status_bar` 即全自动：取第一个有可用窗口的已选供应商的最大窗口。

推荐在「设置」窗口中完成配置：填写网关地址与 API Key 后点「加载供应商列表」，勾选要展示的供应商（最多三个）并保存。

## 使用

1. 运行应用后，菜单栏出现供应商名与剩余百分比图标
2. 点击图标查看各供应商用量详情，点击「立即刷新」强制更新
3. 点击「设置」打开设置窗口（API Key 默认掩码，可切换明文）；保存后自动刷新
4. 点击「开机自启动」注册登录项（系统会弹出授权确认）
5. 点击「退出」关闭应用

## 故障排除

### 菜单显示「未配置 llm-gateway」

在「设置」中填写网关地址与 API Key 并勾选至少一个供应商，或直接在 `~/.config/kimiquotabar/config.json` 中配置 `gateway` 段。

### 显示「API Key 无效或已过期」

网关返回 401：检查 `gateway.api_key` 是否为网关管理后台中已启用的 `lg-` 密钥。

### 显示「解析失败」/「服务端错误」

点击菜单中的红点错误行可查看完整错误详情；常见原因是网关版本过旧（无 `/v1/providers*` 接口）或网络不可达，请升级网关并确认地址可访问。

## 隐私与安全

- API Key 只保存在你的 `~/.config/kimiquotabar/config.json`（明文），应用不会将其写入 Bundle 或上传到任何地方。
- 请保护该配置文件的权限（建议 `chmod 600`）。
- 网络请求只发送给配置中的网关地址（`/v1/providers` 与 `/v1/providers/{id}/usage`），附带 `Authorization: Bearer <api_key>`。

## 技术栈

- Swift 5.9
- SwiftUI + AppKit（`NSStatusBar`）
- Swift Package Manager
- GitHub Actions（构建 + 发版）

## 贡献

欢迎提交 Issue 和 Pull Request，请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
