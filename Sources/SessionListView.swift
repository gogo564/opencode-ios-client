import SwiftUI

/// 会话列表。
struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var config: ServerConfig

    var body: some View {
        Group {
            if !config.isConfigured {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("尚未配置服务器")
                        .font(.headline)
                    Text("请在右上角设置中填写 OpenCode 服务器地址和密码")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.sessions.isEmpty {
                VStack(spacing: 12) {
                    Text("连接失败")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("重试") {
                        Task { await store.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无会话")
                        .font(.headline)
                    Text("点击右上角新建会话")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.sessions) { session in
                        NavigationLink(destination: ChatView(session: session)
                            .environmentObject(store)) {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            Task { await store.refresh() }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            if index < store.sessions.count {
                store.delete(store.sessions[index])
            }
        }
    }
}

struct SessionRow: View {
    let session: OpenCodeClient.OCSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title ?? "未命名会话")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(session.id)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
