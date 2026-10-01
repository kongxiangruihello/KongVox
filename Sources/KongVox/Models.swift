import Foundation
import CryptoKit

struct VoiceSettings: Codable, Equatable {
    var service: ServiceProfile?
    var resolvedService: ServiceProfile { service ?? .openAI }
    var voice = "marin"
    var speed = 1.0
    var mode = "短视频口播"
    var direction = ""
    var pause = 0.35
    var instructions: String {
        let base = mode == "短视频口播" ? "用自然的普通话口播，亲切、有感染力，节奏利落，避免夸张的播音腔。" : "用自然的普通话朗读，平稳、温暖、耐听，保持一致的音色和节奏，尊重句子停顿。"
        return base + direction
    }
}
struct Take: Codable, Identifiable {
    var id = UUID()
    var file: String
    var fingerprint: String
    var date = Date()
    var service: ServiceProfile?
    var settings: VoiceSettings?
    var spokenText: String?
}
struct Segment: Codable, Identifiable {
    var id = UUID()
    var text: String
    var pronunciation = ""
    var takes: [Take] = []
    var selectedTake: UUID?
    var spokenText: String { pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : pronunciation }
    var current: Take? { takes.first { $0.id == selectedTake } }
    func fingerprint(_ settings: VoiceSettings) -> String {
        // Pause is applied at export, so it must not invalidate generated speech.
        var fields = [spokenText, settings.voice, String(settings.speed), settings.instructions]
        if !settings.resolvedService.isLegacyOpenAI { fields.append(settings.resolvedService.signature) }
        let payload = fields.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func ready(_ settings: VoiceSettings) -> Bool { current?.fingerprint == fingerprint(settings) }
}
struct Project: Codable, Identifiable {
    var id = UUID()
    var title = "未命名配音"
    var settings = VoiceSettings()
    var segments: [Segment] = []
    var draft = ""
    // Optional fields keep older projects readable without a destructive migration.
    var longMode: Bool?
    var longText: String?
    var preparedLongText: String?
    var archivedSegments: [Segment]?
    var isLongMode: Bool { longMode ?? true }
    var fullText: String { longText ?? (segments.map(\.text) + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n") }
    var chunkLimit: Int { settings.resolvedService.kind == .qwenTTS ? 500 : 700 }
    var needsLongPreparation: Bool {
        fullText != (preparedLongText ?? segments.map(\.text).joined(separator: "\n\n")) ||
        !draft.isEmpty || segments.contains { $0.spokenText.count > chunkLimit }
    }
    mutating func prepareLongDocument() {
        let text = fullText
        if !needsLongPreparation { longText = text; preparedLongText = text; return }
        var available = segments + (archivedSegments ?? [])
        // Reuse unchanged segments, including their history, pronunciation overrides and recovery IDs.
        segments = TextSplitter.split(text, limit: chunkLimit).map { piece in
            if let index = available.firstIndex(where: { $0.text == piece && $0.spokenText.count <= chunkLimit }) {
                return available.remove(at: index)
            }
            return Segment(text: piece)
        }
        archivedSegments = available
        longText = text; preparedLongText = text; draft = ""
    }
}
enum TextSplitter {
    static func split(_ text: String, limit: Int = 700) -> [String] {
        precondition(limit > 0)
        var result: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            var remaining = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            while remaining.count > limit {
                let prefix = String(remaining.prefix(limit))
                let boundary = prefix.lastIndex { "。！？；.!?;".contains($0) }
                let cut = boundary.map { prefix.index(after: $0) } ?? prefix.endIndex
                let piece = String(prefix[..<cut])
                result.append(piece)
                remaining = String(remaining.dropFirst(piece.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !remaining.isEmpty { result.append(remaining) }
        }
        return result
    }
}
struct VoxError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
