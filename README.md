# KongVox 0.4

个人使用的原生 macOS 配音工作台，面向短视频口播与长文章。SwiftUI 编写，无第三方 Swift 依赖。

## 0.4：长文模式

默认以完整文章编辑，不再要求手动「添加为配音段落」。粘贴全文 → 点击「生成全文」→ 完成后试听或「导出完整音频」。WAV/M4A 导出自动合并全文；MP3 仍需 FFmpeg。

- 文章原样保留，服务长度限制由后台分段处理：Qwen 最多 500 字，其他服务最多 700 字。服务仍按实际 API 使用计费。
- 显示全文进度，生成失败或关闭后重新点击「生成全文」继续；未变化的处理片段保留原有音频、历史与下载恢复标识。
- 修改全文后禁用旧音频的完整试听和导出，更新生成后恢复。字幕也遵循同一校验。
- 「段落精调」保留发音替代文本、单段重做、历史选择及下载缓存操作。切回长文时合并精调后的文本。
- 旧项目默认以全文展示，已有段落与待添加草稿均保留；全新字段为可选，旧项目可以直接读取。重新分段时未使用的段落历史保留在项目内，不删除对应音频。
- 保留精确匹配的片段以减少重做；修改导致分段边界变化时，受影响片段仍需重新生成。

## 0.3.1：修复实际 CosyVoice 返回格式，加入 Qwen-TTS

- 已用两份实际失败缓存定位：24 kHz 单声道 PCM16 的 RIFF/data 长度分别为 `0x7fffffbf` / `0x7fffff9b`，是未回填的流式占位长度。本版仅识别此确定的配对格式，继续拒绝一般截断文件。原有失败缓存可直接继续处理，无需放弃缓存重新合成。
- 新增「阿里云 Qwen-TTS」服务，支持 `qwen3-tts-flash` 和 `qwen3-tts-instruct-flash`。默认 Cherry 音色，需在新服务中保存百炼北京地域 API Key，旧密钥不会自动复制。
- 服务设置统一提供「选择模型预设」，CosyVoice 可选 v3-flash / v3-plus；也可手填其他兼容模型。当前 CosyVoice v3-plus 适配仅发送文本、音色、格式和语速，不发送表达指令。
- Qwen 标准 Flash 不应用表达和语速设置；Instruct Flash 通过自然语言提示表达和语速，不保证精确倍速。每段最多 600 字；选用 Qwen 后，新导入文稿按最多 500 字拆分，已有超长段落需手工拆分。支持北京域名音频下载及失败缓存恢复。
- 新增服务不改变已有项目或默认服务。Qwen 模型可用性需由实际账户验证。

接口与声音依据：[Qwen-TTS 官方接口](https://help.aliyun.com/en/model-studio/qwen-tts-api)、[CosyVoice 音色列表](https://help.aliyun.com/en/model-studio/cosyvoice-voice-list)。

## 0.3：恢复下载、服务诊断、字幕导出

- **CosyVoice 恢复下载**：服务返回成功的音频链接后，先保存到本地，再下载。下载失败、取消或重启后，相同段落/试听文本和设置会继续下载，不再次合成。下载完成但解码失败时，保留原始 WAV 供再次处理。项目音频和记录成功保存后清除对应缓存。
- **明确错误与诊断**：区分密钥、权限、模型/音色配置、额度、频率限制、网络、下载和音频格式问题。服务试听和生成失败支持复制诊断，诊断仅含阶段、分类、HTTP 状态及建议，不含文稿、密钥、服务响应正文或签名链接。部分服务仅返回 429 时无法精确区分限流和额度。
- **SRT 段落字幕**：在「导出音频 → SRT · 段落字幕」单独保存字幕，再导出相同项目的完整音频。字幕使用原文（不是发音替代文本），按实际音频帧数及当前段间停顿计算时间。每个段落一条字幕，不是逐字或逐句语音对齐；修改段落、音频版本或停顿后需要重新导出。

恢复缓存位于本机 Application Support/KongVox/Recovery，不写入项目 JSON 或 Git 仓库。链接过期或缓存音频持续异常时，可在段落/服务试听处选择「放弃下载缓存」，确认后再次生成；重新合成可能计费。修改文稿或声音设置会使用另一份缓存。旧版失败的请求没有保存链接，不能追溯恢复。OpenAI/Gemini 直接返回音频，本版没有为其实现远端任务恢复。

## 0.2.2：WAV 兼容性修复

修复试听时 WAV 解析过于严格的问题：兼容流式文件头中的未知长度，支持整数 PCM、32-bit 浮点和标准扩展 WAV；将不同采样率和声道转换为 24 kHz、单声道、16-bit PCM。截断文件、无效格式及非有限浮点采样仍会报错，并提供更具体的原因。

已通过模拟 CosyVoice 下载与本地音频测试，未取得本次报错的原始响应或进行真实付费合成，需在新版中重试试听确认。

## 0.2.1：阿里云 CosyVoice

已加入阿里云百炼 CosyVoice 原生 HTTP 接口。升级后自动补充服务入口，不改变现有默认服务或项目选择。

1. 打开「服务设置 → 阿里云 CosyVoice」。
2. 填入**阿里云百炼北京地域 API Key**（不是阿里云 AccessKey，也不是智能语音交互产品的临时 Token）。
3. 默认模型 `cosyvoice-v3-flash`；默认音色 `longanyang`（龙安洋）、`longanhuan`（龙安欢）。
4. 点击「测试并试听」后保存。在项目右侧选择该服务再生成。

默认基础地址为 `https://dashscope.aliyuncs.com/api/v1`。使用业务空间专属域名时，填写 `https://你的WorkspaceID.cn-beijing.maas.aliyuncs.com/api/v1`；应用自动拼接 `/services/audio/tts/SpeechSynthesizer`。本版 HTTP 适配针对北京地域。

支持填写自有音色 ID 和模型，音色必须与模型匹配。`cosyvoice-v3.5-*` 需要对应的自定义音色，不能直接沿用系统音色。CosyVoice 表达要求直接用作 `instruction`，需遵守具体音色的格式（例如 `你说话的情感是happy。`）。两个默认音色在未填写指令时使用适合口播/长文的预设。v3-plus/v2 不发送表达指令。

应用请求 24 kHz WAV，收到成功结果后立即通过 HTTPS 下载到本地。下载请求不携带 API Key。合成成功且链接已保存后，可继续下载；放弃缓存后重新合成可能再次计费。未进行真实 CosyVoice 付费调用，账户权限及实际音质需你自行试听。

参考：[CosyVoice HTTP API](https://help.aliyun.com/zh/model-studio/cosyvoice-tts-http-api)、[音色与指令格式](https://help.aliyun.com/zh/model-studio/cosyvoice-voice-list)。

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
open dist/KongVox-0.4/KongVox.app
```

产出 `dist/KongVox-0.4/KongVox.app` 与 `dist/KongVox-0.4-Mac.zip`，按当前 Mac 架构构建。本地交付为 Apple Silicon 版本，使用 ad-hoc 签名，尚未 Developer ID 公证。

## 数据

数据目录：`~/Library/Application Support/KongVox/`。

- `projects.json`：项目与历史版本元数据。
- `services.json`：服务配置，不含密钥。
- `Audio/`：历史音频。
- `projects-before-0.2.json`：首次读取旧项目时保留的备份。
- 密钥只存于 macOS 钥匙串，不进入仓库。生成时文稿与表达要求发送给所选服务。

升级前退出其他 KongVox 版本，避免多个进程同时编辑同一数据文件。关闭应用会终止当前请求，已保存段落可以继续；服务端已接收的请求可能仍计费。损坏项目不会被空项目覆盖。移除段落后暂不自动清理历史音频。

## 验证与限制

20 组本地测试通过，覆盖 Gemini 新旧请求、WAV/PCM 解析、异常响应、服务切换、凭据隔离、旧项目恢复、长文队列续接/取消、音频合并与 M4A 导出。使用模拟 HTTP，不调用真实付费服务。

真实云端配音、账户权限、声音自然度和 MP3 编码尚需配置后验证。本版聚焦 Gemini 与多 API 管理，不包含发音词典、A/B 对比面板或章节编辑。

## 接口文档

- [Gemini TTS](https://ai.google.dev/gemini-api/docs/generate-content/speech-generation)
- [Gemini API Key](https://ai.google.dev/gemini-api/docs/api-key)
- [OpenAI TTS](https://developers.openai.com/api/docs/guides/text-to-speech)
