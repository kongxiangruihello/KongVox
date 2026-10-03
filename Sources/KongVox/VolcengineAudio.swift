import Foundation

/// V3 SSE response: ordered base64 PCM chunks followed by an explicit completion event.
enum VolcengineAudio {
    static func decode(_ body: Data) throws -> Data {
        guard body.count <= 128 * 1024 * 1024, let text = String(data: body, encoding: .utf8) else { throw invalid() }
        var result = Data(), complete = false, fields: [String] = []
        func consume() throws {
            guard !fields.isEmpty else { return }
            let data = Data(fields.joined(separator: "\n").utf8); fields = []
            guard !complete, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = event["code"] as? Int else { throw invalid() }
            guard code == 0 || code == 20000000 else {
                throw ServiceFailure(stage: "火山引擎合成失败", category: "volcengine_\(code)", hint: "服务返回错误码 \(code)。请核对 API Key、资源 ID、音色权限及账户额度；未采用本次残缺音频。")
            }
            if let encoded = event["data"] as? String {
                guard let bytes = Data(base64Encoded: encoded), result.count + bytes.count <= 96 * 1024 * 1024 else { throw invalid() }
                result.append(bytes)
            } else if let value = event["data"], !(value is NSNull) { throw invalid() }
            if code == 20000000 { complete = true }
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { try consume() }
            else if line.hasPrefix("data:") { fields.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix(":") || line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { continue }
            else { throw invalid() }
        }
        try consume()
        guard complete, !result.isEmpty, result.count % 2 == 0 else { throw invalid() }
        return result
    }
    static func invalid() -> ServiceFailure { ServiceFailure(stage: "火山引擎音频异常", category: "volcengine_stream", hint: "响应未完整结束或音频格式无效，未保存残缺配音。可重试，重新请求可能计费。") }
}
