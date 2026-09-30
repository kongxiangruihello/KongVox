import Foundation

enum Subtitles {
    static func render(texts: [String], audio: [URL], pause: Double) throws -> String {
        guard !texts.isEmpty, texts.count == audio.count, pause.isFinite else { throw VoxError(message: "字幕与配音段落不一致。") }
        var cursor: Int64 = 0
        let gap = Int64(max(0, min(3, pause)) * 24000)
        func timestamp(_ frames: Int64) -> String {
            let ms = (frames * 1000 + 12000) / 24000
            return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var cues: [String] = []
        for (i, url) in audio.enumerated() {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 44, (size - 44) % 2 == 0,
                  try handle.read(upToCount: 44) == AudioFiles.wavHeader(byteCount: size - 44) else { throw VoxError(message: "音频损坏，无法计算字幕时间。") }
            let frames = Int64((size - 44) / 2)
            let text = texts[i].components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { throw VoxError(message: "字幕段落为空。") }
            cues.append("\(i + 1)\n\(timestamp(cursor)) --> \(timestamp(cursor + frames))\n\(text)\n")
            cursor += frames + gap
        }
        return cues.joined(separator: "\n")
    }
}
