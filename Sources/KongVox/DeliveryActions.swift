import SwiftUI

extension Studio {
    func splitLocal(_ id: UUID) {
        guard !isWorking, var p = project else { return }
        do { try p.splitForLocalRepair(id); edit { $0 = p }; status = "只拆分了所选段落，其他音频保留；请检查本次生成范围。" }
        catch { self.error = error.localizedDescription }
    }
    func restoreContext() {
        guard !isWorking, var p = project else { return }
        do { try p.restoreContextGrouping(); edit { $0 = p }; status = "已恢复上下文分批；匹配的历史音频可复用，其余内容需确认后生成。" }
        catch { self.error = error.localizedDescription }
    }
    func playRange(_ url: URL, start: Double, end: Double, loop: Bool) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return }
        play(url)
        guard let player, end <= player.duration + 0.001 else { stop(); error = "试听范围超过音频时长。"; return }
        playbackRange = start...min(end, player.duration); repeatRange = loop; seek(start)
    }
    func playSeam(after id: UUID) {
        guard !isWorking, let p = project, let i = p.segments.firstIndex(where: { $0.id == id }), i + 1 < p.segments.count else { return }
        guard !(p.isLongMode && p.needsLongPreparation), ready(p.segments[i], in: p), ready(p.segments[i + 1], in: p) else { error = "接缝两侧需有匹配当前设置的音频。"; return }
        let folder = root, destination = root.appendingPathComponent("seam-preview.wav")
        stop(); busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                let pcm = try await Task.detached { try SeamPreview.pcm(p, after: i, root: folder) }.value
                try AudioFiles.writePCM(pcm, to: destination)
                playRange(destination, start: 0, end: Double(pcm.count) / 48000, loop: true)
                status = "循环试听接缝前后各最多 3 秒，包含实际停顿与音量处理；点击停止结束。"
            } catch { self.error = error.localizedDescription }
        }
    }
    func saveCaptions(_ cues: [CaptionCue], signature: String, duration: Int64) throws {
        guard !isWorking, storageAvailable, let p = project, p.captionSignature == signature, fullAudioReady else { throw VoxError(message: "音频已改变，请重新加载字幕时间轴。") }
        try CaptionTimeline.validate(cues, duration: duration)
        guard let index = projects.firstIndex(where: { $0.id == p.id }) else { return }
        stop(); let previous = projects[index]
        projects[index].captionEdits = CaptionEdits(signature: signature, cues: cues)
        guard save() else { projects[index] = previous; throw VoxError(message: "字幕保存失败，原字幕保持不变。") }
        findings = []; qualitySummary = "字幕已改变，请重新检查交付内容。"
        status = "字幕已保存，单独 SRT、ZIP 与整篇批量导出使用此版本。"
    }
    /// Drops saved manual captions so exports fall back to automatic captions. Audio and manuscript are untouched.
    func clearCaptionEdits() {
        guard !isWorking, storageAvailable, project?.captionEdits != nil else { return }
        edit { $0.captionEdits = nil }
        status = "已清除手工字幕，导出将使用自动字幕。"
    }
}
enum SeamPreview {
    static func pcm(_ p: Project, after index: Int, root: URL) throws -> Data {
        guard index >= 0, index + 1 < p.segments.count else { throw VoxError(message: "接缝位置无效。") }
        var prepared: [Data] = []
        let seam = p.resolvedSeam
        for i in index...index + 1 {
            guard p.isReady(p.segments[i], root: root), let take = p.segments[i].current else { throw VoxError(message: "接缝音频尚未就绪。") }
            let source = try Data(contentsOf: root.appendingPathComponent("Audio").appendingPathComponent(take.file))
            let joinedBefore = i > 0 && p.gaps[i - 1] == 0, joinedAfter = i + 1 < p.segments.count && p.gaps[i] == 0
            var pcm = try AudioAssembly.prepare(source, trimStart: joinedBefore, trimEnd: joinedAfter, normalize: p.levelsEnabled)
            // Same seam fades and gain as the exported mix, so the preview is what will be delivered.
            if seam.enabled { pcm = AudioAssembly.applySeam(pcm, fadeIn: joinedBefore, fadeOut: joinedAfter, options: seam) }
            prepared.append(pcm)
        }
        var result = Data(prepared[0].suffix(3 * 48000))
        result.append(Data(count: Int(p.gaps[index] * 24000) * 2))
        result.append(prepared[1].prefix(3 * 48000))
        return result
    }
}
