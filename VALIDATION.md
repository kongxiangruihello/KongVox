# KongVox 0.1 验证记录

2026-09-28，Apple Silicon Mac。

- Release 构建成功，生成原生 `.app` 与 ZIP；本地 ad-hoc 签名校验通过。
- 8 组核心测试通过：Unicode 分段、过期音频判定、WAV 合并/静音/M4A 转换、错误时保留导出原文件、项目恢复/音频缺失、损坏项目保护、模拟 HTTP 错误、生成失败续接与取消。
- 本机仅有 Command Line Tools，缺少 XCTest；使用 `bash scripts/test-core.sh` 执行同一份测试。GitHub Actions 配置在完整 Xcode 环境执行 `swift test`。
- 原生 UI 已打开，验证项目改名、粘贴示例文稿、生成两个段落卡片，检查窗口布局。
- 未进行真实付费 API 合成，未验证声音自然度、钥匙串实际密钥读写、MP3 编码与其它 Mac 版本兼容性。
- 本地构建为 arm64，适用于 Apple Silicon；Intel 用户需要自行在对应架构构建。
