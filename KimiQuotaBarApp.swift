import SwiftUI

@main
struct KimiQuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @MainActor
    init() {
        // 设置为 accessory 模式，不在 Dock 中显示图标
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var quotaManager: QuotaManager!
    var timer: Timer?

    private let launchManager = LaunchAtLoginManager.shared
    private var launchAtLoginError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例检测：若已有实例运行，激活旧实例并退出
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ijkzen.KimiQuotaBar"
        let otherApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if let other = otherApps.first {
            other.activate(options: .activateIgnoringOtherApps)
            NSApplication.shared.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏳"

        quotaManager = QuotaManager()
        quotaManager.onUpdate = { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateMenu()
            }
        }

        // 首次加载
        quotaManager.refresh()

        // 每5分钟自动刷新
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.quotaManager.refresh()
            }
        }
    }

    func updateMenu() {
        let menu = NSMenu()

        // 标题
        let titleItem = NSMenuItem(title: "Kimi Code 额度", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        if let error = quotaManager.lastError {
            let errorItem = NSMenuItem(title: "⚠️ \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

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

        if let data = quotaManager.quotaData {
            // 状态栏只显示七天额度剩余百分比
            let sevenDayPercent = percentageString(remaining: data.usage.remaining, limit: data.usage.limit)

            // 本周剩余
            let totalItem = NSMenuItem(
                title: "本周剩余: \(sevenDayPercent)",
                action: nil,
                keyEquivalent: ""
            )
            totalItem.isEnabled = false
            menu.addItem(totalItem)

            // 5小时窗口
            let windowLimitInfo = data.limits.first?.detail
            let windowPercent = percentageString(remaining: windowLimitInfo?.remaining ?? "0", limit: windowLimitInfo?.limit ?? "0")
            let windowItem = NSMenuItem(
                title: "5h窗口: \(windowPercent)",
                action: nil,
                keyEquivalent: ""
            )
            windowItem.isEnabled = false
            menu.addItem(windowItem)

            // 重置时间
            let resetItem = NSMenuItem(
                title: "重置: \(formatResetTime(data.usage.resetTime))",
                action: nil,
                keyEquivalent: ""
            )
            resetItem.isEnabled = false
            menu.addItem(resetItem)

            menu.addItem(NSMenuItem.separator())

            // 更新状态栏标题
            updateStatusBar(weeklyPercent: sevenDayPercent)
        } else {
            updateStatusBar(weeklyPercent: nil)
        }

        // 刷新按钮
        let refreshItem = NSMenuItem(
            title: "立即刷新",
            action: #selector(refreshClicked),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func refreshClicked() {
        quotaManager.refresh()
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLoginError = launchManager.toggle()
        updateMenu()
    }

    @objc func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    func formatResetTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let output = DateFormatter()
            output.dateFormat = "MM-dd HH:mm"
            output.timeZone = TimeZone.current
            return output.string(from: date)
        }
        return isoString
    }

    func percentageString(remaining: String, limit: String) -> String {
        let r = Double(remaining) ?? 0
        let l = Double(limit) ?? 0
        guard l > 0 else { return "0%" }
        return "\(Int((r / l) * 100))%"
    }

    func updateStatusBar(weeklyPercent: String?) {
        let size = NSSize(width: 34, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let kimiText = "KIMI" as NSString
        let percentText = (weeklyPercent ?? "--%") as NSString

        let headerFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let percentFont = NSFont.systemFont(ofSize: 10, weight: .bold)

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.controlTextColor
        ]
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: percentFont,
            .foregroundColor: NSColor.controlTextColor
        ]

        let headerSize = kimiText.size(withAttributes: headerAttrs)
        let percentSize = percentText.size(withAttributes: percentAttrs)

        let totalHeight = headerSize.height + percentSize.height - 1
        let startY = (size.height - totalHeight) / 2

        let headerRect = NSRect(
            x: (size.width - headerSize.width) / 2,
            y: startY + percentSize.height - 1,
            width: headerSize.width,
            height: headerSize.height
        )
        let percentRect = NSRect(
            x: (size.width - percentSize.width) / 2,
            y: startY,
            width: percentSize.width,
            height: percentSize.height
        )

        kimiText.draw(in: headerRect, withAttributes: headerAttrs)
        percentText.draw(in: percentRect, withAttributes: percentAttrs)

        image.unlockFocus()

        let button = statusItem.button
        button?.image = image
        button?.imagePosition = .imageOnly
        button?.title = ""
        button?.attributedTitle = NSAttributedString(string: "")
        statusItem.length = 34
    }
}