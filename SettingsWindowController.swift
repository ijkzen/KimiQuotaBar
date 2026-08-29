import AppKit
import SwiftUI

// MARK: - 通知

extension Notification.Name {
    /// 设置保存后发出，AppDelegate 监听并刷新全部额度
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

/// 配置设置表单：覆盖 ~/.config/kimiquotabar/config.json 中所有可配置字段。
/// 敏感字段（API Key / CookieCloud 密码）默认隐藏，可切换明文显示。
/// 保存后写回配置文件，并通过 NotificationCenter 通知触发额度刷新。
struct SettingsView: View {
    // Kimi
    @State private var kimiAPIKey: String
    @State private var showKimiKey = false

    // OpenCode Go
    @State private var opencodeAPIKey: String
    @State private var showOpencodeKey = false

    // Command Code
    @State private var commandCodeAPIKey: String
    @State private var showCommandCodeKey = false

    // 显示模式
    @State private var quotaProvider: String

    @Environment(\.dismiss) private var dismiss

    init() {
        let config = AppConfig.load()
        _kimiAPIKey = State(initialValue: config?.kimi?.apiKey ?? "")
        _opencodeAPIKey = State(initialValue: config?.opencodeGo?.apiKey ?? "")
        _commandCodeAPIKey = State(initialValue: config?.commandCode?.apiKey ?? "")
        _quotaProvider = State(initialValue: config?.quotaProvider ?? "opencode_go")
    }

    var body: some View {
        Form {
            Section("显示模式") {
                Picker("次要额度区块", selection: $quotaProvider) {
                    Text("OpenCode Go").tag("opencode_go")
                    Text("Command Code").tag("command_code")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("Kimi Code") {
                stackedField(title: "API Key", text: $kimiAPIKey, isSecure: $showKimiKey)
            }

            // 动态显示：只展示当前 quota_provider 对应的区块，切换后即时联动
            if quotaProvider == "opencode_go" {
                Section("OpenCode Go") {
                    stackedField(title: "API Key", text: $opencodeAPIKey, isSecure: $showOpencodeKey)
                }
            } else {
                Section("Command Code") {
                    stackedField(title: "API Key", text: $commandCodeAPIKey, isSecure: $showCommandCodeKey)
                }
            }

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
            .padding(.top, 8)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }

    /// 字段行：标签与编辑栏分两行显示（标签在上、编辑栏在下）
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
    }

    // MARK: 保存

    /// 写回配置文件：仅写入非空字段，opencode_go 整段为空（无 API Key）则省略。
    /// 其余段落在表单中未涉及的字段保持原样不覆盖。
    private func save() {
        var root: [String: Any] = [:]

        if !kimiAPIKey.isEmpty {
            root["kimi"] = ["api_key": kimiAPIKey]
        }

        root["quota_provider"] = quotaProvider

        if !opencodeAPIKey.isEmpty {
            root["opencode_go"] = ["api_key": opencodeAPIKey]
        }

        if !commandCodeAPIKey.isEmpty {
            root["command_code"] = ["api_key": commandCodeAPIKey]
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
