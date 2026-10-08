import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor final class Studio: ObservableObject {
    @Published var globalDictionary: [PronunciationRule] = []
    @Published var findings: [AudioFinding] = []
    /// Suspected missing/extra reading from on-device transcription, for `speechFindingsProject`.
    @Published var speechFindings: [SpeechFinding] = []
    @Published var speechSummary = "尚未核对"
    @Published var speechChecking = false
    var speechFindingsProject: UUID?
    @Published var qualitySummary = "尚未检查"
    @Published var preflightMessage = "尚未检查密钥；配置检查不调用付费接口。"
    @Published var pauseRequested = false
    @Published var activeProject: UUID?
    @Published var catalog = ServiceCatalog()
    @Published var projects: [Project] = [] { didSet { usageCache = nil } }
    @Published var selected: UUID? { didSet { usageCache = nil } }
    @Published var busy = false
    @Published var comparingVoices = false
    @Published var voiceFavorites: [VoiceFavorite] = []
    @Published var presets: [VoicePreset] = []
    @Published var queue: [QueueEntry] = []
    @Published var batchBudget = BatchBudget()
    @Published var queueRunning = false
    var queueTask: Task<Void, Never>?
    var queueStop = false
    var queueSkip = false
    var isWorking: Bool { busy || queueRunning }
    @Published var activeSegment: UUID?
    @Published var status = "准备好，让文字开口。"
    @Published var error: String?
    @Published var diagnostic = ""
    @Published var playbackCues: [PlaybackCue] = []
    @Published var readingSegment: UUID?
    var playbackProject: UUID?
    private var usageCache: UsageEstimate?
    @Published var playing = false
    /// The 20 Hz playhead lives in its own object so playback does not re-render every view observing the studio.
    let clock = PlaybackClock()
    var playbackTime: Double {
        get { clock.time }
        set { if clock.time != newValue { clock.time = newValue } }
    }
    @Published var playbackDuration = 0.0
    /// Debounced save for high-frequency edits (typing, sliders); flushed by any explicit save and on quit.
    private var pendingSave: Task<Void, Never>?
    /// In-memory cache of version files under Versions/, loaded per project on first access.
    private var versionCache: [UUID: [ProjectVersion]] = [:]
    @Published var notificationsEnabled = false
    @Published var progress = 0.0
    let root: URL
    var task: Task<Void, Never>?
    var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    var playbackRange: ClosedRange<Double>?
    var repeatRange = false
    var storageAvailable = true
    let client: SpeechClient
    let keyProvider: (ServiceProfile) throws -> String
    init(root: URL? = nil, client: SpeechClient = SpeechClient(), keyProvider: @escaping (ServiceProfile) throws -> String = { try KeyStore.read(account: $0.keyAccount) }) {
        notificationsEnabled = root == nil && UserDefaults.standard.bool(forKey: "completionNotifications")
        self.client = client
        self.keyProvider = keyProvider
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongVox")
        do {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            let dictionaryFile = self.root.appendingPathComponent("dictionary.json")
            if FileManager.default.fileExists(atPath: dictionaryFile.path) {
                globalDictionary = try JSONDecoder().decode([PronunciationRule].self, from: Data(contentsOf: dictionaryFile))
            }
            let servicesFile = self.root.appendingPathComponent("services.json")
            if FileManager.default.fileExists(atPath: servicesFile.path) {
                catalog = try JSONDecoder().decode(ServiceCatalog.self, from: Data(contentsOf: servicesFile))
                if catalog.builtinsRevision == nil {
                    if !catalog.profiles.contains(where: { $0.id == ServiceProfile.cosyVoice.id }) { catalog.profiles.append(.cosyVoice) }
                    catalog.builtinsRevision = 1
                    try JSONEncoder().encode(catalog).write(to: servicesFile, options: .atomic)
                }
            }
            if (catalog.builtinsRevision ?? 0) < 2 {
                if !catalog.profiles.contains(where: { $0.id == ServiceProfile.qwenTTS.id }) { catalog.profiles.append(.qwenTTS) }
                catalog.builtinsRevision = 2
                try JSONEncoder().encode(catalog).write(to: servicesFile, options: .atomic)
            }
            if (catalog.builtinsRevision ?? 0) < 3 {
                if !catalog.profiles.contains(where: { $0.id == ServiceProfile.volcengine.id }) { catalog.profiles.append(.volcengine) }
                catalog.builtinsRevision = 3
                try JSONEncoder().encode(catalog).write(to: servicesFile, options: .atomic)
            }
            let voicesFile = self.root.appendingPathComponent("voices.json")
            if FileManager.default.fileExists(atPath: voicesFile.path) { voiceFavorites = try JSONDecoder().decode([VoiceFavorite].self, from: Data(contentsOf: voicesFile)) }
            for name in ["presets", "queue"] {
                let extra = self.root.appendingPathComponent(name + ".json")
                if FileManager.default.fileExists(atPath: extra.path) {
                    if name == "presets" { presets = try JSONDecoder().decode([VoicePreset].self, from: Data(contentsOf: extra)) }
                    else { queue = try JSONDecoder().decode([QueueEntry].self, from: Data(contentsOf: extra)) }
                }
            }
            let budgetFile = self.root.appendingPathComponent("batch-budget.json")
            if FileManager.default.fileExists(atPath: budgetFile.path) { batchBudget = try JSONDecoder().decode(BatchBudget.self, from: Data(contentsOf: budgetFile)) }
            for i in queue.indices where queue[i].state == "生成中" { queue[i].state = "已暂停" }
            let file = self.root.appendingPathComponent("projects.json")
            if FileManager.default.fileExists(atPath: file.path) {
                projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: file))
                let backup = self.root.appendingPathComponent("projects-before-0.2.json")
                if projects.contains(where: { $0.settings.service == nil }), !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: file, to: backup)
                }
            }
        } catch {
            storageAvailable = false
            self.error = "项目读取失败，已停止自动保存以保护原文件：\(error.localizedDescription)"
        }
        if projects.isEmpty { projects = [makeProject()] }
        for i in projects.indices {
            if projects[i].usesDictionarySnapshot != true { projects[i].settings.globalPronunciationRules = globalDictionary }
            if projects[i].taskState == "生成中" {
                projects[i].taskState = "待继续"; projects[i].taskMessage = "上次运行已中断，已完成片段会复用。"
            }
        }
        migrateVersionsOutOfProjects()
        selected = projects.first?.id
    }
    // MARK: Version snapshots (stored under Versions/, not in projects.json)
    func versionsFile(_ id: UUID) -> URL { root.appendingPathComponent("Versions").appendingPathComponent(id.uuidString + ".json") }
    /// Throws when an existing version file cannot be read, so callers never overwrite it with an empty list.
    func loadVersions(_ id: UUID) throws -> [ProjectVersion] {
        if let cached = versionCache[id] { return cached }
        let file = versionsFile(id)
        let values: [ProjectVersion] = try FileManager.default.fileExists(atPath: file.path) ? JSONDecoder().decode([ProjectVersion].self, from: Data(contentsOf: file)) : []
        versionCache[id] = values
        return values
    }
    func versions(for id: UUID) -> [ProjectVersion] { (try? loadVersions(id)) ?? [] }
    func writeVersions(_ values: [ProjectVersion], for id: UUID) throws {
        let file = versionsFile(id)
        if values.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
        }
        versionCache[id] = values
    }
    /// 0.11.3: snapshots used to live inside each project, so every edit rewrote up to 30 full copies.
    /// Move them to one file per project; a project keeps its inline versions if moving fails.
    private func migrateVersionsOutOfProjects() {
        guard storageAvailable, projects.contains(where: { !($0.versions ?? []).isEmpty }) else { return }
        for i in projects.indices {
            guard let inline = projects[i].versions, !inline.isEmpty else { projects[i].versions = nil; continue }
            do {
                let existing = try loadVersions(projects[i].id)
                let known = Set(existing.map(\.id))
                try writeVersions(Array((existing + inline.filter { !known.contains($0.id) }).suffix(30)), for: projects[i].id)
                projects[i].versions = nil
            } catch { self.error = "项目版本迁移未完成，已保留原记录：\(error.localizedDescription)" }
        }
        save()
    }
    func makeProject() -> Project {
        var p = Project()
        let service = catalog.profiles.first { $0.id == catalog.defaultID && $0.enabled } ?? catalog.profiles.first { $0.enabled } ?? .openAI
        p.settings.globalPronunciationRules = globalDictionary
        p.settings.service = service
        p.settings.voice = service.voices.first ?? "marin"
        return p
    }
    func selectService(_ id: String) {
        guard let service = catalog.profiles.first(where: { $0.id == id && $0.enabled }) else { return }
        edit { p in p.settings.service = service; p.settings.voice = service.voices.first ?? "" }
    }
    func saveService(_ service: ServiceProfile, key: String?, makeDefault: Bool) throws {
        guard !isWorking, storageAvailable else { throw VoxError(message: "当前无法修改服务设置。") }
        let profile = try service.validated()
        var updated = catalog
        if let i = updated.profiles.firstIndex(where: { $0.id == profile.id }) { updated.profiles[i] = profile }
        else { updated.profiles.append(profile) }
        if makeDefault {
            guard profile.enabled else { throw VoxError(message: "默认服务必须启用。") }
            updated.defaultID = profile.id
        }
        guard updated.profiles.contains(where: { $0.enabled }) else { throw VoxError(message: "请保留至少一个启用的服务。") }
        if updated.profiles.first(where: { $0.id == updated.defaultID })?.enabled != true { updated.defaultID = updated.profiles.first { $0.enabled }!.id }
        if let key { try KeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: profile.keyAccount) }
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("services.json"), options: .atomic)
        catalog = updated
        preflightMessage = "服务已改变，可重新检查。"
        // Projects keep the exact service snapshot used for their voice settings.
        // Explicitly selecting the edited service applies it to a project; existing takes remain exportable.
    }
    func deleteService(_ id: String) throws {
        guard !isWorking, storageAvailable else { return }
        guard !projects.contains(where: { $0.settings.resolvedService.id == id }) else { throw VoxError(message: "有项目正在使用此服务，请先切换这些项目的服务；也可以先停用。") }
        var updated = catalog
        updated.profiles.removeAll { $0.id == id }
        guard updated.profiles.contains(where: { $0.enabled }) else { throw VoxError(message: "请保留至少一个启用的服务。") }
        if updated.defaultID == id { updated.defaultID = updated.profiles.first { $0.enabled }!.id }
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("services.json"), options: .atomic)
        catalog = updated
        preflightMessage = "服务已改变，可重新检查。"
        // Historical take snapshots may still reference this account. Do not silently erase their key.
    }
    var project: Project? { projects.first { $0.id == selected } }
    @discardableResult func save() -> Bool {
        // Any full save also covers a pending debounced save.
        pendingSave?.cancel(); pendingSave = nil
        guard storageAvailable else { return false }
        do { try JSONEncoder().encode(projects).write(to: root.appendingPathComponent("projects.json"), options: .atomic); return true }
        catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    func edit(_ change: (inout Project) -> Void) {
        guard applyEdit(change) else { return }
        save()
    }
    /// Same as `edit`, but for high-frequency inputs (typing, sliders): the change applies now and is written
    /// to disk after input pauses, instead of re-encoding every project on each keystroke.
    func editLive(_ change: (inout Project) -> Void) {
        guard applyEdit(change) else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    /// Writes a pending debounced edit immediately (called on quit and before leaving the editor).
    func flushPendingSave() { if pendingSave != nil { save() } }
    private func applyEdit(_ change: (inout Project) -> Void) -> Bool {
        guard !isWorking, let index = projects.firstIndex(where: { $0.id == selected }) else { return false }
        stop()
        change(&projects[index]); preflightMessage = "配置或文稿已改变，可重新检查。"; findings = []; qualitySummary = "内容已改变，请重新检查"
        clearSpeechFindings("内容已改变，请重新核对")
        return true
    }
    func newProject() {
        guard !isWorking else { return }
        stop()
        let p = makeProject(); projects.insert(p, at: 0); selected = p.id; save()
    }
    func importDraft() {
        edit { p in
            p.segments.append(contentsOf: TextSplitter.split(p.draft, limit: p.settings.resolvedService.kind == .qwenTTS ? 500 : 700).map { Segment(text: $0) })
            p.draft = ""
        }
    }
    func setLongMode(_ enabled: Bool) {
        edit { p in
            if enabled && !p.isLongMode {
                p.longText = (p.segments.map(\.text) + (p.draft.isEmpty ? [] : [p.draft])).joined(separator: "\n\n")
                p.preparedLongText = p.segments.map(\.text).joined(separator: "\n\n")
            } else if !enabled && p.isLongMode {
                p.prepareLongDocument()
            }
            p.longMode = enabled
        }
    }
    var fullAudioReady: Bool { (try? currentURLs()) != nil }
    var fullProgress: Double {
        guard let p = project, !p.segments.isEmpty, !(p.isLongMode && p.needsLongPreparation) else { return 0 }
        return Double(p.segments.filter { ready($0, in: p) }.count) / Double(p.segments.count)
    }
    func audioURL(_ take: Take) -> URL { root.appendingPathComponent("Audio").appendingPathComponent(take.file) }
    /// Readiness judged against the project that owns the segment.
    func ready(_ segment: Segment, in project: Project) -> Bool { project.isReady(segment, root: root) }
    /// Readiness for a segment of the selected project (main editor). Prefer `ready(_:in:)` when the project is known.
    func ready(_ segment: Segment, settings: VoiceSettings) -> Bool {
        var owner = project ?? Project()
        owner.settings = settings
        return owner.isReady(segment, root: root)
    }
    func saveBatchBudget() {
        guard storageAvailable else { return }
        do { try JSONEncoder().encode(batchBudget).write(to: root.appendingPathComponent("batch-budget.json"), options: .atomic) }
        catch { self.error = "无法保存批量预算设置。" }
    }
    func recoveryFile(_ segment: Segment, project: Project) -> URL {
        root.appendingPathComponent("Recovery").appendingPathComponent("\(project.id)-\(segment.id)-\(segment.fingerprint(project.settings)).json")
    }
    func hasRecovery(_ segment: Segment) -> Bool {
        guard let p = project else { return false }
        return FileManager.default.fileExists(atPath: recoveryFile(segment, project: p).path)
    }
    func discardRecovery(_ segment: Segment) {
        guard !isWorking, let p = project else { return }
        do { try DownloadReceipt.clear(recoveryFile(segment, project: p)); status = "已放弃该段下载缓存，下次生成会重新请求服务。" }
        catch { self.error = "无法清除下载缓存，请检查本地文件权限。" }
    }
    func copyDiagnostic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostic, forType: .string)
    }
    struct UsageEstimate { var total = 0; var generate = 0; var reuse = 0; var recover = 0 }
    var usageEstimate: UsageEstimate {
        if let usageCache { return usageCache }
        guard var p = project else { return UsageEstimate() }
        if p.isLongMode { p.prepareLongDocument() }
        var result = UsageEstimate()
        for segment in p.segments {
            let count = p.settings.reading(segment.spokenText).count; result.total += count
            if ready(segment, in: p) { result.reuse += count }
            else if FileManager.default.fileExists(atPath: recoveryFile(segment, project: p).path) { result.recover += count }
            else { result.generate += count }
        }
        usageCache = result; return result
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notificationsEnabled = false; UserDefaults.standard.set(false, forKey: "completionNotifications"); return }
        Task {
            do {
                notificationsEnabled = try await CompletionNotice.shared.enable()
                UserDefaults.standard.set(notificationsEnabled, forKey: "completionNotifications")
                if !notificationsEnabled { status = "通知未开启，可在系统设置 → 通知中允许 KongVox。" }
            } catch { self.error = "无法启用完成通知，请检查系统通知设置。" }
        }
    }
    func generateOpening() {
        guard !isWorking, storageAvailable, let index = projects.firstIndex(where: { $0.id == selected }) else { return }
        if projects[index].isLongMode { projects[index].prepareLongDocument(); guard save() else { return } }
        guard let p = project, let first = p.segments.first else { return }
        if ready(first, in: p), let take = first.current { playOpening(audioURL(take)) }
        else { generate(only: first.id, opening: true) }
    }
    func playOpening(_ url: URL) {
        do {
            let pcm = try AudioAssembly.prepare(Data(contentsOf: url), trimStart: false, trimEnd: false, normalize: project?.levelsEnabled ?? true)
            let clip = root.appendingPathComponent("opening-preview.wav")
            try AudioFiles.writePCM(Data(pcm.prefix(20 * 48000)), to: clip)
            play(clip); status = "正在试听开头（最多 20 秒），全文生成会复用已生成的开头。"
        } catch { self.error = error.localizedDescription }
    }
    func generate(only: UUID? = nil, opening: Bool = false, scope: Set<UUID>? = nil, force: Bool = false, audition: Bool = false, fromQueue: Bool = false) {
        guard !busy, (!queueRunning || fromQueue), storageAvailable else { return }
        if only == nil, project?.isLongMode == true, let index = projects.firstIndex(where: { $0.id == selected }) {
            projects[index].prepareLongDocument()
            guard save() else { return }
        }
        guard let snapshot = project else { return }
        let pending = snapshot.segments.filter { (scope == nil || scope!.contains($0.id)) && (only == nil ? (force || !ready($0, in: snapshot)) : $0.id == only) }
        guard pending.allSatisfy({ snapshot.settings.reading($0.spokenText).count <= snapshot.chunkLimit }) else {
            error = "发音替换后的片段超过服务长度限制，请缩短替代读法或在段落精调中拆分。"; return
        }
        guard !pending.isEmpty else { status = "全文已就绪，可以试听或导出完整音频。"; return }
        var scopedSnapshot = snapshot; scopedSnapshot.segments = pending
        let issues = ServicePreflight.inspect(scopedSnapshot, catalog: catalog).filter(\.blocking)
        guard issues.isEmpty else { error = issues.map(\.message).joined(separator: "\n"); return }
        let service = snapshot.settings.resolvedService
        guard let saved = catalog.profiles.first(where: { $0.id == service.id }), saved.enabled else { error = "该服务已停用，请在声音工作台切换或在服务设置中启用。"; return }
        guard saved == service else { error = "服务配置已更新，请在声音工作台点击「应用最新服务配置」，确认后再生成。"; return }
        stop(); findings = []; qualitySummary = "音频更新后请重新检查"
        busy = true; pauseRequested = false; activeProject = snapshot.id
        progress = only == nil ? fullProgress : 0; diagnostic = ""
        setTaskState(snapshot.id, "生成中", "正在处理待更新内容")
        task = Task {
            defer { busy = false; activeSegment = nil; activeProject = nil; pauseRequested = false; task = nil }
            var auditionTake: Take?
            var generationKey: String?
            do {
                let fresh = pending.filter { !FileManager.default.fileExists(atPath: recoveryFile($0, project: snapshot).path) }
                if !fresh.isEmpty {
                    generationKey = try keyProvider(service)
                    for segment in fresh {
                        _ = try client.request(text: snapshot.settings.reading(segment.spokenText), settings: segment.effectiveSettings(snapshot.settings), key: generationKey ?? "", context: snapshot.context(for: segment.id))
                    }
                }
            } catch {
                self.error = error.localizedDescription; diagnostic = ServiceFailure.report(error)
                setTaskState(snapshot.id, "配置待检查", diagnostic); return
            }
            for (offset, segment) in pending.enumerated() {
                do {
                    try Task.checkCancellation()
                    activeSegment = segment.id
                    let recovery = recoveryFile(segment, project: snapshot)
                    let resume = FileManager.default.fileExists(atPath: recovery.path)
                    status = snapshot.isLongMode && only == nil
                        ? "\(resume ? "正在恢复全文" : "正在生成全文") · \(Int(progress * 100))%（剩余 \(pending.count - offset) 个处理单元）"
                        : "\(resume ? "正在恢复下载" : "正在生成") \(offset + 1) / \(pending.count) 段…"
                    if !resume && generationKey == nil { generationKey = try keyProvider(service) }
                    let key = resume ? "" : generationKey ?? ""
                    let pcm = try await client.generate(text: snapshot.settings.reading(segment.spokenText), settings: segment.effectiveSettings(snapshot.settings), key: key, recoveryFile: recovery, context: snapshot.context(for: segment.id))
                    try Task.checkCancellation()
                    let take = Take(file: "\(UUID().uuidString).wav", fingerprint: segment.fingerprint(snapshot.settings), service: service, settings: segment.effectiveSettings(snapshot.settings), spokenText: snapshot.settings.reading(segment.spokenText))
                    try AudioFiles.writePCM(pcm, to: audioURL(take))
                    guard let pi = projects.firstIndex(where: { $0.id == snapshot.id }), let si = projects[pi].segments.firstIndex(where: { $0.id == segment.id }) else { return }
                    projects[pi].segments[si].takes.insert(take, at: 0)
                    projects[pi].segments[si].contextFingerprint = snapshot.contextFingerprint(for: segment.id)
                    if !audition { projects[pi].segments[si].selectedTake = take.id }
                    auditionTake = take
                    guard save() else { status = "保存失败，已停止后续生成。"; setTaskState(snapshot.id, "保存失败", status); return }
                    try? DownloadReceipt.clear(recovery)
                    progress = only == nil ? fullProgress : Double(offset + 1) / Double(pending.count)
                    if pauseRequested && offset + 1 < pending.count {
                        status = "当前片段已保存，任务已暂停。"
                        setTaskState(snapshot.id, "已暂停", status); return
                    }
                } catch {
                    if Task.isCancelled { status = "已取消，完成的段落已保存。"; setTaskState(snapshot.id, "已暂停", status) }
                    else { diagnostic = ServiceFailure.report(error); self.error = error.localizedDescription; status = "生成已暂停，点击生成即可继续未完成段落。"; setTaskState(snapshot.id, "失败待继续", diagnostic) }
                    return
                }
            }
            status = "配音已完成，可以试听或导出。"
            setTaskState(snapshot.id, fullAudioReady ? "已完成" : "待继续", fullAudioReady ? "全部音频已保存" : "部分内容已保存，可继续生成剩余内容")
            if only == nil, fullAudioReady, notificationsEnabled { CompletionNotice.shared.send() }
            if audition, let take = auditionTake {
                play(audioURL(take)); status = "新版本已保存，请对比试听后选择采用。"
            } else if only != nil, let updated = project?.segments.first(where: { $0.id == only }), let take = updated.current {
                if opening { playOpening(audioURL(take)) } else { play(audioURL(take)) }
            }
        }
    }
    func setTaskState(_ id: UUID, _ state: String, _ message: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].taskState = state; projects[i].taskMessage = message; save()
    }
    func pauseAfterSegment() { if activeSegment != nil { pauseRequested = true; status = "当前片段完成并保存后暂停…" } }
    func prepareReview() {
        guard !isWorking else { return }
        if project?.isLongMode == true { edit { $0.prepareLongDocument() } }
    }
    func saveDictionary(_ rules: [PronunciationRule], global: Bool) {
        guard !isWorking, storageAvailable else { return }
        guard rules.allSatisfy({ !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(rules.map(\.word)).count == rules.count else {
            error = "原词与读法不能为空，同一词典中原词不能重复。"; return
        }
        if global {
            do {
                try JSONEncoder().encode(rules).write(to: root.appendingPathComponent("dictionary.json"), options: .atomic)
                globalDictionary = rules
                stop()
                for i in projects.indices where projects[i].usesDictionarySnapshot != true { projects[i].settings.globalPronunciationRules = rules }
                findings = []; qualitySummary = "词典已改变，请重新检查"; save()
            } catch { self.error = "词典保存失败：\(error.localizedDescription)" }
        } else { edit { $0.settings.pronunciationRules = rules } }
    }
    func inspectAudio() {
        guard !isWorking, let p = project else { return }
        guard !(p.isLongMode && p.needsLongPreparation) else { error = "请先更新处理片段，再检查当前文稿。"; return }
        busy = true; findings = []; qualitySummary = "正在检查…"
        let folder = root
        task = Task {
            defer { busy = false; task = nil }
            do {
                findings = try await Task.detached { try AudioQuality.inspect(p, root: folder) }.value
                qualitySummary = findings.isEmpty ? "未发现规则可检测的异常；仍建议完整复听。" : "发现 \(findings.count) 条复听提示"
            } catch { qualitySummary = "检查未完成"; self.error = error.localizedDescription }
        }
    }
    func playFinding(_ finding: AudioFinding) {
        guard !isWorking, let take = project?.segments.first(where: { $0.id == finding.segmentID })?.current else { return }
        play(audioURL(take)); seek(max(0, finding.seconds - 0.3))
    }
    func chapterAudio(_ chapter: VoiceChapter, export: Bool) {
        guard !isWorking, let p = project else { return }
        guard !(p.isLongMode && p.needsLongPreparation) else { error = "请先更新处理片段。"; return }
        let indices = p.segments.indices.filter { chapter.segmentIDs.contains(p.segments[$0].id) }
        guard !indices.isEmpty, indices.allSatisfy({ ready(p.segments[$0], in: p) }) else { error = "本章尚有未更新的音频，请先生成本章。"; return }
        let urls = indices.map { audioURL(p.segments[$0].current!) }, gaps = indices.map { p.gaps[$0] }, seam = p.resolvedSeam
        var destination = root.appendingPathComponent("chapter-preview.wav")
        if export {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]
            panel.nameFieldStringValue = String(chapter.title.prefix(60)).replacingOccurrences(of: "/", with: "-") + ".wav"
            guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url
        }
        let output = destination
        stop(); busy = true
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await Task.detached { _ = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: p.levelsEnabled, to: output, seam: seam) }.value
                if export { status = "本章已导出"; NSWorkspace.shared.activateFileViewerSelecting([output]) }
                else { play(output); status = "正在试听：\(chapter.title)" }
            } catch { self.error = error.localizedDescription }
        }
    }
    func updatePronunciation(_ id: UUID, text: String) {
        edit { p in
            if let i = p.segments.firstIndex(where: { $0.id == id }) { p.segments[i].pronunciation = text }
        }
    }
    func adoptTake(segmentID: UUID, takeID: UUID) {
        guard !isWorking, let p = project, let segment = p.segments.first(where: { $0.id == segmentID }),
              let take = segment.takes.first(where: { $0.id == takeID }),
              take.fingerprint == segment.fingerprint(p.settings), FileManager.default.fileExists(atPath: audioURL(take).path) else {
            error = "此版本与当前文稿或声音设置不匹配，不能作为当前成品采用。"; return
        }
        edit { p in if let i = p.segments.firstIndex(where: { $0.id == segmentID }) { p.segments[i].selectedTake = takeID } }
        status = "已采用所选版本，请重新检查成品。"
    }
    func cancel() { task?.cancel() }
    func stop() { playbackRange = nil; repeatRange = false; playbackCues = []; readingSegment = nil; playbackProject = nil; player?.stop(); player = nil; playing = false; playbackTime = 0; playbackDuration = 0; playbackTimer?.invalidate(); playbackTimer = nil }
    func togglePause() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false } else { if let range = playbackRange, player.currentTime >= range.upperBound { player.currentTime = range.lowerBound } else if player.currentTime >= player.duration { player.currentTime = 0 }; playing = player.play() }
    }
    func play(_ url: URL, cues: [PlaybackCue] = [], projectID: UUID? = nil) {
        stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            guard player?.play() == true else { throw VoxError(message: "无法播放音频。") }
            playbackCues = cues; playbackProject = projectID; readingSegment = PlaybackTimeline.current(0, cues: cues)
            playing = true; playbackDuration = player?.duration ?? 0
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                // Read the weak capture here, not inside the Task: Swift 5.10 rejects referencing a captured
                // `var self` from concurrently-executing code. Studio is main-actor isolated, hence Sendable.
                let studio = self
                Task { @MainActor in studio?.tickPlayback() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func tickPlayback() {
        guard let player else { return }
        if let range = playbackRange, playing, (!player.isPlaying || player.currentTime >= range.upperBound) {
            if repeatRange { player.currentTime = range.lowerBound; playing = player.play(); playbackTime = range.lowerBound }
            else { player.pause(); player.currentTime = range.upperBound; playing = false; playbackTime = range.upperBound }
            return
        }
        if player.isPlaying { playbackTime = player.currentTime }
        else if playing { playing = false; playbackTime = player.duration }
        // @Published fires on every assignment; only publish when the highlighted segment changes.
        let reading = PlaybackTimeline.current(playbackTime, cues: playbackCues)
        if reading != readingSegment { readingSegment = reading }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, let player else { return }
        player.currentTime = max(0, min(player.duration, seconds)); playbackTime = player.currentTime
        readingSegment = PlaybackTimeline.current(playbackTime, cues: playbackCues)
    }
    func skip(_ seconds: Double) { seek(playbackTime + seconds) }
    static func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    func currentURLs() throws -> [URL] {
        guard let p = project, !p.segments.isEmpty else { throw VoxError(message: "请先添加文稿。") }
        guard !(p.isLongMode && p.needsLongPreparation) else { throw VoxError(message: "全文已修改，请点击「生成全文」更新后再试听或导出。") }
        guard p.segments.allSatisfy({ ready($0, in: p) }) else { throw VoxError(message: "有未生成或已修改的段落，请先生成最新配音。") }
        return p.segments.compactMap { $0.current.map(audioURL) }
    }
    func playAll(from segmentID: UUID? = nil) {
        guard !isWorking else { return }
        do {
            let urls = try currentURLs(); let snapshot = project!; let gaps = snapshot.gaps; let normalize = snapshot.levelsEnabled
            if playbackProject == snapshot.id, let segmentID, let cue = playbackCues.first(where: { $0.id == segmentID }), player != nil {
                seek(cue.start); if !playing { togglePause() }; return
            }
            stop(); busy = true; status = "正在准备试听…"
            task = Task {
                defer { busy = false; task = nil }
                do {
                    let preview = root.appendingPathComponent("preview.wav")
                    let frames = try await Task.detached { try AudioAssembly.render(urls: urls, gaps: gaps, normalize: normalize, to: preview, seam: snapshot.resolvedSeam) }.value
                    let cues = try PlaybackTimeline.make(ids: snapshot.segments.map(\.id), frames: frames, gaps: gaps)
                    play(preview, cues: cues, projectID: snapshot.id)
                    if let segmentID, let cue = cues.first(where: { $0.id == segmentID }) { seek(cue.start) }
                    status = "正在试听完整配音。"
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    func exportSubtitles() {
        guard !isWorking, let p = project else { return }
        do {
            let urls = try currentURLs()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
            panel.nameFieldStringValue = p.title + ".srt"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let folder = root
            busy = true; status = "正在计算字幕时间轴…"
            task = Task {
                defer { busy = false; task = nil }
                do {
                    try await Task.detached {
                        let frames: [Int64]
                        var pcm: Data?
                        if p.needsAlignmentPCM {
                            let mixed = try AudioAssembly.renderWithPCM(urls: urls, gaps: p.gaps, normalize: p.levelsEnabled, seam: p.resolvedSeam)
                            frames = mixed.frames; pcm = mixed.pcm
                        } else {
                            frames = try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: p.levelsEnabled, seam: p.resolvedSeam)
                        }
                        let content = try p.captionContent(frames: frames, pcm: pcm, root: folder)
                        try content.write(to: destination, atomically: true, encoding: .utf8)
                    }.value
                    status = "已导出段落字幕：\(destination.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func exportBundle() {
        guard !isWorking, let p = project else { return }
        do {
            let urls = try currentURLs()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = p.title + "-音频与字幕.zip"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let folder = root
            busy = true; stop(); status = "正在导出音频与字幕组合包…"
            task = Task {
                defer { busy = false; task = nil }
                do {
                    try await Task.detached { try ExportBundle.write(urls: urls, texts: p.segments.map(\.text), gaps: p.gaps, normalize: p.levelsEnabled, destination: destination, subtitleStyle: p.resolvedSubtitleStyle, captionProject: p, seam: p.resolvedSeam, root: folder) }.value
                    status = "已导出同一版本的配音.wav 与配音.srt。"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.error = error.localizedDescription; status = "组合包导出失败，原文件未修改。" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func export(format: String) {
        guard !isWorking else { return }
        do {
            let urls = try currentURLs()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == "wav" ? .wav : format == "mp3" ? .mp3 : .mpeg4Audio]
            panel.nameFieldStringValue = (project?.title ?? "KongVox") + "." + format
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let gaps = project!.gaps; let normalize = project!.levelsEnabled; let seam = project!.resolvedSeam
            busy = true; stop(); status = "正在导出…"
            task = Task {
                defer { busy = false; task = nil }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let wav = folder.appendingPathComponent("mix.wav")
                    try await Task.detached { _ = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: normalize, to: wav, seam: seam) }.value
                    var result = wav
                    if format == "m4a" {
                        result = folder.appendingPathComponent("mix.m4a")
                        try await AudioFiles.m4a(from: wav, to: result)
                    } else if format == "mp3" {
                        guard let executable = Self.ffmpeg else { throw VoxError(message: "MP3 导出需要安装 FFmpeg；WAV 和 M4A 可直接使用。") }
                        result = folder.appendingPathComponent("mix.mp3")
                        let output = result
                        try await Task.detached {
                            let process = Process(), errors = Pipe(); process.executableURL = executable
                            process.arguments = ["-nostdin", "-v", "error", "-i", wav.path, "-codec:a", "libmp3lame", "-b:a", "192k", output.path]
                            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
                            try process.run()
                            // Drain stderr before waiting so a chatty FFmpeg cannot block on a full pipe.
                            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                            process.waitUntilExit()
                            guard process.terminationStatus == 0 else {
                                let reason = detail.split(whereSeparator: \.isNewline).last.map { "（FFmpeg：\(String($0).prefix(160))）" } ?? ""
                                throw VoxError(message: "MP3 转换失败\(reason)，请改用 WAV 导出。")
                            }
                        }.value
                    }
                    // Copy alongside destination first; never destroy an existing export on conversion failure.
                    let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(format)")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: result, to: staging)
                    if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
                    else { try FileManager.default.moveItem(at: staging, to: destination) }
                    status = "已导出：\(destination.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.error = error.localizedDescription; status = "导出失败，原文件未被替换。" }
            }
        } catch { self.error = error.localizedDescription }
    }
}
