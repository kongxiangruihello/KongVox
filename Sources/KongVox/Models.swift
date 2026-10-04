import Foundation
import CryptoKit

struct VoiceSettings: Codable, Equatable {
    var service: ServiceProfile?
    var resolvedService: ServiceProfile { service ?? .openAI }
    var pronunciationRules: [PronunciationRule]?
    var globalPronunciationRules: [PronunciationRule]?
    func reading(_ text: String) -> String { PronunciationDictionary.apply(text, rules: (pronunciationRules ?? []) + (globalPronunciationRules ?? [])) }
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
    var paragraphEnd: Bool?
    var speedOverride: Double?
    var pauseOverride: Double?
    var takes: [Take] = []
    var selectedTake: UUID?
    var spokenText: String { pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : pronunciation }
    var current: Take? { takes.first { $0.id == selectedTake } }
    func effectiveSettings(_ base: VoiceSettings) -> VoiceSettings {
        var value = base
        if let speedOverride { value.speed = speedOverride }
        return value
    }
    func fingerprint(_ base: VoiceSettings) -> String {
        let settings = effectiveSettings(base)
        // Pause is applied at export, so it must not invalidate generated speech.
        var fields = [settings.reading(spokenText), settings.voice, String(settings.speed), settings.instructions]
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
    var usesDictionarySnapshot: Bool?
    var taskState: String?
    var taskMessage: String?
    var normalizeVolume: Bool?
    var sentenceEditing: Bool?
    var preparedSentenceEditing: Bool?
    var subtitleStyle: SubtitleStyle?
    var sentenceMode: Bool { sentenceEditing ?? false }
    var resolvedSubtitleStyle: SubtitleStyle { subtitleStyle ?? .paragraph }
    var levelsEnabled: Bool { normalizeVolume ?? true }
    var paragraphEnds: [Bool] {
        if segments.allSatisfy({ $0.paragraphEnd != nil }) { return segments.map { $0.paragraphEnd! } }
        // Recover natural paragraph boundaries for unchanged 0.4 full-text projects.
        var texts: [String] = [], ends: [Bool] = []
        for paragraph in fullText.components(separatedBy: .newlines) {
            let pieces = TextSplitter.split(paragraph, limit: chunkLimit)
            texts += pieces; ends += pieces.indices.map { $0 == pieces.count - 1 }
        }
        if texts == segments.map(\.text) { return ends }
        return segments.map { $0.paragraphEnd ?? true }
    }
    var gaps: [Double] {
        let ends = paragraphEnds
        return segments.enumerated().map { i, segment in
            let value = segment.pauseOverride ?? (ends[i] ? settings.pause : 0)
            return value.isFinite ? max(0, min(3, value)) : 0
        }
    }
    var isLongMode: Bool { longMode ?? true }
    var fullText: String { longText ?? (segments.map(\.text) + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n") }
    var chunkLimit: Int { settings.resolvedService.kind == .qwenTTS ? 500 : 700 }
    var needsLongPreparation: Bool {
        sentenceMode != (preparedSentenceEditing ?? false) ||
        fullText != (preparedLongText ?? segments.map(\.text).joined(separator: "\n\n")) ||
        !draft.isEmpty || segments.contains { $0.spokenText.count > chunkLimit }
    }
    mutating func prepareLongDocument() {
        let text = fullText
        if !needsLongPreparation { longText = text; preparedLongText = text; return }
        var available = segments + (archivedSegments ?? [])
        // Reuse unchanged segments, including their history, pronunciation overrides and recovery IDs.
        let chunks = sentenceMode ? SentenceText.chunks(text, limit: chunkLimit) : LongChunker.reconcile(text, limit: chunkLimit, existing: available)
        segments = chunks.map { chunk in
            let piece = chunk.text
            if let index = available.firstIndex(where: { $0.text == piece && $0.spokenText.count <= chunkLimit }) {
                var segment = available.remove(at: index); segment.paragraphEnd = chunk.paragraphEnd; return segment
            }
            var segment = Segment(text: piece); segment.paragraphEnd = chunk.paragraphEnd; return segment
        }
        archivedSegments = available
        longText = text; preparedLongText = text; preparedSentenceEditing = sentenceMode; draft = ""
    }
}
enum LongChunker {
    struct Chunk { var text: String; var paragraphEnd: Bool }
    // Exact existing pieces act as anchors so an insertion does not shift every later chunk.
    static func reconcile(_ text: String, limit: Int, existing: [Segment]) -> [Chunk] {
        var pool = existing.filter { $0.text.count <= limit && !$0.text.isEmpty }
        var output: [Chunk] = []
        for paragraph in text.components(separatedBy: .newlines) {
            var remaining = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = output.count
            while !remaining.isEmpty {
                let matches = pool.enumerated().compactMap { pair -> (Int, Range<String.Index>)? in
                    remaining.range(of: pair.element.text).map { (pair.offset, $0) }
                }
                let match = matches.min { a, b in
                    a.1.lowerBound == b.1.lowerBound ? pool[a.0].text.count > pool[b.0].text.count : a.1.lowerBound < b.1.lowerBound
                }
                if let match {
                    let prefix = String(remaining[..<match.1.lowerBound])
                    output += (output.isEmpty ? split(prefix, limit: limit) : TextSplitter.split(prefix, limit: limit).map { Chunk(text: $0, paragraphEnd: false) })
                    output.append(Chunk(text: pool.remove(at: match.0).text, paragraphEnd: false))
                    remaining = String(remaining[match.1.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    output += (output.isEmpty ? split(remaining, limit: limit) : TextSplitter.split(remaining, limit: limit).map { Chunk(text: $0, paragraphEnd: false) })
                    remaining = ""
                }
            }
            if output.count > start {
                for i in start..<output.count { output[i].paragraphEnd = i == output.count - 1 }
            }
        }
        return output
    }
    static func split(_ text: String, limit: Int) -> [Chunk] {
        var result: [Chunk] = []
        for paragraph in text.components(separatedBy: .newlines) {
            var remaining = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remaining.isEmpty else { continue }
            if result.isEmpty, remaining.count > 120, let opening = TextSplitter.split(remaining, limit: min(120, limit)).first {
                result.append(Chunk(text: opening, paragraphEnd: false))
                remaining = String(remaining.dropFirst(opening.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pieces = TextSplitter.split(remaining, limit: limit)
            result += pieces.enumerated().map { Chunk(text: $0.element, paragraphEnd: $0.offset == pieces.count - 1) }
        }
        return result
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
