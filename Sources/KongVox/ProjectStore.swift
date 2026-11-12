import Foundation

/// Projects on disk, one file each: `Projects/<id>.json`, plus `Projects/index.json` holding their order.
///
/// Until 0.14 every project lived in a single `projects.json`, rewritten in full on each save — once per
/// generated passage. Now a save only rewrites the projects whose content actually changed.
/// The old file is migrated on first load and kept, renamed, as a backup; it is never deleted.
struct ProjectStore {
    let root: URL
    var folder: URL { root.appendingPathComponent("Projects") }
    var indexFile: URL { folder.appendingPathComponent("index.json") }
    var legacyFile: URL { root.appendingPathComponent("projects.json") }
    /// Bytes last read from or written to each project file, to skip unchanged projects on save.
    private var written: [UUID: Data] = [:]
    private var order: [UUID]?

    init(root: URL) { self.root = root }

    func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    private static func encoder() -> JSONEncoder {
        // Stable key order, so an unchanged project always encodes to the same bytes.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }

    /// Reads every project. Throws rather than returning a partial list, so a caller that cannot read
    /// something never goes on to save over it.
    /// `beforeMigrating` sees the projects of an old single-file store before it is converted.
    mutating func load(beforeMigrating: (([Project], URL) throws -> Void)? = nil) throws -> [Project] {
        let fm = FileManager.default
        let stored = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        if !fm.fileExists(atPath: indexFile.path), stored.isEmpty {
            guard fm.fileExists(atPath: legacyFile.path) else { written = [:]; order = nil; return [] }
            let projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: legacyFile))
            try beforeMigrating?(projects, legacyFile)
            try save(projects)
            // Keep the old file as a backup under a name no version reads again.
            var backup = root.appendingPathComponent("projects-before-0.14.json"), attempt = 1
            while fm.fileExists(atPath: backup.path) { attempt += 1; backup = root.appendingPathComponent("projects-before-0.14-\(attempt).json") }
            try? fm.moveItem(at: legacyFile, to: backup)
            return projects
        }
        var ids: [UUID] = []
        if fm.fileExists(atPath: indexFile.path) { ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: indexFile)) }
        let listed = Set(ids)
        // A project file the index does not mention (e.g. the index write was interrupted) is still a project.
        let unlisted = stored.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }.filter { !listed.contains($0) }
        var projects: [Project] = [], bytes: [UUID: Data] = [:]
        for id in ids + unlisted.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard fm.fileExists(atPath: file(id).path) else { throw VoxError(message: "项目文件缺失：\(id.uuidString).json") }
            let data = try Data(contentsOf: file(id))
            let project = try JSONDecoder().decode(Project.self, from: data)
            guard project.id == id else { throw VoxError(message: "项目文件与内容不符：\(id.uuidString).json") }
            projects.append(project); bytes[id] = data
        }
        written = bytes
        // With unlisted files present the index on disk is stale; leaving `order` unset makes the next save rewrite it.
        order = unlisted.isEmpty ? ids : nil
        return projects
    }

    /// Writes the projects that changed, the order if it changed, and removes the files of projects no longer present.
    mutating func save(_ projects: [Project]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = Self.encoder()
        for project in projects {
            let data = try encoder.encode(project)
            if written[project.id] == data, fm.fileExists(atPath: file(project.id).path) { continue }
            try data.write(to: file(project.id), options: .atomic)
            written[project.id] = data
        }
        let ids = projects.map(\.id)
        if order != ids || !fm.fileExists(atPath: indexFile.path) {
            try JSONEncoder().encode(ids).write(to: indexFile, options: .atomic)
            order = ids
        }
        let kept = Set(ids)
        for id in Array(written.keys) where !kept.contains(id) {
            if fm.fileExists(atPath: file(id).path) { try fm.removeItem(at: file(id)) }
            written[id] = nil
        }
    }
}
