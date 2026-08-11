import SwiftUI

@main
struct OpenCodeClientApp: App {
    @StateObject private var config = ServerConfig.shared
    @StateObject private var store = SessionStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(config)
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var config: ServerConfig
    @EnvironmentObject private var store: SessionStore
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            SessionListView()
                .navigationTitle("会话")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            store.newSession()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(config)
        }
    }
}
