import SwiftUI

/// 单会话聊天界面（即时对话 + 模型选择）。
struct ChatView: View {
    let session: OpenCodeClient.OCSession
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var config: ServerConfig
    @State private var messages: [OpenCodeClient.OCMessage] = []
    @State private var input = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isStreaming = false
    @State private var streamingText = ""
    @State private var availableModels: [OpenCodeClient.OCModel] = []
    @State private var isModelsLoading = false

    private let client = OpenCodeClient.shared

    var body: some View {
        VStack(spacing: 0) {
            modelPicker
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await loadInitial() }
        }
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
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
            messages = try await client.messages(sessionID: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
                let result = try await client.sendMessage(
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
                    messages.append(result.message)
                }
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
