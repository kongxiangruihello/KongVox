import Foundation
import Security
import AVFoundation

struct KeyStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.kongvox.api", kSecAttrAccount as String: "openai"]
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw VoxError(message: "无法读取钥匙串（\(status)）") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String) throws {
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
struct SpeechClient {
    var session: URLSession = .shared
    func generate(text: String, settings: VoiceSettings, key: String) async throws -> Data {
        guard !key.isEmpty else { throw VoxError(message: "请先在服务设置中保存 API Key。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 12000 else { throw VoxError(message: "朗读文本为空或过长，请拆成更短的段落。") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4o-mini-tts", "voice": settings.voice, "input": text, "instructions": settings.instructions, "speed": settings.speed, "response_format": "pcm"])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoxError(message: "未收到有效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            switch http.statusCode {
            case 401: message = "API Key 无效或已过期。"
            case 403: message = "账户或所在地区没有访问权限。"
            case 429: message = "额度不足或请求过于频繁，请检查账户后重试。"
            default: message = "语音服务返回错误（\(http.statusCode)），请稍后重试。"
            }
            throw VoxError(message: message)
        }
        guard !data.isEmpty, data.count % 2 == 0, !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else { throw VoxError(message: "服务返回的音频无效。") }
        return data
    }
}
enum AudioFiles {
    // OpenAI raw PCM: signed 16-bit little-endian, 24 kHz mono.
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
