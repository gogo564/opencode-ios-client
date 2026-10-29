import SwiftUI

// MARK: - 权限确认

/// V2 权限请求弹窗：允许一次 / 始终允许 / 拒绝。
struct PermissionSheet: View {
    let request: OpenCodeClient.OCPermission
    var onDecision: (String) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(actionTitle)
                        .font(.headline)
                    if let message = request.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("助手请求执行操作")
                }

                if !request.resources.isEmpty {
                    Section(header: Text("涉及内容")) {
                        ForEach(request.resources, id: \.self) { item in
                            Text(item)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    Button {
                        onDecision("once")
                    } label: {
                        Label("允许这一次", systemImage: "checkmark.circle")
                    }
                    Button {
                        onDecision("always")
                    } label: {
                        Label("始终允许（记住选择）", systemImage: "checkmark.shield")
                    }
                    Button(role: .destructive) {
                        onDecision("reject")
                    } label: {
                        Label("拒绝", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle("需要授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { onDismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var actionTitle: String {
        switch request.action {
        case "bash": return "执行命令"
        case "edit": return "修改文件"
        case "webfetch": return "访问网页"
        case "write": return "写入文件"
        default: return request.action
        }
    }
}

// MARK: - 表单（选择题）

/// V2 表单弹窗：把服务器发来的问题渲染成单选/多选/文本/开关。
struct FormSheet: View {
    static let customTag = "__oc_form_custom__"

    let form: OpenCodeClient.OCForm
    var onSubmit: ([String: Any]) -> Void
    var onCancel: () -> Void

    @State private var texts: [String: String] = [:]
    @State private var numbers: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var selections: [String: String] = [:]
    @State private var customTexts: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var didSeed = false

    init(form: OpenCodeClient.OCForm,
         onSubmit: @escaping ([String: Any]) -> Void,
         onCancel: @escaping () -> Void) {
        self.form = form
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            Form {
                if !form.title.isEmpty {
                    Section {
                        Text(form.title).font(.headline)
                    }
                }
                ForEach(form.fields.filter { !$0.hidden }) { field in
                    Section {
                        fieldView(field)
                    } header: {
                        if !field.description.isEmpty {
                            Text(field.description)
                        }
                    }
                }
            }
            .navigationTitle("请选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { onSubmit(buildAnswer()) }
                        .disabled(!isValid)
                }
            }
            .onAppear { seedDefaults() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func fieldView(_ field: OpenCodeClient.OCFormField) -> some View {
        switch field.type {
        case "boolean":
            Toggle(fieldLabel(field), isOn: Binding(
                get: { bools[field.key] ?? false },
                set: { bools[field.key] = $0 }
            ))

        case "multiselect":
            ForEach(field.options) { option in
                Button {
                    toggleMulti(field.key, option.value)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .foregroundColor(.primary)
                            if !option.detail.isEmpty {
                                Text(option.detail).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: (multiSelections[field.key] ?? []).contains(option.value) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(.accentColor)
                    }
                }
            }

        case "number", "integer":
            HStack {
                Text(fieldLabel(field))
                Spacer()
                TextField("数值", text: Binding(
                    get: { numbers[field.key] ?? "" },
                    set: { numbers[field.key] = $0 }
                ))
                .keyboardType(field.type == "integer" ? .numberPad : .numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            }

        case "external":
            if let url = URL(string: field.url) {
                Link(fieldLabel(field), destination: url)
            } else {
                Text(fieldLabel(field))
            }

        default:
            if field.options.isEmpty {
                TextField(field.title, text: Binding(
                    get: { texts[field.key] ?? "" },
                    set: { texts[field.key] = $0 }
                ))
            } else {
                Picker(fieldLabel(field), selection: Binding(
                    get: { selections[field.key] ?? "" },
                    set: { selections[field.key] = $0 }
                )) {
                    Text("未选择").tag("")
                    ForEach(field.options) { option in
                        Text(option.label).tag(option.value)
                    }
                    if field.custom {
                        Text("其他（自行输入）").tag(FormSheet.customTag)
                    }
                }
                if field.custom && selections[field.key] == FormSheet.customTag {
                    TextField("请输入", text: Binding(
                        get: { customTexts[field.key] ?? "" },
                        set: { customTexts[field.key] = $0 }
                    ))
                }
            }
        }
    }

    private func fieldLabel(_ field: OpenCodeClient.OCFormField) -> String {
        field.required ? "\(field.title) *" : field.title
    }

    private var isValid: Bool {
        for field in form.fields where !field.hidden && field.required && !field.conditional {
            switch field.type {
            case "string":
                if field.options.isEmpty {
                    if (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
                } else {
                    let selection = selections[field.key] ?? ""
                    if selection.isEmpty { return false }
                    if selection == FormSheet.customTag {
                        if (customTexts[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return false }
                    }
                }
            case "multiselect":
                if (multiSelections[field.key] ?? []).isEmpty { return false }
            case "number", "integer":
                if numbers[field.key] == nil || numbers[field.key]?.isEmpty == true { return false }
            default:
                break
            }
        }
        return true
    }

    private func buildAnswer() -> [String: Any] {
        var answer: [String: Any] = [:]
        for field in form.fields where !field.hidden {
            switch field.type {
            case "string":
                if field.options.isEmpty {
                    let value = (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { answer[field.key] = value }
                } else if let value = selections[field.key], !value.isEmpty {
                    if value == FormSheet.customTag {
                        let custom = (customTexts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                        if !custom.isEmpty { answer[field.key] = custom }
                    } else {
                        answer[field.key] = value
                    }
                }
            case "multiselect":
                let values = Array(multiSelections[field.key] ?? [])
                if !values.isEmpty { answer[field.key] = values }
            case "boolean":
                answer[field.key] = bools[field.key] ?? false
            case "number":
                if let value = numbers[field.key], let d = Double(value) { answer[field.key] = d }
            case "integer":
                if let value = numbers[field.key], let i = Int(value) { answer[field.key] = i }
            default:
                break
            }
        }
        return answer
    }

    private func toggleMulti(_ key: String, _ value: String) {
        var set = multiSelections[key] ?? []
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        multiSelections[key] = set
    }

    private func seedDefaults() {
        guard !didSeed else { return }
        didSeed = true
        for field in form.fields {
            guard let def = field.defaultValue else { continue }
            switch field.type {
            case "string":
                if let s = def as? String {
                    if field.options.contains(where: { $0.value == s }) {
                        selections[field.key] = s
                    } else {
                        texts[field.key] = s
                    }
                }
            case "multiselect":
                if let arr = def as? [String] {
                    multiSelections[field.key] = Set(arr)
                }
            case "boolean":
                if let b = def as? Bool { bools[field.key] = b }
            case "number", "integer":
                if let d = def as? Double { numbers[field.key] = String(d) }
                else if let i = def as? Int { numbers[field.key] = String(i) }
                else if let n = def as? NSNumber { numbers[field.key] = n.stringValue }
            default:
                break
            }
        }
    }
}
