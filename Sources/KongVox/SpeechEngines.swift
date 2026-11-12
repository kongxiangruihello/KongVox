import Foundation

/// One synthesis job as an engine sees it. `profile` has already passed `ServiceProfile.validated()`
/// and the checks shared by every engine (text length, voice list, speed range).
struct SpeechJob {
    var text: String
    var settings: VoiceSettings
    var profile: ServiceProfile
    var key: String
    var context: String?
    /// Neighbouring sentences, for tone and pacing only. Empty when context hints are off.
    var contextHint: String {
        context.map { "\n前后文只用于语气和节奏参考，不要朗读这些文字：\n\($0)\n只朗读目标正文。" } ?? ""
    }
}

/// A speech service. Every engine returns canonical PCM: signed 16-bit little-endian, 24 kHz, mono.
///
/// To add a service: write a type conforming to `SpeechEngine` (or `HTTPSpeechEngine` for a web API),
/// add a `ServiceKind` case, and return the type from `ServiceKind.engine`. `SpeechClient` needs no change.
/// An on-device engine conforms to `SpeechEngine` directly and sets `requiresKey` to false.
protocol SpeechEngine {
    /// False for engines that run on this Mac and need no stored credential.
    var requiresKey: Bool { get }
    /// Longest text, in characters, sent in one request when a document is split.
    var chunkLimit: Int { get }
    /// Service-specific configuration checks that run before the speed check. No network.
    func validate(_ job: SpeechJob) throws
    /// Every remaining local check, so a bad configuration fails before any billable request. No network.
    func prepare(_ job: SpeechJob) throws
    /// Finishes an earlier synthesis whose audio was not fully fetched. Nil when there is nothing to resume.
    func resume(recoveryFile: URL?, client: SpeechClient) async throws -> Data?
    func synthesize(_ job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data
}
extension SpeechEngine {
    var requiresKey: Bool { true }
    var chunkLimit: Int { 700 }
    func validate(_ job: SpeechJob) throws {}
    func resume(recoveryFile: URL?, client: SpeechClient) async throws -> Data? { nil }
}

/// An engine reached with one HTTPS POST carrying a JSON body.
protocol HTTPSpeechEngine: SpeechEngine {
    /// Path appended to the profile's base URL.
    func path(_ profile: ServiceProfile) -> String
    /// Sets the credential and other headers on `request` and returns the JSON body.
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any]
    /// Turns the service response into canonical PCM, or throws the failure to show the user.
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data
}
extension HTTPSpeechEngine {
    func makeRequest(_ job: SpeechJob) throws -> URLRequest {
        guard let url = URL(string: job.profile.normalizedURL + path(job.profile)) else { throw VoxError(message: "服务地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let json = try payload(job, request: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }
    func prepare(_ job: SpeechJob) throws { _ = try makeRequest(job) }
    func synthesize(_ job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        let outgoing = try makeRequest(job)
        let data: Data, response: URLResponse
        do { (data, response) = try await client.session.data(for: outgoing) }
        catch { throw ServiceFailure.network(error, download: false) }
        guard let http = response as? HTTPURLResponse else { throw VoxError(message: "未收到有效响应。") }
        return try await audio(data, http: http, job: job, recoveryFile: recoveryFile, client: client)
    }
}

extension ServiceKind {
    var engine: any SpeechEngine {
        switch self {
        case .volcengine: return VolcengineEngine()
        case .openAI: return OpenAICompatibleEngine()
        case .gemini: return GeminiEngine()
        case .cosyVoice: return CosyVoiceEngine()
        case .qwenTTS: return QwenEngine()
        }
    }
}

struct OpenAICompatibleEngine: HTTPSpeechEngine {
    func path(_ profile: ServiceProfile) -> String { "/audio/speech" }
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any] {
        request.setValue("Bearer \(job.key)", forHTTPHeaderField: "Authorization")
        var speech: [String: Any] = ["model": job.profile.model, "voice": job.settings.voice, "input": job.text, "speed": job.settings.speed, "response_format": "pcm"]
        // The two legacy models reject the instructions field.
        if job.profile.model != "tts-1" && job.profile.model != "tts-1-hd" { speech["instructions"] = job.settings.instructions + job.contextHint }
        return speech
    }
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        guard (200..<300).contains(http.statusCode) else { throw ServiceFailure.http(http.statusCode, body: data) }
        try Task.checkCancellation()
        return try SpeechClient.audioPCM(data, mime: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
}

struct GeminiEngine: HTTPSpeechEngine {
    func path(_ profile: ServiceProfile) -> String { "/models/\(profile.model):generateContent" }
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any] {
        request.setValue(job.key, forHTTPHeaderField: "x-goog-api-key")
        let style = job.settings.instructions + " 语速目标为正常速度的 \(job.settings.speed) 倍。" + job.contextHint
        // Gemini 3.8 takes the style in its own field; earlier preview models read it from the prompt.
        let part: [String: Any] = job.profile.modernGemini
            ? ["text": job.text, "speech_metadata": ["style": style]]
            : ["text": "请按以下要求朗读，仅读出正文。\n表达要求：\(style)\n正文：\n\(job.text)"]
        let voice: [String: Any] = job.profile.modernGemini ? ["voice": job.settings.voice] : ["prebuiltVoiceConfig": ["voiceName": job.settings.voice]]
        return ["contents": [["role": "user", "parts": [part]]], "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": voice]]]
    }
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        guard (200..<300).contains(http.statusCode) else { throw ServiceFailure.http(http.statusCode, body: data) }
        try Task.checkCancellation()
        return try SpeechClient.geminiPCM(data)
    }
}

struct VolcengineEngine: HTTPSpeechEngine {
    func path(_ profile: ServiceProfile) -> String { "/tts/unidirectional/sse" }
    func validate(_ job: SpeechJob) throws {
        if job.profile.model != "seed-tts-2.0", job.settings.voice == ServiceProfile.volcVVVoice {
            throw VoxError(message: "火山引擎配置不匹配：\(job.profile.model) 不能使用 VV 音色 \(ServiceProfile.volcVVVoice)。请切回 seed-tts-2.0，或填写与当前资源对应的 speaker ID。")
        }
    }
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any] {
        let credential = job.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains("\n"), !credential.contains("\r") else { throw VoxError(message: "请填写有效的火山语音凭据，不要包含换行。") }
        if job.profile.usesVolcLegacyAuth {
            request.setValue(job.profile.volcAppID, forHTTPHeaderField: "X-Api-App-Id")
            request.setValue(credential, forHTTPHeaderField: "X-Api-Access-Key")
        } else {
            request.setValue(credential, forHTTPHeaderField: "X-Api-Key")
        }
        request.setValue(job.profile.model, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let audioParams: [String: Any] = ["format": "pcm", "sample_rate": 24000, "speech_rate": Int(((job.settings.speed - 1) * 100).rounded())]
        let reqParams: [String: Any] = ["text": job.text, "speaker": job.settings.voice, "audio_params": audioParams]
        return ["user": ["uid": "kongvox"], "req_params": reqParams]
    }
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        try Task.checkCancellation()
        if !(200..<300).contains(http.statusCode) {
            throw VolcengineAudio.failure(body: data, httpStatus: http.statusCode, resourceID: job.profile.model, speaker: job.settings.voice)
        }
        return try VolcengineAudio.decode(data, resourceID: job.profile.model, speaker: job.settings.voice)
    }
}

/// Shared by the two Aliyun Bailian services: synthesis returns a signed link, and the audio is fetched separately.
/// The link is saved first, so an interrupted download resumes without a second (billable) synthesis.
enum DashScopeAudio {
    static func resume(recoveryFile: URL?, client: SpeechClient) async throws -> Data? {
        guard let file = recoveryFile, FileManager.default.fileExists(atPath: file.path) else { return nil }
        let receipt = try JSONDecoder().decode(DownloadReceipt.self, from: Data(contentsOf: file))
        return try await client.download(receipt.url, recoveryFile: file)
    }
    static func audio(_ data: Data, http: HTTPURLResponse, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        guard (200..<300).contains(http.statusCode) else { throw ServiceFailure.http(http.statusCode, body: data) }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let code = json["code"] as? String, !code.isEmpty {
            throw ServiceFailure.http(http.statusCode, body: data)
        }
        let url = try SpeechClient.cosyVoiceAudioURL(data)
        // Persist before cancellation checks or downloads so a successful synthesis can be resumed.
        if let file = recoveryFile { try DownloadReceipt(url: url).save(to: file) }
        try Task.checkCancellation()
        return try await client.download(url, recoveryFile: recoveryFile)
    }
}

struct CosyVoiceEngine: HTTPSpeechEngine {
    func path(_ profile: ServiceProfile) -> String { "/services/audio/tts/SpeechSynthesizer" }
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any] {
        request.setValue("Bearer \(job.key)", forHTTPHeaderField: "Authorization")
        let settings = job.settings
        var input: [String: Any] = ["text": job.text, "voice": settings.voice, "format": "wav", "sample_rate": 24000, "rate": settings.speed]
        // Only these models accept an instruction; v3-plus and v2 get text, voice, format and rate.
        if job.profile.model == "cosyvoice-v3-flash" || job.profile.model.hasPrefix("cosyvoice-v3.5-") {
            let direction = settings.direction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !direction.isEmpty { input["instruction"] = direction }
            else if settings.voice == "longanyang" {
                input["instruction"] = settings.mode == "长文章" ? "你现在说话的角色是一个旁白，你说话的情感是neutral。" : "你正在进行闲聊互动，你说话的情感是neutral。"
            } else if settings.voice == "longanhuan" {
                input["instruction"] = settings.mode == "长文章" ? "你正在进行深夜电台广播，你说话的情感是neutral。" : "你正在进行闲聊对话，你说话的情感是neutral。"
            }
            let hint = job.contextHint
            if !hint.isEmpty, let instruction = input["instruction"] as? String { input["instruction"] = instruction + hint }
        }
        return ["model": job.profile.model, "input": input]
    }
    func resume(recoveryFile: URL?, client: SpeechClient) async throws -> Data? {
        try await DashScopeAudio.resume(recoveryFile: recoveryFile, client: client)
    }
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        try await DashScopeAudio.audio(data, http: http, recoveryFile: recoveryFile, client: client)
    }
}

struct QwenEngine: HTTPSpeechEngine {
    // Requests allow 600 characters; documents are split at 500 to leave room for pronunciation replacements.
    var chunkLimit: Int { 500 }
    func path(_ profile: ServiceProfile) -> String { "/services/aigc/multimodal-generation/generation" }
    func payload(_ job: SpeechJob, request: inout URLRequest) throws -> [String: Any] {
        guard job.text.count <= 600 else { throw VoxError(message: "Qwen-TTS 每段最多 600 字，请拆分段落后重试。") }
        request.setValue("Bearer \(job.key)", forHTTPHeaderField: "Authorization")
        var input: [String: Any] = ["text": job.text, "voice": job.settings.voice, "language_type": "Auto"]
        // Standard Flash ignores expression and speed; Instruct Flash takes both as a natural-language prompt.
        if job.profile.model.hasPrefix("qwen3-tts-instruct-flash") {
            input["instructions"] = job.settings.instructions + " 语速目标为正常速度的 \(job.settings.speed) 倍。" + job.contextHint
            input["optimize_instructions"] = true
        }
        return ["model": job.profile.model, "input": input]
    }
    func resume(recoveryFile: URL?, client: SpeechClient) async throws -> Data? {
        try await DashScopeAudio.resume(recoveryFile: recoveryFile, client: client)
    }
    func audio(_ data: Data, http: HTTPURLResponse, job: SpeechJob, recoveryFile: URL?, client: SpeechClient) async throws -> Data {
        try await DashScopeAudio.audio(data, http: http, recoveryFile: recoveryFile, client: client)
    }
}
