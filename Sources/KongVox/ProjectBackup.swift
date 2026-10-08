import Foundation
import CryptoKit

// Streaming, versioned backup: bounded JSON manifest followed by raw audio blocks.
// No archive paths are extracted, and no credentials or recovery URLs are included.
enum ProjectBackup {
    struct AudioEntry: Codable { var name: String; var bytes: Int; var sha256: String }
    struct Manifest: Codable { var version = 1; var project: Project; var audio: [AudioEntry] }
    static let magic = Data("KONGVOX1\n".utf8)
    static let manifestLimit = 32 * 1024 * 1024
    static let audioLimit = 256 * 1024 * 1024
    static let totalLimit: Int64 = 8 * 1024 * 1024 * 1024
    static func fileNames(_ p: Project) -> Set<String> { Set((p.segments + (p.archivedSegments ?? [])).flatMap { $0.takes.map(\.file) }) }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count < 200 && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." && name.hasSuffix(".wav") && !name.contains("\0")
    }
    static func regularFile(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= audioLimit else { throw VoxError(message: "备份音频无效或超出单文件 256 MB 限制。") }
        return size
    }
    static func hash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func write(_ project: Project, root: URL, to destination: URL) throws {
        var p = project; p.taskMessage = nil; p.taskState = nil
        let names = fileNames(p).sorted()
        guard names.allSatisfy(validName) else { throw VoxError(message: "项目中存在无效音频路径，备份已停止。") }
        var entries: [AudioEntry] = [], total: Int64 = 0
        for name in names {
            let url = root.appendingPathComponent("Audio").appendingPathComponent(name)
            let bytes = try regularFile(url); total += Int64(bytes)
            guard total <= totalLimit else { throw VoxError(message: "备份超过 8 GB 限制。") }
            entries.append(AudioEntry(name: name, bytes: bytes, sha256: try hash(url)))
        }
        let manifest = try JSONEncoder().encode(Manifest(project: p, audio: entries))
        guard manifest.count <= manifestLimit else { throw VoxError(message: "项目记录过大，无法备份。") }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).kongvox")
        defer { try? FileManager.default.removeItem(at: temp) }
        try magic.write(to: temp)
        let out = try FileHandle(forWritingTo: temp); defer { try? out.close() }
        try out.seekToEnd()
        var size = UInt64(manifest.count).littleEndian
        try withUnsafeBytes(of: &size) { try out.write(contentsOf: Data($0)) }
        try out.write(contentsOf: manifest)
        for entry in entries {
            let input = try FileHandle(forReadingFrom: root.appendingPathComponent("Audio").appendingPathComponent(entry.name))
            defer { try? input.close() }
            var written = 0, digest = SHA256()
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation(); written += chunk.count; digest.update(data: chunk); try out.write(contentsOf: chunk)
            }
            guard written == entry.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw VoxError(message: "备份时音频发生变化，请重新备份。") }
        }
        try out.synchronize(); try out.close()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: destination) }
    }
    static func exact(_ file: FileHandle, _ count: Int) throws -> Data {
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw VoxError(message: "备份文件不完整，未恢复任何项目。") }; return data
    }
    // Validated contents are staged in a new private directory; caller commits metadata last.
    static func read(_ source: URL, staging: URL) throws -> Project {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard try exact(input, magic.count) == magic else { throw VoxError(message: "不是支持的 KongVox 备份文件。") }
        let lengthData = try exact(input, 8)
        let length = lengthData.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length <= manifestLimit else { throw VoxError(message: "备份目录长度无效。") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: exact(input, Int(length)))
        guard manifest.version == 1, manifest.audio.count <= 100000,
              manifest.audio.allSatisfy({ validName($0.name) && $0.bytes > 0 && $0.bytes <= audioLimit }),
              Set(manifest.audio.map(\.name)).count == manifest.audio.count,
              Set(manifest.audio.map(\.name)) == fileNames(manifest.project),
              manifest.audio.reduce(Int64(0), { $0 + Int64($1.bytes) }) <= totalLimit else { throw VoxError(message: "备份目录无效或版本不支持。") }
        let allSegments = manifest.project.segments + (manifest.project.archivedSegments ?? [])
        guard Set(allSegments.map(\.id)).count == allSegments.count,
              allSegments.allSatisfy({ s in Set(s.takes.map(\.id)).count == s.takes.count && (s.selectedTake == nil || s.takes.contains { $0.id == s.selectedTake }) }),
              manifest.project.settings.speed.isFinite, manifest.project.settings.pause.isFinite else { throw VoxError(message: "备份项目结构无效。") }
        _ = try manifest.project.settings.resolvedService.validated()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: staging) } }
        var mapping: [String: String] = [:]
        for entry in manifest.audio {
            try Task.checkCancellation()
            let newName = UUID().uuidString + ".wav"; mapping[entry.name] = newName
            let target = staging.appendingPathComponent(newName)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            var remaining = entry.bytes, digest = SHA256()
            while remaining > 0 {
                let chunk = try exact(input, min(1024 * 1024, remaining)); digest.update(data: chunk)
                try output.write(contentsOf: chunk); remaining -= chunk.count
            }
            try output.close()
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw VoxError(message: "备份音频校验失败，未恢复项目。") }
            _ = try AudioFiles.extractPCM(Data(contentsOf: target))
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VoxError(message: "备份包含多余数据，未恢复项目。") }
        var p = manifest.project
        p.id = UUID(); p.title += "（恢复副本）"; p.taskState = "待检查"; p.taskMessage = nil; p.usesDictionarySnapshot = true
        let hadCurrentCaptions = p.captionEdits != nil && !p.captionsStale
        var segmentMapping: [UUID: UUID] = [:]
        func remap(_ segments: [Segment]) -> [Segment] {
            segments.map { original in
                var s = original; s.id = UUID(); segmentMapping[original.id] = s.id
                for i in s.takes.indices { s.takes[i].file = mapping[s.takes[i].file]! }
                return s
            }
        }
        p.segments = remap(p.segments); p.archivedSegments = remap(p.archivedSegments ?? [])
        p.localSplitSources = p.localSplitSources?.compactMap { segmentMapping[$0] }
        if hadCurrentCaptions { let signature = p.captionSignature; p.captionEdits?.signature = signature }
        success = true; return p
    }
}
