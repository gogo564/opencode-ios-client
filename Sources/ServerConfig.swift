import Foundation
import Combine

/// OpenCode 服务器配置（地址/密码），UserDefaults 持久化。
///
/// 注意：OpenCode V2 的 Basic Auth 用户名固定为 `opencode`，
/// `OPENCODE_SERVER_USERNAME` 在 2.0.x 的 serve 上并不生效，因此这里写死。
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    static let fixedUsername = "opencode"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "oc_baseURL") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "oc_password") }
    }
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "oc_selectedModel") }
    }

    init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: "oc_baseURL") ?? ""
        password = d.string(forKey: "oc_password") ?? ""
        selectedModel = d.string(forKey: "oc_selectedModel") ?? ""
    }

    /// 规范化服务器地址：去掉尾部和头部的斜杠/空格
    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// 是否已填完整配置
    var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !password.isEmpty
    }

    /// Basic Auth 头
    var authHeader: String? {
        let raw = "\(ServerConfig.fixedUsername):\(password)"
        let data = raw.data(using: .utf8) ?? Data()
        return "Basic " + data.base64EncodedString()
    }
}
