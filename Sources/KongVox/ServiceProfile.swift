import Foundation
import CryptoKit

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case openAI = "OpenAI 兼容"
    case gemini = "Gemini 原生"
    var id: String { rawValue }
}
struct ServiceProfile: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var kind: ServiceKind
    var baseURL: String
    var model: String
    var voices: [String]
    var enabled = true
    static let openAI = ServiceProfile(id: "openai", name: "OpenAI", kind: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-tts", voices: ["marin", "cedar", "coral", "sage", "alloy"])
    static let gemini = ServiceProfile(id: "gemini", name: "Gemini", kind: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-3.8-flash-tts", voices: ["Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"])
    var normalizedURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var signature: String { [id, kind.rawValue, normalizedURL, model].joined(separator: "\u{0}") }
    var keyAccount: String {
        // Preserve 0.1's OpenAI key only at its original endpoint. A changed endpoint never inherits a secret.
        if id == "openai", kind == .openAI, normalizedURL == Self.openAI.baseURL { return "openai" }
        let hash = SHA256.hash(data: Data((kind.rawValue + normalizedURL).utf8)).map { String(format: "%02x", $0) }.joined()
        return id + ":" + hash
    }
    var endpointHost: String { URL(string: normalizedURL)?.host ?? "未设置地址" }
    var isLegacyOpenAI: Bool { signature == Self.openAI.signature }
    var modernGemini: Bool { model.hasPrefix("gemini-3.8-") }
    func validated() throws -> ServiceProfile {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = normalizedURL
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.voices = Array(NSOrderedSet(array: voices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
        guard !result.name.isEmpty, !result.voices.isEmpty, !result.model.isEmpty else { throw VoxError(message: "请填写服务名称、模型和至少一个声音 ID。") }
        guard let components = URLComponents(string: result.baseURL), components.scheme == "https", let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw VoxError(message: "请填写 HTTPS 基础地址，不要包含密钥、查询参数或账号密码。") }
        guard result.model.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw VoxError(message: "模型名称只能包含字母、数字、点、下划线和连字符。") }
        return result
    }
}
struct ServiceCatalog: Codable {
    var profiles: [ServiceProfile] = [.openAI, .gemini]
    var defaultID = "gemini"
}
