# KongVox

个人使用的原生 macOS 配音工作台，面向短视频口播与长文章。SwiftUI 编写，无第三方 Swift 依赖。

## 第一版功能

- 口播 / 长文章两种表达预设，5 个声音、语速和表达要求。
- 文稿按自然段拆分，过长段落按句子边界拆分；每段可单独编辑发音替代文本。
- 单段生成试听、待更新段落顺序生成、取消、失败后手动继续。
- 每段保留历史音频版本；文本或声音设置改变后阻止导出过期音频。
- 项目自动保存，API Key 使用 macOS 钥匙串保存。
- 全文试听与暂停、段间停顿、WAV / M4A 导出。
- 可选 MP3 导出：需要本机 `/opt/homebrew/bin/ffmpeg` 或 `/usr/local/bin/ffmpeg`，不自动安装。

## 使用

1. 打开 `KongVox.app`，点击左下角「服务设置」，填入自己的 OpenAI API Key。
2. 粘贴文稿，点击「添加为配音段落」。
3. 选择场景和声音，先对一段「生成并试听」。
4. 满意后「生成待更新段落」，最后导出音频。

每次生成会发送对应段落的朗读文本和表达要求至 OpenAI，并产生 API 费用；播放已有音频、切换历史版本和本地导出不会调用生成接口。应用显示字符数而非未经验证的费用估算。没有 API Key 仍可编辑、保存项目。

服务固定为 OpenAI `gpt-4o-mini-tts`，需要账户额度和所在地区的服务访问权限。未验证的第三方兼容服务暂不接入。声音自然度和长文段落衔接需用自己的真实文稿试听。

## 构建

macOS 13+，Swift 5.9+ / Xcode Command Line Tools。

```sh
swift test  # 完整 Xcode 环境
# 仅安装 Command Line Tools 时可改用：bash scripts/test-core.sh
bash scripts/build-app.sh
open dist/KongVox.app
```

脚本产出 `dist/KongVox.app` 与 `dist/KongVox-0.1.0-Mac.zip`，按当前 Mac 架构构建。应用使用本地 ad-hoc 签名，尚未进行 Developer ID 签名与公证；适合本机试用，不是已公证的公开发行版。

## 数据与恢复

- 项目：`~/Library/Application Support/KongVox/projects.json`
- 音频版本：同目录 `Audio/`，每次生成独立文件。
- 密钥：钥匙串服务 `com.kongvox.api`，不进入项目文件或仓库。
- 项目保存为原子写入。损坏的项目文件不会被空项目覆盖，界面会报错。
- 移除段落后暂不自动清理历史音频，防止误删；可备份整个 KongVox 数据目录。
- 不同项目之间不能同时生成。关闭应用会终止当前请求，已保存段落可在重启后继续；服务端已接收的请求可能仍计费。

## 验证范围

自动化测试覆盖 Unicode 分段、音频失效标记、项目恢复、损坏文件保护、HTTP 错误、PCM/WAV 合并与停顿、M4A 转换。网络测试使用本地模拟响应，不使用真实密钥或产生费用。

真实云端合成与主观音质需要用户提供 API Key 后验证。MP3 转换需要安装 FFmpeg 后验证。当前不含声音克隆、背景音乐、视频编辑、章节批量导出或自动重试计费请求。

## 接口依据

[OpenAI 官方语音合成文档](https://developers.openai.com/api/docs/guides/text-to-speech)：使用 24 kHz、16-bit little-endian PCM，应用在本地封装 WAV，并在段间插入指定长度静音。生成的配音属于 AI 合成声音。
