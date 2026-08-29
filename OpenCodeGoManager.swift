import Foundation

// MARK: - Data Models

/// 配置文件 ~/.config/kimiquotabar/config.json 的结构
struct AppConfig: Codable {
    let kimi: KimiConfig?
    let opencodeGo: OpenCodeGoConfig?
    let commandCode: CommandCodeConfig?
    /// 次要额度区块的显示模式："opencode_go"（默认）或 "command_code"（二选一）
    let quotaProvider: String?

    enum CodingKeys: String, CodingKey {
        case kimi
        case opencodeGo = "opencode_go"
        case commandCode = "command_code"
        case quotaProvider = "quota_provider"
    }

    /// 配置文件路径
    static let filePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kimiquotabar/config.json")
        .path

    /// 读取并解码配置文件；文件不存在或格式错误时返回 nil。
    /// 每次调用都重读磁盘，修改配置后无需重启即可生效
    static func load() -> AppConfig? {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }
}

/// 配置文件中的 kimi 段落（Kimi Code API Key）
struct KimiConfig: Codable {
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

/// 配置文件中的 opencode_go 段落（OpenCode Go workspace API Key）
struct OpenCodeGoConfig: Codable {
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

/// opencode go 单个时间窗口（5小时 / 每周 / 每月）的用量
struct OpenCodeGoWindow {
    /// 已用百分比（0-100 整数，服务端返回）
    let usedPercent: Int
    /// 窗口重置时刻（ISO 8601）
    let resetsAt: String
    /// 窗口状态："ok" | "rate-limited"
    let status: String

    /// 剩余百分比（用于进度条展示）
    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
    }

    /// 是否被限流（上游已把 percent 钉在 100）
    var isRateLimited: Bool {
        status == "rate-limited"
    }
}

// MARK: - OpenCode Go Manager

/// 查询 opencode go 额度。
/// 官方额度接口（2026-08-29 实测）：
///   GET https://opencode.ai/zen/go/v1/usage
///   Authorization: Bearer <workspace API key>
/// 只认 Bearer（推理侧 /messages 只认 x-api-key，不可互换）。
/// 401 = 无鉴权或头用错；403 = key 有效但未购买 Go（EntitlementError）。
/// 响应只有 5h/周/月 三个窗口的已用百分比，无金额。
class OpenCodeGoManager: ObservableObject {
    @Published var rollingUsage: OpenCodeGoWindow?
    @Published var weeklyUsage: OpenCodeGoWindow?
    @Published var monthlyUsage: OpenCodeGoWindow?
    @Published var lastError: String?

    /// 是否已配置（config.json 存在且包含 opencode_go.api_key）
    /// 每次读取都重读磁盘，不缓存，修改配置后点「立即刷新」即可生效，无需重启
    var isConfigured: Bool {
        (AppConfig.load()?.opencodeGo?.apiKey ?? "").isEmpty == false
    }

    var onUpdate: (() -> Void)?

    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    /// 失败后自动重试一次的间隔（秒）
    private let retryDelay: TimeInterval = 3

    func refresh() {
        attemptRefresh(shouldRetry: true)
    }

    private func attemptRefresh(shouldRetry: Bool) {
        guard let apiKey = AppConfig.load()?.opencodeGo?.apiKey, !apiKey.isEmpty else {
            // 未配置时静默跳过，不在菜单中显示该区块
            return
        }

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.handleFailure("网络错误: \(error.localizedDescription)", shouldRetry: shouldRetry)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.handleFailure("无数据返回", shouldRetry: shouldRetry)
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    // 401 = key 无效或鉴权头用错；403 = key 有效但未购买 Go
                    if http.statusCode == 401 {
                        self.handleFailure("API Key 无效或已过期", shouldRetry: shouldRetry)
                    } else if http.statusCode == 403 {
                        self.handleFailure("该 Key 未购买 OpenCode Go 套餐", shouldRetry: shouldRetry)
                    } else {
                        self.handleFailure("服务端错误: HTTP \(http.statusCode)", shouldRetry: shouldRetry)
                    }
                    return
                }
                guard let data = data, let windows = Self.parseUsage(data) else {
                    self.handleFailure("解析响应失败", shouldRetry: shouldRetry)
                    return
                }
                self.rollingUsage = windows.rolling
                self.weeklyUsage = windows.weekly
                self.monthlyUsage = windows.monthly
                self.lastError = nil
                self.onUpdate?()
            }
        }.resume()
    }

    /// 失败处理：首次失败自动重试一次；仍失败则记录错误。
    /// 注意不清空已展示的旧数据，由 UI 层决定如何呈现错误
    private func handleFailure(_ message: String, shouldRetry: Bool) {
        if shouldRetry {
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.attemptRefresh(shouldRetry: false)
            }
            return
        }
        lastError = message
        onUpdate?()
    }

    // MARK: 响应解析

    /// 解析 /zen/go/v1/usage。
    /// 实测响应：
    ///   {"usage":{
    ///     "rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-29T00:03:30.118Z"},
    ///     "weekly":{"status":"ok","percent":16,"resetsAt":"2026-08-31T00:00:00.118Z"},
    ///     "monthly":{"status":"ok","percent":95,"resetsAt":"2026-09-14T08:53:55.118Z"}}}
    /// 注意：percent 为 0 时 resetsAt 是「now + 窗口时长」的占位值，不代表真实重置时间
    static func parseUsage(_ data: Data) -> (rolling: OpenCodeGoWindow?, weekly: OpenCodeGoWindow?, monthly: OpenCodeGoWindow?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return nil }

        func window(_ key: String) -> OpenCodeGoWindow? {
            guard let object = usage[key] as? [String: Any],
                  let percent = object["percent"] as? Int ?? (object["percent"] as? NSNumber)?.intValue,
                  let resetsAt = object["resetsAt"] as? String else { return nil }
            return OpenCodeGoWindow(
                usedPercent: percent,
                resetsAt: resetsAt,
                status: object["status"] as? String ?? "ok"
            )
        }

        return (window("rolling"), window("weekly"), window("monthly"))
    }
}
