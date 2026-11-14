import SwiftUI

struct VersionHistoryView: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ProjectVersion?
    var versions: [ProjectVersion] {
        guard let id = studio.project?.id else { return [] }
        return Array(studio.versions(for: id).reversed())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("项目版本").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("保存版本只记录本地文稿、声音、字幕和音频选择，不上传项目。恢复版本后会重新检查生成范围，历史音频文件不会删除。最多保留 30 个版本。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Button("保存当前版本") { studio.saveVersion("手动保存") }; Spacer() }
            List(versions) { version in
                HStack {
                    VStack(alignment: .leading) { Text(version.label).font(.headline); Text(version.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("预览恢复…") { preview = version }
                }.padding(.vertical, 5)
            }
            if versions.isEmpty { Text("尚未保存版本。").foregroundStyle(.secondary) }
        }.padding(24).frame(width: 650, height: 520)
        .disabled(studio.isWorking)
        .sheet(item: $preview) { version in
            VStack(alignment: .leading, spacing: 12) {
                Text("恢复预览").font(.headline)
                if let current = studio.project, let saved = try? JSONDecoder().decode(Project.self, from: version.payload) {
                    Text("文稿：\(current.fullText.count) → \(saved.fullText.count) 字")
                    Text("已选音频：\(current.segments.filter { $0.current != nil }.count) → \(saved.segments.filter { $0.current != nil }.count) 段")
                    Text("声音：\(current.settings.resolvedService.name) / \(current.settings.voice) → \(saved.settings.resolvedService.name) / \(saved.settings.voice)")
                    Text("语速：\(current.settings.speed)× → \(saved.settings.speed)×")
                    ScrollView { Text(saved.fullText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 150)
                    Button("确认恢复", role: .destructive) { studio.restoreVersion(version); preview = nil }
                } else { Text("版本无法读取。") }
                Button("取消") { preview = nil }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 500)
        }
    }
}
