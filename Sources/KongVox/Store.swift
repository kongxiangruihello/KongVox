import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor final class Studio: ObservableObject {
    @Published var catalog = ServiceCatalog()
    @Published var projects: [Project] = []
    @Published var selected: UUID?
    @Published var busy = false
    @Published var activeSegment: UUID?
    @Published var status = "准备好，让文字开口。"
    @Published var error: String?
    @Published var playing = false
    @Published var progress = 0.0
    let root: URL
    var task: Task<Void, Never>?
    var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var storageAvailable = true
    let client: SpeechClient
    let keyProvider: (ServiceProfile) throws -> String
    init(root: URL? = nil, client: SpeechClient = SpeechClient(), keyProvider: @escaping (ServiceProfile) throws -> String = { try KeyStore.read(account: $0.keyAccount) }) {
        self.client = client
        self.keyProvider = keyProvider
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongVox")
        do {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            let servicesFile = self.root.appendingPathComponent("services.json")
            if FileManager.default.fileExists(atPath: servicesFile.path) { catalog = try JSONDecoder().decode(ServiceCatalog.self, from: Data(contentsOf: servicesFile)) }
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
        selected = projects.first?.id
    }
    func makeProject() -> Project {
        var p = Project()
        let service = catalog.profiles.first { $0.id == catalog.defaultID && $0.enabled } ?? catalog.profiles.first { $0.enabled } ?? .openAI
        p.settings.service = service
        p.settings.voice = service.voices.first ?? "marin"
        return p
    }
    func selectService(_ id: String) {
        guard let service = catalog.profiles.first(where: { $0.id == id && $0.enabled }) else { return }
        edit { p in p.settings.service = service; p.settings.voice = service.voices.first ?? "" }
    }
    func saveService(_ service: ServiceProfile, key: String?, makeDefault: Bool) throws {
        guard !busy, storageAvailable else { throw VoxError(message: "当前无法修改服务设置。") }
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
        // Projects keep the exact service snapshot used for their voice settings.
        // Explicitly selecting the edited service applies it to a project; existing takes remain exportable.
    }
    func deleteService(_ id: String) throws {
        guard !busy, storageAvailable else { return }
        guard !projects.contains(where: { $0.settings.resolvedService.id == id }) else { throw VoxError(message: "有项目正在使用此服务，请先切换这些项目的服务；也可以先停用。") }
        var updated = catalog
        updated.profiles.removeAll { $0.id == id }
        guard updated.profiles.contains(where: { $0.enabled }) else { throw VoxError(message: "请保留至少一个启用的服务。") }
        if updated.defaultID == id { updated.defaultID = updated.profiles.first { $0.enabled }!.id }
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("services.json"), options: .atomic)
        catalog = updated
        // Historical take snapshots may still reference this account. Do not silently erase their key.
    }
    var project: Project? { projects.first { $0.id == selected } }
    @discardableResult func save() -> Bool {
        guard storageAvailable else { return false }
        do { try JSONEncoder().encode(projects).write(to: root.appendingPathComponent("projects.json"), options: .atomic); return true }
        catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    func edit(_ change: (inout Project) -> Void) {
        guard !busy, let index = projects.firstIndex(where: { $0.id == selected }) else { return }
        stop()
        change(&projects[index]); save()
    }
    func newProject() {
        guard !busy else { return }
        stop()
        let p = makeProject(); projects.insert(p, at: 0); selected = p.id; save()
    }
    func importDraft() {
        edit { p in
            p.segments.append(contentsOf: TextSplitter.split(p.draft).map { Segment(text: $0) })
            p.draft = ""
        }
    }
    func audioURL(_ take: Take) -> URL { root.appendingPathComponent("Audio").appendingPathComponent(take.file) }
    func ready(_ segment: Segment, settings: VoiceSettings) -> Bool {
        segment.ready(settings) && segment.current.map { FileManager.default.fileExists(atPath: audioURL($0).path) } == true
    }
    func generate(only: UUID? = nil) {
        guard !busy, storageAvailable, let snapshot = project else { return }
        let pending = snapshot.segments.filter { only == nil ? !ready($0, settings: snapshot.settings) : $0.id == only }
        guard !pending.isEmpty else { status = "全部段落已生成。"; return }
        let service = snapshot.settings.resolvedService
        guard let saved = catalog.profiles.first(where: { $0.id == service.id }), saved.enabled else { error = "该服务已停用，请在声音工作台切换或在服务设置中启用。"; return }
        guard saved == service else { error = "服务配置已更新，请在声音工作台点击「应用最新服务配置」，确认后再生成。"; return }
        let key: String
        do { key = try keyProvider(service); guard !key.isEmpty else { throw VoxError(message: "请先打开服务设置，保存 API Key。") } }
        catch { self.error = error.localizedDescription; return }
        stop(); busy = true; progress = 0
        task = Task {
            defer { busy = false; activeSegment = nil; task = nil }
            for (offset, segment) in pending.enumerated() {
                do {
                    try Task.checkCancellation()
                    activeSegment = segment.id
                    status = "正在生成 \(offset + 1) / \(pending.count) 段…"
                    let pcm = try await client.generate(text: segment.spokenText, settings: snapshot.settings, key: key)
                    try Task.checkCancellation()
                    let take = Take(file: "\(UUID().uuidString).wav", fingerprint: segment.fingerprint(snapshot.settings), service: service, settings: snapshot.settings, spokenText: segment.spokenText)
                    try AudioFiles.writePCM(pcm, to: audioURL(take))
                    guard let pi = projects.firstIndex(where: { $0.id == snapshot.id }), let si = projects[pi].segments.firstIndex(where: { $0.id == segment.id }) else { return }
                    projects[pi].segments[si].takes.insert(take, at: 0)
                    projects[pi].segments[si].selectedTake = take.id
                    guard save() else { status = "保存失败，已停止后续生成。"; return }
                    progress = Double(offset + 1) / Double(pending.count)
                } catch {
                    if Task.isCancelled { status = "已取消，完成的段落已保存。" }
                    else { self.error = error.localizedDescription; status = "生成已暂停，点击生成即可继续未完成段落。" }
                    return
                }
            }
            status = "配音已完成，可以试听或导出。"
            if only != nil, let updated = project?.segments.first(where: { $0.id == only }), let take = updated.current { play(audioURL(take)) }
        }
    }
    func cancel() { task?.cancel() }
    func stop() { player?.stop(); player = nil; playing = false; playbackTimer?.invalidate(); playbackTimer = nil }
    func togglePause() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true }
    }
    func play(_ url: URL) {
        stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            guard player?.play() == true else { throw VoxError(message: "无法播放音频。") }
            playing = true
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.player?.isPlaying == false && self.playing { self.playing = false; self.playbackTimer?.invalidate() }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func currentURLs() throws -> [URL] {
        guard let p = project, !p.segments.isEmpty else { throw VoxError(message: "请先添加文稿。") }
        guard p.segments.allSatisfy({ ready($0, settings: p.settings) }) else { throw VoxError(message: "有未生成或已修改的段落，请先生成最新配音。") }
        return p.segments.compactMap { $0.current.map(audioURL) }
    }
    func playAll() {
        guard !busy else { return }
        do {
            let urls = try currentURLs(); let gap = project?.settings.pause ?? 0.35
            busy = true; status = "正在准备试听…"
            task = Task {
                defer { busy = false; task = nil }
                do {
                    let preview = root.appendingPathComponent("preview.wav")
                    try await Task.detached { try AudioFiles.merge(urls, pause: gap, to: preview) }.value
                    play(preview); status = "正在试听完整配音。"
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    func export(format: String) {
        guard !busy else { return }
        do {
            let urls = try currentURLs()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == "wav" ? .wav : format == "mp3" ? .mp3 : .mpeg4Audio]
            panel.nameFieldStringValue = (project?.title ?? "KongVox") + "." + format
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let pause = project?.settings.pause ?? 0.35
            busy = true; stop(); status = "正在导出…"
            task = Task {
                defer { busy = false; task = nil }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let wav = folder.appendingPathComponent("mix.wav")
                    try await Task.detached { try AudioFiles.merge(urls, pause: pause, to: wav) }.value
                    var result = wav
                    if format == "m4a" {
                        result = folder.appendingPathComponent("mix.m4a")
                        try await AudioFiles.m4a(from: wav, to: result)
                    } else if format == "mp3" {
                        guard let executable = Self.ffmpeg else { throw VoxError(message: "MP3 导出需要安装 FFmpeg；WAV 和 M4A 可直接使用。") }
                        result = folder.appendingPathComponent("mix.mp3")
                        let output = result
                        try await Task.detached {
                            let process = Process(); process.executableURL = executable
                            process.arguments = ["-nostdin", "-v", "error", "-i", wav.path, "-codec:a", "libmp3lame", "-b:a", "192k", output.path]
                            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                            try process.run(); process.waitUntilExit()
                            guard process.terminationStatus == 0 else { throw VoxError(message: "MP3 转换失败，请改用 WAV 导出。") }
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
