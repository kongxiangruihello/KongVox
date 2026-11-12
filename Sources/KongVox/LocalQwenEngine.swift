import SwiftUI
#if canImport(MLXAudioTTS)
import MLX
import MLXAudioCore
import MLXAudioTTS
import HuggingFace
#endif

/// What the on-device engine is doing before it can speak: downloading the model, then loading it.
/// Shown in the main window and in service settings; nil message means there is nothing to show.
@MainActor final class LocalModelStatus: ObservableObject {
    static let shared = LocalModelStatus()
    @Published var message: String?
    @Published var fraction: Double?
    func set(_ message: String?, fraction: Double? = nil) { self.message = message; self.fraction = fraction }
    func report(_ progress: Progress) {
        let value = progress.fractionCompleted
        guard value.isFinite else { return }
        let done = progress.completedUnitCount, total = progress.totalUnitCount
        // The unit is bytes for a model download; only show sizes when the total looks like one.
        let sizes = total > 10_000_000 ? String(format: "（%.1f / %.1f GB）", Double(done) / 1e9, Double(total) / 1e9) : ""
        set(String(format: "正在下载本机模型 %.0f%%", max(0, min(1, value)) * 100) + sizes + "，可随时取消", fraction: max(0, min(1, value)))
    }
}
struct LocalModelProgressView: View {
    @ObservedObject private var status = LocalModelStatus.shared
    var body: some View {
        if let message = status.message {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = status.fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Qwen3-TTS running on this Mac through MLX. Nothing is uploaded and nothing is billed;
/// the model is downloaded once from the address in the service profile.
struct LocalQwenEngine: SpeechEngine {
    var requiresKey: Bool { false }
    // Shorter than the online services: a small on-device model holds its voice better on short passages,
    // and one passage takes roughly as long to generate as it does to play.
    var chunkLimit: Int { 300 }
    static let requestLimit = 400

    func prepare(_ job: SpeechJob) throws {
        guard job.text.count <= Self.requestLimit else { throw VoxError(message: "本机 Qwen3-TTS 每段最多 \(Self.requestLimit) 字，请拆分段落后重试。") }
        _ = try job.profile.localModelRepository()
        try LocalQwenRuntime.checkAvailable()
    }

    func synthesize(_ job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        try prepare(job)
        #if canImport(MLXAudioTTS)
        let source = try job.profile.localModelRepository()
        return try await LocalQwenRuntime.shared.pcm(
            repository: source.repository, endpoint: source.endpoint, text: job.text,
            voice: Self.voicePrompt(speaker: job.settings.voice, direction: job.settings.direction, speed: job.settings.speed))
        #else
        throw LocalQwenRuntime.notBuiltIn
        #endif
    }

    /// CustomVoice checkpoints take "speaker, instruction" in one string. The model has no speed control,
    /// so a speed other than 1 is passed as an instruction and is a target, not an exact rate.
    static func voicePrompt(speaker: String, direction: String, speed: Double) -> String {
        var parts: [String] = []
        let direction = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direction.isEmpty { parts.append(direction) }
        if abs(speed - 1) > 0.001 { parts.append("语速约为正常速度的 \(String(format: "%.2f", speed)) 倍") }
        return parts.isEmpty ? speaker : speaker + ", " + parts.joined(separator: "。")
    }
}

extension ServiceProfile {
    /// For an on-device service the base address is "https://<hub host>/<publisher>" and the model is the
    /// repository name, e.g. https://huggingface.co/mlx-community + Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16.
    /// `endpoint` is nil for the default hub and set for a mirror.
    func localModelRepository() throws -> (repository: String, endpoint: String?) {
        guard let url = URL(string: normalizedURL), let host = url.host else { throw VoxError(message: "本机模型地址无效。") }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 1 else { throw VoxError(message: "本机模型地址应为「https://huggingface.co/发布者」的形式，例如 https://huggingface.co/mlx-community。") }
        return (path[0] + "/" + model.trimmingCharacters(in: .whitespacesAndNewlines), host.lowercased() == "huggingface.co" ? nil : "https://" + host)
    }
}

#if canImport(MLXAudioTTS)
/// Holds the loaded model between passages, so only the first one pays the loading time.
actor LocalQwenRuntime {
    static let shared = LocalQwenRuntime()
    static let isBuiltIn = true
    private var loaded: (repository: String, model: any SpeechGenerationModel)?

    /// MLX aborts the process if its Metal shader library is missing, so find it before the first MLX call.
    /// It is built by Xcode into mlx-swift_Cmlx.bundle, which the packaging script copies into the app.
    private static let metallib: URL? = {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL { roots.append(executable.deletingLastPathComponent()) }
        for bundle in Bundle.allBundles { roots.append(bundle.bundleURL.deletingLastPathComponent()) }
        for root in roots {
            let bundle = root.appendingPathComponent("mlx-swift_Cmlx.bundle")
            guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.lastPathComponent == "default.metallib" {
                GPU.metallib = url
                return url
            }
        }
        return nil
    }()

    static func checkAvailable() throws {
        guard metallib != nil else {
            throw VoxError(message: "此安装包缺少本机引擎所需的 Metal 着色库，无法使用本机 Qwen3-TTS。请使用由 Xcode 构建的安装包；其他服务不受影响。")
        }
    }

    func pcm(repository: String, endpoint: String?, text: String, voice: String) async throws -> Data {
        try Self.checkAvailable()
        // The hub client reads this each time it is created; only set it for a mirror.
        if let endpoint { setenv("HF_ENDPOINT", endpoint, 1) }
        let model: any SpeechGenerationModel
        if let loaded, loaded.repository == repository { model = loaded.model }
        else {
            loaded = nil
            do {
                // Fetch the files first with progress reporting; loading then finds them in the cache.
                guard let id = Repo.ID(rawValue: repository) else { throw VoxError(message: "本机模型名称无效。") }
                await LocalModelStatus.shared.set("正在检查本机模型…")
                let cache = HubCache.default
                let client = HubClient(cache: cache)
                _ = try await ModelUtils.resolveOrDownloadModel(client: client, cache: client.cache ?? cache, repoID: id, requiredExtension: "safetensors",
                    progressHandler: { progress in LocalModelStatus.shared.report(progress) })
                try Task.checkCancellation()
                await LocalModelStatus.shared.set("正在载入本机模型…")
                model = try await TTS.loadModel(modelRepo: repository)
                await LocalModelStatus.shared.set(nil)
            }
            catch {
                await LocalModelStatus.shared.set(nil)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ServiceFailure(stage: "本机模型加载失败", category: "local_model",
                    hint: "首次使用需联网下载模型（数 GB），请检查网络或代理后重试；无法访问时可把服务地址改为镜像站。原因：\(String(error.localizedDescription.prefix(160)))")
            }
            loaded = (repository, model)
        }
        try Task.checkCancellation()
        guard model.sampleRate == 24000 else { throw VoxError(message: "该本机模型输出 \(model.sampleRate) Hz，KongVox 目前只支持 24 kHz 的模型。") }
        let samples: [Float]
        do { samples = try await model.generate(text: text, voice: voice, refAudio: nil, refText: nil, language: "Chinese").asArray(Float.self) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ServiceFailure(stage: "本机合成失败", category: "local_model", hint: "可重试；若反复失败，请缩短段落或关闭其他占用内存的应用。原因：\(String(error.localizedDescription.prefix(160)))")
        }
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw ServiceFailure(stage: "本机合成失败", category: "local_model", hint: "模型没有输出有效音频，未保存。可重试。")
        }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}
#else
/// Built without MLX (KONGVOX_LOCAL_SPEECH=0, or compiled outside Swift Package Manager).
enum LocalQwenRuntime {
    static let isBuiltIn = false
    static let notBuiltIn = VoxError(message: "此安装包未包含本机引擎，无法使用本机 Qwen3-TTS。请使用由 Xcode 构建的安装包；其他服务不受影响。")
    static func checkAvailable() throws { throw notBuiltIn }
}
#endif

/// `KongVox --local-speech-selftest <output.wav> [voice,voice…]`
/// Synthesises with the built-in on-device profile and exits, without opening a window. Used after packaging
/// to prove the app bundle really contains a working engine, and handy for diagnosing a Mac where it fails.
enum LocalSpeechSelfTest {
    static let passage = "读书这件事，贵在日日不辍。清晨翻开一页，未必立刻读懂，却总有一两句话留在心里，等到某一天忽然明白。古人说温故而知新，讲的正是这个道理：旧的文字没有变，变的是读它的人。所以不必急着读完，也不必担心记不住，把书放在手边，想起来就读几行，日子久了，自然会有自己的体会。"
    static func run(_ arguments: [String]) async -> Int32 {
        guard let flag = arguments.firstIndex(of: "--local-speech-selftest"), arguments.count > flag + 1 else {
            print("用法：KongVox --local-speech-selftest <输出.wav> [音色,音色…]"); return 2
        }
        let output = URL(fileURLWithPath: arguments[flag + 1])
        let profile = ServiceProfile.localQwen
        let voices = arguments.count > flag + 2 ? arguments[flag + 2].components(separatedBy: ",").filter { !$0.isEmpty } : [profile.voices[0]]
        do {
            for (index, voice) in voices.enumerated() {
                var settings = VoiceSettings(); settings.service = profile; settings.voice = voice
                // The first voice reads a full paragraph; the rest only prove each speaker exists.
                let text = index == 0 ? passage : "这是音色 \(voice) 的试听，本机合成，不上传文稿。"
                let started = Date()
                let pcm = try await SpeechClient().generate(text: text, settings: settings, key: "")
                let seconds = Double(pcm.count) / 48000, elapsed = Date().timeIntervalSince(started)
                let file = voices.count == 1 ? output : output.deletingPathExtension().appendingPathExtension(voice + ".wav")
                try AudioFiles.writePCM(pcm, to: file)
                var peak: Int16 = 0
                pcm.withUnsafeBytes { raw in for value in raw.bindMemory(to: Int16.self) { peak = max(peak, value == .min ? .max : abs(value)) } }
                print(String(format: "SELFTEST voice=%@ chars=%d audio=%.2fs elapsed=%.2fs peak=%d file=%@", voice, text.count, seconds, elapsed, Int(peak), file.lastPathComponent))
                // Mandarin runs at roughly 3–6 characters a second; far outside that means skipped or looping speech.
                guard peak > 1000, seconds > Double(text.count) / 12, seconds < Double(text.count) / 1.5 + 3 else {
                    print("SELFTEST FAILED: 音频时长或音量异常"); return 1
                }
            }
            print("SELFTEST OK"); return 0
        } catch {
            print("SELFTEST FAILED: \(error.localizedDescription)"); return 1
        }
    }
}
