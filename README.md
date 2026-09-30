# KongVox 0.2

个人使用的原生 macOS 配音工作台，面向短视频口播与长文章。SwiftUI 编写，无第三方 Swift 依赖。

## 0.2 新增

- Gemini 原生 TTS：内置 Gemini 服务、模型预设和声音列表。
- 多服务管理：新增、编辑、停用、删除服务，选择新项目默认服务。
- 自定义 OpenAI 兼容 API：基础地址、模型名称、声音 ID 均可配置。
- 服务设置内短句测试并试听，生成请求可能产生服务商 API 费用。
- 按项目选择服务，历史音频记录服务、模型、声音设置和朗读文本。
- 不同服务和地址隔离钥匙串密钥；更换地址不会自动复用旧地址密钥。拒绝 HTTP 重定向。
- 读取 0.1 项目时自动保留迁移前备份；旧音频仍可播放和导出。

## 配置 Gemini

1. 打开「服务设置」，选择左侧 **Gemini**。
2. 从 [Google AI Studio](https://aistudio.google.com/apikey) 获取 API Key，填入密钥框。`gen-lang-client-…` 是项目 ID，不能用作密钥。
3. 默认基础地址为 `https://generativelanguage.googleapis.com/v1beta`，模型为 `gemini-3.8-flash-tts`。也可选择其他内置 TTS 模型或输入模型 ID，实际可用性取决于账户和服务商。
4. 点击「测试并试听」，确认声音后「保存服务」。试听不会自动保存配置。
5. 返回主窗口，在「声音工作台 → 配音服务」选择 Gemini。旧项目保持原服务，不会自动切换。

Gemini 3.8 使用独立的表达风格字段，较早预览模型使用朗读提示。Gemini 的语速设置是表达目标，不保证精确倍速。应用将 WAV 或带正确格式声明的 PCM 统一为 24 kHz、单声道、16-bit PCM，再用于播放和导出。

## 添加其他 API

在「服务设置 → 添加服务」选择 Gemini 原生或 OpenAI 兼容 API。填写 HTTPS 基础地址（不含最终 `/audio/speech` 或 `/models/…:generateContent` 路径）、模型和声音列表。声音 ID 用逗号分隔。

OpenAI 兼容服务需支持 `/audio/speech` 的请求格式，并返回 24 kHz、单声道、16-bit little-endian PCM 或 WAV。并非任意语音 API 都兼容。API Key 留空保留同一地址的已存密钥，勾选清除选项后保存可删除该地址的密钥。

修改服务配置不会悄悄改变已有项目。需要在项目内点击「应用最新服务配置」。改变服务、模型、声音或文稿后，过期音频会标记为待更新，并阻止导出。历史音频不删除。

删除被项目使用的服务前，需先切换对应项目；也可停用。删除配置不自动删除钥匙串条目，需清除密钥时先在该服务中勾选清除并保存。

## 配音流程

粘贴文稿 → 添加配音段落 → 选段生成试听 → 生成待更新段落 → 导出。

- 按自然段拆分，过长段落按句子边界拆分；支持独立发音替代文本。
- 单段重做、历史版本、顺序生成、取消、失败后继续。
- 项目自动保存，全文试听与暂停、段间停顿。
- WAV / M4A 导出；可选 MP3 需要本机 `/opt/homebrew/bin/ffmpeg` 或 `/usr/local/bin/ffmpeg`。
- 播放已有音频、切换历史版本和本地导出不调用生成接口。

## 构建

macOS 13+，Swift 5.9+ / Xcode Command Line Tools。

```sh
swift test  # 完整 Xcode 环境
# 仅有 Command Line Tools：bash scripts/test-core.sh
bash scripts/build-app.sh
open dist/KongVox-0.2.0/KongVox.app
```

产出 `dist/KongVox-0.2.0/KongVox.app` 与 `dist/KongVox-0.2.0-Mac.zip`，按当前 Mac 架构构建。本地交付为 Apple Silicon 版本，使用 ad-hoc 签名，尚未 Developer ID 公证。

## 数据

数据目录：`~/Library/Application Support/KongVox/`。

- `projects.json`：项目与历史版本元数据。
- `services.json`：服务配置，不含密钥。
- `Audio/`：历史音频。
- `projects-before-0.2.json`：首次读取旧项目时保留的备份。
- 密钥只存于 macOS 钥匙串，不进入仓库。生成时文稿与表达要求发送给所选服务。

升级前退出其他 KongVox 版本，避免多个进程同时编辑同一数据文件。关闭应用会终止当前请求，已保存段落可以继续；服务端已接收的请求可能仍计费。损坏项目不会被空项目覆盖。移除段落后暂不自动清理历史音频。

## 验证与限制

15 组本地测试通过，覆盖 Gemini 新旧请求、WAV/PCM 解析、异常响应、服务切换、凭据隔离、旧项目恢复、长文队列续接/取消、音频合并与 M4A 导出。使用模拟 HTTP，不调用真实付费服务。

真实云端配音、账户权限、声音自然度和 MP3 编码尚需配置后验证。本版聚焦 Gemini 与多 API 管理，不包含发音词典、A/B 对比面板或章节编辑。

## 接口文档

- [Gemini TTS](https://ai.google.dev/gemini-api/docs/generate-content/speech-generation)
- [Gemini API Key](https://ai.google.dev/gemini-api/docs/api-key)
- [OpenAI TTS](https://developers.openai.com/api/docs/guides/text-to-speech)
