import SwiftUI
import UIKit

/// 聊天页可能弹出的交互
enum ChatSheet: Identifiable {
    case permission(OpenCodeClient.OCPermission)
    case form(OpenCodeClient.OCForm)

    var id: String {
        switch self {
        case .permission(let p): return "p-\(p.id)"
        case .form(let f): return "f-\(f.id)"
        }
    }
}

/// 单会话聊天界面（V2：prompt + /api/event 事件流 + 权限/表单弹窗）。
struct ChatView: View {
    let session: OpenCodeClient.OCSession

    @EnvironmentObject private var config: ServerConfig
    @State private var messages: [OpenCodeClient.OCMessage] = []
    @State private var streaming: OpenCodeClient.OCMessage?
    @State private var input = ""
    @State private var isStreaming = false
    @State private var isConnected = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var olderCursor: String?
    @State private var errorMessage: String?
    @State private var availableModels: [OpenCodeClient.OCModel] = []
    @State private var isModelsLoading = false
    @State private var activeSheet: ChatSheet?
    @State private var dismissedPermissionIDs: Set<String> = []
    @State private var dismissedFormIDs: Set<String> = []
    @State private var title: String
    @State private var pollTask: Task<Void, Never>?

    private let client = OpenCodeClient.shared
    @StateObject private var stream = OCEventStream()
    private let pageSize = 40

    init(session: OpenCodeClient.OCSession) {
        self.session = session
        _title = State(initialValue: session.title ?? "会话")
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { start() }
        .onDisappear {
            stream.stop()
            pollTask?.cancel()
        }
        .onChange(of: config.selectedModel) { newValue in
            switchModel(newValue)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
        }
    }

    // MARK: - 顶栏（模型 / 连接状态）

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            if isModelsLoading {
                ProgressView().controlSize(.small)
                Text("加载模型…").font(.caption).foregroundColor(.secondary)
            } else if availableModels.isEmpty {
                Text("无可用模型").font(.caption).foregroundColor(.secondary)
            } else {
                Menu {
                    ForEach(availableModels) { model in
                        Button {
                            config.selectedModel = model.id
                        } label: {
                            if model.id == config.selectedModel {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(currentModelName).font(.caption).foregroundColor(.primary)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }
            }
            Spacer()
            if !isConnected {
                Text("重连中…").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
    }

    private var currentModelName: String {
        if let m = availableModels.first(where: { $0.id == config.selectedModel }) { return m.displayName }
        return availableModels.first?.displayName ?? "模型"
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if olderCursor != nil {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            if isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("加载更早消息").font(.caption).foregroundColor(.accentColor)
                            }
                        }
                        .padding(.top, 8)
                    } else if !messages.isEmpty {
                        Text("--------- 对话开始 ---------")
                            .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                    }

                    if messages.isEmpty && streaming == nil && !isStreaming {
                        Text("发送消息开始对话")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    }

                    ForEach(messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }

                    if let streaming {
                        MessageBubble(message: streaming).id("streaming")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: streaming?.text) { _ in
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if streaming != nil {
            withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
        } else if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("输入消息…", text: $input)
                .textFieldStyle(.roundedBorder)
                .disabled(isStreaming)
                .onSubmit { send() }

            if isStreaming {
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                }
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - 启动与加载

    private func start() {
        guard config.isConfigured else { return }
        stream.start(onEvent: { event in
            Task { @MainActor in handle(event) }
        }, onState: { ok in
            Task { @MainActor in isConnected = ok }
        })
        Task {
            await loadModels()
            await loadMessages()
            await refreshInteractions()
        }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                await refreshInteractions()
            }
        }
    }

    private func loadModels() async {
        await MainActor.run { isModelsLoading = true }
        do {
            let list = try await client.models()
            await MainActor.run {
                availableModels = list
                isModelsLoading = false
                if config.selectedModel.isEmpty || !list.contains(where: { $0.id == config.selectedModel }) {
                    config.selectedModel = session.modelID ?? list.first?.id ?? ""
                }
            }
        } catch {
            await MainActor.run { isModelsLoading = false }
        }
    }

    private func loadMessages() async {
        await MainActor.run { isLoading = true }
        do {
            let page = try await client.messages(sessionID: session.id, limit: pageSize)
            await MainActor.run {
                messages = page.messages
                olderCursor = page.olderCursor
                errorMessage = nil
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadOlder() async {
        guard let cursor = olderCursor, !isLoadingMore else { return }
        await MainActor.run { isLoadingMore = true }
        do {
            let page = try await client.messages(sessionID: session.id, limit: pageSize, cursor: cursor)
            await MainActor.run {
                let existing = Set(messages.map { $0.id })
                let newOnes = page.messages.filter { !existing.contains($0.id) }
                messages = newOnes + messages
                olderCursor = page.olderCursor
                isLoadingMore = false
            }
        } catch {
            await MainActor.run {
                olderCursor = nil
                isLoadingMore = false
            }
        }
    }

    // MARK: - 交互（权限 / 表单）

    private func refreshInteractions() async {
        guard activeSheet == nil else { return }
        do {
            let permissions = try await client.permissions()
                .filter { $0.sessionID == session.id && !dismissedPermissionIDs.contains($0.id) }
            if let request = permissions.first {
                await MainActor.run { activeSheet = .permission(request) }
                return
            }
        } catch {}
        do {
            let forms = try await client.forms(sessionID: session.id)
                .filter { !dismissedFormIDs.contains($0.id) }
            if let form = forms.first {
                await MainActor.run { activeSheet = .form(form) }
            }
        } catch {}
    }

    @ViewBuilder
    private func sheetView(_ sheet: ChatSheet) -> some View {
        switch sheet {
        case .permission(let request):
            PermissionSheet(request: request) { decision in
                dismissedPermissionIDs.insert(request.id)
                activeSheet = nil
                Task {
                    do {
                        try await client.replyPermission(request, decision: decision)
                    } catch {
                        await MainActor.run { errorMessage = error.localizedDescription }
                    }
                    await refreshInteractions()
                }
            } onDismiss: {
                dismissedPermissionIDs.insert(request.id)
                activeSheet = nil
            }
        case .form(let form):
            FormSheet(form: form, onSubmit: { answer in
                dismissedFormIDs.insert(form.id)
                activeSheet = nil
                Task {
                    do {
                        try await client.replyForm(form, answer: answer)
                    } catch {
                        await MainActor.run { errorMessage = error.localizedDescription }
                    }
                    await refreshInteractions()
                }
            }, onCancel: {
                dismissedFormIDs.insert(form.id)
                activeSheet = nil
            })
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: OCEvent) {
        let sid = event.data["sessionID"] as? String
        switch event.type {
        case "session.text.started":
            guard sid == session.id else { return }
            let mid = event.data["assistantMessageID"] as? String ?? "streaming"
            if streaming?.id != mid {
                streaming = OpenCodeClient.OCMessage(id: mid, kind: .assistant, text: "", reasoning: "", tools: [], created: nowMs(), isStreaming: true, isError: false)
            }
            isStreaming = true

        case "session.text.delta":
            guard sid == session.id, let delta = event.data["delta"] as? String else { return }
            let mid = event.data["assistantMessageID"] as? String ?? "streaming"
            var msg = streaming ?? OpenCodeClient.OCMessage(id: mid, kind: .assistant, text: "", reasoning: "", tools: [], created: nowMs(), isStreaming: true, isError: false)
            msg.text += delta
            streaming = msg
            isStreaming = true

        case "session.text.ended":
            guard sid == session.id else { return }
            if let full = event.data["text"] as? String {
                var msg = streaming ?? OpenCodeClient.OCMessage(id: event.data["assistantMessageID"] as? String ?? "streaming", kind: .assistant, text: "", reasoning: "", tools: [], created: nowMs(), isStreaming: true, isError: false)
                msg.text = full
                streaming = msg
            }

        case "session.execution.started":
            if sid == session.id { isStreaming = true }

        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.execution.cancelled":
            guard sid == session.id else { return }
            isStreaming = false
            streaming = nil
            Task { await loadMessages() }

        case "session.renamed":
            if sid == session.id, let newTitle = event.data["title"] as? String { title = newTitle }

        default:
            if event.type.contains("permission") || event.type.contains("form") {
                if sid == nil || sid == session.id {
                    Task { await refreshInteractions() }
                }
            }
        }
    }

    // MARK: - 发送 / 停止 / 切模型

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        errorMessage = nil
        let localID = "local-\(UUID().uuidString)"
        messages.append(OpenCodeClient.OCMessage(id: localID, kind: .user, text: text, reasoning: "", tools: [], created: nowMs(), isStreaming: false, isError: false))
        isStreaming = true
        let model = availableModels.first { $0.id == config.selectedModel }
        Task {
            do {
                if let model {
                    try? await client.switchModel(sessionID: session.id, model: model)
                }
                let serverID = try await client.sendPrompt(sessionID: session.id, text: text)
                await MainActor.run {
                    if let serverID, let index = messages.firstIndex(where: { $0.id == localID }) {
                        messages[index] = OpenCodeClient.OCMessage(id: serverID, kind: .user, text: text, reasoning: "", tools: [], created: nowMs(), isStreaming: false, isError: false)
                    }
                }
            } catch {
                await MainActor.run {
                    isStreaming = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stop() {
        Task {
            do {
                try await client.interrupt(sessionID: session.id)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isStreaming = false }
        }
    }

    private func switchModel(_ id: String) {
        guard let model = availableModels.first(where: { $0.id == id }) else { return }
        Task { try? await client.switchModel(sessionID: session.id, model: model) }
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: OpenCodeClient.OCMessage

    var body: some View {
        HStack {
            if message.kind == .user { Spacer(minLength: 40) }
            VStack(alignment: message.kind == .user ? .trailing : .leading, spacing: 6) {
                Text(message.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !message.reasoning.isEmpty {
                    ReasoningBubble(text: message.reasoning)
                }

                if !message.text.isEmpty {
                    Text(attributed(message.text))
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(message.kind == .user ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground))
                        )
                } else if message.isStreaming {
                    Text("…")
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground)))
                }

                ForEach(message.tools) { tool in
                    ToolRow(tool: tool)
                }

                if message.isError {
                    Text(message.errorText ?? "回复失败")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            if message.kind != .user { Spacer(minLength: 40) }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct ReasoningBubble: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain").font(.caption2)
                    Text(expanded ? "思考过程（点击收起）" : "思考过程（点击展开）").font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRow: View {
    let tool: OpenCodeClient.OCTool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(tool.name).font(.caption).bold()
                Text(statusText).font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button(expanded ? "收起" : "详情") {
                    withAnimation { expanded.toggle() }
                }
                .font(.caption2)
            }
            if expanded {
                if !tool.input.isEmpty {
                    Text(tool.input)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                }
                if !tool.output.isEmpty {
                    Text(String(tool.output.prefix(4000)))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                if let error = tool.error {
                    Text(error).font(.caption2).foregroundColor(.red)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemBackground)))
    }

    private var icon: String {
        if tool.isError { return "exclamationmark.triangle.fill" }
        if tool.isRunning { return "hourglass" }
        return "wrench.and.screwdriver.fill"
    }

    private var color: Color {
        if tool.isError { return .red }
        if tool.isRunning { return .orange }
        return .accentColor
    }

    private var statusText: String {
        switch tool.status {
        case "streaming": return "准备中"
        case "running": return "运行中"
        case "completed": return "完成"
        case "error": return "失败"
        default: return tool.status
        }
    }
}
