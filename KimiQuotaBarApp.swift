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
    var openCodeGoManager: OpenCodeGoManager!
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

        openCodeGoManager = OpenCodeGoManager()
        openCodeGoManager.onUpdate = { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateMenu()
            }
        }

        // 首次加载
        quotaManager.refresh()
        openCodeGoManager.refresh()

        // 每5分钟自动刷新
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.quotaManager.refresh()
                self?.openCodeGoManager.refresh()
            }
        }
    }

    func updateMenu() {
        let menu = NSMenu()

        // 开机自启动（置顶，使用原生勾选样式）
        let loginItem = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // 登录项设置错误
        if let launchAtLoginError = launchAtLoginError {
            addInfoItem(menu: menu, text: "⚠️ \(launchAtLoginError)")
        }

        menu.addItem(NSMenuItem.separator())

        // Kimi Code 额度区块：标题贴合额度详情
        addInfoItem(menu: menu, text: "Kimi Code 额度")

        if let error = quotaManager.lastError {
            addInfoItem(menu: menu, text: "⚠️ \(error)")
        }

        if let data = quotaManager.quotaData {
            // 状态栏只显示七天额度剩余百分比
            let sevenDayPercent = percentageString(remaining: data.usage.remaining ?? "0", limit: data.usage.limit)

            // 本周剩余
            addQuotaBar(
                menu: menu,
                label: "本周剩余",
                percent: remainingPercent(remaining: data.usage.remaining ?? "0", limit: data.usage.limit)
            )

            // 5小时窗口
            let windowLimitInfo = data.limits.first?.detail
            addQuotaBar(
                menu: menu,
                label: "5h窗口",
                percent: remainingPercent(remaining: windowLimitInfo?.remaining ?? "0", limit: windowLimitInfo?.limit ?? "0")
            )

            // 重置时间
            addInfoItem(menu: menu, text: "重置: \(formatResetTime(data.usage.resetTime))", fontSize: MenuRowLayout.smallFontSize)

            // 更新状态栏标题
            updateStatusBar(weeklyPercent: sevenDayPercent)
        } else {
            updateStatusBar(weeklyPercent: nil)
        }

        // OpenCode Go 区块（仅在配置了 ~/.config/kimiquotabar/config.json 时显示）
        if openCodeGoManager.isConfigured {
            menu.addItem(NSMenuItem.separator())

            addInfoItem(menu: menu, text: "OpenCode Go 额度")

            if let error = openCodeGoManager.lastError {
                // 刷新失败时保留旧数据展示，仅追加一行错误提示
                addInfoItem(menu: menu, text: "⚠️ \(error)")
            }
            for (label, window) in [
                ("5h窗口", openCodeGoManager.rollingUsage),
                ("本周剩余", openCodeGoManager.weeklyUsage),
                ("本月剩余", openCodeGoManager.monthlyUsage)
            ] {
                guard let window = window else { continue }
                addQuotaBar(menu: menu, label: label, percent: window.remainingPercent)
            }

            // 5 小时窗口的重置倒计时最短，最有参考价值
            if let rolling = openCodeGoManager.rollingUsage {
                addInfoItem(menu: menu, text: "重置: \(formatDate(rolling.resetDate))", fontSize: MenuRowLayout.smallFontSize)
            }

            if let balance = openCodeGoManager.billing?.balanceUSD {
                addInfoItem(menu: menu, text: String(format: "Zen 余额: $%.2f", balance), fontSize: MenuRowLayout.smallFontSize)
            }
        }

        menu.addItem(NSMenuItem.separator())

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
        openCodeGoManager.refresh()
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
            return formatDate(date)
        }
        return isoString
    }

    func formatDate(_ date: Date) -> String {
        let output = DateFormatter()
        output.dateFormat = "MM-dd HH:mm"
        output.timeZone = TimeZone.current
        return output.string(from: date)
    }

    func percentageString(remaining: String, limit: String) -> String {
        "\(remainingPercent(remaining: remaining, limit: limit))%"
    }

    func remainingPercent(remaining: String, limit: String) -> Int {
        let r = Double(remaining) ?? 0
        let l = Double(limit) ?? 0
        guard l > 0 else { return 0 }
        return Int((r / l) * 100)
    }

    /// 添加一行「标签 + 进度条 + 百分比数字」的额度展示
    private func addQuotaBar(menu: NSMenu, label: String, percent: Int) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = QuotaBarView(label: label, percent: percent)
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 添加一行纯文本信息（区块标题、重置时间、余额、错误提示）。
    /// 使用自定义视图以收窄左右边距（原生 NSMenuItem 缩进是系统固定的）
    private func addInfoItem(menu: NSMenu, text: String, fontSize: CGFloat = MenuRowLayout.fontSize) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = MenuInfoView(text: text, fontSize: fontSize)
        item.isEnabled = false
        menu.addItem(item)
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

// MARK: - Menu Row Layout

/// 菜单信息行的统一排版：收窄的左右边距与基准宽度。
/// 原生 NSMenuItem 的缩进（约 22pt）由系统固定，信息行改用自定义视图自行控制边距
enum MenuRowLayout {
    static let inset: CGFloat = 12
    static let width: CGFloat = 240
    static let height: CGFloat = 22
    /// 默认文本大小（区块标题、错误提示）
    static let fontSize: CGFloat = 14
    /// 弱化文本大小（额度行标签、重置时间、余额）
    static let smallFontSize: CGFloat = 12
}

// MARK: - Menu Info View

/// 菜单中的纯文本信息行（区块标题、重置时间、余额、错误提示）。
/// 宽度随文本自适应（长文本如错误提示会相应撑宽菜单）
class MenuInfoView: NSView {
    private let text: String
    private let textAttributes: [NSAttributedString.Key: Any]

    init(text: String, fontSize: CGFloat) {
        self.text = text
        self.textAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.disabledControlTextColor
        ]
        let size = (text as NSString).size(withAttributes: textAttributes)
        let width = max(MenuRowLayout.width, ceil(size.width) + MenuRowLayout.inset * 2)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: MenuRowLayout.height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = (text as NSString).size(withAttributes: textAttributes)
        (text as NSString).draw(
            at: NSPoint(x: MenuRowLayout.inset, y: (bounds.height - size.height) / 2),
            withAttributes: textAttributes
        )
    }
}

// MARK: - Quota Bar View

/// 菜单中的额度行视图：标签 + 进度条 + 百分比数字
/// 剩余 ≤10% 显示红色，否则显示绿色。
/// 边距与 MenuInfoView 信息行一致（MenuRowLayout）
class QuotaBarView: NSView {
    private let label: String
    private let percent: Int

    /// 与信息行的左边距一致
    private let leadingInset: CGFloat = MenuRowLayout.inset
    /// 与信息行的右边距一致
    private let trailingInset: CGFloat = MenuRowLayout.inset
    /// 标签列固定宽度，保证各行进度条左对齐
    private let labelColumnWidth: CGFloat = 56

    init(label: String, percent: Int) {
        self.label = label
        self.percent = max(0, min(100, percent))
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRowLayout.width, height: 22))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let barColor = percent <= 10 ? NSColor.systemRed : NSColor.systemGreen

        // 左侧标签：比原生菜单项小一号，弱化标签、突出进度条与数字
        let labelFont = NSFont.systemFont(ofSize: MenuRowLayout.smallFontSize)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.disabledControlTextColor
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(
            at: NSPoint(x: leadingInset, y: (bounds.height - labelSize.height) / 2),
            withAttributes: labelAttrs
        )

        // 右侧百分比数字：等宽数字防止抖动，与进度条同色
        let percentText = "\(percent)%" as NSString
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: barColor
        ]
        let percentSize = percentText.size(withAttributes: percentAttrs)
        let percentRect = NSRect(
            x: bounds.width - trailingInset - percentSize.width,
            y: (bounds.height - percentSize.height) / 2,
            width: percentSize.width,
            height: percentSize.height
        )
        percentText.draw(in: percentRect, withAttributes: percentAttrs)

        // 中间进度条
        let barX = leadingInset + labelColumnWidth
        let barWidth = percentRect.minX - barX - 10
        guard barWidth > 0 else { return }
        let barHeight: CGFloat = 5
        let barY = (bounds.height - barHeight) / 2
        let trackRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        if percent > 0 {
            let fillRect = NSRect(
                x: barX,
                y: barY,
                width: barWidth * CGFloat(percent) / 100,
                height: barHeight
            )
            barColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
    }
}