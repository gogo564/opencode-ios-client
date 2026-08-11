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
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
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

    /// GET /session/:id/message 获取会话消息列表（按时间升序）。
    /// limit 为最近消息数（不含历史），before 为从某条消息之前继续分页（均可选）。
    func messages(sessionID: String, limit: Int? = nil, before: String? = nil) async throws -> [OCMessage] {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
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

    /// 发送消息（即时对话，兼容新旧版本服务器）。
    /// 使用 POST /session/:id/message 并流式读取响应：
    /// - 现代版本返回单段 JSON {info, parts}
    /// - 旧版本返回 SSE 事件流（text/event-stream），逐块回调文本
    /// 两种都支持，保证一定能收到回复。
    func sendMessage(
        sessionID: String,
        text: String,
        model: OCModel? = nil,
        onText: @escaping (String) -> Void = { _ in }
    ) async throws -> OCSendResult {
        var request = try makeRequest("/session/\(sessionID)/message", method: "POST")
        var body: [String: Any] = [
            "parts": [
                ["type": "text", "text": text]
            ]
        ]
        if let model {
            body["model"] = ["providerID": model.providerID, "modelID": model.modelID]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try ensureOK(response)

        var accumulated = ""
        var fullJSON = ""

        do {
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("data:") {
                    let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard !payload.isEmpty, payload != "[DONE]" else { continue }
                    switch parseEventText(payload) {
                    case .some(let result):
                        if !result.full.isEmpty {
                            accumulated = result.full
                            onText(accumulated)
                        } else if !result.delta.isEmpty {
                            accumulated += result.delta
                            onText(accumulated)
                        }
                    case .none:
                        break
                    }
                } else if t.hasPrefix("{") {
                    // 可能是不带 data: 前缀的整段 JSON（单段响应），累积拼接供整体解析
                    if accumulated.isEmpty {
                        fullJSON += t
                    }
                }
            }
        } catch {}

        // 1) 若已通过 SSE 拿到文本，直接返回
        if !accumulated.isEmpty {
            let msg = OCMessage(id: UUID().uuidString, role: "assistant", content: accumulated, isStreaming: false, error: false, completed: true)
            return OCSendResult(message: msg, parts: [accumulated])
        }

        // 2) 否则尝试整体 JSON {info, parts}
        if let json = try? JSONSerialization.jsonObject(with: Data(fullJSON.utf8)) as? [String: Any] {
            if let info = json["info"] as? [String: Any],
               let mid = info["id"] as? String {
                let role = info["role"] as? String ?? "assistant"
                let isError = info["error"] != nil
                let parts = parseParts(json["parts"] as? [[String: Any]] ?? [])
                let text = parts.joined()
                let msg = OCMessage(id: mid, role: role, content: text, isStreaming: false, error: isError, completed: true)
                return OCSendResult(message: msg, parts: parts)
            }
        }

        // 3) 尝试整段 SSE 文本兜底
        let sseText = mergeSSELines(fullJSON)
        if !sseText.isEmpty {
            let msg = OCMessage(id: UUID().uuidString, role: "assistant", content: sseText, isStreaming: false, error: false, completed: true)
            return OCSendResult(message: msg, parts: [sseText])
        }

        throw OCError.decoding
    }

    /// 解析 opencode 事件帧 JSON，提取 assistant 文本。
    /// -.full: 该 part 的完整文本（覆盖），-.delta: 增量文本（追加）。
    private func parseEventText(_ payload: String) -> (full: String, delta: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        // 新版事件：{ type: "message.part.updated", properties: { part: {…}, delta } }
        if let properties = obj["properties"] as? [String: Any] {
            if let part = properties["part"] as? [String: Any] {
                let type = part["type"] as? String ?? ""
                if type == "text", let pt = part["text"] as? String, !pt.isEmpty {
                    return (pt, "")
                }
                if type == "error", let error = part["error"] as? String {
                    return ("[错误] \(error)", "")
                }
            }
            if let delta = properties["delta"] as? String, !delta.isEmpty {
                return ("", delta)
            }
            return nil
        }
        // 旧格式：顶层 part/text/content
        if let part = obj["part"] as? [String: Any], part["type"] as? String == "text", let pt = part["text"] as? String, !pt.isEmpty {
            return (pt, "")
        }
        if let t = obj["text"] as? String, !t.isEmpty { return (t, "") }
        if let content = obj["content"] as? String, !content.isEmpty { return (content, "") }
        return nil
    }

    private func mergeSSELines(_ raw: String) -> String {
        var out = ""
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("data:") else { continue }
            let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                if let properties = json["properties"] as? [String: Any],
                   let part = properties["part"] as? [String: Any],
                   let pt = part["text"] as? String {
                    out = pt
                } else if let pt = json["text"] as? String {
                    out += pt
                } else if let pc = json["content"] as? String {
                    out += pc
                }
            }
        }
        return out
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