# OpenCodeClient

一个 iOS 15+ 的原生 OpenCode 服务器客户端。适配 OpenCode V2（2.0.x）的 `/api` 接口，通过 `GET /api/event` 事件流接收流式回复。

## 功能

- 💬 流式对话（`POST /api/session/{id}/prompt` + `/api/event` SSE）
- 📋 会话列表 / 新建 / 删除，历史消息分页加载
- 🔀 会话模型切换
- 🔐 权限确认弹窗（允许一次 / 始终允许 / 拒绝）
- 📝 表单弹窗（单选、多选、开关、数字、自定义输入）
- 🛠 工具调用展示（输入/输出/错误可折叠）
- 📱 iOS 15+ 兼容，SwiftUI 原生实现

## 使用

1. 打开 App，进入设置，填写 OpenCode 服务器地址和密码（Basic Auth 用户名固定为 `opencode`）
2. 点击"测试连接"验证
3. 回到会话列表，新建会话并开始对话

需要你的服务器以 `opencode serve` 运行并暴露给手机可访问。

## 构建

```bash
brew install xcodegen
xcodegen generate --project .
xcodebuild -project OpenCodeClient.xcodeproj -scheme OpenCodeClient -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO archive -archivePath /tmp/OpenCodeClient.xcarchive
```

CI 见 `.github/workflows/build.yml`（生成无签名 IPA，用 ldid 签名以便侧载）。