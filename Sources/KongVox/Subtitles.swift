import Foundation

enum Subtitles {
    static func render(texts: [String], audio: [URL], pause: Double) throws -> String {
        guard !texts.isEmpty, texts.count == audio.count, pause.isFinite else { throw VoxError(message: "字幕与配音段落不一致。") }
        var frames: [Int64] = []
        for url in audio {
            frames.append(Int64(try AudioFiles.extractPCM(Data(contentsOf: url)).count / 2))
        }
        return try render(texts: texts, frames: frames, gaps: Array(repeating: max(0, min(3, pause)), count: audio.count))
    }
    static func render(texts: [String], frames: [Int64], gaps: [Double]) throws -> String {
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
            cues.append("\(i + 1)\n\(timestamp(cursor)) --> \(timestamp(cursor + frameCount))\n\(text)\n")
            cursor += frameCount + Int64(gaps[i] * 24000)
        }
        return cues.joined(separator: "\n")
    }
}
