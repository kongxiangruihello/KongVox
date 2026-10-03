import SwiftUI
import UniformTypeIdentifiers

final class BatchViewState: ObservableObject {
    @Published var tab = "导入文稿"
    @Published var documents: [ImportedDocument] = []
    @Published var documentID: UUID?
    @Published var omitURLs = true
    @Published var omitFootnotes = true
    @Published var loading = false
    @Published var presetName = ""
    @Published var skipFailures = false
    @Published var confirmQueue = false
    @Published var exportIDs = Set<UUID>()
    @Published var chapters = false
}
struct BatchWorkbench: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = BatchViewState()
    var options: ImportOptions { ImportOptions(omitURLs: state.omitURLs, omitFootnotes: state.omitFootnotes) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("批量工作台").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Picker("工作内容", selection: $state.tab) {
                ForEach(["导入文稿", "生成队列", "配音预设", "批量导出"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            if state.tab == "导入文稿" { importView }
            else if state.tab == "生成队列" { queueView }
            else if state.tab == "配音预设" { presetView }
            else { exportView }
            Text(studio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 850, height: 650)
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
        .confirmationDialog("开始队列生成？", isPresented: $state.confirmQueue) {
            Button("按所列顺序开始生成") { studio.startQueue(skipFailures: state.skipFailures) }
        } message: { Text("将依次向每个项目选择的服务提交待处理文字，按服务账户计费。已完成且未修改的音频会复用，失败项目不会自动重试。") }
    }
    var importView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(state.loading ? "正在读取…" : "选择 TXT / Markdown / DOCX…") { chooseDocuments() }
                Text("可多选；每份文件新建一个长文项目。").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Toggle("略过网址", isOn: $state.omitURLs); Toggle("略过 Markdown 脚注", isOn: $state.omitFootnotes) }
            Text("Word 导入正文与可识别的标题，不导入图片、页眉及脚注正文。请在预览中核对章节和朗读内容。").font(.caption).foregroundStyle(.secondary)
            if !state.documents.isEmpty {
                Picker("预览文稿", selection: $state.documentID) {
                    ForEach(state.documents) { document in Text(document.title).tag(Optional(document.id)) }
                }
                if let document = state.documents.first(where: { $0.id == state.documentID }) {
                    let content = DocumentImport.clean(document.text, options: options)
                    Text("\(document.title) · \(content.count) 字").font(.headline)
                    ScrollView { Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.background(.quaternary.opacity(0.3))
                }
                Button("导入 \(state.documents.count) 份文稿") {
                    studio.error = nil; studio.importDocuments(state.documents, options: options)
                    if studio.error == nil { state.documents = []; state.documentID = nil }
                }.buttonStyle(.borderedProminent)
            } else { Spacer(); Text("选择文稿后，可先预览清理后的完整内容。").foregroundStyle(.secondary); Spacer() }
        }.disabled(studio.isWorking || state.loading)
    }
    func chooseDocuments() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["txt", "md", "markdown", "docx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard urls.count <= 30 else { studio.error = "一次最多导入 30 份文稿。"; return }
        state.loading = true
        Task { @MainActor in
            defer { state.loading = false }
            do {
                state.documents = try await Task.detached { try urls.map { try DocumentImport.read($0) } }.value
                state.documentID = state.documents.first?.id
            } catch { studio.error = error.localizedDescription }
        }
    }
    var queueView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("添加当前项目") { if let id = studio.selected { studio.enqueue(id) } }
                Button("添加全部项目") { for p in studio.projects { studio.enqueue(p.id) } }
                Spacer()
                Button("清空队列") { studio.queue = []; studio.saveQueue() }
            }.disabled(studio.isWorking)
            Text("显示待处理字数（包含可恢复下载的内容），实际计费以服务商为准。再次开始会检查全部项目，复用已完成内容。重启后不会自动生成。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(studio.queue.enumerated()), id: \.element.id) { index, entry in
                    let p = studio.projects.first { $0.id == entry.projectID }
                    HStack {
                        Text("\(index + 1)").monospacedDigit()
                        VStack(alignment: .leading) {
                            Text(p?.title ?? "项目不存在").font(.headline)
                            if let p { Text("\(p.settings.resolvedService.name) · \(p.settings.resolvedService.model) · 待处理 \(studio.queueCharacters(p)) 字").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Text(entry.state)
                        HStack {
                            Button("上移") { studio.queue.swapAt(index, index - 1); studio.saveQueue() }.disabled(index == 0)
                            Button("下移") { studio.queue.swapAt(index, index + 1); studio.saveQueue() }.disabled(index + 1 == studio.queue.count)
                            Button("移除") { studio.queue.removeAll { $0.id == entry.id }; studio.saveQueue() }
                        }.disabled(studio.isWorking).controlSize(.small)
                    }.padding(.vertical, 6)
                }
            }
            Toggle("遇到失败时继续其他项目", isOn: $state.skipFailures).disabled(studio.isWorking)
            HStack {
                if studio.queueRunning {
                    Button("本段完成后暂停队列") { studio.pauseQueue() }
                    Button("跳过当前项目") { studio.skipQueueProject() }
                    Text("取消或跳过不能撤销服务端已发生的费用。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("检查完毕，开始队列…") { state.confirmQueue = true }.buttonStyle(.borderedProminent).disabled(studio.isWorking || studio.queue.isEmpty)
                }
            }
        }
    }
    var presetView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存当前项目的服务、音色、语速、表达要求、段间停顿和音量设置。密钥与发音词典不包含在预设中。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("预设名称，例如：温和长文", text: $state.presetName).textFieldStyle(.roundedBorder)
                Button("保存当前声音") { studio.storePreset(state.presetName); state.presetName = "" }.disabled(state.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List(studio.presets) { preset in
                HStack {
                    VStack(alignment: .leading) { Text(preset.name).font(.headline); Text("\(preset.settings.resolvedService.name) · \(preset.settings.voice)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("应用到当前") { studio.applyPreset(preset, create: false) }
                    Button("用于新项目") { studio.applyPreset(preset, create: true) }
                    Button("删除") { studio.savePresets(studio.presets.filter { $0.id != preset.id }) }
                }.padding(.vertical, 6)
            }
        }.disabled(studio.isWorking)
    }
    var exportView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出所选项目的 WAV、SRT 与交付清单。所有选中内容需已生成；文件会保存到新建的交付文件夹。").font(.caption).foregroundStyle(.secondary)
            Picker("拆分方式", selection: $state.chapters) { Text("每篇一份完整音频").tag(false); Text("按章节分别导出").tag(true) }.pickerStyle(.segmented)
            HStack { Button("全选") { state.exportIDs = Set(studio.projects.map(\.id)) }; Button("取消选择") { state.exportIDs = [] } }
            List(studio.projects) { p in
                Toggle(isOn: Binding(get: { state.exportIDs.contains(p.id) }, set: { if $0 { state.exportIDs.insert(p.id) } else { state.exportIDs.remove(p.id) } })) {
                    Text(p.title)
                    Text(p.needsLongPreparation && p.isLongMode ? "\(p.fullText.count) 字 · 待生成" : "\(p.fullText.count) 字 · \(p.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            Button("选择文件夹并导出…") { studio.exportBatch(ids: state.exportIDs, chapters: state.chapters) }.buttonStyle(.borderedProminent).disabled(state.exportIDs.isEmpty)
        }.disabled(studio.isWorking)
    }
}
