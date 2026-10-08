import Foundation

/// Audio files under Audio/ that no project, archived segment or saved version refers to.
struct AudioCleanupPlan {
    var files: [URL]
    var bytes: Int64
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum AudioMaintenance {
    /// Take files referenced by current segments, archived segments and every saved version snapshot.
    /// Throws if a snapshot cannot be decoded, because its references would then be unknown.
    static func referencedFiles(projects: [Project], versions: [[ProjectVersion]]) throws -> Set<String> {
        var names = Set<String>()
        func collect(_ p: Project) {
            for segment in p.segments + (p.archivedSegments ?? []) { for take in segment.takes { names.insert(take.file) } }
        }
        projects.forEach(collect)
        for list in versions {
            for version in list {
                guard let snapshot = try? JSONDecoder().decode(Project.self, from: version.payload) else {
                    throw VoxError(message: "有项目版本无法读取，为避免误删音频，已停止清理。")
                }
                collect(snapshot)
            }
        }
        return names
    }
    /// Lists unreferenced `.wav` files directly inside the audio folder. Hidden and non-regular files are ignored.
    static func plan(audioFolder: URL, referenced: Set<String>) throws -> AudioCleanupPlan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioFolder.path) else { return AudioCleanupPlan(files: [], bytes: 0) }
        var files: [URL] = [], bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for url in try fm.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true, url.pathExtension.lowercased() == "wav",
                  !referenced.contains(url.lastPathComponent) else { continue }
            files.append(url); bytes += Int64(values.fileSize ?? 0)
        }
        return AudioCleanupPlan(files: files.sorted { $0.lastPathComponent < $1.lastPathComponent }, bytes: bytes)
    }
}

extension Studio {
    /// Every saved version list, read from Versions/ plus any snapshots still stored inline.
    func allVersionLists() throws -> [[ProjectVersion]] {
        var lists = projects.compactMap(\.versions)
        let folder = root.appendingPathComponent("Versions")
        if FileManager.default.fileExists(atPath: folder.path) {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where file.pathExtension == "json" {
                lists.append(try JSONDecoder().decode([ProjectVersion].self, from: Data(contentsOf: file)))
            }
        }
        return lists
    }
    func audioCleanupPlan() throws -> AudioCleanupPlan {
        let referenced = try AudioMaintenance.referencedFiles(projects: projects, versions: allVersionLists())
        return try AudioMaintenance.plan(audioFolder: root.appendingPathComponent("Audio"), referenced: referenced)
    }
    /// Deletes files from a previewed plan that are still unreferenced now.
    func cleanUnreferencedAudio(_ preview: AudioCleanupPlan) {
        guard !isWorking, storageAvailable else { return }
        stop()
        do {
            let allowed = Set(try audioCleanupPlan().files.map(\.lastPathComponent))
            var removed = 0, bytes: Int64 = 0
            for url in preview.files where allowed.contains(url.lastPathComponent) {
                let size: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                try FileManager.default.removeItem(at: url)
                // Its cached on-device transcript is no longer needed either.
                try? FileManager.default.removeItem(at: root.appendingPathComponent("Transcripts").appendingPathComponent(url.lastPathComponent + ".json"))
                removed += 1; bytes += Int64(size)
            }
            status = "已清理 \(removed) 个未引用的音频文件，释放约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。"
        } catch { self.error = "清理未完成：\(error.localizedDescription)" }
    }
    /// Removes a project, its queue entry, version snapshots and download receipts. Audio files stay until cleanup.
    func deleteProject(_ id: UUID) {
        guard !isWorking, storageAvailable, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        stop()
        let oldProjects = projects, oldSelected = selected
        let removed = projects.remove(at: index)
        if projects.isEmpty { projects = [makeProject()] }
        if selected == id { selected = projects[min(index, projects.count - 1)].id }
        guard save() else { projects = oldProjects; selected = oldSelected; return }
        if queue.contains(where: { $0.projectID == id }) { queue.removeAll { $0.projectID == id }; saveQueue() }
        try? writeVersions([], for: id)
        let recovery = root.appendingPathComponent("Recovery")
        if let receipts = try? FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil) {
            for file in receipts where file.lastPathComponent.hasPrefix(id.uuidString + "-") { try? FileManager.default.removeItem(at: file) }
        }
        findings = []; qualitySummary = "尚未检查"
        status = "已删除「\(removed.title)」。音频文件暂时保留，可用「清理未引用音频」释放空间。"
    }
}
