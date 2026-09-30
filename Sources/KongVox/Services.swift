import Foundation
import Security
import AVFoundation

struct KeyStore {
    static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.kongvox.api", kSecAttrAccount as String: account] }
    static func read(account: String = "openai") throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw VoxError(message: "无法读取钥匙串（\(status)）") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, account: String = "openai") throws {
        let query = query(account)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VoxError(message: "无法删除密钥（\(status)）") }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VoxError(message: "无法保存密钥（\(status)）") }
    }
}
// Do not forward credentials through HTTP redirects, including custom endpoints.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct SpeechClient {
    static let secureSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    var session: URLSession = secureSession
    func request(text: String, settings: VoiceSettings, key: String) throws -> URLRequest {
        let profile = try settings.resolvedService.validated()
        guard !key.isEmpty else { throw VoxError(message: "请先在服务设置中保存 \(profile.name) 的 API Key。") }
        guard !key.hasPrefix("gen-lang-client-") else { throw VoxError(message: "这是 Google 项目 ID，不是 API Key。请从 Google AI Studio 获取该项目的密钥。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 3000, text.utf8.count <= 12000 else { throw VoxError(message: "朗读文本为空或过长，请拆成更短的段落。") }
        guard profile.voices.contains(settings.voice) else { throw VoxError(message: "当前声音不在服务的声音列表中，请重新选择。") }
        guard settings.speed.isFinite, (0.7...1.3).contains(settings.speed) else { throw VoxError(message: "语速超出支持范围。") }
        let path: String
        switch profile.kind {
        case .gemini: path = "/models/\(profile.model):generateContent"
        case .qwenTTS: path = "/services/aigc/multimodal-generation/generation"
        case .cosyVoice: path = "/services/audio/tts/SpeechSynthesizer"
        case .openAI: path = "/audio/speech"
        }
        guard let url = URL(string: profile.normalizedURL + path) else { throw VoxError(message: "服务地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if profile.kind == .gemini {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let style = settings.instructions + " 语速目标为正常速度的 \(settings.speed) 倍。"
            let part: [String: Any] = profile.modernGemini ? ["text": text, "speech_metadata": ["style": style]] : ["text": "请按以下要求朗读，仅读出正文。\n表达要求：\(style)\n正文：\n\(text)"]
            let voice: [String: Any] = profile.modernGemini ? ["voice": settings.voice] : ["prebuiltVoiceConfig": ["voiceName": settings.voice]]
            body = ["contents": [["role": "user", "parts": [part]]], "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": voice]]]
        } else if profile.kind == .qwenTTS {
            guard text.count <= 600 else { throw VoxError(message: "Qwen-TTS 每段最多 600 字，请拆分段落后重试。") }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var input: [String: Any] = ["text": text, "voice": settings.voice, "language_type": "Auto"]
            if profile.model.hasPrefix("qwen3-tts-instruct-flash") {
                input["instructions"] = settings.instructions + " 语速目标为正常速度的 \(settings.speed) 倍。"
                input["optimize_instructions"] = true
            }
            body = ["model": profile.model, "input": input]
        } else if profile.kind == .cosyVoice {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var input: [String: Any] = ["text": text, "voice": settings.voice, "format": "wav", "sample_rate": 24000, "rate": settings.speed]
            if profile.model == "cosyvoice-v3-flash" || profile.model.hasPrefix("cosyvoice-v3.5-") {
                let direction = settings.direction.trimmingCharacters(in: .whitespacesAndNewlines)
                if !direction.isEmpty { input["instruction"] = direction }
                else if settings.voice == "longanyang" {
                    input["instruction"] = settings.mode == "长文章" ? "你现在说话的角色是一个旁白，你说话的情感是neutral。" : "你正在进行闲聊互动，你说话的情感是neutral。"
                } else if settings.voice == "longanhuan" {
                    input["instruction"] = settings.mode == "长文章" ? "你正在进行深夜电台广播，你说话的情感是neutral。" : "你正在进行闲聊对话，你说话的情感是neutral。"
                }
            }
            body = ["model": profile.model, "input": input]
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var speech: [String: Any] = ["model": profile.model, "voice": settings.voice, "input": text, "speed": settings.speed, "response_format": "pcm"]
            if profile.model != "tts-1" && profile.model != "tts-1-hd" { speech["instructions"] = settings.instructions }
            body = speech
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func generate(text: String, settings: VoiceSettings, key: String, recoveryFile: URL? = nil) async throws -> Data {
        if settings.resolvedService.kind.usesAudioDownload, let file = recoveryFile,
           FileManager.default.fileExists(atPath: file.path) {
            let receipt = try JSONDecoder().decode(DownloadReceipt.self, from: Data(contentsOf: file))
            return try await download(receipt.url, recoveryFile: file)
        }
        let request = try request(text: text, settings: settings, key: key)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ServiceFailure.network(error, download: false) }
        guard let http = response as? HTTPURLResponse else { throw VoxError(message: "未收到有效响应。") }
        guard (200..<300).contains(http.statusCode) else { throw ServiceFailure.http(http.statusCode, body: data) }
        if settings.resolvedService.kind.usesAudioDownload {
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let code = json["code"] as? String, !code.isEmpty {
                throw ServiceFailure.http(http.statusCode, body: data)
            }
            let url = try Self.cosyVoiceAudioURL(data)
            // Persist before cancellation checks or downloads so a successful synthesis can be resumed.
            if let file = recoveryFile { try DownloadReceipt(url: url).save(to: file) }
            try Task.checkCancellation()
            return try await download(url, recoveryFile: recoveryFile)
        }
        try Task.checkCancellation()
        if settings.resolvedService.kind == .gemini { return try Self.geminiPCM(data) }
        return try Self.audioPCM(data, mime: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
    func download(_ url: URL, recoveryFile: URL?) async throws -> Data {
        // Revalidate persisted URLs; downloads never inherit service credentials.
        let wrapper = try JSONSerialization.data(withJSONObject: ["output": ["finish_reason": "stop", "audio": ["url": url.absoluteString]]])
        let safeURL = try Self.cosyVoiceAudioURL(wrapper)
        let audio: Data
        if let file = recoveryFile, FileManager.default.fileExists(atPath: DownloadReceipt.audioFile(file).path) {
            audio = try Data(contentsOf: DownloadReceipt.audioFile(file))
        } else {
            var request = URLRequest(url: safeURL); request.timeoutInterval = 120
            let response: URLResponse
            do { (audio, response) = try await session.data(for: request) }
            catch { throw ServiceFailure.network(error, download: true) }
            guard let http = response as? HTTPURLResponse else { throw ServiceFailure.http(0, body: Data(), download: true) }
            guard (200..<300).contains(http.statusCode) else { throw ServiceFailure.http(http.statusCode, body: Data(), download: true) }
            if let file = recoveryFile { try audio.write(to: DownloadReceipt.audioFile(file), options: .atomic) }
        }
        try Task.checkCancellation()
        do { return try AudioFiles.extractPCM(audio) }
        catch { throw ServiceFailure(stage: "音频格式异常", category: "audio", hint: "已保留原始音频。请确认服务返回 WAV；重试会使用缓存。若仍失败，可放弃下载缓存后重新生成（可能计费）。") }
    }
    static func cosyVoiceAudioURL(_ data: Data) throws -> URL {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoxError(message: "阿里云语音服务返回格式无效。") }
        guard (response["code"] as? String ?? "").isEmpty,
              let output = response["output"] as? [String: Any],
              output["finish_reason"] as? String == "stop",
              let audio = output["audio"] as? [String: Any], let address = audio["url"] as? String,
              var components = URLComponents(string: address) else { throw VoxError(message: "阿里云语音服务未完整生成音频，请核对北京地域的 API Key、模型与音色是否匹配。") }
        // Official responses may use HTTP OSS links. Upgrade to TLS without logging the signed query.
        guard let host = components.host?.lowercased(), host.hasSuffix(".oss-cn-beijing.aliyuncs.com"),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              ["https", "http"].contains(components.scheme?.lowercased() ?? "") else { throw VoxError(message: "阿里云语音服务返回了不支持的音频下载地址。") }
        components.scheme = "https"
        guard let url = components.url else { throw VoxError(message: "阿里云语音服务音频地址无效。") }
        return url
    }
    static func geminiPCM(_ data: Data) throws -> Data {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoxError(message: "Gemini 返回格式无效。") }
        if let feedback = response["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw VoxError(message: "Gemini 拒绝了这段内容，请检查文稿后重试。") }
        guard let candidates = response["candidates"] as? [[String: Any]], let candidate = candidates.first else { throw VoxError(message: "Gemini 没有返回音频，请确认使用的是 TTS 配音模型。") }
        if let reason = candidate["finishReason"] as? String, reason != "STOP" { throw VoxError(message: "Gemini 未完整生成音频，请缩短段落或修改内容后重试。") }
        guard let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw VoxError(message: "Gemini 未返回可用音频。") }
        var result = Data()
        for part in parts {
            guard let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any] else { continue }
            guard let base64 = inline["data"] as? String, let bytes = Data(base64Encoded: base64), let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String else { throw VoxError(message: "Gemini 音频数据无效。") }
            result.append(try audioPCM(bytes, mime: mime))
        }
        guard !result.isEmpty else { throw VoxError(message: "Gemini 没有返回音频，请确认使用的是 TTS 配音模型。") }
        return result
    }
    static func audioPCM(_ data: Data, mime: String) throws -> Data {
        let mime = mime.lowercased().replacingOccurrences(of: " ", with: "")
        if data.prefix(4) == Data("RIFF".utf8) { return try AudioFiles.extractPCM(data) }
        let type = mime.components(separatedBy: ";").first ?? ""
        guard ["audio/pcm", "audio/l16", "application/octet-stream"].contains(type), !data.isEmpty, data.count % 2 == 0 else { throw VoxError(message: "服务未返回有效的 PCM/WAV 音频，请检查接口兼容性。") }
        for parameter in mime.components(separatedBy: ";").dropFirst() {
            if parameter.hasPrefix("rate="), parameter != "rate=24000" { throw VoxError(message: "暂不支持该采样率，服务需返回 24 kHz PCM 或 WAV。") }
            if parameter.hasPrefix("channels="), parameter != "channels=1" { throw VoxError(message: "服务需返回单声道音频。") }
        }
        return data
    }
}
enum AudioFiles {
    static func extractPCM(_ data: Data) throws -> Data { try WAVDecoder.decode(data) }
    // Canonical raw PCM: signed 16-bit little-endian, 24 kHz mono.
    static func wavHeader(byteCount: Int) throws -> Data {
        guard byteCount >= 0, byteCount <= Int(UInt32.max) - 36 else { throw VoxError(message: "音频超过 WAV 大小限制，请分项目导出。") }
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { result.append(contentsOf: $0) } }
        append(UInt32(byteCount + 36)); result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(24000)); append(UInt32(48000)); append(UInt16(2)); append(UInt16(16))
        result.append(Data("data".utf8)); append(UInt32(byteCount))
        return result
    }
    static func writePCM(_ data: Data, to url: URL) throws {
        var wav = try wavHeader(byteCount: data.count); wav.append(data)
        try wav.write(to: url, options: .atomic)
    }
    static func merge(_ urls: [URL], pause: Double, to destination: URL) throws {
        guard !urls.isEmpty else { throw VoxError(message: "没有可以导出的音频。") }
        let silence = Data(count: Int(max(0, min(3, pause)) * 24000) * 2)
        let sizes = try urls.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize! - 44 }
        let header = try wavHeader(byteCount: sizes.reduce(0,+) + silence.count * max(0, urls.count - 1))
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        try header.write(to: temp)
        let out = try FileHandle(forWritingTo: temp)
        defer { try? out.close() }
        try out.seekToEnd()
        for (index, url) in urls.enumerated() {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let sourceHeader = try input.read(upToCount: 44) ?? Data()
            guard sourceHeader == (try wavHeader(byteCount: sizes[index])) else { throw VoxError(message: "项目音频格式不一致或已损坏。") }
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            if index < urls.count - 1 { try out.write(contentsOf: silence) }
        }
        try out.synchronize()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: destination) }
    }
    static func m4a(from source: URL, to destination: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else { throw VoxError(message: "无法创建音频转换任务。") }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? VoxError(message: "音频转换失败。") }
    }
}
