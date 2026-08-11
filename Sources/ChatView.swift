import SwiftUI

/// 单会话聊天界面（即时对话 + 模型选择）。
struct ChatView: View {
    let session: OpenCodeClient.OCSession
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var config: ServerConfig
    @State private var messages: [OpenCodeClient.OCMessage] = []
    @State private var input = ""
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMoreHistory = true
    @State private var errorMessage: String?
    @State private var isStreaming = false
    @State private var streamingText = ""
    @State private var availableModels: [OpenCodeClient.OCModel] = []
    @State private var isModelsLoading = false
    @State private var pendingCommand: String?

    private let client = OpenCodeClient.shared
    private let pageSize = 30

    var body: some View {
        VStack(spacing: 0) {
            modelPicker
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("压缩上下文 (/compact)") {
                        pendingCommand = "/compact"
                    }
                    Button("新建会话 (/new)") {
                        pendingCommand = "/new"
                    }
                    Button("清空本会话 (/clear)") {
                        pendingCommand = "/clear"
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").accessibilityLabel("会话工具")
                }
                .disabled(isStreaming)
            }
        }
        .confirmationDialog(
            pendingCommandConfirmTitle,
            isPresented: commandDialogPresented,
            titleVisibility: .visible
        ) {
            Button("确认发送 \(pendingCommand ?? "")", role: .destructive) {
                sendCommand(pendingCommand ?? "")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingCommandConfirmMessage)
        }
        .onAppear {
            Task { await loadInitial() }
        }
    }

    private var pendingCommandConfirmTitle: String {
        switch pendingCommand {
        case "/compact": return "压缩上下文"
        case "/new": return "新建会话"
        case "/clear": return "清空本会话"
        default: return "会话工具"
        }
    }

    private var pendingCommandConfirmMessage: String {
        switch pendingCommand {
        case "/compact": return "把本会话历史压缩为摘要，保留话题并加快后续回复"
        case "/new": return "开启全新空白会话，当前会话仍会保留"
        case "/clear": return "清除本会话全部历史记录"
        default: return ""
        }
    }

    private func sendCommand(_ command: String) {
        input = command
        send()
    }

    private var modelPicker: some View {
        HStack {
            if isModelsLoading {
                ProgressView()
                    .controlSize(.small)
                Text("加载模型…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if availableModels.isEmpty {
                Text("当前服务器无可用模型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else if let selected = currentModel {
                Text("模型：\(selected.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Picker("选择模型", selection: Binding(
                        get: { config.selectedModel },
                        set: { config.selectedModel = $0 }
                    )) {
                        ForEach(availableModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 18))
                }
            } else {
                Text("加载模型失败")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("重试") { Task { await loadModels() } }
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    private var currentModel: OpenCodeClient.OCModel? {
        availableModels.first { $0.id == config.selectedModel }
    }

    private var commandDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingCommand != nil },
            set: { if !$0 { pendingCommand = nil } }
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !hasMoreHistory {
                        Text("--------- 对话开始 ---------")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    } else {
                        Button {
                            Task { await loadOlderMessages() }
                        } label: {
                            if isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("加载更早消息")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.top, 8)
                    }
                    if let errorMessage, errorMessage.isEmpty == false {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                    }
                    if messages.isEmpty && !isStreaming {
                        Text("发送消息开始对话")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if isStreaming {
                        MessageBubble(
                            message: OpenCodeClient.OCMessage(
                                id: "streaming",
                                role: "assistant",
                                content: streamingText,
                                isStreaming: true,
                                error: false,
                                completed: false
                            )
                        )
                        .id("streaming")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: streamingText) { _ in
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("输入消息…", text: $input)
                .textFieldStyle(.roundedBorder)
                .disabled(isStreaming)
                .onSubmit { send() }
            Button(action: send) {
                if isLoading {
                    ProgressView()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStreaming)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    @MainActor
    private func loadInitial() async {
        async let models: Void = loadModelsIfNeeded()
        async let msgs: Void = loadMessages()
        _ = await (models, msgs)
    }

    @MainActor
    private func loadModelsIfNeeded() async {
        guard availableModels.isEmpty else { return }
        await loadModels()
    }

    @MainActor
    private func loadModels() async {
        isModelsLoading = true
        defer { isModelsLoading = false }
        do {
            let list = try await client.models()
            availableModels = list
            if config.selectedModel.isEmpty || !list.contains(where: { $0.id == config.selectedModel }) {
                config.selectedModel = list.first?.id ?? ""
            }
        } catch {
            // 模型列表失败不阻塞聊天
        }
    }

    @MainActor
    private func loadMessages() async {
        isLoading = true
        errorMessage = nil
        do {
            let latest = try await client.messages(sessionID: session.id, limit: pageSize)
            messages = latest
            hasMoreHistory = latest.count >= pageSize
            // 加载到更早的历史（如果有），让列表完整
            await loadOlderMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func loadOlderMessages() async {
        guard hasMoreHistory, !isLoadingMore, let before = messages.first?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let older = try await client.messages(sessionID: session.id, limit: pageSize, before: before)
            hasMoreHistory = older.count >= pageSize
            // 去重合并，保持时间升序（旧的在前）
            let existing = Set(messages.map { $0.id })
            let newOnes = older.filter { !existing.contains($0.id) }
            messages = newOnes + messages
        } catch {
            // 静默：可能是没有更早消息了
            hasMoreHistory = false
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        Task {
            await MainActor.run {
                messages.append(OpenCodeClient.OCMessage(
                    id: UUID().uuidString, role: "user", content: text, isStreaming: false, error: false, completed: true
                ))
                isStreaming = true
                streamingText = ""
                errorMessage = nil
            }
            do {
                let model = availableModels.first { $0.id == config.selectedModel }
                _ = try await client.sendMessage(
                    sessionID: session.id,
                    text: text,
                    model: model
                ) { chunk in
                    Task { @MainActor in
                        streamingText = chunk
                    }
                }
                await MainActor.run {
                    isStreaming = false
                    streamingText = ""
                    // 以服务器保存的消息为准，重新加载列表（避免本地乐观消息与服务器重复）
                    messages.removeLast()
                }
                await loadMessages()
            } catch {
                await MainActor.run {
                    isStreaming = false
                    streamingText = ""
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: OpenCodeClient.OCMessage

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer(minLength: 50)
            }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if message.error {
                    Text("回复失败")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.role == "user" ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                    )
                    .foregroundColor(.primary)
            }
            if message.role != "user" {
                Spacer(minLength: 50)
            }
        }
    }
}
