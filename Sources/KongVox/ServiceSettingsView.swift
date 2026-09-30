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
    @Published var testText = "你好，欢迎使用 KongVox。让每一段文字，都有自然的声音。"
    @Published var testVoice = "Kore"
    var task: Task<Void, Never>?
    var player: AVAudioPlayer?
    func load(_ profile: ServiceProfile, defaultID: String) {
        cancel()
        self.profile = profile; voicesText = profile.voices.joined(separator: ", ")
        key = ""; removeKey = false; makeDefault = profile.id == defaultID
        testVoice = profile.voices.first ?? ""; message = ""
    }
    func value() throws -> ServiceProfile {
        var result = profile
        result.voices = voicesText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
        return try result.validated()
    }
    func cancel() { task?.cancel(); player?.stop(); player = nil }
    func test() {
        guard !testing else { return }
        do {
            let service = try value()
            let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = token.isEmpty && !removeKey ? try KeyStore.read(account: service.keyAccount) : token
            guard !secret.isEmpty else { throw VoxError(message: "请填写 API Key；Google 项目 ID 不能用作密钥。") }
            var settings = VoiceSettings(); settings.service = service; settings.voice = testVoice
            let text = testText
            // Validate before presenting a loading state or making a billable request.
            _ = try SpeechClient().request(text: text, settings: settings, key: secret)
            testing = true; message = "正在生成短句试听…"; player?.stop()
            task = Task {
                defer { testing = false; task = nil }
                do {
                    let pcm = try await SpeechClient().generate(text: text, settings: settings, key: secret)
                    try Task.checkCancellation()
                    var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm)
                    player = try AVAudioPlayer(data: wav)
                    guard player?.play() == true else { throw VoxError(message: "音频已生成，但无法播放。") }
                    message = "连接成功，正在试听。配置尚需点击保存。"
                } catch { message = Task.isCancelled ? "已取消试听。" : error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
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
                        Button("Gemini 原生") { add(.gemini) }
                        Button("OpenAI 兼容 API") { add(.openAI) }
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
                        TextField("输入一段测试文稿", text: $editor.testText, axis: .vertical).lineLimit(2...4).disabled(editor.testing)
                        HStack {
                            Picker("测试声音", selection: $editor.testVoice) {
                                ForEach((try? editor.value().voices) ?? [editor.testVoice], id: \.self) { Text($0).tag($0) }
                            }.disabled(editor.testing)
                            if editor.testing { ProgressView().controlSize(.small); Button("取消") { editor.cancel() } }
                            else { Button("测试并试听") { editor.test() } }
                        }
                        Text("测试会发送上方短句至 \(editor.profile.endpointHost)，可能产生 API 费用。不会自动保存配置或修改项目。").font(.caption).foregroundStyle(.secondary)
                        if !editor.message.isEmpty { Text(editor.message).font(.callout).textSelection(.enabled) }
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
        .onAppear {
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
            Text("API 基础地址").font(.caption)
            TextField("https://…/v1 或 …/v1beta", text: $editor.profile.baseURL)
            Text("模型名称").font(.caption)
            TextField("TTS 模型 ID", text: $editor.profile.model)
            if editor.profile.kind == .gemini {
                Menu("选择 Gemini 模型预设") {
                    ForEach(["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.1-flash-tts-preview", "gemini-2.5-pro-preview-tts"], id: \.self) { model in Button(model) { editor.profile.model = model } }
                }.fixedSize()
                Text("使用 Google AI Studio API Key；gen-lang-client-… 是项目 ID，不能用作密钥。模型可用性取决于你的账户。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("兼容 /audio/speech；需支持 24 kHz、单声道、16-bit PCM 或 WAV 返回。").font(.caption).foregroundStyle(.secondary)
            }
            SecureField("API Key（留空保留当前地址已存密钥）", text: $editor.key).disabled(editor.removeKey)
            Toggle("保存时清除这个地址的密钥", isOn: $editor.removeKey).font(.caption)
            Text("密钥保存在钥匙串。更换地址后需重新输入对应密钥。").font(.caption2).foregroundStyle(.secondary)
            TextField("声音 ID，以逗号分隔", text: $editor.voicesText, axis: .vertical).lineLimit(2...4)
            HStack { Toggle("启用", isOn: $editor.profile.enabled); Toggle("设为新项目默认", isOn: $editor.makeDefault) }
        }
    }
    func add(_ kind: ServiceKind) {
        var profile = kind == .gemini ? ServiceProfile.gemini : .openAI
        profile.id = UUID().uuidString; profile.name = kind == .gemini ? "新的 Gemini 服务" : "新的兼容服务"
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
