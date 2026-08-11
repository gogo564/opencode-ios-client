import Foundation

/// OpenCode 服务器配置（地址/用户名/密码），UserDefaults 持久化。
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "oc_baseURL") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "oc_username") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "oc_password") }
    }
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "oc_selectedModel") }
    }

    init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: "oc_baseURL") ?? "http://gogo564.x3322.net:4096"
        username = d.string(forKey: "oc_username") ?? "opencode"
        password = d.string(forKey: "oc_password") ?? ""
        selectedModel = d.string(forKey: "oc_selectedModel") ?? ""
    }

    /// 规范化服务器地址：去掉尾部斜杠
    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// 是否已填完整配置
    var isConfigured: Bool {
        !baseURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    /// Basic Auth 头
    var authHeader: String? {
        let raw = "\(username):\(password)"
        let data = raw.data(using: .utf8) ?? Data()
        return "Basic " + data.base64EncodedString()
    }
}
