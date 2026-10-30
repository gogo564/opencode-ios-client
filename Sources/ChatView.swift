import SwiftUI
import UIKit
import Combine

/// 聊天页可能弹出的交互
enum ChatSheet: Identifiable {
    case permission(OpenCodeClient.OCPermission)
    case form(OpenCodeClient.OCForm)
    case rename
    case photo
    case camera
    case files

    var id: String {
        switch self {
        case .permission(let p): return "p-\(p.id)"
        case .form(let f): return "f-\(f.id)"
        case .rename: return "rename"
        case .photo: return "photo"
        case .camera: return "camera"
        case .files: return "files"
        }
    }
}

/// 待发送的附件（图片以 data URI 提交）
struct PendingAttachment: Identifiable {
    let id = UUID()
    let name: String
    let uri: String
    let preview: UIImage?
}

/// 点击缩略图后全屏查看
struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
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
    @State private var queued: [OpenCodeClient.OCInboxMessage] = []
    @State private var attachments: [PendingAttachment] = []
    @State private var previewImage: PreviewImage?
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
            inputBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    activeSheet = .rename
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
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
        .fullScreenCover(item: $previewImage) { item in
            FullImageView(image: item.image)
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
                        MessageBubble(message: msg) { image in
                            previewImage = PreviewImage(image: image)
                        }
                        .id(msg.id)
                    }

                    if let streaming {
                        MessageBubble(message: streaming) { image in
                            previewImage = PreviewImage(image: image)
                        }
                        .id("streaming")
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
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                // 键盘弹起后列表可视高度变小，把最后的内容顶到输入框上方
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy)
                }
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
        VStack(spacing: 8) {
            if !queued.isEmpty { queuedBar }
            if !attachments.isEmpty { attachmentBar }

            HStack(spacing: 8) {
                Menu {
                    Button {
                        openPicker(.photo)
                    } label: {
                        Label("从相册选择图片", systemImage: "photo")
                    }
                    Button {
                        openPicker(.camera)
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    Button {
                        activeSheet = .files
                    } label: {
                        Label("引用项目文件", systemImage: "doc.text.magnifyingglass")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                }

                InputTextField(text: $input, placeholder: "输入消息…") {
                    send(delivery: nil)
                }
                .frame(height: 34)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 17)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )

                if isStreaming {
                    Menu {
                        Button {
                            send(delivery: "steer")
                        } label: {
                            Label("插话（立即发送）", systemImage: "arrow.up.circle")
                        }
                        Button {
                            send(delivery: "queue")
                        } label: {
                            Label("排队到下一轮", systemImage: "tray.and.arrow.down")
                        }
                        Divider()
                        Button(role: .destructive) {
                            stop()
                        } label: {
                            Label("停止生成", systemImage: "stop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 28))
                    }
                } else {
                    Button {
                        send(delivery: nil)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                    .disabled(canSend == false)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(height: inputBarHeight)
        .background(Color(uiColor: .systemBackground))
    }

    /// 输入栏固定高度：基础一行 + 附件行 + 排队行，避免聚焦/键盘时被拉伸
    private var inputBarHeight: CGFloat {
        var height: CGFloat = 54
        if !attachments.isEmpty { height += 42 }
        if !queued.isEmpty { height += 42 + CGFloat(queued.count) * 18 }
        return height
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: - 排队与附件

    private var queuedBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "tray.full").font(.caption2)
                Text("排队中 \(queued.count) 条（当前回复结束后自动发送）").font(.caption2)
                Spacer()
            }
            .foregroundColor(.secondary)

            ForEach(queued) { item in
                HStack(spacing: 6) {
                    Text(item.text.isEmpty ? "（附件）" : item.text)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        removeQueued(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .frame(height: 34 + CGFloat(queued.count) * 18)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(8)
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    HStack(spacing: 4) {
                        if let preview = item.preview {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipped()
                                .cornerRadius(4)
                        } else {
                            Image(systemName: "doc").font(.caption2)
                        }
                        Text(item.name).font(.caption2).lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(6)
                }
            }
        }
        .frame(height: 34)
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
            await refreshQueued()
            await refreshInteractions()
        }
        pollTask?.cancel()
        pollTask = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                tick += 1
                await pollLive()
                if tick % 3 == 0 {
                    await refreshQueued()
                    await refreshInteractions()
                }
            }
        }
    }

    /// 流式期间轮询最新消息：经反代后 SSE 不一定实时，靠轮询保证能看到工作状态
    private func pollLive() async {
        guard isStreaming else { return }
        do {
            let page = try await client.messages(sessionID: session.id, limit: 12)
            await MainActor.run {
                let existing = Set(messages.map { $0.id })
                let newOnes = page.messages.filter { !existing.contains($0.id) }
                if !newOnes.isEmpty {
                    let incomingUserTexts = Set(newOnes.filter { $0.kind == .user }.map { $0.text })
                    messages.removeAll { $0.id.hasPrefix("local-") && incomingUserTexts.contains($0.text) }
                    messages.append(contentsOf: newOnes)
                }
                for msg in page.messages where msg.isStreaming {
                    if let index = messages.firstIndex(where: { $0.id == msg.id }) {
                        messages[index] = msg
                    }
                }
                streaming = nil
                if let last = page.messages.last, last.kind == .assistant, !last.isStreaming {
                    isStreaming = false
                }
            }
        } catch {}
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
                if let last = page.messages.last, last.kind == .assistant, last.isStreaming {
                    isStreaming = true
                }
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

        case .rename:
            RenameSheet(title: title, onSave: { newTitle in
                activeSheet = nil
                rename(newTitle)
            }, onCancel: {
                activeSheet = nil
            })

        case .photo:
            ImagePicker(sourceType: .photoLibrary) { image in
                activeSheet = nil
                addAttachment(image)
            }

        case .camera:
            ImagePicker(sourceType: .camera) { image in
                activeSheet = nil
                addAttachment(image)
            }

        case .files:
            FileSearchSheet(onPick: { path in
                activeSheet = nil
                let spacer = input.isEmpty ? "" : " "
                input += "\(spacer)@\(path) "
            }, onCancel: {
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
            isStreaming = true
            Task { await pollLive() }

        case "session.execution.started":
            if sid == session.id { isStreaming = true }

        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.execution.cancelled":
            guard sid == session.id else { return }
            isStreaming = false
            streaming = nil
            Task { await loadMessages() }
            Task { await refreshQueued() }

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

    private func send(delivery: String?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments.map { OpenCodeClient.OCFileAttachment(uri: $0.uri, name: $0.name) }
        guard !text.isEmpty || !files.isEmpty else { return }

        let previews = attachments.compactMap { $0.preview }
        input = ""
        attachments = []
        errorMessage = nil
        let isQueue = delivery == "queue"
        let displayText = text.isEmpty ? "（附件）" : text
        let localID = "local-\(UUID().uuidString)"

        if !isQueue {
            messages.append(OpenCodeClient.OCMessage(id: localID, kind: .user, text: displayText, reasoning: "", tools: [], created: nowMs(), isStreaming: false, isError: false, images: previews))
            isStreaming = true
        }

        let model = availableModels.first { $0.id == config.selectedModel }
        Task {
            do {
                if let model {
                    try? await client.switchModel(sessionID: session.id, model: model)
                }
                let serverID = try await client.sendPrompt(sessionID: session.id, text: text, delivery: delivery, files: files)
                if isQueue {
                    await refreshQueued()
                } else if let serverID {
                    await MainActor.run {
                        if let index = messages.firstIndex(where: { $0.id == localID }) {
                            messages[index] = OpenCodeClient.OCMessage(id: serverID, kind: .user, text: displayText, reasoning: "", tools: [], created: nowMs(), isStreaming: false, isError: false, images: previews)
                        }
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

    private func refreshQueued() async {
        do {
            let list = try await client.inbox(sessionID: session.id)
            await MainActor.run { queued = list }
        } catch {}
    }

    private func removeQueued(_ item: OpenCodeClient.OCInboxMessage) {
        Task {
            try? await client.deleteInbox(sessionID: session.id, inboxID: item.id)
            await refreshQueued()
        }
    }

    private func rename(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
        Task { try? await client.renameSession(sessionID: session.id, title: trimmed) }
    }

    private func openPicker(_ sheet: ChatSheet) {
        if case .camera = sheet, !UIImagePickerController.isSourceTypeAvailable(.camera) {
            errorMessage = "这台设备没有可用的相机"
            return
        }
        activeSheet = sheet
    }

    private func addAttachment(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        let uri = "data:image/jpeg;base64," + data.base64EncodedString()
        let name = "image_\(attachments.count + 1).jpg"
        attachments.append(PendingAttachment(name: name, uri: uri, preview: image))
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
    var onTapImage: ((UIImage) -> Void)? = nil

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

                if !message.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { item in
                                Button {
                                    onTapImage?(item.element)
                                } label: {
                                    Image(uiImage: item.element)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 150, height: 150)
                                        .clipped()
                                        .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 300, height: 150, alignment: message.kind == .user ? .trailing : .leading)
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
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在处理…")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
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
