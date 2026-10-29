import SwiftUI

/// 服务器设置。
struct SettingsView: View {
    @EnvironmentObject private var config: ServerConfig
    @Environment(\.presentationMode) private var presentationMode
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("服务器")) {
                    TextField("服务器地址", text: $config.baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textContentType(.URL)
                    Text("例如 https://gogo564.duckdns.org:4097")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("认证"), footer: Text("OpenCode V2 的 Basic Auth 用户名固定为 opencode，只需填密码。")) {
                    HStack {
                        Text("用户名")
                        Spacer()
                        Text(ServerConfig.fixedUsername)
                            .foregroundColor(.secondary)
                    }
                    SecureField("密码", text: $config.password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(footer: Text("测试连接会调用服务器的 /api/session 接口，验证地址和密码是否正确。")) {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "checkmark.circle")
                            }
                            Text("测试连接")
                        }
                        .foregroundColor(.accentColor)
                    }
                    .disabled(isTesting || !config.isConfigured)

                    if let testResult {
                        Text(testResult)
                            .font(.subheadline)
                            .foregroundColor(testResult.hasPrefix("连接成功") ? .green : .red)
                    }
                }
                Section(footer: Text("删除后，助手再次执行同类操作时会重新询问。")) {
                    NavigationLink(destination: SavedPermissionsView()) {
                        Label("已保存的授权", systemImage: "checkmark.shield")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let _ = try await OpenCodeClient.shared.sessions()
                await MainActor.run {
                    testResult = "连接成功"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "连接失败：\(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
