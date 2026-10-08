import Foundation
import CryptoKit

struct CaptionCue: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Int64
    var end: Int64
    var text: String
}
struct CaptionEdits: Codable {
    var signature: String
    var cues: [CaptionCue]
}
enum CaptionTimeline {
    static func milliseconds(_ frames: Int64) -> Int64 { (frames * 1000 + 12000) / 24000 }
    static func duration(frames: [Int64], gaps: [Double]) -> Int64 {
        milliseconds(frames.reduce(0, +) + gaps.dropLast().reduce(Int64(0)) { $0 + Int64($1 * 24000) })
    }
    static func validate(_ cues: [CaptionCue], duration: Int64) throws {
        guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count else { throw VoxError(message: "字幕不能为空或包含重复条目。") }
        var end: Int64 = 0
        for cue in cues {
            guard cue.start >= end, cue.end > cue.start, cue.end <= duration,
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !cue.text.contains("\n\n"), !cue.text.contains("\r"), !cue.text.contains("-->") else {
                throw VoxError(message: "字幕须按时间排序、互不重叠且不超过音频时长；文字不能为空、含空行或时间轴箭头。")
            }
            end = cue.end
        }
    }
    static func split(_ cue: CaptionCue, after count: Int) throws -> [CaptionCue] {
        guard count > 0, count < cue.text.count, cue.end - cue.start >= 2 else { throw VoxError(message: "请选择文字中间的拆分位置，并留出至少 2 毫秒。") }
        let first = String(cue.text.prefix(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(cue.text.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { throw VoxError(message: "拆分后的两条字幕都需要文字。") }
        let boundary = cue.start + max(1, min(cue.end - cue.start - 1, Int64(Double(cue.end - cue.start) * Double(count) / Double(cue.text.count))))
        return [CaptionCue(id: cue.id, start: cue.start, end: boundary, text: first), CaptionCue(start: boundary, end: cue.end, text: second)]
    }
    static func merge(_ first: CaptionCue, _ second: CaptionCue) -> CaptionCue {
        CaptionCue(id: first.id, start: first.start, end: second.end, text: first.text + "\n" + second.text)
    }
    static func render(_ cues: [CaptionCue], duration: Int64) throws -> String {
        try validate(cues, duration: duration)
        func time(_ ms: Int64) -> String { String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000) }
        return cues.enumerated().map { "\($0.offset + 1)\n\(time($0.element.start)) --> \(time($0.element.end))\n\($0.element.text)\n" }.joined(separator: "\n")
    }
}
extension Project {
    // Includes audio identity and every input that changes the rendered timeline or generated captions.
    var captionSignature: String {
        struct Identity: Encodable { var ids: [UUID]; var takes: [UUID?]; var files: [String?]; var text: [String]; var fingerprints: [String]; var gaps: [Double]; var normalize: Bool; var style: SubtitleStyle }
        let identity = Identity(ids: segments.map(\.id), takes: segments.map(\.selectedTake), files: segments.map { $0.current?.file }, text: segments.map(\.text), fingerprints: segments.map { $0.fingerprint(settings) }, gaps: gaps, normalize: levelsEnabled, style: resolvedSubtitleStyle)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(identity)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    var captionsStale: Bool { captionEdits.map { $0.signature != captionSignature } ?? false }
    func captionCues(frames: [Int64], pcm: Data? = nil) throws -> [CaptionCue] {
        guard !captionsStale else { throw VoxError(message: "音频、文稿或字幕样式已改变，请打开字幕编辑器重新生成时间轴并核对。") }
        let result: [CaptionCue]
        if let saved = captionEdits { result = saved.cues }
        else if resolvedAlignment == .localPauses, let pcm {
            result = try Version011Tools.localPauseCues(texts: segments.map(\.text), frames: frames, gaps: gaps, style: resolvedSubtitleStyle, pcm: pcm)
        } else { result = try Subtitles.cues(texts: segments.map(\.text), frames: frames, gaps: gaps, style: resolvedSubtitleStyle) }
        try CaptionTimeline.validate(result, duration: CaptionTimeline.duration(frames: frames, gaps: gaps))
        return result
    }
    func captionContent(frames: [Int64]) throws -> String {
        try CaptionTimeline.render(captionCues(frames: frames), duration: CaptionTimeline.duration(frames: frames, gaps: gaps))
    }
    mutating func splitForLocalRepair(_ id: UUID) throws {
        guard !(isLongMode && needsLongPreparation), let i = segments.firstIndex(where: { $0.id == id }) else { throw VoxError(message: "请先更新文稿处理范围。") }
        let old = segments[i]
        guard old.pronunciation.isEmpty, old.speedOverride == nil, old.pauseOverride == nil else { throw VoxError(message: "本段已有精修，请先备份并清除本段精修，再拆句。其他段落不受影响。") }
        let pieces = SentenceText.chunks(old.text, limit: chunkLimit)
        guard pieces.count > 1 else { throw VoxError(message: "这一段已经是单句，无需拆分。") }
        var replacements = pieces.map { chunk -> Segment in var s = Segment(text: chunk.text); s.paragraphEnd = false; return s }
        replacements[replacements.count - 1].paragraphEnd = paragraphEnds[i]
        archivedSegments = (archivedSegments ?? []) + [old]
        localSplitSources = (localSplitSources ?? []) + [old.id]
        segments.replaceSubrange(i...i, with: replacements)
    }
    mutating func restoreContextGrouping() throws {
        guard segments.allSatisfy({ $0.pronunciation.isEmpty && $0.speedOverride == nil && $0.pauseOverride == nil }) else { throw VoxError(message: "请先备份并处理现有读法、语速和停顿精修，再恢复上下文分批。") }
        let text = isLongMode ? fullText : (segments.map(\.text) + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n")
        var available = segments + (archivedSegments ?? [])
        segments = LongChunker.split(text, limit: chunkLimit).map { chunk in
            if let i = available.firstIndex(where: { $0.text == chunk.text }) { var s = available.remove(at: i); s.paragraphEnd = chunk.paragraphEnd; return s }
            var s = Segment(text: chunk.text); s.paragraphEnd = chunk.paragraphEnd; return s
        }
        localSplitSources = nil
        archivedSegments = available; sentenceEditing = false; preparedSentenceEditing = false
        longText = text; preparedLongText = text; draft = ""
    }
}
struct GenerationImpact {
    var generate = 0
    var recover = 0
    var reuse = 0
    var untouched = 0
    var pending = Set<UUID>()
    init(_ p: Project, selected: Set<UUID>, force: Bool, ready: (Segment) -> Bool, recovery: (Segment) -> Bool) {
        for s in p.segments {
            let count = p.settings.reading(s.spokenText).count
            guard selected.contains(s.id) else { untouched += count; continue }
            if !force && ready(s) { reuse += count }
            else { pending.insert(s.id); if recovery(s) { recover += count } else { generate += count } }
        }
    }
}
struct DeliveryReport {
    var duration: Double?
    var missing: [UUID]
    var candidates: [UUID]
    var findings: [AudioFinding]
    var subtitleError: String?
    var renderError: String?
    var needsPreparation: Bool
    var audioReady: Bool { !needsPreparation && missing.isEmpty && duration != nil && renderError == nil }
    static func inspect(_ p: Project, root: URL) throws -> DeliveryReport {
        let urls = p.segments.compactMap { $0.current.map { root.appendingPathComponent("Audio").appendingPathComponent($0.file) } }
        let missing = p.segments.filter { !$0.ready(p.settings) || $0.current.map { !FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio").appendingPathComponent($0.file).path) } ?? true }.map(\.id)
        let candidates = p.segments.filter { s in s.takes.contains { $0.id != s.selectedTake && $0.fingerprint == s.fingerprint(p.settings) } }.map(\.id)
        var report = DeliveryReport(missing: missing, candidates: candidates, findings: try AudioQuality.inspect(p, root: root), needsPreparation: (p.isLongMode && p.needsLongPreparation) || !p.draft.isEmpty || p.segments.isEmpty)
        if missing.isEmpty && !report.needsPreparation {
            do {
                let frames = try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: p.levelsEnabled)
                report.duration = Double(CaptionTimeline.duration(frames: frames, gaps: p.gaps)) / 1000
                do { _ = try p.captionContent(frames: frames) } catch { report.subtitleError = error.localizedDescription }
            } catch { report.renderError = error.localizedDescription }
        }
        return report
    }
}
