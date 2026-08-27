import CommonCrypto
import CryptoKit
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

struct OpenCodeGoConfig: Codable {
    let workspaceId: String
    let cookiecloud: CookieCloudConfig

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case cookiecloud
    }
}

struct CookieCloudConfig: Codable {
    let host: String
    let uuid: String
    let password: String
}

/// opencode go 单个时间窗口（5小时 / 每周 / 每月）的用量
struct OpenCodeGoWindow {
    let usedPercent: Double
    let resetInSec: Double

    var remainingPercent: Int {
        Int(max(0, 100 - usedPercent).rounded())
    }

    var resetDate: Date {
        Date().addingTimeInterval(resetInSec)
    }
}

/// opencode go 账单信息（金额单位为美元）
struct OpenCodeGoBilling {
    let balanceUSD: Double?
    let monthlyLimitUSD: Double?
    let monthlyUsageUSD: Double?
}

// MARK: - OpenCode Go Manager

/// 查询 opencode go 额度。
/// 官方没有 JSON 额度 API，数据内嵌在 dashboard HTML 的 SSR 数据中：
///   GET https://opencode.ai/workspace/{id}/go      → rollingUsage/weeklyUsage/monthlyUsage
///   GET https://opencode.ai/workspace/{id}/billing → balance/monthlyLimit/monthlyUsage
/// 认证使用 opencode.ai 的 HttpOnly `auth` cookie，通过 CookieCloud 同步获取。
class OpenCodeGoManager: ObservableObject {
    @Published var rollingUsage: OpenCodeGoWindow?
    @Published var weeklyUsage: OpenCodeGoWindow?
    @Published var monthlyUsage: OpenCodeGoWindow?
    @Published var billing: OpenCodeGoBilling?
    @Published var lastError: String?

    /// 是否已配置（配置文件存在且包含 opencode_go 段落）。
    /// 每次读取都重读磁盘，不缓存，修改配置后点「立即刷新」即可生效，无需重启
    var isConfigured: Bool {
        Self.loadConfig() != nil
    }

    var onUpdate: (() -> Void)?

    /// 账单金额单位：1 USD = 1e8（已与支付记录核对：$5.00 → amount:500000000）
    private let unitsPerUSD = 100_000_000.0

    private let dashboardBase = "https://opencode.ai"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0"

    // MARK: Config

    private static func loadConfig() -> OpenCodeGoConfig? {
        AppConfig.load()?.opencodeGo
    }

    // MARK: Refresh

    /// CookieCloud 服务器通常是局域网/自托管地址，绕过系统代理直连。
    /// 系统代理（如 Clash 开启 SOCKS 时）对局域网地址的转发不稳定，
    /// 会导致 URLSession 返回假性的 "The Internet connection appears to be offline"
    private lazy var directSession: URLSession = {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.connectionProxyDictionary = [:]
        return URLSession(configuration: sessionConfig)
    }()

    /// 失败后自动重试一次的间隔（秒）
    private let retryDelay: TimeInterval = 3

    func refresh() {
        attemptRefresh(shouldRetry: true)
    }

    private func attemptRefresh(shouldRetry: Bool) {
        // 每次刷新都重读配置文件（不缓存），修改配置后无需重启即可生效
        guard let config = Self.loadConfig() else {
            // 未配置时静默跳过，不在菜单中显示该区块
            return
        }

        fetchAuthCookie(config: config) { [weak self] authCookie, message in
            guard let self = self else { return }
            guard let authCookie = authCookie else {
                self.handleFailure(message ?? "获取 auth cookie 失败", shouldRetry: shouldRetry)
                return
            }
            self.fetchDashboard(config: config, authCookie: authCookie, shouldRetry: shouldRetry)
        }
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
        DispatchQueue.main.async {
            self.lastError = message
            self.onUpdate?()
        }
    }

    private func fetchDashboard(config: OpenCodeGoConfig, authCookie: String, shouldRetry: Bool) {
        let group = DispatchGroup()
        var usageHTML: String?
        var billingHTML: String?
        var fetchError: String?

        for path in ["go", "billing"] {
            group.enter()
            let urlString = "\(dashboardBase)/workspace/\(config.workspaceId)/\(path)"
            var request = URLRequest(url: URL(string: urlString)!)
            request.setValue("auth=\(authCookie)", forHTTPHeaderField: "Cookie")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            URLSession.shared.dataTask(with: request) { data, response, error in
                defer { group.leave() }
                if let error = error {
                    fetchError = "网络错误: \(error.localizedDescription)"
                    return
                }
                // cookie 失效时服务端会 302 跳转到登录页
                if let finalURL = (response as? HTTPURLResponse)?.url,
                   finalURL.path.hasSuffix("/auth") {
                    fetchError = "auth cookie 已失效，请重新同步"
                    return
                }
                guard let data = data, let html = String(data: data, encoding: .utf8) else {
                    fetchError = "无数据返回"
                    return
                }
                if path == "go" {
                    usageHTML = html
                } else {
                    billingHTML = html
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if let fetchError = fetchError {
                self.handleFailure(fetchError, shouldRetry: shouldRetry)
                return
            }
            guard let usageHTML = usageHTML,
                  let windows = Self.parseUsageHTML(usageHTML), !windows.isEmpty else {
                self.handleFailure("解析用量页面失败", shouldRetry: shouldRetry)
                return
            }
            self.rollingUsage = windows["rolling"]
            self.weeklyUsage = windows["weekly"]
            self.monthlyUsage = windows["monthly"]
            self.billing = billingHTML.flatMap { Self.parseBillingHTML($0, unitsPerUSD: self.unitsPerUSD) }
            self.lastError = nil
            self.onUpdate?()
        }
    }

    // MARK: SSR HTML 解析

    /// 从 /go 页面提取 rollingUsage/weeklyUsage/monthlyUsage。
    /// SSR 数据形如: rollingUsage:$R[33]={status:"ok",resetInSec:13771,usagePercent:1}
    static func parseUsageHTML(_ html: String) -> [String: OpenCodeGoWindow]? {
        var windows: [String: OpenCodeGoWindow] = [:]
        for field in ["rollingUsage", "weeklyUsage", "monthlyUsage"] {
            // 对象可能为 null（未订阅相应窗口），字段顺序也可能变化
            guard let object = firstMatch(in: html, pattern: "\(field):\\$R\\[\\d+\\]=\\{[^}]*\\}") else {
                continue
            }
            guard let reset = firstCapture(in: object, pattern: "resetInSec:([0-9.]+)").flatMap(Double.init),
                  let percent = firstCapture(in: object, pattern: "usagePercent:([0-9.]+)").flatMap(Double.init) else {
                continue
            }
            let key = String(field.dropLast("Usage".count))
            windows[key] = OpenCodeGoWindow(usedPercent: percent, resetInSec: reset)
        }
        return windows
    }

    /// 从 /billing 页面提取 balance/monthlyLimit/monthlyUsage（原始单位 1e8 = 1 USD）。
    /// 形如: balance:0,reload:null,...,monthlyLimit:null,monthlyUsage:null
    static func parseBillingHTML(_ html: String, unitsPerUSD: Double) -> OpenCodeGoBilling? {
        func field(_ name: String) -> Double? {
            firstCapture(in: html, pattern: "\\b\(name):(\\d+(?:\\.\\d+)?)\\b").flatMap(Double.init)
        }
        guard let balance = field("balance") else {
            return nil
        }
        return OpenCodeGoBilling(
            balanceUSD: balance / unitsPerUSD,
            monthlyLimitUSD: field("monthlyLimit").map { $0 / unitsPerUSD },
            monthlyUsageUSD: field("monthlyUsage").map { $0 / unitsPerUSD }
        )
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange])
    }

    // MARK: CookieCloud

    /// 从 CookieCloud 服务器下载并解密 cookie，返回 opencode.ai 的 auth cookie 值
    /// 回调参数: (cookie 值, 错误信息)，二者必居其一
    private func fetchAuthCookie(config: OpenCodeGoConfig, completion: @escaping (String?, String?) -> Void) {
        let host = config.cookiecloud.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(host)/get/\(config.cookiecloud.uuid)") else {
            completion(nil, "CookieCloud 地址无效")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        directSession.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, "CookieCloud 网络错误: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encrypted = json["encrypted"] as? String else {
                completion(nil, "CookieCloud 返回数据无效")
                return
            }
            do {
                let payload = try Self.decryptCookieCloud(
                    encrypted: encrypted,
                    uuid: config.cookiecloud.uuid,
                    password: config.cookiecloud.password
                )
                guard let cookies = payload["cookie_data"] as? [String: Any] else {
                    completion(nil, "CookieCloud 数据中缺少 cookie_data")
                    return
                }
                // 域名可能是 "opencode.ai" 或 ".opencode.ai"
                for (domain, value) in cookies where domain.contains("opencode.ai") {
                    guard let items = value as? [[String: Any]] else { continue }
                    for item in items where item["name"] as? String == "auth" {
                        if let auth = item["value"] as? String, !auth.isEmpty {
                            completion(auth, nil)
                            return
                        }
                    }
                }
                completion(nil, "CookieCloud 中未找到 opencode.ai 的 auth cookie")
            } catch {
                completion(nil, "CookieCloud 解密失败: \(error.localizedDescription)")
            }
        }.resume()
    }

    // MARK: CookieCloud 解密（CryptoJS 兼容格式）

    enum CookieCloudError: LocalizedError {
        case invalidCiphertext
        case decryptFailed
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .invalidCiphertext: return "密文格式无效"
            case .decryptFailed: return "AES 解密失败（密码可能不正确）"
            case .invalidUTF8: return "解密结果不是有效的 UTF-8"
            }
        }
    }

    /// 解密 CookieCloud 的 encrypted 字段。
    /// 算法（与浏览器插件一致）:
    ///   passphrase = md5hex("\(uuid)-\(password)") 的前 16 个字符
    ///   密文 = base64("Salted__" + 8字节salt + AES-256-CBC密文)
    ///   key/iv = OpenSSL EVP_BytesToKey(MD5, passphrase, salt) → key 32字节 + iv 16字节
    static func decryptCookieCloud(encrypted: String, uuid: String, password: String) throws -> [String: Any] {
        // 1. passphrase
        let md5 = Insecure.MD5.hash(data: Data("\(uuid)-\(password)".utf8))
        let passphrase = md5.map { String(format: "%02x", $0) }.joined()
        let passphraseKey = String(passphrase.prefix(16))

        // 2. base64 解码并校验 Salted__ 前缀
        guard let raw = Data(base64Encoded: encrypted),
              raw.count > 16,
              raw.prefix(8) == Data("Salted__".utf8) else {
            throw CookieCloudError.invalidCiphertext
        }
        let salt = raw.subdata(in: 8..<16)
        let ciphertext = raw.subdata(in: 16..<raw.count)

        // 3. EVP_BytesToKey 派生 key + iv
        let (key, iv) = evpBytesToKey(password: Data(passphraseKey.utf8), salt: salt, keyLength: 32, ivLength: 16)

        // 4. AES-256-CBC 解密（PKCS7 填充由 CommonCrypto 处理）
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var decrypted = Data(count: capacity)
        var decryptedLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { cipherBytes in
                    decrypted.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, capacity,
                            &decryptedLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw CookieCloudError.decryptFailed
        }
        decrypted.count = decryptedLength

        guard let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else {
            throw CookieCloudError.invalidUTF8
        }
        return json
    }

    /// OpenSSL EVP_BytesToKey：循环计算 MD5(上一次结果 + password + salt) 直到凑够 key+iv 长度
    private static func evpBytesToKey(password: Data, salt: Data, keyLength: Int, ivLength: Int) -> (key: Data, iv: Data) {
        var derived = Data()
        var block = Data()
        while derived.count < keyLength + ivLength {
            var input = Data()
            input.append(block)
            input.append(password)
            input.append(salt)
            block = Data(Insecure.MD5.hash(data: input))
            derived.append(block)
        }
        return (derived.prefix(keyLength), derived.subdata(in: keyLength..<(keyLength + ivLength)))
    }
}
