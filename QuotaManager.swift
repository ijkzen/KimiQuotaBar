import Foundation

// MARK: - Data Models

struct QuotaResponse: Codable {
    let user: UserInfo
    let usage: UsageInfo
    let limits: [LimitInfo]
    let parallel: ParallelInfo?
}

struct UserInfo: Codable {
    let membership: MembershipInfo
    let userId: String?
    let region: String?
}

struct MembershipInfo: Codable {
    let level: String
}

struct UsageInfo: Codable {
    let limit: String
    // 额度用尽时 API 可能不返回 remaining，按 0 处理
    let remaining: String?
    let resetTime: String
    let used: String?
}

struct LimitInfo: Codable {
    let detail: DetailInfo
    let window: WindowInfo?
}

struct WindowInfo: Codable {
    let duration: Int
    let timeUnit: String
}

struct DetailInfo: Codable {
    let limit: String
    // 与 UsageInfo 一致：额度用尽时 API 可能不返回 remaining，按 0 处理
    let remaining: String?
    let used: String?
    let resetTime: String?
}

struct ParallelInfo: Codable {
    let limit: String?
}

// MARK: - Quota Manager

class QuotaManager: ObservableObject {
    @Published var quotaData: QuotaResponse?
    @Published var lastError: String?

    var onUpdate: (() -> Void)?

    private let apiURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    func refresh() {
        guard let apiKey = loadAPIKey() else {
            self.lastError = "未找到 API Key，请在 ~/.config/kimiquotabar/config.json 中配置 kimi.api_key"
            self.onUpdate?()
            return
        }

        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastError = "网络错误: \(error.localizedDescription)"
                    self?.onUpdate?()
                    return
                }

                guard let data = data else {
                    self?.lastError = "无数据返回"
                    self?.onUpdate?()
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    let response = try decoder.decode(QuotaResponse.self, from: data)
                    self?.quotaData = response
                    self?.lastError = nil
                } catch {
                    // 尝试解析错误信息
                    if let message = Self.parseErrorMessage(data) {
                        self?.lastError = message
                    } else {
                        let detail = (error as? DecodingError).map { decodingError -> String in
                            switch decodingError {
                            case .keyNotFound(let key, let context):
                                return "缺少字段 '\(key.stringValue)'（路径: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))）"
                            case .valueNotFound(let type, let context):
                                return "字段 '\(context.codingPath.map { $0.stringValue }.joined(separator: "."))' 缺少 \(type) 值"
                            case .typeMismatch(let type, let context):
                                return "字段 '\(context.codingPath.map { $0.stringValue }.joined(separator: "."))' 类型不匹配，期望 \(type)"
                            case .dataCorrupted(let context):
                                return "数据损坏: \(context.debugDescription)"
                            @unknown default:
                                return error.localizedDescription
                            }
                        } ?? error.localizedDescription
                        self?.lastError = "解析失败: \(detail)"
                    }
                }
                self?.onUpdate?()
            }
        }
        task.resume()
    }

    /// 解析 API 错误响应，返回可读错误信息（无则返回 nil，交由解码异常分支兜底）。
    /// 兼容两种格式：
    ///   旧: {"error": {"message": "..."}}
    ///   新: {"code": "unauthenticated", "details": [{"debug": {"localizedMessage": {"message": "..."}}}]}
    static func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let errMsg = json["error"] as? [String: Any],
           let message = errMsg["message"] as? String, !message.isEmpty {
            return message
        }

        // 新格式：逐个 details 找 localizedMessage.message，找不到再用顶层 code
        if let details = json["details"] as? [[String: Any]] {
            for detail in details {
                if let message = ((detail["debug"] as? [String: Any])?["localizedMessage"]
                    as? [String: Any])?["message"] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        return json["code"] as? String
    }

    private func loadAPIKey() -> String? {
        // 1. 配置文件 ~/.config/kimiquotabar/config.json 的 kimi.api_key
        //    load() 每次重读磁盘，修改配置后点击「立即刷新」即可生效，无需重启
        if let key = AppConfig.load()?.kimi?.apiKey, !key.isEmpty {
            return key
        }

        // 2. 兜底：环境变量
        if let envKey = ProcessInfo.processInfo.environment["KIMI_API_KEY"], !envKey.isEmpty {
            return envKey
        }

        return nil
    }
}
