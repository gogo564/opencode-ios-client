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

/// opencode server HTTP API 客户端（Basic Auth + SSE 流式）。
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
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
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

    struct OCRole: Codable {
        let role: String
        let name: String?
    }

    struct OCMessage: Identifiable {
        let id: String
        let role: String
        let content: String
        let isStreaming: Bool
        let error: Bool

        var displayName: String {
            role == "user" ? "我" : "Assistant"
        }
    }

    /// GET /session/:id/message 获取会话消息列表
    func messages(sessionID: String) async throws -> [OCMessage] {
        let request = try makeRequest("/session/\(sessionID)/message")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OCError.decoding
        }
        var result: [OCMessage] = []
        for item in arr {
            guard let info = item["info"] as? [String: Any], let mid = info["id"] as? String else { continue }
            let role = info["role"] as? String ?? "assistant"
            let parts = item["parts"] as? [[String: Any]] ?? []
            var text = ""
            for part in parts {
                let type = part["type"] as? String ?? ""
                if type == "text", let t = part["text"] as? String {
                    text += t
                }
            }
            if !text.isEmpty {
                result.append(OCMessage(id: mid, role: role, content: text, isStreaming: false, error: false))
            }
        }
        return result
    }

    // MARK: - 发送消息

    struct OCSendResult {
        let message: OCMessage
        let parts: [String]
    }

    /// POST /session/:id/message 发送消息。
    /// body: { parts: [{ type: "text", text: "..." }] }
    /// 返回的是 SSE 流，用 bytes(for:) 逐行增量读取，并把已生成的文本通过 onText 回调
    /// （避免 data(for:) 一直等到流关闭才返回，导致界面长时间转圈）。
    func sendMessage(
        sessionID: String,
        text: String,
        onText: @escaping (String) -> Void = { _ in }
    ) async throws -> OCSendResult {
        var request = try makeRequest("/session/\(sessionID)/message", method: "POST")
        let body: [String: Any] = [
            "parts": [
                ["type": "text", "text": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try ensureOK(response)

        var lastText = ""
        do {
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else { continue }
                let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]" else { continue }
                if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    if let part = json["part"] as? [String: Any],
                       let pt = part["text"] as? String {
                        lastText = pt
                    } else if let pt = json["text"] as? String {
                        lastText = lastText.isEmpty ? pt : lastText + pt
                    } else if let pc = json["content"] as? String {
                        lastText = lastText.isEmpty ? pc : lastText + pc
                    }
                    onText(lastText)
                }
            }
        } catch {}

        guard !lastText.isEmpty else {
            throw OCError.decoding
        }
        let msg = OCMessage(id: UUID().uuidString, role: "assistant", content: lastText, isStreaming: false, error: false)
        return OCSendResult(message: msg, parts: [lastText])
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
