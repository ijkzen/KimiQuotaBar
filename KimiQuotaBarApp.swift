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
    var gatewayManager: GatewayManager!
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

        gatewayManager = GatewayManager()
        gatewayManager.onUpdate = { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateMenu()
            }
        }

        // 先构建一次菜单：未配置网关时 refresh() 静默返回、不会触发 onUpdate，
        // 若不在此赋值 statusItem.menu，图标点击无任何反应
        updateMenu()

        // 首次加载
        gatewayManager.refresh()

        // 设置保存后自动刷新
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidSave(_:)),
            name: .configDidSave,
            object: nil
        )

        // 每5分钟自动刷新
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.gatewayManager.refresh()
            }
        }

        // 调试钩子：KQB_OPEN_SETTINGS=1 启动后自动打开设置窗口（供 UI 自动化验证）
        if ProcessInfo.processInfo.environment["KQB_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SettingsWindowController.shared.show()
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
            addErrorRow(
                menu: menu,
                title: "开机自启动设置失败",
                label: "设置失败 · 点击查看详情",
                message: launchAtLoginError
            )
        }

        menu.addItem(NSMenuItem.separator())

        // llm-gateway 供应商用量区块（唯一数据源，最多两个，由 config.json 的
        // gateway.provider_ids 控制）；未配置时给出去向提示
        if gatewayManager.isConfigured {
            addGatewaySections(menu: menu)
        } else {
            addInfoItem(menu: menu, text: "未配置 llm-gateway，请在「设置」中填写")
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

        // 设置（独立窗口，保存后自动刷新额度）
        let settingsItem = NSMenuItem(
            title: "设置",
            action: #selector(settingsClicked),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 退出
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        updateStatusBar()
    }

    @objc func settingsClicked() {
        // 手动打开设置窗口（accessory 模式下 SwiftUI Settings scene 不可靠）
        SettingsWindowController.shared.show()
    }

    /// 设置保存后自动刷新用量，菜单与状态栏同步更新
    @objc private func configDidSave(_ notification: Notification) {
        gatewayManager.refresh()
        // 供应商选择可能变化，立即重建菜单
        updateMenu()
    }

    @objc func refreshClicked() {
        // 手动刷新绕过网关 10 分钟缓存，强制回源
        gatewayManager.refresh(force: true)
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLoginError = launchManager.toggle()
        updateMenu()
    }

    @objc func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// llm-gateway 区块：按配置展示已选供应商的用量（数据形态与网关网页用量卡一致）
    private func addGatewaySections(menu: NSMenu) {
        let ids = gatewayManager.selectedProviderIds
        guard !ids.isEmpty else { return }

        for (index, id) in ids.enumerated() {
            if index > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            let name = gatewayManager.providerNames[id] ?? "Provider \(id)"
            let usage = gatewayManager.usages[id]

            var title = "\(name) 用量"
            if let plan = usage?.plan, !plan.isEmpty {
                title += " · \(plan)"
            }
            // 更新时间并入标题行右侧（不再单独占一行）
            let updatedTrailing = usage.map { "更新 \(Self.formatGatewayFetchedAt($0.fetchedAt))" }
            addInfoItem(menu: menu, text: title, trailing: updatedTrailing)

            if let error = gatewayManager.errors[id] {
                addErrorRow(
                    menu: menu,
                    title: "\(name) 用量刷新失败",
                    label: "刷新失败 · 点击查看详情",
                    message: error
                )
            }

            guard let usage else { continue }

            if usage.kind == "balance" {                // 按量余额：逐项「label: amount currency」（与网页一致，不画进度条、不合计）
                for balance in usage.balances ?? [] {
                    let currency = balance.currency.map { " \($0)" } ?? ""
                    let amount = Self.formatGatewayAmount(balance.amount)
                    addInfoItem(
                        menu: menu,
                        text: "\(balance.label): \(amount)\(currency)",
                        fontSize: MenuRowLayout.smallFontSize
                    )
                }
            } else {
                // 订阅窗口：仅展示 available 窗口，保持网关返回顺序。
                // 窗口 label（套餐/积分池名）仅在同一供应商存在多种不同标注时才逐行展示
                // （如商汤多积分池）；全部窗口同属一个套餐时标注已在标题 plan 中体现，不重复。
                let availableWindows = (usage.windows ?? []).filter { $0.available }
                let distinctLabels = Set(availableWindows.compactMap { $0.label })
                let showRowLabel = distinctLabels.count > 1
                for window in availableWindows {
                    let label = showRowLabel && window.label != nil
                        ? "\(window.windowTitle) · \(window.label!)"
                        : window.windowTitle
                    if let remaining = window.remainingPercent {
                        addQuotaBar(menu: menu, label: label, percent: remaining)
                    } else {
                        addInfoItem(menu: menu, text: "\(label): —", fontSize: MenuRowLayout.smallFontSize)
                    }
                    // 已用/总量与重置时间同一行：已用居左，重置时间右对齐（按网关返回时区渲染）
                    var usedLimitText: String?
                    if let used = window.used, let limit = window.limit {
                        let unit = window.unit.map { " \($0)" } ?? ""
                        usedLimitText = "已用 \(Self.formatGatewayAmount(used)) / \(Self.formatGatewayAmount(limit))\(unit)"
                    }
                    let resetText = Self.formatGatewayReset(window.resetsAt, timezone: usage.timezone)
                    if usedLimitText != nil || resetText != nil {
                        addInfoItem(
                            menu: menu,
                            text: usedLimitText ?? "",
                            fontSize: MenuRowLayout.smallFontSize,
                            trailing: resetText
                        )
                    }
                }
            }
        }
    }

    /// 窗口重置时间：按网关返回时区渲染为「M月d日 HH:mm 重置」（与网页一致）
    private static func formatGatewayReset(_ resetsAt: String?, timezone: String?) -> String? {
        guard let resetsAt, let date = parseISO8601(resetsAt) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        formatter.timeZone = timezone.flatMap { TimeZone(identifier: $0) } ?? .current
        return formatter.string(from: date) + " 重置"
    }

    /// 用量更新时间：按本机时区显示时刻（展示在区块标题行右侧，精确到分钟）
    private static func formatGatewayFetchedAt(_ fetchedAt: String) -> String {
        guard let date = parseISO8601(fetchedAt) else { return fetchedAt }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// ISO 8601 解析：兼容带/不带小数秒；小数位超过毫秒时截断后再试
    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let normalized = string.replacingOccurrences(
            of: "\\.(\\d{3})\\d+",
            with: ".$1",
            options: .regularExpression
        )
        if normalized != string, let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// 金额/用量数字：千分位、最多两位小数（与网页 formatAmount 一致）
    private static func formatGatewayAmount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 添加一行「标签 + 进度条 + 百分比数字」的额度展示
    private func addQuotaBar(menu: NSMenu, label: String, percent: Double) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = QuotaBarView(label: label, percent: percent)
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 添加一行纯文本信息（区块标题、重置时间、余额）。
    /// 使用自定义视图以收窄左右边距（原生 NSMenuItem 缩进是系统固定的）；
    /// 标题字号（默认 14）用默认行高，弱化小字（12）用紧凑行高。
    private func addInfoItem(
        menu: NSMenu,
        text: String,
        fontSize: CGFloat = MenuRowLayout.fontSize,
        trailing: String? = nil
    ) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let height = fontSize >= MenuRowLayout.fontSize ? MenuRowLayout.height : MenuRowLayout.compactHeight
        item.view = MenuInfoView(text: text, fontSize: fontSize, trailing: trailing, height: height)
        item.isEnabled = false
        menu.addItem(item)
    }

    /// 添加一行「红点 + 短文案」的错误行：固定宽度，长错误文本不会撑宽菜单；
    /// 点击该行时下拉菜单自动消失，并弹窗展示完整错误详情
    private func addErrorRow(menu: NSMenu, title: String, label: String, message: String) {
        let item = NSMenuItem(title: "", action: #selector(errorRowClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ErrorDetail(title: title, message: message)
        item.view = ErrorRowView(label: label)
        menu.addItem(item)
    }

    @objc private func errorRowClicked(_ sender: NSMenuItem) {
        guard let detail = sender.representedObject as? ErrorDetail else { return }
        showErrorAlert(title: detail.title, message: detail.message)
    }

    /// 弹窗展示错误详情（触发前下拉菜单已通过 cancelTracking 关闭）
    private func showErrorAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 状态栏：优先显示配置指定的供应商 + 窗口（status_bar），数据不可用时回退为
    /// 自动（第一个有可展示订阅窗口的已选供应商的最大窗口：月 > 周 > 日 > 5h）；
    /// 按量供应商可指定「主余额」。百分比/金额均只保留一位小数。
    /// 头部为供应商名（超宽截断），无配置/无数据时显示「--」。
    private func updateStatusBar() {
        var header = "用量"
        var valueText = "--"

        if let (name, text) = statusBarContent() {
            header = name
            valueText = text
        }

        let size = NSSize(width: 34, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let headerFont = NSFont.systemFont(ofSize: 7, weight: .medium)
        let percentFont = NSFont.systemFont(ofSize: 10, weight: .bold)

        // 供应商名可能超宽，逐字截断到状态栏可用宽度
        var headerText = header
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.controlTextColor
        ]
        while headerText.count > 1,
              (headerText as NSString).size(withAttributes: headerAttrs).width > size.width - 2 {
            headerText.removeLast()
        }
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: percentFont,
            .foregroundColor: NSColor.controlTextColor
        ]

        let headerSize = (headerText as NSString).size(withAttributes: headerAttrs)
        let percentSize = (valueText as NSString).size(withAttributes: percentAttrs)

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

        (headerText as NSString).draw(in: headerRect, withAttributes: headerAttrs)
        (valueText as NSString).draw(in: percentRect, withAttributes: percentAttrs)

        image.unlockFocus()

        let button = statusItem.button
        button?.image = image
        button?.imagePosition = .imageOnly
        button?.title = ""
        button?.attributedTitle = NSAttributedString(string: "")
        statusItem.length = 34
    }

    /// 菜单栏数字内容：配置的供应商 + 窗口优先，取不到数据回退自动
    private func statusBarContent() -> (String, String)? {
        let ids = gatewayManager.selectedProviderIds
        if let statusBar = AppConfig.load()?.gateway?.statusBar,
           let providerId = statusBar.providerId, providerId != 0,
           let usage = gatewayManager.usages[providerId],
           let text = statusBarValue(usage, window: statusBar.window ?? "auto") {
            return (gatewayManager.providerNames[providerId] ?? "Provider \(providerId)", text)
        }
        // 自动：按配置顺序找第一个有可用数据的供应商
        for id in ids {
            guard let usage = gatewayManager.usages[id],
                  let text = statusBarValue(usage, window: "auto") else { continue }
            return (gatewayManager.providerNames[id] ?? "Provider \(id)", text)
        }
        return nil
    }

    /// 从单个供应商用量中取状态栏数字：窗口剩余百分比（一位小数）或主余额金额
    private func statusBarValue(_ usage: GatewayUsage, window: String) -> String? {
        if window == "balance" {
            let items = usage.balances ?? []
            guard let primary = items.first(where: { $0.primary }) ?? items.first else { return nil }
            return String(format: "%.1f", primary.amount)
        }
        let available = (usage.windows ?? []).filter { $0.available && $0.remainingPercent != nil }
        if window == "auto" {
            for kind in ["monthly", "weekly", "daily", "five_hour"] {
                if let window = available.first(where: { $0.window == kind }),
                   let remaining = window.remainingPercent {
                    return String(format: "%.1f%%", remaining)
                }
            }
            return nil
        }
        guard let window = available.first(where: { $0.window == window }),
              let remaining = window.remainingPercent else { return nil }
        return String(format: "%.1f%%", remaining)
    }
}

// MARK: - Menu Row Layout

/// 菜单信息行的统一排版：收窄的左右边距与基准宽度。
/// 原生 NSMenuItem 的缩进（约 22pt）由系统固定，信息行改用自定义视图自行控制边距
enum MenuRowLayout {
    static let inset: CGFloat = 12
    static let width: CGFloat = 240
    /// 默认行高（区块标题、错误行、操作项）
    static let height: CGFloat = 22
    /// 弱化信息行的紧凑高度（已用/总量、重置时间、余额）
    static let compactHeight: CGFloat = 18
    /// 进度条行高
    static let barHeight: CGFloat = 20
    /// 默认文本大小（区块标题、错误提示）
    static let fontSize: CGFloat = 14
    /// 弱化文本大小（额度行标签、重置时间、余额）
    static let smallFontSize: CGFloat = 12
}

// MARK: - Menu Info View

/// 菜单中的纯文本信息行（区块标题、重置时间、余额）。
/// 支持可选的右侧尾随文本（如「更新 14:03」，弱化色右对齐）。
/// 宽度随文本自适应并随菜单宽度拉伸（autoresizing），长文本相应撑宽菜单
class MenuInfoView: NSView {
    private let text: String
    private let trailing: String?
    private let textAttributes: [NSAttributedString.Key: Any]
    private let trailingAttributes: [NSAttributedString.Key: Any]

    init(text: String, fontSize: CGFloat, trailing: String? = nil, height: CGFloat) {
        self.text = text
        self.trailing = trailing
        self.textAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor
        ]
        let trailingAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MenuRowLayout.smallFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        self.trailingAttributes = trailingAttrs
        let size = (text as NSString).size(withAttributes: textAttributes)
        let trailingSize = trailing.map { ($0 as NSString).size(withAttributes: trailingAttrs) } ?? .zero
        let trailingWidth = trailing == nil ? 0 : trailingSize.width + 8
        let width = max(MenuRowLayout.width, ceil(size.width + trailingWidth) + MenuRowLayout.inset * 2)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // 尾随文本始终贴菜单右缘
        autoresizingMask = [.width]
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
        if let trailing {
            let trailingSize = (trailing as NSString).size(withAttributes: trailingAttributes)
            (trailing as NSString).draw(
                at: NSPoint(
                    x: bounds.width - MenuRowLayout.inset - trailingSize.width,
                    y: (bounds.height - trailingSize.height) / 2
                ),
                withAttributes: trailingAttributes
            )
        }
    }
}

// MARK: - Error Row View

/// 错误行在弹窗中展示的数据（菜单项 representedObject）
private struct ErrorDetail {
    let title: String
    let message: String
}

/// 菜单中的「刷新失败」提示行：左侧红点 + 短文案，固定宽度，
/// 长错误文本不会撑宽菜单。点击该行先关闭下拉菜单（NSMenu.cancelTracking），
/// 再通过菜单项 action 弹窗展示完整错误详情。
final class ErrorRowView: NSView {
    private let label: String

    init(label: String) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: MenuRowLayout.width, height: MenuRowLayout.height))
        setAccessibilityElement(true)
        setAccessibilityLabel("\(label)，点击弹窗查看错误详情")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        guard let item = enclosingMenuItem else { return }
        // 先让下拉菜单消失，再触发菜单项 action（弹窗展示错误详情）
        item.menu?.cancelTracking()
        _ = item.target?.perform(item.action, with: item)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 左侧红点
        let dotRadius: CGFloat = 4
        let dotCenter = NSPoint(x: MenuRowLayout.inset + dotRadius, y: bounds.midY)
        let dotRect = NSRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // 右侧文案（比 MenuInfoView 默认色更深，暗示可点击）
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MenuRowLayout.fontSize),
            .foregroundColor: NSColor.labelColor
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(
            at: NSPoint(x: dotCenter.x + dotRadius + 8, y: (bounds.height - labelSize.height) / 2),
            withAttributes: labelAttrs
        )
    }
}

// MARK: - Quota Bar View

/// 菜单中的额度行视图：标签 + 进度条 + 百分比数字。
/// 颜色与 llm-gateway 网页用量卡一致：剩余 >50% 绿、>20% 黄、≤20% 红；
/// 百分比支持小数（如 62.5%），整数不带小数点。
/// 标签列至少 56pt（保证短标签各行进度条左对齐），长标签自适应加宽。
/// 边距与 MenuInfoView 信息行一致（MenuRowLayout）
class QuotaBarView: NSView {
    private let label: String
    private let percent: Double
    private let percentText: String
    /// 标签列实际宽度（含与进度条的间距）
    private let labelColumnWidth: CGFloat

    /// 与信息行的左边距一致
    private let leadingInset: CGFloat = MenuRowLayout.inset
    /// 与信息行的右边距一致
    private let trailingInset: CGFloat = MenuRowLayout.inset

    private static let labelFont = NSFont.systemFont(ofSize: MenuRowLayout.smallFontSize)
    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    init(label: String, percent: Double) {
        self.label = label
        let clamped = max(0, min(100, percent))
        self.percent = clamped
        let percentText = Self.formatPercent(clamped)
        self.percentText = percentText
        let labelSize = Self.measure(label, font: Self.labelFont)
        let labelColumn = max(56, ceil(labelSize.width) + 8)
        self.labelColumnWidth = labelColumn
        // 标签 + 百分比之外至少给进度条留 40pt，不足则整体加宽
        let percentSize = Self.measure(percentText, font: Self.percentFont)
        let needed = MenuRowLayout.inset * 2 + labelColumn + 10 + 40 + percentSize.width
        super.init(frame: NSRect(x: 0, y: 0, width: max(MenuRowLayout.width, ceil(needed)), height: MenuRowLayout.barHeight))
        // 进度条随菜单实际宽度横向撑满（保持标签/间距/百分比的固定间隔，剩余全给进度条）
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func measure(_ text: String, font: NSFont) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    /// 百分比文本：与网关网页一致保留小数（后端已 round2），整数不带小数点
    private static func formatPercent(_ percent: Double) -> String {
        if percent == percent.rounded() {
            return String(format: "%.0f%%", percent)
        }
        var digits = String(format: "%.2f", percent)
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.hasSuffix(".") { digits.removeLast() }
        return digits + "%"
    }

    /// 与网关网页用量卡一致：>50% 充足绿，>20% 紧张黄，≤20% 告急红
    private var barColor: NSColor {
        if percent > 50 { return .systemGreen }
        if percent > 20 { return .systemYellow }
        return .systemRed
    }

    override func draw(_ dirtyRect: NSRect) {
        let barColor = self.barColor

        // 左侧标签：比原生菜单项小一号，弱化标签、突出进度条与数字（与信息行同色）
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor
        ]
        let labelSize = Self.measure(label, font: Self.labelFont)
        (label as NSString).draw(
            at: NSPoint(x: leadingInset, y: (bounds.height - labelSize.height) / 2),
            withAttributes: labelAttrs
        )

        // 右侧百分比数字：等宽数字防止抖动，与进度条同色
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont,
            .foregroundColor: barColor
        ]
        let percentSize = Self.measure(percentText, font: Self.percentFont)
        let percentRect = NSRect(
            x: bounds.width - trailingInset - percentSize.width,
            y: (bounds.height - percentSize.height) / 2,
            width: percentSize.width,
            height: percentSize.height
        )
        (percentText as NSString).draw(in: percentRect, withAttributes: percentAttrs)

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
