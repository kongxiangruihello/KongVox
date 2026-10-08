import Foundation

struct PronunciationRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var reading: String
    var category: String?
    var enabled: Bool?
    var isEnabled: Bool { enabled ?? true }
}
enum PronunciationDictionary {
    struct Match: Identifiable {
        var id = UUID()
        var rule: PronunciationRule
        var offset: Int
    }
    struct Preview { var text: String; var matches: [Match] }
    static func apply(_ text: String, rules: [PronunciationRule]) -> String { preview(text, rules: rules, recordMatches: false).text }
    static func preview(_ text: String, rules: [PronunciationRule], recordMatches: Bool = true) -> Preview {
        var seen = Set<String>()
        let rules = rules.filter { !$0.word.isEmpty && !$0.reading.isEmpty && seen.insert($0.word).inserted }
            .filter(\.isEnabled).sorted { $0.word.count > $1.word.count }
        if rules.isEmpty { return Preview(text: text, matches: []) }
        var result = "", cursor = text.startIndex, offset = 0, matches: [Match] = []
        while cursor < text.endIndex {
            if let rule = rules.first(where: { text[cursor...].hasPrefix($0.word) }) {
                if recordMatches { matches.append(Match(rule: rule, offset: offset)) }
                result += rule.reading; cursor = text.index(cursor, offsetBy: rule.word.count); offset += rule.word.count
            } else { result.append(text[cursor]); cursor = text.index(after: cursor); offset += 1 }
        }
        return Preview(text: result, matches: matches)
    }
}

struct VoiceChapter: Identifiable {
    var id: UUID { segmentIDs[0] }
    var title: String
    var segmentIDs: [UUID]
}
extension Project {
    var chapters: [VoiceChapter] {
        var result: [VoiceChapter] = []
        for segment in segments {
            let line = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = line.count <= 90 && line.range(of: #"^(#{1,6}\s+\S|第[零〇一二三四五六七八九十百千万0-9]+[章节部篇卷]|[一二三四五六七八九十]+[、．.]|[0-9]+[、．.]\s*\S)"#, options: .regularExpression) != nil
            if heading || result.isEmpty { result.append(VoiceChapter(title: heading ? line : "正文", segmentIDs: [])) }
            result[result.count - 1].segmentIDs.append(segment.id)
        }
        return result
    }
}

struct AudioFinding: Identifiable {
    var id = UUID()
    var segmentID: UUID
    var index: Int
    var seconds: Double
    var message: String
}
enum AudioQuality {
    static func inspect(_ p: Project, root: URL) throws -> [AudioFinding] {
        var findings: [AudioFinding] = [], previousDB: Double?
        for (index, segment) in p.segments.enumerated() {
            try Task.checkCancellation()
            func add(_ message: String, _ seconds: Double = 0) {
                findings.append(AudioFinding(segmentID: segment.id, index: index, seconds: seconds, message: message))
            }
            guard segment.ready(p.settings), let take = segment.current else {
                add("尚未生成或音频已过期"); previousDB = nil; continue
            }
            do {
                let pcm = try AudioFiles.extractPCM(Data(contentsOf: root.appendingPathComponent("Audio").appendingPathComponent(take.file)))
                let frames = pcm.count / 2
                guard frames > 0 else { add("音频为空"); continue }
                var sum = 0.0, voiced = 0, run = 0, longest = 0, longestEnd = 0
                for i in 0..<frames {
                    let sample = Double(Int16(bitPattern: UInt16(pcm[2*i]) | UInt16(pcm[2*i+1]) << 8)) / 32768
                    if abs(sample) < 0.001 { run += 1; if run > longest { longest = run; longestEnd = i + 1 } }
                    else { run = 0; sum += sample * sample; voiced += 1 }
                }
                if longest >= 36000 { add("存在至少 1.5 秒的近静音，请复听", Double(longestEnd - longest) / 24000) }
                if voiced == 0 { add("未检测到明显声音"); previousDB = nil }
                else {
                    let db = 20 * log10(sqrt(sum / Double(voiced)))
                    if let previousDB, abs(db - previousDB) > 8 { add("与前段原始音量相差超过 8 dB；请检查合并后的效果") }
                    previousDB = db
                }
                if Double(frames) / 24000 < Double(p.settings.reading(segment.spokenText).count) * 0.025 {
                    add("音频时长偏短，请核对是否完整朗读")
                }
            } catch { add("音频文件缺失或无法解码"); previousDB = nil }
        }
        return findings
    }
}
