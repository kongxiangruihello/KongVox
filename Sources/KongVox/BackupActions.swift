import SwiftUI
import UniformTypeIdentifiers

extension Studio {
    func chooseBackup() {
        guard !isWorking, let p = project else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.data]; panel.nameFieldStringValue = p.title + ".kongvox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupProject(to: url)
    }
    func backupProject(to destination: URL) {
        guard !isWorking, storageAvailable, let p = project else { return }
        busy = true; stop(); status = "正在备份文稿、词典和历史音频…"
        let folder = root
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await Task.detached { try ProjectBackup.write(p, root: folder, to: destination) }.value
                status = "项目备份已保存：\(destination.lastPathComponent)"
            } catch { self.error = "备份失败：\(error.localizedDescription)"; status = "未完成备份，原文件保留。" }
        }
    }
    func chooseRestore() {
        guard !isWorking, storageAvailable else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 .kongvox 备份；恢复为新项目，保留现有项目。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreProject(from: url)
    }
    func restoreProject(from source: URL) {
        guard !isWorking, storageAvailable else { return }
        busy = true; stop(); status = "正在校验并恢复备份…"
        let staging = root.appendingPathComponent(".restore-\(UUID())")
        task = Task {
            defer { try? FileManager.default.removeItem(at: staging); busy = false; task = nil }
            var copied: [URL] = []
            do {
                let restored = try await Task.detached { try ProjectBackup.read(source, staging: staging) }.value
                for name in ProjectBackup.fileNames(restored) {
                    let target = root.appendingPathComponent("Audio").appendingPathComponent(name)
                    try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: target); copied.append(target)
                }
                projects.insert(restored, at: 0)
                guard save() else { projects.removeAll { $0.id == restored.id }; throw VoxError(message: "恢复项目保存失败。") }
                selected = restored.id; findings = []; qualitySummary = "恢复后请重新检查"
                status = "已恢复为新项目，词典保留备份快照；继续生成前请核对服务配置。"
            } catch {
                for file in copied { try? FileManager.default.removeItem(at: file) }
                self.error = "恢复失败：\(error.localizedDescription)"; status = "恢复未完成，原项目未修改。"
            }
        }
    }
}
