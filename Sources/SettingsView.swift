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
                    Text("例如 http://gogo564.x3322.net:4096")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section(header: Text("认证")) {
                    TextField("用户名", text: $config.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("密码", text: $config.password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section {
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
                } footer: {
                    Text("测试连接会调用服务器的 /session 接口，验证地址和密码是否正确。")
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
