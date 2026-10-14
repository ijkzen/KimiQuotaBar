import AppKit
import SwiftUI

// MARK: - 通知

extension Notification.Name {
    /// 设置保存后发出，AppDelegate 监听并刷新用量
    static let configDidSave = Notification.Name("KimiQuotaBarConfigDidSave")
}

// MARK: - 设置窗口控制器

/// 设置窗口的单一入口：复用同一个 NSWindow，重复打开只前置不新建。
/// 菜单栏 app 没有标准菜单命令，SwiftUI Settings scene 的 showSettingsWindow:
/// 在 accessory 模式下不可靠，因此手动用 NSWindow + NSHostingView 承载表单。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    /// 打开设置窗口（已存在则前置并聚焦）
    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView())
        let contentSize = hosting.fittingSize

        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "设置"
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = hosting
        newWindow.setContentSize(contentSize)
        newWindow.center()
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 设置表单

/// 配置设置表单：llm-gateway 是唯一信息源，表单即 gateway 段（网关地址 / API Key /
/// 供应商选择最多三个 / 状态栏数字）。API Key 默认隐藏，可切换明文显示。
/// 布局：固定尺寸窗口（不滚动）；上部字段固定，中部供应商列表占满横向、
/// 固定高度且仅此处可滚动，底部操作按钮由 Spacer 顶到窗口底部固定。
/// 保存后写回配置文件，并通过 NotificationCenter 通知触发用量刷新。
struct SettingsView: View {
    // LLM Gateway
    @State private var gatewayURL: String
    @State private var gatewayAPIKey: String
    @State private var showGatewayKey = false
    @State private var gatewayProviderIds: [Int]
    @State private var gatewayProviders: [GatewayProvider] = []
    @State private var gatewayListLoading = false
    @State private var gatewayListStatus: String?

    // 状态栏数字（providerId = 0 表示自动）
    @State private var statusBarProviderId: Int
    @State private var statusBarWindow: String
    /// 所选供应商实际可用的窗口值列表（拉取该供应商用量后填充；空 = 显示静态全集）
    @State private var statusBarWindowData: [String] = []

    @Environment(\.dismiss) private var dismiss

    init() {
        let config = AppConfig.load()
        _gatewayURL = State(initialValue: config?.gateway?.url ?? "")
        _gatewayAPIKey = State(initialValue: config?.gateway?.apiKey ?? "")
        _gatewayProviderIds = State(initialValue: Array((config?.gateway?.providerIds ?? []).prefix(3)))
        _statusBarProviderId = State(initialValue: config?.gateway?.statusBar?.providerId ?? 0)
        _statusBarWindow = State(initialValue: config?.gateway?.statusBar?.window ?? "auto")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LLM Gateway（供应商用量）")
                .font(.headline)

            stackedField(title: "网关地址", text: $gatewayURL)
            stackedField(title: "API Key", text: $gatewayAPIKey, isSecure: $showGatewayKey)

            HStack(spacing: 8) {
                Button(gatewayListLoading ? "加载中…" : "加载供应商列表") {
                    loadGatewayProviders()
                }
                .disabled(gatewayListLoading || gatewayURL.isEmpty || gatewayAPIKey.isEmpty)
                if let gatewayListStatus {
                    Text(gatewayListStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            // 供应商列表：占满横向、固定高度，内容超出时仅此处滚动
            VStack(alignment: .leading, spacing: 4) {
                Text("展示供应商（最多 3 个）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ZStack {
                    if gatewayProviders.isEmpty {
                        Text(gatewayListLoading ? "加载中…" : "点「加载供应商列表」选择要展示的供应商")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(gatewayProviders, id: \.id) { provider in
                                    Toggle(isOn: providerSelectionBinding(provider)) {
                                        Text(providerToggleTitle(provider))
                                    }
                                    .disabled(!provider.usageSupported || !gatewayProviderIds.contains(provider.id) && gatewayProviderIds.count >= 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 菜单栏数字：先选供应商（下拉列出已勾选的供应商），
            // 再选该供应商的窗口（拉取其用量后按实际可用窗口填充；按量供应商为「主余额」）
            VStack(alignment: .leading, spacing: 4) {
                Text("菜单栏数字")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Picker("供应商", selection: $statusBarProviderId) {
                        Text("自动").tag(0)
                        ForEach(gatewayProviderIds, id: \.self) { id in
                            Text(providerDisplayName(id)).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Picker("窗口", selection: $statusBarWindow) {
                        ForEach(statusBarWindowOptionsForSelection, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(statusBarProviderId == 0)
                    Spacer()
                }
                Text("「自动」= 第一个有可用窗口的已选供应商的最大窗口（月 > 周 > 日 > 5 小时）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            // 底部操作按钮：固定位置，不参与任何滚动
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    save()
                    NotificationCenter.default.post(name: .configDidSave, object: nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        // 固定尺寸：fittingSize 恒定，底部按钮位置不随内容变化
        .frame(width: 460, height: 560)
        // 地址或 Key 变化后已加载的列表即失效，需重新加载
        .onChange(of: gatewayURL) { _ in resetGatewayProviderList() }
        .onChange(of: gatewayAPIKey) { _ in resetGatewayProviderList() }
        .onChange(of: statusBarProviderId) { newValue in
            statusBarWindowData = []
            if newValue == 0 {
                statusBarWindow = "auto"
            } else {
                loadStatusBarWindows(providerId: newValue)
            }
        }
        .onAppear {
            // 地址与 Key 齐备时自动加载供应商列表（名称解析 + 勾选态展示）
            if gatewayProviders.isEmpty, !gatewayURL.isEmpty, !gatewayAPIKey.isEmpty {
                loadGatewayProviders()
            }
            if statusBarProviderId != 0 {
                loadStatusBarWindows(providerId: statusBarProviderId)
            }
        }
    }

    /// 字段行：标签与编辑栏分两行显示（标签在上、编辑栏在下），整行左对齐
    @ViewBuilder
    private func stackedField(title: String, text: Binding<String>, isSecure: Binding<Bool>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                if let isSecure = isSecure {
                    if isSecure.wrappedValue {
                        TextField(title, text: text)
                    } else {
                        SecureField(title, text: text)
                    }
                    Button {
                        isSecure.wrappedValue.toggle()
                    } label: {
                        Image(systemName: isSecure.wrappedValue ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isSecure.wrappedValue ? "显示明文" : "隐藏明文")
                } else {
                    TextField(title, text: text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: LLM Gateway 供应商列表

    /// 地址/Key 变动后清空已加载列表与状态，避免用过期列表保存
    private func resetGatewayProviderList() {
        gatewayProviders = []
        gatewayListStatus = nil
    }

    private func loadGatewayProviders() {
        gatewayListLoading = true
        gatewayListStatus = nil
        let base = gatewayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiKey = gatewayAPIKey
        GatewayManager.fetchProviders(base: base, apiKey: apiKey) { result in
            DispatchQueue.main.async {
                gatewayListLoading = false
                switch result {
                case .success(let providers):
                    gatewayProviders = providers
                    gatewayListStatus = providers.isEmpty ? "网关内暂无供应商" : nil
                case .failure(let error):
                    gatewayProviders = []
                    gatewayListStatus = error.message
                }
            }
        }
    }

    /// 供应商显示名：列表已加载用真实名称，否则回退「Provider <id>」
    private func providerDisplayName(_ id: Int) -> String {
        gatewayProviders.first { $0.id == id }?.name ?? "Provider \(id)"
    }

    private func providerToggleTitle(_ provider: GatewayProvider) -> String {
        provider.usageSupported ? provider.name : "\(provider.name) · 不支持用量查询"
    }

    /// 勾选绑定：保持勾选顺序，最多三个（超出时其余选项已禁用，双保险）
    private func providerSelectionBinding(_ provider: GatewayProvider) -> Binding<Bool> {
        Binding(
            get: { gatewayProviderIds.contains(provider.id) },
            set: { selected in
                if selected {
                    if !gatewayProviderIds.contains(provider.id), gatewayProviderIds.count < 3 {
                        gatewayProviderIds.append(provider.id)
                    }
                } else {
                    gatewayProviderIds.removeAll { $0 == provider.id }
                    // 被取消勾选的供应商不再作为状态栏数字来源
                    if statusBarProviderId == provider.id {
                        statusBarProviderId = 0
                        statusBarWindow = "auto"
                    }
                }
            }
        )
    }

    // MARK: 状态栏数字

    /// 窗口下拉选项：已拉到该供应商用量时按实际可用窗口填充，否则给静态全集
    private var statusBarWindowOptionsForSelection: [(value: String, label: String)] {
        if !statusBarWindowData.isEmpty {
            return [("auto", "自动")] + statusBarWindowData.map { ($0, Self.windowDisplayName($0)) }
        }
        return Self.statusBarWindowOptions
    }

    /// 静态全集（未拉到实际窗口时的兜底）
    private static let statusBarWindowOptions: [(value: String, label: String)] = [
        ("auto", "自动"),
        ("five_hour", "5 小时"),
        ("daily", "今日"),
        ("weekly", "本周"),
        ("monthly", "本月"),
        ("balance", "主余额")
    ]

    private static func windowDisplayName(_ value: String) -> String {
        switch value {
        case "five_hour": return "5 小时"
        case "daily": return "今日"
        case "weekly": return "本周"
        case "monthly": return "本月"
        case "balance": return "主余额"
        default: return value
        }
    }

    /// 拉取所选供应商的用量（走网关缓存），用实际可用窗口填充窗口下拉
    private func loadStatusBarWindows(providerId: Int) {
        let base = gatewayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiKey = gatewayAPIKey
        guard !base.isEmpty, !apiKey.isEmpty else { return }
        GatewayManager.fetchUsage(base: base, apiKey: apiKey, id: providerId, force: false) { result in
            DispatchQueue.main.async {
                guard statusBarProviderId == providerId else { return }
                guard case .success(let usage) = result else { return }
                if usage.kind == "balance" {
                    statusBarWindowData = ["balance"]
                } else {
                    statusBarWindowData = (usage.windows ?? [])
                        .filter { $0.available }
                        .map { $0.window }
                }
                // 当前选中的窗口在新列表中不存在时回退「自动」
                if statusBarWindow != "auto", !statusBarWindowData.contains(statusBarWindow) {
                    statusBarWindow = "auto"
                }
            }
        }
    }

    // MARK: 保存

    /// 写回配置文件：地址与 Key 齐备才保留 gateway 段；供应商选择最多保存三个；
    /// 状态栏数字为「自动」或供应商未勾选时不写 status_bar。
    /// 历史信息源字段（kimi/opencode_go/command_code/quota_provider）在保存时清除。
    private func save() {
        // 合并已有文件，避免丢掉表单未覆盖的字段
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: AppConfig.filePath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        // 已删除的直连信息源字段不再保留
        for legacyKey in ["kimi", "opencode_go", "command_code", "quota_provider"] {
            root.removeValue(forKey: legacyKey)
        }

        let trimmedURL = gatewayURL.trimmingCharacters(in: .whitespaces)
        if !trimmedURL.isEmpty, !gatewayAPIKey.isEmpty {
            var gateway: [String: Any] = [
                "url": trimmedURL,
                "api_key": gatewayAPIKey,
                "provider_ids": Array(gatewayProviderIds.prefix(3))
            ]
            if statusBarProviderId != 0, gatewayProviderIds.contains(statusBarProviderId) {
                gateway["status_bar"] = [
                    "provider_id": statusBarProviderId,
                    "window": statusBarWindow
                ]
            }
            root["gateway"] = gateway
        } else {
            root.removeValue(forKey: "gateway")
        }

        let fileURL = URL(fileURLWithPath: AppConfig.filePath)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("设置保存失败: \(error.localizedDescription)")
        }
    }
}
