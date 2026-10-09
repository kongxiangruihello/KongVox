import Foundation
import CryptoKit
import AppKit

enum SubtitleAlignmentMode: String, Codable, CaseIterable, Identifiable {
    case proportional = "按字数分配"
    case localPauses = "本地停顿辅助 · 不上传音频"
    case speech = "本机语音识别对齐 · 不上传音频"
    var id: String { rawValue }
}

enum ShortVideoTemplate: String, Codable, CaseIterable, Identifiable {
    case clean = "简洁竖屏"
    case headline = "标题 + 竖屏字幕"
    case news = "新闻口播"
    var id: String { rawValue }
    var titleHint: String {
        switch self {
        case .clean: return "KongVox 竖屏配音"
        case .headline: return "本期重点"
        case .news: return "今日口播"
        }
    }
}

struct SeamOptions: Codable, Equatable {
    var crossfadeMilliseconds = 0
    var gainAdjustment = 0.0
    var loopSeamPreview = true
    var enabled: Bool { crossfadeMilliseconds > 0 || abs(gainAdjustment) > 0.001 }
}

struct ProjectVersion: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var label: String
    var payload: Data
}

struct BatchBudget: Codable, Equatable {
    var maxYuan = 0.0
    var yuanPerTenThousand = 1.0
    var maxCharacters = 0
    var enabled: Bool { maxYuan > 0 || maxCharacters > 0 }
}

extension Project {
    var resolvedAlignment: SubtitleAlignmentMode { subtitleAlignment ?? .proportional }
    var resolvedTemplate: ShortVideoTemplate { shortVideoTemplate ?? .clean }
    var resolvedSeam: SeamOptions { seamOptions ?? SeamOptions() }

    func context(for segmentID: UUID, radius: Int = 1) -> String? {
        guard settings.contextHintEnabled == true,
              let index = segments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        let lower = max(0, index - radius), upper = min(segments.count - 1, index + radius)
        let previous = index > lower ? segments[lower..<index].map(\.spokenText).joined(separator: " ") : ""
        let next = index < upper ? segments[(index + 1)...upper].map(\.spokenText).joined(separator: " ") : ""
        let value = [previous.isEmpty ? nil : "前文：\(previous)", next.isEmpty ? nil : "后文：\(next)"].compactMap { $0 }.joined(separator: "\n")
        return value.isEmpty ? nil : value
    }

    func contextFingerprint(for segmentID: UUID) -> String? {
        guard let value = context(for: segmentID) else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum Version011Tools {
    /// Search radius around the proportional estimate, in milliseconds.
    static let pauseSearchRadius: Int64 = 400
    /// Moves sentence boundaries inside a segment to a clearly quieter point near the proportional estimate.
    /// Segment boundaries come from real audio and keep their pauses, so they are never moved.
    static func localPauseCues(texts: [String], frames: [Int64], gaps: [Double], style: SubtitleStyle, pcm: Data) throws -> [CaptionCue] {
        let baseline = try Subtitles.cues(texts: texts, frames: frames, gaps: gaps, style: style)
        guard style != .paragraph, baseline.count > 1, pcm.count >= 2 else { return baseline }
        // Canonical PCM is little-endian Int16; decode explicitly instead of rebinding memory.
        let base = pcm.startIndex
        let samples = stride(from: 0, to: pcm.count - 1, by: 2).map { Int16(bitPattern: UInt16(pcm[base + $0]) | UInt16(pcm[base + $0 + 1]) << 8) }
        let duration = CaptionTimeline.duration(frames: frames, gaps: gaps)
        // Same clock as Subtitles.cues: the last cue of each segment ends exactly here.
        var segmentEnds = Set<Int64>(), cursor: Int64 = 0
        for (i, count) in frames.enumerated() {
            segmentEnds.insert(CaptionTimeline.milliseconds(cursor + count))
            cursor += count + Int64(gaps[i] * 24000)
        }
        func energy(_ ms: Int64) -> Double {
            let frame = max(0, min(samples.count - 1, Int(ms * 24)))
            let radius = min(720, samples.count / 20)
            guard radius > 0 else { return 1 }
            var sum = 0.0
            for i in max(0, frame - radius)..<min(samples.count, frame + radius) { sum += abs(Double(samples[i])) }
            return sum / Double(max(1, radius * 2))
        }
        var output = baseline
        let margin: Int64 = 80, step: Int64 = 20
        for i in 0..<(output.count - 1) {
            let boundary = output[i].end
            guard !segmentEnds.contains(boundary), output[i + 1].start == boundary else { continue }
            let lower = max(output[i].start + margin, boundary - pauseSearchRadius)
            let upper = min(output[i + 1].end - margin, boundary + pauseSearchRadius)
            guard upper > lower else { continue }
            let original = energy(boundary)
            var best = original, candidate = boundary, position = lower
            while position <= upper {
                let value = energy(position)
                if value < best { best = value; candidate = position }
                position += step
            }
            // Keep the proportional estimate unless the pause is clearly quieter than it.
            guard candidate != boundary, best < original * 0.5 else { continue }
            output[i].end = candidate; output[i + 1].start = candidate
        }
        try CaptionTimeline.validate(output, duration: duration)
        return output
    }

    static func ass(cues: [CaptionCue], duration: Int64, style: ShortVideoTemplate) throws -> String {
        try CaptionTimeline.validate(cues, duration: duration)
        func time(_ ms: Int64) -> String { String(format: "%lld:%02lld:%02lld.%02lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms / 10 % 100) }
        let header = "[Script Info]\nScriptType: v4.00+\nPlayResX: 1080\nPlayResY: 1920\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,PingFang SC,64,&H00FFFFFF,&H00FFFFFF,&H00111111,&H66000000,0,0,1,3,1,2,80,80,180,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let events = cues.map { cue in "Dialogue: 0,\(time(cue.start)),\(time(cue.end)),Default,,0,0,0,,\(assText(cue.text))" }
        return header + "\n" + events.joined(separator: "\n") + "\n"
    }
    /// Subtitle text as literal ASS text: braces start override tags and backslashes start escapes,
    /// so they are replaced with full-width forms; line breaks become \N.
    static func assText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "＼")
            .replacingOccurrences(of: "{", with: "｛").replacingOccurrences(of: "}", with: "｝")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    static func packageManifest(project: Project, duration: Double, template: ShortVideoTemplate) -> String {
        let payload: [String: Any] = ["template": template.rawValue, "title": project.title, "duration": duration, "subtitleStyle": project.resolvedSubtitleStyle.rawValue, "alignment": project.resolvedAlignment.rawValue, "voice": project.settings.voice]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension Studio {
    func contextAware(_ enabled: Bool) { edit { $0.settings.contextHintEnabled = enabled } }

    func saveVersion(_ label: String) {
        guard !isWorking, storageAvailable, let p = project else { return }
        flushPendingSave()
        var snapshot = p; snapshot.versions = nil
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        do {
            let version = ProjectVersion(label: trimmed.isEmpty ? "自动保存版本" : trimmed, payload: try JSONEncoder().encode(snapshot))
            try writeVersions(Array((try loadVersions(p.id) + [version]).suffix(30)), for: p.id)
            status = "已保存版本：\(version.label)"
        } catch { self.error = "版本保存失败：\(error.localizedDescription)" }
    }

    func restoreVersion(_ version: ProjectVersion) {
        guard !isWorking, let current = project else { return }
        do {
            var restored = try JSONDecoder().decode(Project.self, from: version.payload)
            restored.id = current.id; restored.versions = nil
            edit { $0 = restored }
            status = "已恢复版本：\(version.label)，请重新检查生成范围。"
        } catch { self.error = "版本恢复失败：\(error.localizedDescription)" }
    }

    func estimatedQueueCharacters() -> Int { queue.compactMap { entry in projects.first { $0.id == entry.projectID } }.reduce(0) { $0 + queueCharacters($1) } }
    func estimatedQueueCost() -> Double { Double(estimatedQueueCharacters()) / 10000.0 * batchBudget.yuanPerTenThousand }

    func exportShortVideoPackage() {
        guard !isWorking, let p = project else { return }
        do {
            let urls = try currentURLs()
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "选择文件夹"
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            let destination = directory.appendingPathComponent("KongVox-短视频-" + BatchExport.safeName(String(p.title.prefix(30))))
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw VoxError(message: "目标文件夹已存在，请换一个位置。") }
            busy = true; stop(); status = "正在生成短视频交付包…"
            let folder = root
            task = Task {
                defer { busy = false; task = nil }
                do {
                    try await Task.detached { try ShortVideoExport.write(p, urls: urls, root: folder, to: destination) }.value
                    status = "短视频交付包已生成"; NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

enum ShortVideoExport {
    /// Builds the package in a hidden sibling folder and moves it into place only when every file is written.
    static func write(_ project: Project, urls: [URL], root: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw VoxError(message: "目标文件夹已存在，请换一个位置。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".kongvox-short-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let audioURL = staging.appendingPathComponent("旁白.wav")
        let frames = try AudioAssembly.render(urls: urls, gaps: project.gaps, normalize: project.levelsEnabled, to: audioURL, seam: project.resolvedSeam)
        let total = CaptionTimeline.duration(frames: frames, gaps: project.gaps)
        let pcm: Data? = try project.needsAlignmentPCM ? AudioFiles.extractPCM(Data(contentsOf: audioURL)) : nil
        let cues = try project.captionCues(frames: frames, pcm: pcm, root: root)
        try CaptionTimeline.render(cues, duration: total).write(to: staging.appendingPathComponent("字幕.srt"), atomically: true, encoding: .utf8)
        try Version011Tools.ass(cues: cues, duration: total, style: project.resolvedTemplate).write(to: staging.appendingPathComponent("字幕.ass"), atomically: true, encoding: .utf8)
        try Version011Tools.packageManifest(project: project, duration: Double(total) / 1000, template: project.resolvedTemplate).write(to: staging.appendingPathComponent("项目.json"), atomically: true, encoding: .utf8)
        try "标题：\(project.resolvedTemplate.titleHint)\n项目：\(project.title)".write(to: staging.appendingPathComponent("标题页.txt"), atomically: true, encoding: .utf8)
        try "感谢观看\n\(project.title)".write(to: staging.appendingPathComponent("结尾页.txt"), atomically: true, encoding: .utf8)
        try "KongVox 短视频交付包\n模板：\(project.resolvedTemplate.rawValue)\n旁白：旁白.wav\n字幕：字幕.srt / 字幕.ass\n字幕时间：\(project.resolvedAlignment.rawValue)\n".write(to: staging.appendingPathComponent("交付清单.txt"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: staging, to: destination)
    }
}
