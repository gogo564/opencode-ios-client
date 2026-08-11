import SwiftUI

/// 单会话聊天界面。
struct ChatView: View {
    let session: OpenCodeClient.OCSession
    @EnvironmentObject private var store: SessionStore
    @State private var messages: [OpenCodeClient.OCMessage] = []
    @State private var input = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isStreaming = false
    @State private var streamingText = ""

    private let client = OpenCodeClient.shared

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await loadMessages() } }
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
                                error: false
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
                    id: UUID().uuidString, role: "user", content: text, isStreaming: false, error: false
                ))
                isStreaming = true
                streamingText = ""
                errorMessage = nil
            }
            do {
                let result = try await client.sendMessage(sessionID: session.id, text: text)
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
                Text(message.content)
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
