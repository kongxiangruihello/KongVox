import Foundation

struct PlaybackCue: Identifiable, Equatable {
    var id: UUID
    var start: Double
    var end: Double
}
enum PlaybackTimeline {
    static func make(ids: [UUID], frames: [Int64], gaps: [Double]) throws -> [PlaybackCue] {
        guard ids.count == frames.count, ids.count == gaps.count,
              frames.allSatisfy({ $0 > 0 }), gaps.allSatisfy({ $0.isFinite && (0...3).contains($0) }) else {
            throw VoxError(message: "播放时间轴与文稿不匹配。")
        }
        var cursor: Int64 = 0, cues: [PlaybackCue] = []
        for i in ids.indices {
            let end = cursor + frames[i]
            cues.append(PlaybackCue(id: ids[i], start: Double(cursor) / 24000, end: Double(end) / 24000))
            cursor = end + (i + 1 < ids.count ? Int64(gaps[i] * 24000) : 0)
        }
        return cues
    }
    // Keep the preceding text highlighted during its following paragraph pause.
    static func current(_ seconds: Double, cues: [PlaybackCue]) -> UUID? {
        guard seconds.isFinite, !cues.isEmpty else { return nil }
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        return cues[max(0, low - 1)].id
    }
}
