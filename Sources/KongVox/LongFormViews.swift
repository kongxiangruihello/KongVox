import SwiftUI

final class GenerationReviewState: ObservableObject { @Published var force = false }
struct GenerationReview: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = GenerationReviewState()
    var scope: Set<UUID>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认本次生成范围").font(.title2.bold())
            Text("仅处理待更新内容；已有音频会保留。修改句子仍可能需要重做其所在的整段。生成按所选服务计费。").foregroundStyle(.secondary)
            if let p = studio.project {
                List {
                    ForEach(Array(p.segments.enumerated()).filter { scope == nil || scope!.contains($0.element.id) }, id: \.element.id) { index, segment in
                        HStack(alignment: .top) {
                            Text("\(index + 1)").monospacedDigit().frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(segment.text).lineLimit(3)
                                Text("\(p.settings.reading(segment.spokenText).count) 字").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(studio.ready(segment, settings: p.settings) ? (state.force ? "重新生成" : "复用") : studio.hasRecovery(segment) ? "恢复下载" : "需要生成").foregroundStyle(studio.ready(segment, settings: p.settings) ? .green : .orange)
                        }.padding(.vertical, 5)
                    }
                }
            }
            if scope != nil { Toggle("重新生成本章已就绪片段（保留历史，可能再次计费）", isOn: $state.force) }
            HStack {
                Button("返回编辑") { dismiss() }
                Spacer()
                Button("开始生成待更新内容") { dismiss(); studio.generate(scope: scope, force: state.force) }.buttonStyle(.borderedProminent)
                    .disabled(studio.busy || studio.project?.segments.isEmpty != false)
            }
        }.padding(24).frame(width: 720, height: 520)
    }
}
final class WorkbenchState: ObservableObject {
    @Published var repairID: UUID?
    @Published var showRepair = false
    @Published var tab = "章节"
    @Published var chapterScope: Set<UUID>?
    @Published var showReview = false
}
struct LongFormWorkbench: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WorkbenchState()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("长文工作台").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Picker("工具", selection: $state.tab) {
                Text("章节").tag("章节"); Text("质量检查").tag("质量检查"); Text("发音词典").tag("发音词典"); Text("任务中心").tag("任务中心")
            }.pickerStyle(.segmented)
            if state.tab == "章节" { chapterList }
            else if state.tab == "质量检查" { qualityList }
            else if state.tab == "发音词典" { DictionaryEditor().environmentObject(studio) }
            else { taskList }
        }.padding(24).frame(width: 800, height: 610)
        .sheet(isPresented: $state.showReview) { GenerationReview(scope: state.chapterScope).environmentObject(studio) }
        .sheet(isPresented: $state.showRepair) { if let id = state.repairID { SegmentRepair(segmentID: id).environmentObject(studio) } }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
    var chapterList: some View {
        VStack(alignment: .leading) {
            Text("按独立行的「第一章」、数字编号或 Markdown 标题识别章节；标题也会朗读。没有标题时作为一章。全文仍可统一导出。").font(.caption).foregroundStyle(.secondary)
            Button("按当前文稿更新处理片段") { studio.prepareReview() }.disabled(studio.busy)
            List {
                if let p = studio.project {
                    ForEach(p.chapters) { chapter in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chapter.title).font(.headline).lineLimit(2)
                            HStack {
                                Text("\(chapter.segmentIDs.count) 个片段").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("生成待更新") { state.chapterScope = Set(chapter.segmentIDs); state.showReview = true }
                                Button("试听") { studio.chapterAudio(chapter, export: false) }
                                Button("导出本章 WAV") { studio.chapterAudio(chapter, export: true) }
                            }.disabled(studio.busy || (p.isLongMode && p.needsLongPreparation))
                        }.padding(.vertical, 6)
                    }
                }
            }
            Text("需要整章重做时，在生成范围中勾选重新生成；旧音频仍保留在历史中。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var qualityList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检查原始片段的长静音、音量差异、异常短时长和缺失文件，不上传音频。提示不能代替人工确认漏读。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("检查当前项目") { studio.inspectAudio() }.disabled(studio.busy); Text(studio.qualitySummary).font(.caption) }
            List(studio.findings) { finding in
                HStack {
                    VStack(alignment: .leading) { Text("片段 \(finding.index + 1) · \(Studio.timeLabel(finding.seconds))").font(.headline); Text(finding.message) }
                    Spacer()
                    Button("修复 / 对比") { state.repairID = finding.segmentID; state.showRepair = true }.disabled(studio.busy)
                    Button("定位试听") { studio.playFinding(finding) }.disabled(studio.busy || studio.project?.segments.first(where: { $0.id == finding.segmentID })?.current == nil)
                }.padding(.vertical, 5)
            }
        }
    }
    var taskList: some View {
        VStack(alignment: .leading) {
            Text("逐个项目继续生成。重启后需手动继续，避免意外计费；已完成的片段会复用。").font(.caption).foregroundStyle(.secondary)
            List(studio.projects) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(p.title).font(.headline); Spacer()
                        Text(p.id == studio.activeProject ? "生成中" : (p.isLongMode && p.needsLongPreparation) ? "文稿待更新" : p.taskState ?? "待生成")
                    }
                    let done = p.segments.filter { studio.ready($0, settings: p.settings) }.count
                    ProgressView(value: Double(done), total: Double(max(1, p.segments.count)))
                    Text("\(done) / \(p.segments.count) 片段就绪").font(.caption)
                    if let message = p.taskMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                    HStack {
                        if p.id == studio.activeProject {
                            Button(studio.pauseRequested ? "等待当前片段完成…" : "本段完成后暂停") { studio.pauseAfterSegment() }.disabled(studio.pauseRequested)
                            Button("立即取消") { studio.cancel() }
                        } else {
                            Button("打开并检查生成范围") {
                                studio.stop(); studio.selected = p.id; studio.findings = []; studio.qualitySummary = "尚未检查"
                                studio.prepareReview(); state.chapterScope = nil; state.showReview = true
                            }.disabled(studio.busy)
                        }
                    }
                }.padding(.vertical, 8)
            }
        }
    }
}
final class DictionaryState: ObservableObject {
    @Published var global = false
    @Published var rules: [PronunciationRule] = []
    @Published var saved = ""
}
struct DictionaryEditor: View {
    @EnvironmentObject var studio: Studio
    @StateObject private var state = DictionaryState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("范围", selection: $state.global) { Text("当前项目").tag(false); Text("所有项目").tag(true) }.pickerStyle(.segmented)
                .onChange(of: state.global) { _ in load() }
            if studio.project?.usesDictionarySnapshot == true { Text("本项目沿用备份时的全局词典快照；当前全局词典的修改不会影响它。").font(.caption).foregroundStyle(.secondary) }
            Text("填写原词与希望朗读的替代文字。项目词条优先，同位置优先匹配长词，不连锁替换；字幕保留原文。保存后仅影响含这些词的音频。切换范围会放弃未保存编辑。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($state.rules) { $rule in
                    HStack {
                        TextField("原词，例如：重庆", text: $rule.word)
                        Image(systemName: "arrow.right")
                        TextField("读法，例如：崇庆", text: $rule.reading)
                        Button { state.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
            }
            HStack {
                Button("添加词条") { state.rules.append(PronunciationRule(word: "", reading: "")); state.saved = "" }
                Button("保存词典") {
                    studio.saveDictionary(state.rules, global: state.global)
                    if studio.error == nil { state.saved = "已保存；生成前可检查受影响范围。" }
                }
                Text(state.saved).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(studio.busy).onAppear { load() }
    }
    func load() { state.rules = state.global ? studio.globalDictionary : studio.project?.settings.pronunciationRules ?? []; state.saved = "" }
}
