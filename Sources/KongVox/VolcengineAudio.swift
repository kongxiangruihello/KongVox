import Foundation

/// V3 SSE response: ordered base64 PCM chunks followed by an explicit completion event.
enum VolcengineAudio {
    static func decode(_ body: Data, resourceID: String? = nil, speaker: String? = nil) throws -> Data {
        guard body.count <= 128 * 1024 * 1024, let text = String(data: body, encoding: .utf8) else { throw invalid() }
        // Authentication/configuration failures can arrive as JSON even with HTTP 200.
        if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let code = statusCode(json), code != 0 && code != 20000000 { throw failure(body: body, resourceID: resourceID, speaker: speaker) }
            throw invalid()
        }
        var result = Data(), complete = false, fields: [String] = []
        func consume() throws {
            guard !fields.isEmpty else { return }
            let data = Data(fields.joined(separator: "\n").utf8); fields = []
            guard !complete, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
            // The official client defaults omitted code to zero for audio events.
            guard let code = statusCode(event) ?? (event["code"] == nil && event["status_code"] == nil && event["data"] is String ? 0 : nil) else { throw invalid() }
            guard code == 0 || code == 20000000 else {
                throw failure(body: data, resourceID: resourceID, speaker: speaker)
            }
            if let encoded = event["data"] as? String {
                guard let bytes = Data(base64Encoded: encoded), result.count + bytes.count <= 96 * 1024 * 1024 else { throw invalid() }
                result.append(bytes)
            } else if let value = event["data"], !(value is NSNull) { throw invalid() }
            if code == 20000000 { complete = true }
        }
        let normalized = (text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.isEmpty { try consume() }
            else if line.hasPrefix("data:") { fields.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix(":") || line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { continue }
            else { throw invalid() }
        }
        try consume()
        guard complete, !result.isEmpty, result.count % 2 == 0 else { throw invalid() }
        return result
    }
    static func statusCode(_ json: [String: Any]) -> Int? {
        let value = json["code"] ?? json["status_code"]
        if let value = value as? String { return Int(value) }
        return value as? Int
    }
    static func failure(body: Data, httpStatus: Int? = nil, resourceID: String? = nil, speaker: String? = nil) -> ServiceFailure {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let code = statusCode(json)
        // Use messages only to classify; never echo response text, credentials or manuscript.
        let message = ((json["message"] as? String) ?? (json["msg"] as? String) ?? "").lowercased()
        let hint: String
        if code == 45000030 {
            let resource = display(resourceID, fallback: "未读取")
            let voice = display(speaker, fallback: "未读取")
            hint = "资源 ID 与声音 ID 不匹配，或资源/音色尚未在当前项目开通。当前请求：资源 ID \(resource)，speaker \(voice)。VV 音色请使用 seed-tts-2.0；复刻音色请使用对应 seed-icl 资源，并检查项目权限。"
        } else if message.contains("quota") || message.contains("balance") || message.contains("credit") {
            hint = "语音服务额度不足，请在豆包语音控制台检查所选资源的额度与开通状态。"
        } else if message.contains("speaker") || message.contains("voice") || message.contains("resource") {
            hint = "资源 ID 与音色不匹配或未开通。VV 音色使用 seed-tts-2.0；复刻音色请使用对应 seed-icl 资源，并检查当前项目的权限。"
        } else if httpStatus == 401 || httpStatus == 403 || message.contains("auth") || message.contains("token") || message.contains("api key") || message.contains("appid") || message.contains("access key") {
            hint = "鉴权失败。新版填写豆包语音控制台的 API Key（不是火山方舟 Key 或云 AccessKey）；旧版填写 AppID 与 Access Token，然后保存并在当前项目应用最新配置。"
        } else if httpStatus == 429 {
            hint = "请求限流，请稍后再试并检查语音服务并发额度。"
        } else if code == 45000001 || httpStatus == 400 {
            hint = "请求参数无效，请核对资源 ID、声音 ID 和文本；若填写了完整接口地址，请改为 https://openspeech.bytedance.com/api/v3。"
        } else {
            hint = "火山语音请求失败，请核对凭据类型、资源开通与音色权限；服务繁忙时稍后重试。"
        }
        return ServiceFailure(stage: "火山引擎合成失败", category: "volcengine_\(code.map(String.init) ?? "http")", hint: (code.map { "错误码 \($0)。" } ?? "") + hint, status: httpStatus)
    }
    private static func display(_ value: String?, fallback: String) -> String {
        let clean = (value ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : String(clean.prefix(120))
    }
    static func invalid() -> ServiceFailure { ServiceFailure(stage: "火山引擎音频异常", category: "volcengine_stream", hint: "响应未完整结束或音频格式无效，未保存残缺配音。可重试，重新请求可能计费。") }
}
