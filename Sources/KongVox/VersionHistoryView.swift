import SwiftUI

struct VersionHistoryView: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("项目版本").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("保存版本只记录本地文稿、声音、字幕和音频选择，不上传项目。恢复版本后会重新检查生成范围，历史音频文件不会删除。最多保留 30 个版本。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Button("保存当前版本") { studio.saveVersion("手动保存") }; Spacer() }
            List(studio.project?.versions?.reversed() ?? []) { version in
                HStack {
                    VStack(alignment: .leading) { Text(version.label).font(.headline); Text(version.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("恢复") { studio.restoreVersion(version) }
                }.padding(.vertical, 5)
            }
            if studio.project?.versions?.isEmpty != false { Text("尚未保存版本。").foregroundStyle(.secondary) }
        }.padding(24).frame(width: 650, height: 520)
        .disabled(studio.isWorking)
    }
}
