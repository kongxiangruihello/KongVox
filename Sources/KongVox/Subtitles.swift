import Foundation

enum SubtitleStyle: String, Codable, CaseIterable, Identifiable {
    case paragraph = "原有段落字幕"
    case sentence = "分句字幕"
    case vertical = "竖屏字幕 · 每行 16 字"
    var id: String { rawValue }
}
enum Subtitles {
    static func render(texts: [String], audio: [URL], pause: Double) throws -> String {
        guard !texts.isEmpty, texts.count == audio.count, pause.isFinite else { throw VoxError(message: "字幕与配音段落不一致。") }
        var frames: [Int64] = []
        for url in audio {
            frames.append(Int64(try AudioFiles.extractPCM(Data(contentsOf: url)).count / 2))
        }
        return try render(texts: texts, frames: frames, gaps: Array(repeating: max(0, min(3, pause)), count: audio.count))
    }
    static func render(texts: [String], frames: [Int64], gaps: [Double], style: SubtitleStyle = .paragraph) throws -> String {
        guard !texts.isEmpty, texts.count == frames.count, frames.count == gaps.count,
              frames.allSatisfy({ $0 > 0 }), gaps.allSatisfy({ $0.isFinite && (0...3).contains($0) }) else { throw VoxError(message: "字幕时间轴无效。") }
        var cursor: Int64 = 0
        func timestamp(_ frames: Int64) -> String {
            let ms = (frames * 1000 + 12000) / 24000
            return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var cues: [String] = []
        for (i, frameCount) in frames.enumerated() {
            let text = texts[i].components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { throw VoxError(message: "字幕段落为空。") }
            var parts = style == .paragraph ? [text] : SentenceText.split(text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if style == .vertical {
                parts = parts.flatMap { part -> [String] in
                    var remaining = part, blocks: [String] = []
                    while !remaining.isEmpty {
                        let block = String(remaining.prefix(32)); blocks.append(block)
                        remaining = String(remaining.dropFirst(block.count))
                    }
                    return blocks
                }
            }
            // Never create zero-length or overlapping cues for abnormally short audio.
            if style != .paragraph && frameCount < Int64(parts.count) * 24 { throw VoxError(message: "音频过短，无法生成有效分句字幕；请检查音频或改用段落字幕。") }
            let total = max(1, parts.reduce(0) { $0 + $1.count })
            var consumed = 0, previous: Int64 = 0
            for (j, part) in parts.enumerated() {
                consumed += part.count
                let minimum: Int64 = style == .paragraph ? 0 : 24
                let remainder = frameCount - minimum * Int64(parts.count)
                let end = j + 1 == parts.count ? frameCount : minimum * Int64(j + 1) + Int64((Double(remainder) * Double(consumed) / Double(total)).rounded(.down))
                let caption: String
                if style == .vertical && part.count > 16 {
                    caption = String(part.prefix(16)) + "\n" + String(part.dropFirst(16))
                } else { caption = part }
                cues.append("\(cues.count + 1)\n\(timestamp(cursor + previous)) --> \(timestamp(cursor + end))\n\(caption)\n")
                previous = end
            }
            cursor += frameCount + Int64(gaps[i] * 24000)
        }
        return cues.joined(separator: "\n")
    }
}
