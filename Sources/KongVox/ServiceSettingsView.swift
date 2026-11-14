import SwiftUI
import AVFoundation

@MainActor final class ServiceEditor: ObservableObject {
    @Published var profile = ServiceProfile.gemini
    @Published var voicesText = ""
    @Published var key = ""
    @Published var removeKey = false
    @Published var makeDefault = false
    @Published var message = ""
    @Published var testing = false
    @Published var diagnostic = ""
    @Published var discardCache = false
    var recoveryRoot: URL?
    @Published var testText = "你好，欢迎使用 KongVox。让每一段文字，都有自然的声音。"
    @Published var testVoice = "Kore"
    var task: Task<Void, Never>?
    var player: AVAudioPlayer?
    @Published var localStatus = ""
    @Published var launching = false
    @Published var launchScript = UserDefaults.standard.string(forKey: "KongVox.sovitsLauncher") ?? ""
    private static var engineProcess: Process?

    func chooseLauncher() {
        let panel = NSOpenPanel()
        panel.message = "选择你已安装的 GPT-SoVITS 启动脚本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["command", "sh"].contains(url.pathExtension.lowercased()) else {
            localStatus = "请选择 .command 或 .sh 启动脚本。"
            return
        }
        launchScript = url.path
        UserDefaults.standard.set(url.path, forKey: "KongVox.sovitsLauncher")
    }

    func launchService() async {
        guard !launching, profile.kind == .gptSoVITS else { return }
        launching = true
        defer { launching = false }
        if await localServiceReady() { localStatus = "本机服务已可用。"; return }
        guard FileManager.default.isReadableFile(atPath: launchScript) else {
            localStatus = "请先选择已安装的 GPT-SoVITS 启动脚本。"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launchScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            if Self.engineProcess?.isRunning != true {
                try process.run()
                Self.engineProcess = process
            }
            localStatus = "正在载入模型…"
            for _ in 0..<30 {
                if await localServiceReady() { localStatus = "本机服务已可用。"; return }
                if let running = Self.engineProcess, !running.isRunning {
                    localStatus = "启动脚本已退出（代码 \(running.terminationStatus)）。请在终端运行同一脚本查看详情。"
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            localStatus = "等待本机接口超时。请核对脚本端口与服务地址。"
        } catch { localStatus = "无法启动：\(error.localizedDescription)" }
    }

    private func localServiceReady() async -> Bool {
        var address = profile
        address.referenceAudioPath = "/reference.wav"
        guard let validated = try? address.validated(),
              let url = URL(string: validated.normalizedURL + "/openapi.json"),
              let (data, response) = try? await SpeechClient.secureSession.data(for: URLRequest(url: url, timeoutInterval: 2)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = schema["paths"] as? [String: Any] else { return false }
        return paths["/tts"] != nil
    }
    var recentResult: String? {
        UserDefaults.standard.dictionary(forKey: "KongVox.serviceTestResults")?[profile.id] as? String
    }

    private func remember(_ result: String, service: ServiceProfile) {
        var results = UserDefaults.standard.dictionary(forKey: "KongVox.serviceTestResults") ?? [:]
        results[service.id] = Date().formatted(date: .abbreviated, time: .shortened) + " · " + result
        UserDefaults.standard.set(results, forKey: "KongVox.serviceTestResults")
    }

    func checkLocalService() async {
        guard profile.kind == .gptSoVITS else { return }
        let address = profile.normalizedURL
        localStatus = "正在检查本机服务…"
        let ready = await localServiceReady()
        guard !launching, profile.kind == .gptSoVITS, profile.normalizedURL == address else { return }
        localStatus = ready ? "本机服务已可用。" : "未检测到本机 GPT-SoVITS 配音服务。"
    }
    func load(_ profile: ServiceProfile, defaultID: String) {
        cancel()
        self.profile = profile; voicesText = profile.voices.joined(separator: ", ")
        key = ""; removeKey = false; makeDefault = profile.id == defaultID
        localStatus = ""
        testVoice = profile.voices.first ?? ""; message = ""; diagnostic = ""
    }
    func value() throws -> ServiceProfile {
        var result = profile
        result.voices = voicesText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
        return try result.validated()
    }
    func cancel() { task?.cancel(); player?.stop(); player = nil }
    func recoveryFile() -> URL? {
        guard let root = recoveryRoot, let service = try? value(), service.kind.usesAudioDownload else { return nil }
        var settings = VoiceSettings(); settings.service = service; settings.voice = testVoice
        return root.appendingPathComponent(Segment(text: testText).fingerprint(settings) + ".json")
    }
    var hasRecovery: Bool { recoveryFile().map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    func clearRecovery() {
        do { if let file = recoveryFile() { try DownloadReceipt.clear(file) }; message = "下载缓存已放弃，下次试听将重新合成。" }
        catch { message = "无法清除缓存，请检查本地文件权限。" }
    }
    func copyDiagnostic() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostic, forType: .string)
    }
    func test() {
        guard !testing else { return }
        do {
            let service = try value()
            let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let needsKey = service.kind.engine.requiresKey
            let secret = hasRecovery || !needsKey ? "" : token.isEmpty && !removeKey ? try KeyStore.read(account: service.keyAccount) : token
            guard hasRecovery || !needsKey || !secret.isEmpty else { throw VoxError(message: "请填写该服务的 API Key。") }
            var settings = VoiceSettings(); settings.service = service; settings.voice = testVoice
            let text = testText
            // Validate before presenting a loading state or making a billable request.
            if !hasRecovery { try SpeechClient().preflight(text: text, settings: settings, key: secret) }
            let recovery = recoveryFile()
            diagnostic = ""; testing = true; message = hasRecovery ? "正在恢复下载…" : service.kind == .localQwen ? "正在用本机模型生成试听；首次使用需下载模型，进度见下方。" : "正在生成短句试听…"; player?.stop()
            task = Task {
                defer { testing = false; task = nil }
                do {
                    let pcm = try await SpeechClient().generate(text: text, settings: settings, key: secret, recoveryFile: recovery)
                    try Task.checkCancellation()
                    var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm)
                    player = try AVAudioPlayer(data: wav)
                    guard player?.play() == true else { throw VoxError(message: "音频已生成，但无法播放。") }
                    if let file = recovery { try? DownloadReceipt.clear(file) }
                    message = needsKey ? "连接成功，正在试听。配置尚需点击保存。" : "本机合成成功，正在试听。配置尚需点击保存。"
                    remember("试听成功", service: service)
                } catch {
                    diagnostic = ServiceFailure.report(error)
                    message = Task.isCancelled ? "已取消试听。" : error.localizedDescription
                    if !Task.isCancelled { remember("试听失败 · " + ((error as? ServiceFailure)?.category ?? "音频或配置错误"), service: service) }
                }
            }
        } catch { message = error.localizedDescription; remember("配置检查失败", service: profile) }
    }
}
struct ServiceSettings: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    @StateObject private var editor = ServiceEditor()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("配音服务", systemImage: "network").font(.title2.bold())
                Spacer()
                Button("完成") { editor.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(studio.catalog.profiles) { profile in
                        Button { editor.load(profile, defaultID: studio.catalog.defaultID) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(profile.name).font(.headline); if profile.id == studio.catalog.defaultID { Image(systemName: "star.fill").font(.caption) } }
                                Text(profile.kind.rawValue + (profile.enabled ? "" : " · 已停用")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(editor.profile.id == profile.id ? Color.indigo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    Divider()
                    Menu("添加服务") {
                        Button("火山引擎 豆包语音") { add(.volcengine) }
                        Button("Gemini 原生") { add(.gemini) }
                        Button("阿里云 CosyVoice") { add(.cosyVoice) }
                        Button("阿里云 Qwen-TTS") { add(.qwenTTS) }
                        Button("OpenAI 兼容 API") { add(.openAI) }
                        Button("本机 Qwen3-TTS") { add(.localQwen) }
                        Button("本机 GPT-SoVITS") { add(.gptSoVITS) }
                    }
                    Text("切换前请保存当前修改。").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.frame(width: 185).disabled(editor.testing)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        configuration.disabled(editor.testing)
                        Divider()
                        Text("短句试听").font(.headline)
                        if let result = editor.recentResult { Text("最近测试  " + result).font(.caption).foregroundStyle(.secondary) }
                        TextField("输入一段测试文稿", text: $editor.testText, axis: .vertical).lineLimit(2...4).disabled(editor.testing)
                        HStack {
                            Picker("测试声音", selection: $editor.testVoice) {
                                ForEach((try? editor.value().voices) ?? [editor.testVoice], id: \.self) { Text($0).tag($0) }
                            }.disabled(editor.testing)
                            if editor.testing { ProgressView().controlSize(.small); Button("取消") { editor.cancel() } }
                            else { Button(editor.hasRecovery ? "继续下载并试听" : "测试并试听") { editor.test() } }
                        }
                        Text("测试会发送上方短句至 \(editor.profile.endpointHost)，可能产生 API 费用。不会自动保存配置或修改项目。").font(.caption).foregroundStyle(.secondary)
                        LocalModelProgressView()
                        if !editor.message.isEmpty { Text(editor.message).font(.callout).textSelection(.enabled) }
                        HStack {
                            if !editor.diagnostic.isEmpty { Button("复制诊断（不含密钥和文稿）") { editor.copyDiagnostic() } }
                            if editor.hasRecovery { Button("放弃下载缓存") { editor.discardCache = true }.disabled(editor.testing) }
                        }
                        HStack {
                            Button("删除服务", role: .destructive) {
                                do { try studio.deleteService(editor.profile.id); if let next = studio.catalog.profiles.first { editor.load(next, defaultID: studio.catalog.defaultID) } }
                                catch { editor.message = error.localizedDescription }
                            }.disabled(!studio.catalog.profiles.contains { $0.id == editor.profile.id })
                            Spacer()
                            Button("保存服务") { save() }.buttonStyle(.borderedProminent)
                        }.disabled(editor.testing)
                    }.textFieldStyle(.roundedBorder).padding(.trailing, 8)
                }
            }
        }.padding(24).frame(width: 850, height: 690)
        .confirmationDialog("放弃已生成的下载结果？", isPresented: $editor.discardCache) {
            Button("放弃缓存", role: .destructive) { editor.clearRecovery() }
        } message: { Text("下次试听会重新合成，可能再次计费。") }
        .onAppear {
            editor.recoveryRoot = studio.root.appendingPathComponent("Recovery/Tests")
            let service = studio.catalog.profiles.first { $0.id == studio.project?.settings.resolvedService.id } ?? .gemini
            editor.load(service, defaultID: studio.catalog.defaultID)
        }
        .onDisappear { editor.cancel() }
        .onChange(of: editor.voicesText) { _ in
            if let voices = try? editor.value().voices, !voices.contains(editor.testVoice) { editor.testVoice = voices.first ?? "" }
        }
    }
    var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("服务名称", text: $editor.profile.name)
            Text(editor.profile.kind.rawValue).font(.caption).foregroundStyle(.secondary)
            Text(editor.profile.kind == .localQwen ? "模型下载地址（Hugging Face 或镜像站 + 发布者）" : "API 基础地址").font(.caption)
            TextField(editor.profile.kind == .gptSoVITS ? "http://127.0.0.1:9880" : "https://…/v1 或 …/v1beta", text: $editor.profile.baseURL)
            if editor.profile.kind != .gptSoVITS {
                Text(editor.profile.kind == .volcengine ? "资源 ID（选择模型及计费方式）" : "模型名称").font(.caption)
                TextField("TTS 模型 ID", text: $editor.profile.model)
                if editor.profile.kind == .volcengine {
                    Menu("选择火山资源预设") {
                        ForEach(editor.profile.volcengineModelPresets) { preset in
                            Button(preset.title) { applyVolcenginePreset(preset) }
                        }
                    }.fixedSize()
                    Text(editor.profile.volcengineModelPresets.first(where: { $0.id == editor.profile.model })?.note ?? "自定义资源 ID：请确认它与 speaker ID 属于同一套音色资源。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu("选择模型预设") {
                        ForEach(editor.profile.modelPresets, id: \.self) { model in Button(model) { editor.profile.model = model } }
                    }.fixedSize()
                }
            }
            if editor.profile.kind == .volcengine {
                LabeledContent("试音资源与音色", value: editor.profile.model + " / " + editor.testVoice)
                Text("新版使用豆包语音 API Key，AppID 留空；旧版填写 AppID，并在下方填写 Access Token。不是火山方舟的 Key，也不是云 AccessKey/SecretKey。切换 1.0 或复刻资源后，必须把 speaker ID 换成该资源已开通的音色。").font(.caption).foregroundStyle(.secondary)
                if editor.profile.model == "seed-tts-2.0" {
                    Button("应用 VV / 2.0 默认音色") { applyVolcenginePreset(editor.profile.volcengineModelPresets[0]) }.font(.caption)
                }
                TextField("AppID（仅旧版鉴权填写，新版留空）", text: Binding(get: { editor.profile.volcAppID ?? "" }, set: { editor.profile.volcAppID = $0 }))
                Text(editor.profile.usesVolcLegacyAuth ? "当前鉴权：AppID + Access Token。切换 AppID 后需重新填写 Token。" : "当前鉴权：新版 API Key。").font(.caption).foregroundStyle(.secondary)
                Text("支持语速设置；本版暂不发送表达指令。中途失败不会采用残缺音频，重试可能重新计费。").font(.caption).foregroundStyle(.secondary)
                Link("打开官方接口文档", destination: URL(string: "https://www.volcengine.com/docs/6561/1598757")!)
            } else if editor.profile.kind == .gptSoVITS {
                HStack {
                    Button("检查本机服务") { Task { await editor.checkLocalService() } }
                    Button("选择启动脚本…") { editor.chooseLauncher() }.disabled(editor.launching)
                    Button("启动") { Task { await editor.launchService() } }.disabled(editor.launching || editor.launchScript.isEmpty)
                }.task(id: editor.profile.normalizedURL) { await editor.checkLocalService() }
                Text(editor.localStatus).font(.caption)
                TextField("参考音频绝对路径", text: Binding(get: { editor.profile.referenceAudioPath ?? "" }, set: { editor.profile.referenceAudioPath = $0 }))
                TextField("参考音频对应的中文文稿", text: Binding(get: { editor.profile.referenceTranscript ?? "" }, set: { editor.profile.referenceTranscript = $0 }))
                Text("先在本机启动 GPT-SoVITS API v2，再点击试听。每个服务配置使用一份参考音频。").font(.caption).foregroundStyle(.secondary)
                Link("查看 GPT-SoVITS API v2", destination: URL(string: "https://github.com/RVC-Boss/GPT-SoVITS/blob/main/api_v2.py")!)
            } else if editor.profile.kind == .localQwen {
                Text("在这台 Mac 上合成，不上传文稿、不计费、不需要密钥。首次使用会下载模型（数 GB）到 ~/.cache/huggingface，之后可离线使用。需要 Apple 芯片，合成时占用数 GB 内存。").font(.caption).foregroundStyle(.secondary)
                Text("无法访问 Hugging Face 时，可把地址中的域名换成镜像站，路径保留发布者（如 /mlx-community）。语速与表达要求以提示方式传给模型，效果为参考；每段最多 \(LocalQwenEngine.requestLimit) 字，文稿自动按 300 字以内分段。").font(.caption).foregroundStyle(.secondary)
            } else if editor.profile.kind == .gemini {
                Text("使用 Google AI Studio API Key；gen-lang-client-… 是项目 ID，不能用作密钥。模型可用性取决于你的账户。").font(.caption).foregroundStyle(.secondary)
            } else if editor.profile.kind == .qwenTTS {
                Text("使用百炼北京地域 API Key，需在此服务单独保存。Flash 用于标准朗读；Instruct Flash 支持表达要求和语速提示。标准 Flash 不应用语速与表达设置。每段最多 600 字，新导入文稿自动按不超过 500 字拆分。").font(.caption).foregroundStyle(.secondary)
                Text("默认音色 Cherry。模型可用性取决于账户权限；可按官方列表填写其他声音 ID。").font(.caption).foregroundStyle(.secondary)
                Link("查看 Qwen-TTS 接口与音色", destination: URL(string: "https://help.aliyun.com/zh/model-studio/qwen-tts-api")!)
            } else if editor.profile.kind == .cosyVoice {
                Text("使用阿里云百炼北京地域 API Key，不是 AccessKey。默认使用北京公共地址；业务空间专属地址请填写 https://你的WorkspaceID.cn-beijing.maas.aliyuncs.com/api/v1。").font(.caption).foregroundStyle(.secondary)
                Text("默认模型 cosyvoice-v3-flash；longanyang 为龙安洋，longanhuan 为龙安欢。自定义音色 ID 必须与所选模型匹配。").font(.caption).foregroundStyle(.secondary)
                Link("查看官方模型与音色", destination: URL(string: "https://help.aliyun.com/zh/model-studio/cosyvoice-voice-list")!)
            } else {
                Text("兼容 /audio/speech；需支持 24 kHz、单声道、16-bit PCM 或 WAV 返回。").font(.caption).foregroundStyle(.secondary)
            }
            if editor.profile.kind.engine.requiresKey {
                SecureField(editor.profile.usesVolcLegacyAuth ? "Access Token（留空保留当前 AppID 已存凭据）" : "API Key（留空保留当前地址已存密钥）", text: $editor.key).disabled(editor.removeKey)
                Toggle("保存时清除这个地址的密钥", isOn: $editor.removeKey).font(.caption)
                Text("密钥保存在钥匙串。更换地址后需重新输入对应密钥。").font(.caption2).foregroundStyle(.secondary)
            }
            if editor.profile.kind != .gptSoVITS {
                TextField("声音 ID，以逗号分隔", text: $editor.voicesText, axis: .vertical).lineLimit(2...4)
            }
            HStack { Toggle("启用", isOn: $editor.profile.enabled); Toggle("设为新项目默认", isOn: $editor.makeDefault) }
        }
    }
    func applyVolcenginePreset(_ preset: VolcengineModelPreset) {
        editor.profile.model = preset.model
        if preset.model == "seed-tts-2.0" {
            editor.voicesText = ServiceProfile.volcVVVoice
            editor.testVoice = ServiceProfile.volcVVVoice
        } else if editor.voicesText.split(whereSeparator: { ",，\n".contains($0) }).map(String.init).contains(ServiceProfile.volcVVVoice) {
            editor.voicesText = ""
            editor.testVoice = ""
            editor.message = "已切换到 \(preset.model)。请粘贴该资源已开通的 speaker ID 后再保存。"
        }
    }
    func add(_ kind: ServiceKind) {
        var profile: ServiceProfile
        switch kind {
        case .volcengine: profile = .volcengine
        case .gemini: profile = .gemini
        case .cosyVoice: profile = .cosyVoice
        case .qwenTTS: profile = .qwenTTS
        case .gptSoVITS: profile = .gptSoVITS
        case .localQwen: profile = .localQwen
        case .openAI: profile = .openAI
        }
        profile.id = UUID().uuidString; profile.name = "新的 " + kind.rawValue + " 服务"
        editor.load(profile, defaultID: studio.catalog.defaultID)
    }
    func save() {
        do {
            let profile = try editor.value()
            let token = editor.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.hasPrefix("gen-lang-client-") else { throw VoxError(message: "你填写的是 Google 项目 ID，请改填 API Key。") }
            try studio.saveService(profile, key: editor.removeKey ? "" : token.isEmpty ? nil : token, makeDefault: editor.makeDefault)
            editor.load(profile, defaultID: studio.catalog.defaultID)
            editor.message = "已保存。现有项目可在声音工作台选择此服务或应用最新配置。"
        } catch { editor.message = error.localizedDescription }
    }
}
