import Foundation
import Combine
import UIKit

enum OCError: LocalizedError {
    case invalidURL
    case http(Int)
    case notConfigured
    case decoding
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .http(let code):
            if code == 401 { return "认证失败：V2 的用户名固定为 opencode，请检查密码" }
            if code == 404 { return "接口不存在（HTTP 404），服务器可能不是 OpenCode V2" }
            return "服务器错误（HTTP \(code)）"
        case .notConfigured: return "请先在设置中填写服务器地址和密码"
        case .decoding: return "返回数据解析失败（服务器可能返回了网页而不是 JSON）"
        case .unauthorized: return "认证失败：V2 的用户名固定为 opencode，请检查密码"
        }
    }
}

/// OpenCode V2 服务器 HTTP API 客户端（Basic Auth）。
///
/// 与 V1 的差别：
/// - 所有接口前缀为 `/api`
/// - 发消息是 `POST /api/session/{id}/prompt`，回复通过 `GET /api/event` 事件流推送
/// - 权限确认、表单（选择题）分别走 `/api/permission/*`、`/api/session/{id}/form/*`
final class OpenCodeClient {
    static let shared = OpenCodeClient()
    private let config = ServerConfig.shared

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - 请求

    private func makeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
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
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        return request
    }

    private func perform(_ request: URLRequest, allowEmpty: Bool = true) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try ensureOK(response, data: data)
        return data
    }

    private func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw OCError.unauthorized }
        if http.statusCode >= 400 { throw OCError.http(http.statusCode) }
        // V2 的旧路径会回退成网页，这里提前识别，避免报难懂的解析错误
        if let prefix = String(data: data.prefix(1), encoding: .utf8), prefix == "<" {
            throw OCError.decoding
        }
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCError.decoding
        }
        return obj
    }

    private func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: - 数据模型

    struct OCModel: Identifiable, Hashable {
        let id: String            // Model.Ref.id（即 modelID）
        let modelID: String
        let providerID: String
        let name: String

        var displayName: String { name.isEmpty ? id : name }
    }

    struct OCSession: Identifiable, Hashable {
        let id: String
        let title: String?
        let created: Double
        let updated: Double
        let modelID: String?
        let providerID: String?

        var updatedDate: Date { Date(timeIntervalSince1970: updated / 1000) }
    }

    struct OCTool: Identifiable {
        let id: String
        let name: String
        let status: String      // streaming / running / completed / error
        let input: String
        let output: String
        let error: String?

        var isRunning: Bool { status == "running" || status == "streaming" }
        var isError: Bool { status == "error" }
    }

    struct OCMessage: Identifiable {
        enum Kind { case user, assistant }
        let id: String
        let kind: Kind
        var text: String
        var reasoning: String
        var tools: [OCTool]
        let created: Double
        var isStreaming: Bool
        var isError: Bool
        var errorText: String? = nil
        var images: [UIImage] = []

        var displayName: String { kind == .user ? "我" : "Assistant" }
    }

    struct OCMessagesPage {
        let messages: [OCMessage]      // 按时间升序
        let olderCursor: String?       // 继续往前翻的游标
    }

    struct OCPermission: Identifiable {
        let id: String
        let sessionID: String
        let action: String
        let resources: [String]
        let message: String?
    }

    struct OCOption: Identifiable, Hashable {
        let value: String
        let label: String
        let detail: String
        var id: String { value }
    }

    struct OCFormField: Identifiable {
        let key: String
        let title: String
        let description: String
        let type: String       // string / number / integer / boolean / multiselect / external
        let required: Bool
        let hidden: Bool
        let custom: Bool
        let conditional: Bool
        let options: [OCOption]
        let defaultValue: Any?
        let url: String

        var id: String { key }
    }

    struct OCForm: Identifiable {
        let id: String
        let sessionID: String
        let title: String
        let fields: [OCFormField]
    }

    /// prompt 的附件（图片走 data URI，文件走项目内相对路径）
    struct OCFileAttachment {
        let uri: String
        let name: String
    }

    /// 排队中的消息（delivery = steer / queue）
    struct OCInboxMessage: Identifiable {
        let id: String
        let text: String
        let delivery: String
    }

    /// 已保存的「始终允许」规则
    struct OCSavedPermission: Identifiable {
        let id: String
        let action: String
        let resource: String
    }

    // MARK: - 模型

    /// GET /api/model -> { location, data: [Model.Info] }
    func models() async throws -> [OCModel] {
        let data = try await perform(try makeRequest("/api/model"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        var result: [OCModel] = []
        for item in arr {
            guard let modelID = item["modelID"] as? String ?? item["id"] as? String else { continue }
            let providerID = item["providerID"] as? String ?? ""
            let enabled = item["enabled"] as? Bool ?? true
            guard enabled else { continue }
            let name = item["name"] as? String ?? modelID
            result.append(OCModel(id: modelID, modelID: modelID, providerID: providerID, name: name))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - 会话

    /// GET /api/session -> { data: [Session.Info], cursor }
    func sessions() async throws -> [OCSession] {
        let data = try await perform(try makeRequest("/api/session"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { parseSession($0) }
            .sorted { $0.updated > $1.updated }
    }

    private func parseSession(_ dict: [String: Any]) -> OCSession? {
        guard let id = dict["id"] as? String else { return nil }
        let time = dict["time"] as? [String: Any] ?? [:]
        let created = number(time["created"]) ?? 0
        let updated = number(time["updated"]) ?? created
        let model = dict["model"] as? [String: Any]
        return OCSession(
            id: id,
            title: dict["title"] as? String,
            created: created,
            updated: updated,
            modelID: model?["id"] as? String,
            providerID: model?["providerID"] as? String
        )
    }

    /// POST /api/session -> { data: Session.Info }
    func createSession(title: String? = nil) async throws -> OCSession {
        var body: [String: Any] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        let data = try await perform(try makeRequest("/api/session", method: "POST", body: body))
        let json = try dictionary(data)
        guard let dict = json["data"] as? [String: Any], let session = parseSession(dict) else {
            throw OCError.decoding
        }
        return session
    }

    /// DELETE /api/session/{id}
    func deleteSession(_ id: String) async throws {
        _ = try await perform(try makeRequest("/api/session/\(id)", method: "DELETE"))
    }

    /// PATCH /api/session/{id} { title } —— 重命名
    func renameSession(sessionID: String, title: String) async throws {
        _ = try await perform(try makeRequest("/api/session/\(sessionID)", method: "PATCH", body: ["title": title]))
    }

    /// 切换会话模型：POST /api/session/{id}/model { model: { id, providerID } }
    func switchModel(sessionID: String, model: OCModel) async throws {
        let body: [String: Any] = ["model": ["id": model.modelID, "providerID": model.providerID]]
        _ = try await perform(try makeRequest("/api/session/\(sessionID)/model", method: "POST", body: body))
    }

    // MARK: - 消息

    /// GET /api/session/{id}/message?limit=&order=desc&cursor=
    func messages(sessionID: String, limit: Int = 30, cursor: String? = nil) async throws -> OCMessagesPage {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "desc")
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await perform(try makeRequest("/api/session/\(sessionID)/message", query: query))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        var msgs: [OCMessage] = []
        for item in arr {
            if let m = parseMessage(item) { msgs.append(m) }
        }
        msgs.sort { $0.created < $1.created }
        let cursorDict = json["cursor"] as? [String: Any] ?? [:]
        let older = cursorDict["previous"] as? String
        return OCMessagesPage(messages: msgs, olderCursor: older)
    }

    private func parseMessage(_ dict: [String: Any]) -> OCMessage? {
        guard let id = dict["id"] as? String, let type = dict["type"] as? String else { return nil }
        let time = dict["time"] as? [String: Any] ?? [:]
        let created = number(time["created"]) ?? 0
        switch type {
        case "user":
            let payload = dict["payload"] as? [String: Any] ?? [:]
            let text = (payload["text"] as? String) ?? (dict["text"] as? String) ?? ""
            let files = (dict["files"] as? [[String: Any]]) ?? (payload["files"] as? [[String: Any]]) ?? []
            var images: [UIImage] = []
            for file in files {
                guard let mime = file["mime"] as? String, mime.hasPrefix("image/"),
                      let base64 = file["data"] as? String,
                      let data = Data(base64Encoded: base64),
                      let image = UIImage(data: data) else { continue }
                images.append(image)
            }
            return OCMessage(id: id, kind: .user, text: text, reasoning: "", tools: [], created: created, isStreaming: false, isError: false, images: images)
        case "assistant":
            var text = ""
            var reasoning = ""
            var tools: [OCTool] = []
            for item in dict["content"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "text":
                    text += item["text"] as? String ?? ""
                case "reasoning":
                    reasoning += item["text"] as? String ?? ""
                case "tool":
                    if let tool = parseTool(item) { tools.append(tool) }
                default:
                    break
                }
            }
            let error = dict["error"] as? [String: Any]
            return OCMessage(
                id: id,
                kind: .assistant,
                text: text,
                reasoning: reasoning,
                tools: tools,
                created: created,
                isStreaming: time["completed"] == nil,
                isError: error != nil,
                errorText: error?["message"] as? String
            )
        default:
            // idle / system / compaction 等不参与聊天气泡
            return nil
        }
    }

    private func parseTool(_ dict: [String: Any]) -> OCTool? {
        guard let id = dict["id"] as? String else { return nil }
        let name = dict["name"] as? String ?? "tool"
        let state = dict["state"] as? [String: Any] ?? [:]
        let status = state["status"] as? String ?? "completed"
        var inputText = ""
        if let input = state["input"], JSONSerialization.isValidJSONObject(input),
           let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            inputText = s
        }
        var output = ""
        for item in state["content"] as? [[String: Any]] ?? [] {
            if let t = item["text"] as? String { output += t }
            else if let t = item["value"] as? String { output += t }
        }
        let error = (state["error"] as? [String: Any])?["message"] as? String
        return OCTool(id: id, name: name, status: status, input: inputText, output: output, error: error)
    }

    /// POST /api/session/{id}/prompt { text, delivery?, files? } -> { data: userMessage }
    @discardableResult
    func sendPrompt(sessionID: String, text: String, delivery: String? = nil, files: [OCFileAttachment] = []) async throws -> String? {
        var body: [String: Any] = ["text": text]
        if let delivery, !delivery.isEmpty { body["delivery"] = delivery }
        if !files.isEmpty { body["files"] = files.map { ["uri": $0.uri, "name": $0.name] } }
        let data = try await perform(try makeRequest("/api/session/\(sessionID)/prompt", method: "POST", body: body))
        let json = try? dictionary(data)
        let message = json?["data"] as? [String: Any]
        return message?["id"] as? String
    }

    /// POST /api/session/{id}/interrupt
    func interrupt(sessionID: String) async throws {
        _ = try await perform(try makeRequest("/api/session/\(sessionID)/interrupt", method: "POST", body: [:]))
    }

    // MARK: - 排队消息（inbox）

    /// GET /api/session/{id}/inbox -> { data: [Inbox.Info] }
    func inbox(sessionID: String) async throws -> [OCInboxMessage] {
        let data = try await perform(try makeRequest("/api/session/\(sessionID)/inbox"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String, (item["type"] as? String) == "user" else { return nil }
            let payload = item["payload"] as? [String: Any] ?? [:]
            return OCInboxMessage(
                id: id,
                text: payload["text"] as? String ?? "",
                delivery: item["delivery"] as? String ?? "queue"
            )
        }
    }

    /// DELETE /api/session/{id}/inbox/{inboxID}
    func deleteInbox(sessionID: String, inboxID: String) async throws {
        _ = try await perform(try makeRequest("/api/session/\(sessionID)/inbox/\(inboxID)", method: "DELETE"))
    }

    // MARK: - 已保存的授权规则

    /// GET /api/permission/saved
    func savedPermissions() async throws -> [OCSavedPermission] {
        let data = try await perform(try makeRequest("/api/permission/saved"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return OCSavedPermission(
                id: id,
                action: item["action"] as? String ?? "",
                resource: item["resource"] as? String ?? ""
            )
        }
    }

    /// DELETE /api/permission/saved/{id}
    func deleteSavedPermission(id: String) async throws {
        _ = try await perform(try makeRequest("/api/permission/saved/\(id)", method: "DELETE"))
    }

    // MARK: - 文件搜索（@引用）

    /// GET /api/fs/find?query=&type=file&limit=
    func findFiles(query: String, limit: Int = 30) async throws -> [String] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "file"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let data = try await perform(try makeRequest("/api/fs/find", query: q))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { $0["path"] as? String }
    }

    // MARK: - 权限（授权确认）

    /// GET /api/permission/request -> { location, data: [Permission.Request] }
    func permissions() async throws -> [OCPermission] {
        let data = try await perform(try makeRequest("/api/permission/request"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String, let sessionID = item["sessionID"] as? String else { return nil }
            return OCPermission(
                id: id,
                sessionID: sessionID,
                action: item["action"] as? String ?? "操作",
                resources: item["resources"] as? [String] ?? [],
                message: item["message"] as? String
            )
        }
    }

    /// POST /api/session/{sid}/permission/{rid}/reply { decision: once|always|reject }
    func replyPermission(_ request: OCPermission, decision: String, message: String? = nil) async throws {
        var body: [String: Any] = ["decision": decision]
        if let message, !message.isEmpty { body["message"] = message }
        _ = try await perform(try makeRequest("/api/session/\(request.sessionID)/permission/\(request.id)/reply", method: "POST", body: body))
    }

    // MARK: - 表单（选择对话框）

    /// GET /api/session/{id}/form -> { data: [Form.Info] }
    func forms(sessionID: String) async throws -> [OCForm] {
        let data = try await perform(try makeRequest("/api/session/\(sessionID)/form"))
        let json = try dictionary(data)
        let arr = json["data"] as? [[String: Any]] ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let fields = (item["fields"] as? [[String: Any]] ?? []).compactMap { parseField($0) }
            return OCForm(
                id: id,
                sessionID: item["sessionID"] as? String ?? sessionID,
                title: item["title"] as? String ?? "请选择",
                fields: fields
            )
        }
    }

    private func parseField(_ dict: [String: Any]) -> OCFormField? {
        guard let key = dict["key"] as? String, let type = dict["type"] as? String else { return nil }
        let opts = (dict["options"] as? [[String: Any]] ?? []).map { o in
            OCOption(
                value: o["value"] as? String ?? "",
                label: o["label"] as? String ?? (o["value"] as? String ?? ""),
                detail: o["description"] as? String ?? ""
            )
        }
        return OCFormField(
            key: key,
            title: dict["title"] as? String ?? key,
            description: dict["description"] as? String ?? "",
            type: type,
            required: dict["required"] as? Bool ?? false,
            hidden: dict["hidden"] as? Bool ?? false,
            custom: dict["custom"] as? Bool ?? false,
            conditional: (dict["when"] as? [[String: Any]])?.isEmpty == false,
            options: opts,
            defaultValue: dict["default"],
            url: dict["url"] as? String ?? ""
        )
    }

    /// POST /api/session/{sid}/form/{fid}/reply { answer: { key: value } }
    func replyForm(_ form: OCForm, answer: [String: Any]) async throws {
        let body: [String: Any] = ["answer": answer]
        _ = try await perform(try makeRequest("/api/session/\(form.sessionID)/form/\(form.id)/reply", method: "POST", body: body))
    }
}

// MARK: - 事件流

struct OCEvent {
    let id: String
    let type: String
    let data: [String: Any]
}

/// `GET /api/event` 的 SSE 长连接（自动重连）。
final class OCEventStream: ObservableObject {
    private var task: Task<Void, Never>?

    func start(onEvent: @escaping (OCEvent) -> Void, onState: @escaping (Bool) -> Void = { _ in }) {
        stop()
        guard let url = URL(string: ServerConfig.shared.normalizedBaseURL + "/api/event") else { return }
        let auth = ServerConfig.shared.authHeader
        task = Task.detached(priority: .background) {
            var attempt = 0
            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3600
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        if http.statusCode == 401 { onState(false); return }
                        throw URLError(.badServerResponse)
                    }
                    attempt = 0
                    onState(true)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty,
                              let raw = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
                        let event = OCEvent(
                            id: obj["id"] as? String ?? UUID().uuidString,
                            type: obj["type"] as? String ?? "",
                            data: obj["data"] as? [String: Any] ?? [:]
                        )
                        onEvent(event)
                    }
                } catch {
                    // 断线（含反代 60s 超时）后自动重连
                }
                onState(false)
                if Task.isCancelled { break }
                attempt += 1
                let delay = min(Double(attempt) * 1.5, 8.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
