import Foundation

// MARK: - Data Models

/// 配置文件中的 command_code 段落（Command Code API Key）
struct CommandCodeConfig: Codable {
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

/// 5小时 / 每周滚动窗口的额度
struct CommandCodeWindow {
    let used: Double
    let cap: Double
    /// 窗口重置时刻（毫秒时间戳）
    let resetAt: Double

    var remainingPercent: Int {
        guard cap > 0 else { return 0 }
        return Int(max(0, min(100, (cap - used) / cap * 100)).rounded())
    }

    var resetDate: Date {
        Date(timeIntervalSince1970: resetAt / 1000)
    }
}

// MARK: - Command Code Manager

/// 查询 Command Code（api.commandcode.ai）的余额、订阅与用量。
/// 官方 Provider API 没有用量端点，以下 /alpha/* 私有端点来自 command-code CLI 逆向
/// （command-code@1.36.0 npm 包 cli.mjs），字段以 2026-08-27 实测为准：
///   GET /alpha/whoami                 → user / org 身份（无组织账号时 org 为 null）
///   GET /alpha/billing/credits        → credits（monthly/purchased/free）+ windowLimits（fiveHour/weekly）
///   GET /alpha/billing/subscriptions  → planId、status、currentPeriodStart/End
///   GET /alpha/usage/summary?since=   → 自 since 以来已消费 totalCost（USD）
/// 无组织账号时省略 orgId 参数（源码用 null 判断）。认证：Authorization: Bearer <key>。
class CommandCodeManager: ObservableObject {
    @Published var credits: CommandCodeCredits?
    @Published var subscription: CommandCodeSubscription?
    @Published var totalCost: Double?
    @Published var lastError: String?

    /// 是否已配置（config.json 存在且包含 command_code.api_key）
    /// 每次读取都重读磁盘，不缓存，修改配置后点「立即刷新」即可生效，无需重启
    var isConfigured: Bool {
        (AppConfig.load()?.commandCode?.apiKey ?? "").isEmpty == false
    }

    var onUpdate: (() -> Void)?

    private let baseURL = "https://api.commandcode.ai/alpha"

    func refresh() {
        guard let apiKey = AppConfig.load()?.commandCode?.apiKey, !apiKey.isEmpty else {
            // 未配置时静默跳过，不在菜单中显示该区块
            return
        }

        fetchWhoami(apiKey: apiKey) { [weak self] orgID in
            guard let self = self else { return }
            let orgQuery = orgID.map { "?orgId=\($0)" } ?? ""
            let group = DispatchGroup()

            var creditsData: Data?
            var subscriptionsData: Data?
            var fetchError: String?

            // credits + subscriptions 并发
            for path in ["billing/credits", "billing/subscriptions"] {
                group.enter()
                let urlString = "\(self.baseURL)/\(path)\(orgQuery)"
                var request = URLRequest(url: URL(string: urlString)!)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15

                URLSession.shared.dataTask(with: request) { data, response, error in
                    defer { group.leave() }
                    if let error = error {
                        fetchError = "网络错误: \(error.localizedDescription)"
                        return
                    }
                    guard let data = data else {
                        fetchError = "无数据返回"
                        return
                    }
                    if path.hasSuffix("credits") {
                        creditsData = data
                    } else {
                        subscriptionsData = data
                    }
                }.resume()
            }

            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                if let fetchError = fetchError {
                    self.handleFailure(fetchError)
                    return
                }
                guard let creditsData = creditsData,
                      let credits = Self.parseCredits(creditsData) else {
                    self.handleFailure("解析 credits 失败")
                    return
                }
                self.credits = credits

                // subscription 失败只影响「本期已用金额」与「月重置」两行，其余额度照常展示
                if let subscriptionsData = subscriptionsData,
                   let subscription = Self.parseSubscription(subscriptionsData) {
                    self.subscription = subscription
                    self.fetchSummary(apiKey: apiKey, since: subscription.currentPeriodStart)
                } else {
                    self.subscription = nil
                    self.totalCost = nil
                }
                self.lastError = nil
                self.onUpdate?()
            }
        }
    }

    /// 获取用户 / 组织身份；无组织账号（org 为 null）时回调 orgID = nil
    private func fetchWhoami(apiKey: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "\(baseURL)/whoami")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard error == nil, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(nil)
                    return
                }
                let orgID = (json["org"] as? [String: Any])?["id"] as? String
                completion(orgID)
            }
        }.resume()
    }

    /// 拉取 usage/summary；since 为订阅周期起始时间（ISO 8601，实测要求，不支持毫秒时间戳）
    private func fetchSummary(apiKey: String, since: String) {
        guard let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        var request = URLRequest(url: URL(string: "\(baseURL)/usage/summary?since=\(encoded)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, let data = data,
                      let totalCost = Self.parseSummary(data) else {
                    // summary 失败不阻断主流程：保留已展示的额度数据，仅置空本期金额
                    self.totalCost = nil
                    return
                }
                self.totalCost = totalCost
                self.onUpdate?()
            }
        }.resume()
    }

    /// 失败处理：记录错误并通知 UI 重建菜单。
    /// 注意不清空已展示的旧数据，由 UI 层决定如何呈现错误
    private func handleFailure(_ message: String) {
        lastError = message
        onUpdate?()
    }

    // MARK: 响应解析

    /// 解析 /alpha/billing/credits。
    /// 实测响应（无 success 包装）：
    ///   {"credits":{"monthlyCredits":38.31,"purchasedCredits":0,"freeCredits":0},
    ///    "windowLimits":{"fiveHour":{"used":0.17,"cap":14,"resetAt":1788037663989},
    ///                     "weekly":{"used":31.68,"cap":35,"resetAt":1788403857032}}}
    /// 注意：monthlyCredits 是「本月剩余额度」（非总额），
    /// 月度总额 = monthlyCredits + usage/summary 的 totalCost（本期已用）。
    /// windowLimits 无 "remaining" 字段，剩余按 cap - used 计算
    static func parseCredits(_ data: Data) -> CommandCodeCredits? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = json["credits"] as? [String: Any] else { return nil }

        func double(_ key: String, in dict: [String: Any]) -> Double? {
            dict[key] as? Double ?? (dict[key] as? NSNumber)?.doubleValue
        }
        func window(_ key: String, in dict: [String: Any]) -> CommandCodeWindow? {
            guard let object = dict[key] as? [String: Any],
                  let used = double("used", in: object),
                  let cap = double("cap", in: object),
                  let resetAt = double("resetAt", in: object) else { return nil }
            return CommandCodeWindow(used: used, cap: cap, resetAt: resetAt)
        }

        let windowLimits = json["windowLimits"] as? [String: Any]
        return CommandCodeCredits(
            monthlyCredits: double("monthlyCredits", in: credits),
            purchasedCredits: double("purchasedCredits", in: credits),
            freeCredits: double("freeCredits", in: credits),
            fiveHour: windowLimits.flatMap { window("fiveHour", in: $0) },
            weekly: windowLimits.flatMap { window("weekly", in: $0) }
        )
    }

    /// 解析 /alpha/billing/subscriptions。
    /// 实测响应（带 success/data 包装，与文档的 data.data 不同）：
    ///   {"success":true,"data":{"id":"sub_...","status":"active","planId":"individual-goat",
    ///    "currentPeriodStart":"2026-08-27T02:38:16.000Z","currentPeriodEnd":"2026-09-27T02:38:16.000Z"}}
    /// 同时兼容文档样式的裸响应（无包装）
    static func parseSubscription(_ data: Data) -> CommandCodeSubscription? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (json["data"] as? [String: Any]) ?? json
        guard let start = payload["currentPeriodStart"] as? String,
              let end = payload["currentPeriodEnd"] as? String else { return nil }
        return CommandCodeSubscription(
            planId: payload["planId"] as? String,
            status: payload["status"] as? String,
            currentPeriodStart: start,
            currentPeriodEnd: end
        )
    }

    /// 解析 /alpha/usage/summary。
    /// 实测响应（无 success 包装）：{"totalCount":480,"totalCost":0.946,"...":"..."}
    static func parseSummary(_ data: Data) -> Double? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cost = json["totalCost"] as? Double ?? (json["totalCost"] as? NSNumber)?.doubleValue else { return nil }
        return cost
    }
}

/// command code 的 credits 汇总与滚动窗口额度
struct CommandCodeCredits {
    let monthlyCredits: Double?
    let purchasedCredits: Double?
    let freeCredits: Double?
    let fiveHour: CommandCodeWindow?
    let weekly: CommandCodeWindow?
}

/// command code 的订阅信息
struct CommandCodeSubscription {
    let planId: String?
    let status: String?
    /// 计费周期起始（ISO 8601，作为 usage/summary 的 since 参数）
    let currentPeriodStart: String
    let currentPeriodEnd: String

    var periodEndDate: Date? {
        // 服务端返回带小数秒的 ISO 8601（如 2026-09-27T02:38:16.000Z），需显式声明格式
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: currentPeriodEnd)
    }
}
