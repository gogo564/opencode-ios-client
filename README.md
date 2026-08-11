# OpenCodeClient

一个 iOS 15+ 的原生 OpenCode 服务器客户端。通过 opencode server HTTP API 与你的 OpenCode（AI 编码助手）服务器对话，支持流式聊天、会话管理、多服务器地址。

## 功能

- 💬 流式对话（基于 opencode server HTTP API）
- 📋 会话列表 / 新建 / 删除会话
- 🖥 服务器地址 + 用户名/密码（Basic Auth）设置
- 📱 iOS 15+ 兼容，SwiftUI 原生实现

## 使用

1. 打开 App，进入设置，填写你的 OpenCode 服务器地址（如 `http://gogo564.x3322.net:4096`）、用户名（默认 `opencode`）和密码（`OPENCODE_SERVER_PASSWORD`）
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