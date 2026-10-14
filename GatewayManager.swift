import Foundation

// MARK: - 配置

/// 配置文件 ~/.config/kimiquotabar/config.json 的结构。
/// llm-gateway 是唯一信息源，配置仅含 gateway 段（历史字段在保存时清除）。
struct AppConfig: Codable {
    /// llm-gateway 对外只读接口配置（供应商用量展示，最多两个）
    let gateway: GatewayConfig?

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

/// 网关请求错误：包装面向用户的中文错误文案
struct GatewayError: Error {
    let message: String
}

/// 配置文件中的 gateway 段落（llm-gateway 对外只读接口）
struct GatewayConfig: Codable {
    /// 网关地址（如 https://gateway.ijkzen.cn，不含尾斜杠）
    let url: String?
    /// 网关 API Key（lg- 前缀，Bearer 鉴权）
    let apiKey: String?
    /// 菜单栏展示用量的供应商 id（最多三个）
    let providerIds: [Int]?
    /// 状态栏数字选择（缺省 = 自动：第一个有可用窗口的供应商的最大窗口）
    let statusBar: StatusBarConfig?

    enum CodingKeys: String, CodingKey {
        case url
        case apiKey = "api_key"
        case providerIds = "provider_ids"
        case statusBar = "status_bar"
    }
}

/// 状态栏数字配置：指定供应商的指定窗口（five_hour/daily/weekly/monthly/balance/auto）
struct StatusBarConfig: Codable {
    let providerId: Int?
    let window: String?

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case window
    }
}

// MARK: - 响应模型

/// llm-gateway 统一响应信封（/v1/providers* 业务响应为 code/msg/data 结构）
struct GatewayResponse<T: Decodable>: Decodable {
    let code: String
    let msg: String
    let data: T?
}

/// GET /v1/providers 列表项（对外仅暴露这几个字段，不含敏感配置）
struct GatewayProvider: Decodable {
    let id: Int
    let name: String
    let enable: Bool
    let billingMode: Int
    let usageSupported: Bool
}

/// GET /v1/providers/{id}/usage 的 data（订阅窗口 / 按量余额两种形态）
struct GatewayUsage: Decodable {
    let providerId: Int
    let fetchedAt: String
    /// "quota"（订阅窗口）| "balance"（按量余额）
    let kind: String
    let plan: String?
    let windows: [GatewayUsageWindow]?
    let balances: [GatewayBalance]?
    /// 网关设置表时区（IANA 名）：窗口重置时间映射到该时区渲染
    let timezone: String?
}

/// 订阅制单个窗口（5 小时 / 今日 / 本周 / 本月）
struct GatewayUsageWindow: Decodable {
    let window: String
    let available: Bool
    let remainingPercent: Double?
    let resetsAt: String?
    let used: Double?
    let limit: Double?
    let unit: String?
    /// 所属容量容器标注（如积分池名，同类型多窗口时区分用）
    let label: String?

    /// 与网关网页一致的窗口中文名
    var windowTitle: String {
        switch window {
        case "five_hour": return "5 小时"
        case "daily": return "今日"
        case "weekly": return "本周"
        case "monthly": return "本月"
        default: return window
        }
    }
}

/// 按量付费的余额条目
struct GatewayBalance: Decodable {
    let label: String
    let amount: Double
    let currency: String?
    /// 是否为该供应商的主余额字段（fetcher 侧标记，每家至多一条；旧数据缺省视为 false）
    let primary: Bool

    enum CodingKeys: String, CodingKey {
        case label, amount, currency, primary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        amount = try container.decode(Double.self, forKey: .amount)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
    }
}

// MARK: - Gateway Manager

/// 从 llm-gateway 拉取已选供应商的用量信息。
/// 接口（Bearer API Key 鉴权，与转发同一套 lg- 密钥）：
///   GET <url>/v1/providers              供应商列表（id/名称/用量支持标记）
///   GET <url>/v1/providers/{id}/usage   单个供应商用量（10 分钟缓存，?refresh=1 强制回源）
/// 配置位于 ~/.config/kimiquotabar/config.json 的 gateway 段（url/api_key/provider_ids）。
class GatewayManager: ObservableObject {
    /// 已选供应商的用量（key = provider id），失败时保留旧数据
    @Published var usages: [Int: GatewayUsage] = [:]
    /// provider id → 名称（每次刷新从 /v1/providers 解析，配置里不存名称）
    @Published var providerNames: [Int: String] = [:]
    /// 按供应商记录刷新错误（菜单在对应区块追加红点行）
    @Published var errors: [Int: String] = [:]

    var onUpdate: (() -> Void)?

    /// 防重入：上一轮刷新未结束时跳过新触发
    private var isRefreshing = false

    /// 已选供应商 id（最多三个，按配置顺序）
    var selectedProviderIds: [Int] {
        Array((AppConfig.load()?.gateway?.providerIds ?? []).prefix(3))
    }

    /// 是否已配置（url + api_key + provider_ids 三者齐备）
    var isConfigured: Bool {
        guard let gateway = AppConfig.load()?.gateway else { return false }
        return !(gateway.url ?? "").isEmpty
            && !(gateway.apiKey ?? "").isEmpty
            && !(gateway.providerIds ?? []).isEmpty
    }

    /// 刷新已选供应商用量。force=true 时带 ?refresh=1 绕过网关 10 分钟缓存（手动「立即刷新」）。
    func refresh(force: Bool = false) {
        guard let snapshot = Self.configSnapshot() else { return }
        guard !isRefreshing else { return }
        isRefreshing = true

        // 先取供应商列表解析名称，再并发拉各供应商用量
        Self.fetchProviders(base: snapshot.base, apiKey: snapshot.apiKey) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    for id in snapshot.ids { self.errors[id] = error.message }
                    self.onUpdate?()
                }
            case .success(let providers):
                DispatchQueue.main.async {
                    self.providerNames = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.name) })
                }
                let group = DispatchGroup()
                var results: [Int: Result<GatewayUsage, GatewayError>] = [:]
                let lock = NSLock()
                for id in snapshot.ids {
                    group.enter()
                    Self.fetchUsage(base: snapshot.base, apiKey: snapshot.apiKey, id: id, force: force) { result in
                        lock.lock()
                        results[id] = result
                        lock.unlock()
                        group.leave()
                    }
                }
                group.notify(queue: .main) { [weak self] in
                    guard let self else { return }
                    self.isRefreshing = false
                    // 请求期间配置被改动（换 Key/改选择）则丢弃本次结果，等待下一轮刷新
                    guard Self.configSnapshot() == snapshot else { return }
                    for (id, result) in results {
                        switch result {
                        case .success(let usage):
                            self.usages[id] = usage
                            self.errors[id] = nil
                        case .failure(let error):
                            self.errors[id] = error.message
                        }
                    }
                    self.onUpdate?()
                }
            }
        }
    }

    /// 当前配置的快照（地址规整掉尾斜杠；ids 截取前两个），用于丢弃过期响应
    private struct ConfigSnapshot: Equatable {
        let base: String
        let apiKey: String
        let ids: [Int]
    }

    private static func configSnapshot() -> ConfigSnapshot? {
        guard let gateway = AppConfig.load()?.gateway,
              let url = gateway.url, !url.isEmpty,
              let apiKey = gateway.apiKey, !apiKey.isEmpty
        else { return nil }
        let ids = Array((gateway.providerIds ?? []).prefix(3))
        guard !ids.isEmpty else { return nil }
        let base = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ConfigSnapshot(base: base, apiKey: apiKey, ids: ids)
    }

    // MARK: 网络请求（completion 在后台队列回调，调用方自行切主线程）

    /// 拉取供应商列表（设置页「加载供应商列表」与刷新时的名称解析共用）
    static func fetchProviders(
        base: String,
        apiKey: String,
        completion: @escaping (Result<[GatewayProvider], GatewayError>) -> Void
    ) {
        guard let url = URL(string: "\(base)/v1/providers") else {
            completion(.failure(GatewayError(message: "网关地址无效")))
            return
        }
        perform(url: url, apiKey: apiKey, timeout: 15, completion: completion)
    }

    /// 拉取单个供应商用量。网关回源抓取上游有 15s 超时，客户端留足余量（同网页 30s）
    static func fetchUsage(
        base: String,
        apiKey: String,
        id: Int,
        force: Bool,
        completion: @escaping (Result<GatewayUsage, GatewayError>) -> Void
    ) {
        guard var components = URLComponents(string: "\(base)/v1/providers/\(id)/usage") else {
            completion(.failure(GatewayError(message: "网关地址无效")))
            return
        }
        if force {
            components.queryItems = [URLQueryItem(name: "refresh", value: "1")]
        }
        guard let url = components.url else {
            completion(.failure(GatewayError(message: "网关地址无效")))
            return
        }
        perform(url: url, apiKey: apiKey, timeout: 30, completion: completion)
    }

    /// 统一请求与信封解析：2xx 且 code == "0" 返回 data；
    /// 错误文案优先取业务信封 msg，再取 /v1 鉴权中间件的 OpenAI 风格 error.message
    private static func perform<T: Decodable>(
        url: URL,
        apiKey: String,
        timeout: TimeInterval,
        completion: @escaping (Result<T, GatewayError>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(GatewayError(message: "网络错误: \(error.localizedDescription)")))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(GatewayError(message: "无数据返回")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 {
                    completion(.failure(GatewayError(message: "API Key 无效或已过期")))
                } else {
                    let message = Self.errorMessage(from: data) ?? "服务端错误: HTTP \(http.statusCode)"
                    completion(.failure(GatewayError(message: message)))
                }
                return
            }
            guard let envelope = try? JSONDecoder().decode(GatewayResponse<T>.self, from: data) else {
                completion(.failure(GatewayError(message: "解析响应失败")))
                return
            }
            guard envelope.code == "0", let payload = envelope.data else {
                completion(.failure(GatewayError(message: envelope.msg.isEmpty ? "网关返回异常" : envelope.msg)))
                return
            }
            completion(.success(payload))
        }.resume()
    }

    /// 错误响应正文取可读文案：管理信封 msg 或 OpenAI 风格 error.message
    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let msg = json["msg"] as? String, !msg.isEmpty { return msg }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
