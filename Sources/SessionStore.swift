import Foundation

/// 会话列表状态管理。
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var sessions: [OpenCodeClient.OCSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeSessionID: String?

    private let client = OpenCodeClient.shared

    func refresh() async {
        guard ServerConfig.shared.isConfigured else {
            await MainActor.run { sessions = [] }
            return
        }
        await MainActor.run { isLoading = true; errorMessage = nil }
        do {
            let list = try await client.sessions()
            await MainActor.run {
                sessions = list
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func newSession() {
        Task {
            do {
                let session = try await client.createSession()
                await MainActor.run {
                    activeSessionID = session.id
                    sessions.insert(session, at: 0)
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    func delete(_ session: OpenCodeClient.OCSession) {
        Task {
            do {
                try await client.deleteSession(session.id)
                await MainActor.run {
                    sessions.removeAll { $0.id == session.id }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}
