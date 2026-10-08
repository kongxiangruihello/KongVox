import SwiftUI

struct VoicePreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var settings: VoiceSettings
    var normalize: Bool
}
struct QueueEntry: Codable, Identifiable {
    var id = UUID()
    var projectID: UUID
    var state = "等待"
    var maxCharacters: Int?
    var maxYuan: Double?
}
extension Studio {
    func savePresets(_ values: [VoicePreset]) {
        guard !isWorking, storageAvailable else { return }
        do { try JSONEncoder().encode(values).write(to: root.appendingPathComponent("presets.json"), options: .atomic); presets = values }
        catch { self.error = "无法保存配音预设。" }
    }
    func storePreset(_ name: String) {
        guard let p = project, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var settings = p.settings; settings.pronunciationRules = nil; settings.globalPronunciationRules = nil
        savePresets(presets + [VoicePreset(name: String(name.prefix(80)), settings: settings, normalize: p.levelsEnabled)])
    }
    func applyPreset(_ preset: VoicePreset, create: Bool) {
        guard !isWorking else { return }
        guard catalog.profiles.contains(where: { $0 == preset.settings.resolvedService && $0.enabled }) else { error = "预设的服务配置已改变或停用，请重新保存预设。"; return }
        if create { newProject() }
        edit { p in
            let local = p.settings.pronunciationRules, global = p.settings.globalPronunciationRules
            p.settings = preset.settings; p.settings.pronunciationRules = local; p.settings.globalPronunciationRules = global
            p.normalizeVolume = preset.normalize
        }
        status = "已应用预设：\(preset.name)。已有音频保留；声音改变的内容需重新生成。"
    }
    func importDocuments(_ documents: [ImportedDocument], options: ImportOptions) {
        guard !isWorking, storageAvailable else { return }
        var additions: [Project] = []
        for document in documents {
            let text = DocumentImport.clean(document.text, options: options)
            guard !text.isEmpty else { error = "过滤后文稿为空，请检查导入预览。"; return }
            var p = makeProject(); p.title = document.title; p.longMode = true; p.longText = text
            additions.append(p)
        }
        let old = projects; projects.insert(contentsOf: additions, at: 0)
        guard save() else { projects = old; return }
        selected = additions.first?.id; status = "已导入 \(additions.count) 篇文稿，尚未调用语音服务。"
    }
    @discardableResult func saveQueue() -> Bool {
        guard storageAvailable else { return false }
        do { try JSONEncoder().encode(queue).write(to: root.appendingPathComponent("queue.json"), options: .atomic); return true }
        catch { self.error = "无法保存任务队列，已停止后续生成。"; return false }
    }
    func enqueue(_ id: UUID) {
        guard !isWorking, !queue.contains(where: { $0.projectID == id }) else { return }
        queue.append(QueueEntry(projectID: id)); saveQueue()
    }
    func queueCharacters(_ p: Project) -> Int {
        var prepared = p; if prepared.isLongMode { prepared.prepareLongDocument() }
        return prepared.segments.filter { !ready($0, in: prepared) }.reduce(0) { $0 + prepared.settings.reading($1.spokenText).count }
    }
    func pauseQueue() {
        queueStop = true
        if busy { pauseRequested = true; status = "当前片段完成并保存后暂停队列…" }
    }
    func skipQueueProject() { queueSkip = true; task?.cancel() }
    func startQueue(skipFailures: Bool) {
        guard !isWorking, storageAvailable, !queue.isEmpty else { return }
        let totalCharacters = estimatedQueueCharacters()
        let totalCost = estimatedQueueCost()
        if batchBudget.maxCharacters > 0 && totalCharacters > batchBudget.maxCharacters { error = "队列预计 \(totalCharacters) 字，超过设定上限 \(batchBudget.maxCharacters) 字。"; return }
        if batchBudget.maxYuan > 0 && totalCost > batchBudget.maxYuan { error = String(format: "队列预计约 %.2f 元，超过设定上限 %.2f 元。", totalCost, batchBudget.maxYuan); return }
        // Explicit start retries paused/failed/skipped entries, and rechecks previously completed projects.
        for i in queue.indices { queue[i].state = "等待" }
        guard saveQueue() else { return }
        queueRunning = true; queueStop = false; queueSkip = false; stop()
        queueTask = Task {
            defer { queueRunning = false; queueTask = nil; queueStop = false; queueSkip = false }
            for i in queue.indices {
                if queueStop { break }
                if queueSkip {
                    queue[i].state = "已跳过"; queueSkip = false
                    guard saveQueue() else { break }; continue
                }
                guard let p = projects.first(where: { $0.id == queue[i].projectID }) else {
                    queue[i].state = "项目不存在"; if !saveQueue() || !skipFailures { break }; continue
                }
                selected = p.id; error = nil; queue[i].state = "生成中"
                guard saveQueue() else { break }
                generate(fromQueue: true)
                let generation = task; await generation?.value
                if queueSkip { queue[i].state = "已跳过"; queueSkip = false }
                else if fullAudioReady { queue[i].state = "已完成" }
                else if queueStop { queue[i].state = "已暂停" }
                else { queue[i].state = "失败" }
                guard saveQueue() else { break }
                if queue[i].state == "失败" && !skipFailures { break }
            }
            status = queueStop ? "队列已暂停，已完成音频可复用。" : queue.allSatisfy { $0.state == "已完成" } ? "队列全部完成。" : "队列已停止；可检查失败或跳过的项目后再次开始。"
        }
    }
    func exportBatch(ids: Set<UUID>, chapters: Bool) {
        guard !isWorking else { return }
        let snapshots = projects.filter { ids.contains($0.id) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "导出到此文件夹"
        guard !snapshots.isEmpty, panel.runModal() == .OK, let directory = panel.url else { return }
        let destination = directory.appendingPathComponent("KongVox-交付-" + UUID().uuidString.prefix(8))
        let audioRoot = root
        busy = true; stop(); status = "正在批量导出 WAV、SRT 和交付清单…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await Task.detached { try BatchExport.write(snapshots, root: audioRoot, chapters: chapters, to: destination) }.value
                status = "批量导出完成：\(snapshots.count) 个项目。"; NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { self.error = error.localizedDescription; status = "批量导出未完成。" }
        }
    }
}

enum BatchExport {
    static func safeName(_ source: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        let value = source.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名" : String(value.prefix(60))
    }
    static func write(_ projects: [Project], root: URL, chapters: Bool, to destination: URL) throws {
        let fm = FileManager.default
        guard !projects.isEmpty, !fm.fileExists(atPath: destination.path) else { throw VoxError(message: "导出目录已存在或未选择项目。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".kongvox-export-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var manifest = ["KongVox 配音交付清单", "格式：WAV · 24 kHz · 单声道 · 16-bit PCM；SRT 按各项目字幕设置导出", ""]
        for (projectIndex, p) in projects.enumerated() {
            guard !p.segments.isEmpty, !p.needsLongPreparation || !p.isLongMode,
                  p.segments.allSatisfy({ p.isReady($0, root: root) }) else { throw VoxError(message: "「\(p.title)」尚有未生成或待更新的音频。") }
            if chapters && p.captionEdits != nil { throw VoxError(message: "「\(p.title)」有手工字幕，请按整篇导出以保留自定义时间轴；分章导出暂不拆用手工字幕。") }
            let groups: [(String, [Int])] = chapters ? p.chapters.map { chapter in (chapter.title, p.segments.indices.filter { chapter.segmentIDs.contains(p.segments[$0].id) }) } : [(p.title, Array(p.segments.indices))]
            for (chapterIndex, group) in groups.enumerated() {
                try Task.checkCancellation()
                let name = String(format: "%02d-%02d-", projectIndex + 1, chapterIndex + 1) + safeName(p.title) + (chapters ? "-" + safeName(group.0) : "")
                let urls = group.1.map { root.appendingPathComponent("Audio").appendingPathComponent(p.segments[$0].current!.file) }
                let gaps = group.1.map { p.gaps[$0] }
                let audio = staging.appendingPathComponent(name + ".wav")
                let frames = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: p.levelsEnabled, to: audio, seam: p.resolvedSeam)
                let subtitle: String
                if !chapters {
                    subtitle = try p.captionContent(frames: frames, renderedAudio: audio)
                } else {
                    let texts = group.1.map { p.segments[$0].text }
                    let cues: [CaptionCue]
                    if p.resolvedAlignment == .localPauses {
                        cues = try Version011Tools.localPauseCues(texts: texts, frames: frames, gaps: gaps, style: p.resolvedSubtitleStyle, pcm: AudioFiles.extractPCM(Data(contentsOf: audio)))
                    } else {
                        cues = try Subtitles.cues(texts: texts, frames: frames, gaps: gaps, style: p.resolvedSubtitleStyle)
                    }
                    subtitle = try CaptionTimeline.render(cues, duration: CaptionTimeline.duration(frames: frames, gaps: gaps))
                }
                try subtitle.write(to: staging.appendingPathComponent(name + ".srt"), atomically: true, encoding: .utf8)
                let duration = Double(frames.reduce(0,+)) / 24000 + gaps.dropLast().reduce(0,+)
                manifest.append("\(name)\n时长：\(String(format: "%.2f", duration)) 秒\n文件：\(name).wav / \(name).srt\n")
            }
        }
        try manifest.joined(separator: "\n").write(to: staging.appendingPathComponent("交付清单.txt"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: staging, to: destination)
    }
}
