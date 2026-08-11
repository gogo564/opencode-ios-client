import Foundation

enum OCError: LocalizedError {
    case invalidURL
    case http(Int)
    case notConfigured
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .http(let code): return "服务器错误（HTTP \(code)）"
        case .notConfigured: return "请先在设置中填写服务器地址和密码"
        case .decoding: return "返回数据解析失败"
        }
    }
}

/// opencode server HTTP API 客户端（Basic Auth）。
final class OpenCodeClient {
    static let shared = OpenCodeClient()
    private let config = ServerConfig.shared

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        guard config.isConfigured, var comps = URLComponents(string: config.normalizedBaseURL + path) else {
            throw OCError.notConfigured
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw OCError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let auth = config.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    // MARK: - 模型

    struct OCModel: Identifiable, Hashable {
        let id: String            // providerID/modelID
        let providerID: String
        let modelID: String
        let name: String
        let providerName: String

        var displayName: String {
            name.isEmpty ? id : "\(name)"
        }
    }

    /// GET /config/providers 返回 { providers: [...], default: {...} }
    func models() async throws -> [OCModel] {
        let request = try makeRequest("/config/providers")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]] else {
            throw OCError.decoding
        }
        var result: [OCModel] = []
        for provider in providers {
            let providerID = provider["id"] as? String ?? ""
            let providerName = provider["name"] as? String ?? providerID
            let modelsDict = provider["models"] as? [String: Any] ?? [:]
            for (modelID, value) in modelsDict {
                let name = (value as? [String: Any])?["name"] as? String ?? modelID
                result.append(OCModel(
                    id: "\(providerID)/\(modelID)",
                    providerID: providerID,
                    modelID: modelID,
                    name: name,
                    providerName: providerName
                ))
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - 会话

    struct OCSession: Identifiable, Codable {
        let id: String
        let title: String?
        let time: OCSessionTime?

        enum CodingKeys: String, CodingKey {
            case id, title, time
        }
    }

    struct OCSessionTime: Codable {
        let created: Double?
        let updated: Double?
    }

    /// GET /session 列出全部会话
    func sessions() async throws -> [OCSession] {
        let request = try makeRequest("/session")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OCError.decoding
        }
        return arr.compactMap { dict -> OCSession? in
            guard let id = dict["id"] as? String else { return nil }
            return OCSession(
                id: id,
                title: dict["title"] as? String,
                time: nil
            )
        }
    }

    /// POST /session 创建会话
    func createSession() async throws -> OCSession {
        var request = try makeRequest("/session", method: "POST")
        request.httpBody = Data()
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = dict["id"] as? String else {
            throw OCError.decoding
        }
        return OCSession(id: id, title: dict["title"] as? String, time: nil)
    }

    /// DELETE /session/:id 删除会话
    func deleteSession(_ id: String) async throws {
        let request = try makeRequest("/session/\(id)", method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
    }

    // MARK: - 消息

    struct OCMessage: Identifiable, Hashable {
        let id: String
        let role: String
        let content: String
        let isStreaming: Bool
        let error: Bool
        let completed: Bool

        var displayName: String {
            role == "user" ? "我" : "Assistant"
        }
    }

    /// GET /session/:id/message 获取会话消息列表（按时间升序）
    func messages(sessionID: String, limit: Int? = nil) async throws -> [OCMessage] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let request = try makeRequest("/session/\(sessionID)/message", query: query)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        return parseMessages(data)
    }

    private func parseMessages(_ data: Data) -> [OCMessage] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var result: [OCMessage] = []
        for item in arr {
            guard let info = item["info"] as? [String: Any] else { continue }
            guard let mid = info["id"] as? String else { continue }
            let role = info["role"] as? String ?? "assistant"
            let completed = (info["time"] as? [String: Any])?["completed"] != nil
            let isError = info["error"] != nil
            let parts = parseParts(item["parts"] as? [[String: Any]] ?? [])
            result.append(OCMessage(
                id: mid,
                role: role,
                content: parts.joined(),
                isStreaming: false,
                error: isError,
                completed: completed
            ))
        }
        return result
    }

    // MARK: - 发送消息

    struct OCSendResult {
        let message: OCMessage
        let parts: [String]
    }

    /// 发送消息（即时对话）。
    /// 先用 POST /session/:id/prompt_async 立即提交（204），随后轮询
    /// GET /session/:id/message 增量读取回复文本，通过 onText 逐段回调，
    /// 直到 assistant 消息标记完成（time.completed 存在）。
    func sendMessage(
        sessionID: String,
        text: String,
        model: OCModel? = nil,
        onText: @escaping (String) -> Void = { _ in }
    ) async throws -> OCSendResult {
        let messageID = "msg_" + UUID().uuidString.lowercased()
        var request = try makeRequest("/session/\(sessionID)/prompt_async", method: "POST")
        var body: [String: Any] = [
            "messageID": messageID,
            "parts": [
                ["type": "text", "text": text]
            ]
        ]
        if let model {
            body["model"] = ["providerID": model.providerID, "modelID": model.modelID]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (_, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)

        return try await pollForReply(sessionID: sessionID, messageID: messageID, text: text, onText: onText)
    }

    /// 轮询消息列表，直到出现本轮用户消息之后 assistant 的完整回复。
    /// 优先按自定义 messageID 定位；若服务器不保存该 ID（旧版本），回退按文本匹配最新用户消息。
    private func pollForReply(
        sessionID: String,
        messageID: String,
        text: String,
        onText: @escaping (String) -> Void
    ) async throws -> OCSendResult {
        let deadline = Date().addingTimeInterval(300)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 900_000_000)
            let msgs = try await messages(sessionID: sessionID, limit: 20)

            // 定位本轮用户消息：优先 messageID，回退匹配最新一条内容相同的用户消息
            var userIndex = msgs.firstIndex(where: { $0.id == messageID })
            if userIndex == nil {
                userIndex = msgs.lastIndex(where: { $0.role == "user" && $0.content == text })
            }
            guard let userIndex else { continue }
            let suffix = msgs[(userIndex + 1)...]

            var replyText = ""
            var isDone = false
            for m in suffix where m.role == "assistant" {
                replyText += m.content
                if m.completed { isDone = true }
            }

            if replyText.isEmpty && !isDone { continue }

            if !replyText.isEmpty {
                onText(replyText)
            }

            if isDone && !replyText.isEmpty {
                let msg = OCMessage(id: "assistant", role: "assistant", content: replyText, isStreaming: false, error: false, completed: true)
                return OCSendResult(message: msg, parts: [replyText])
            }
        }

        throw OCError.decoding
    }

    private func parseParts(_ parts: [[String: Any]]) -> [String] {
        var out: [String] = []
        for part in parts {
            let type = part["type"] as? String ?? ""
            if type == "text", let t = part["text"] as? String {
                out.append(t)
            }
        }
        return out
    }

    private func ensureOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OCError.http(http.statusCode)
        }
    }
}