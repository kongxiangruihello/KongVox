import SwiftUI

final class GenerationReviewState: ObservableObject {
    @Published var force = false
    @Published var selected = Set<UUID>()
}
struct GenerationReview: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = GenerationReviewState()
    var scope: Set<UUID>?
    var initialForce = false
    var audition = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认本次生成范围").font(.title2.bold())
            if let p = studio.project {
                let impact = GenerationImpact(p, selected: state.selected, force: state.force, ready: { studio.ready($0, in: p) }, recovery: { studio.hasRecovery($0) })
                Text("\(p.settings.resolvedService.name) · \(p.settings.voice) · 提交正文按服务商实际计费").font(.caption)
                Text("新请求 \(impact.generate) 字 · 恢复下载 \(impact.recover) 字 · 所选复用 \(impact.reuse) 字 · 未选保持 \(impact.untouched) 字").font(.headline)
                Text("仅提交勾选且需要处理的内容；下方展开可核对词典替换后的完整读法。旧音频保留，批量重做不会删除历史。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("全选范围内") { state.selected = Set(p.segments.filter { scope == nil || scope!.contains($0.id) }.map(\.id)) }
                    Button("只选待更新") { state.force = false; state.selected = Set(p.segments.filter { (scope == nil || scope!.contains($0.id)) && !studio.ready($0, in: p) }.map(\.id)) }
                    Button("全不选") { state.selected = [] }
                }
                List {
                    ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Toggle("选择片段 \(index + 1)", isOn: Binding(get: { state.selected.contains(segment.id) }, set: { value in
                                    if value { state.selected.insert(segment.id) } else { state.selected.remove(segment.id) }
                                })).labelsHidden().disabled(scope != nil && !scope!.contains(segment.id))
                                Text("\(index + 1)").monospacedDigit()
                                Text(segment.text).lineLimit(3)
                                Spacer()
                                Text(label(segment, p)).font(.caption).foregroundStyle(impact.pending.contains(segment.id) ? .orange : .secondary)
                            }
                            DisclosureGroup("提交读法 · \(p.settings.reading(segment.spokenText).count) 字") {
                                Text(p.settings.reading(segment.spokenText)).font(.caption).textSelection(.enabled)
                                DictionaryMatches(text: segment.spokenText, rules: (p.settings.pronunciationRules ?? []) + (p.settings.globalPronunciationRules ?? []))
                            }.font(.caption)
                        }.padding(.vertical, 5)
                    }
                }
                Toggle("重新生成所选已就绪内容（可能再次计费）", isOn: $state.force)
                let issues = scopedIssues(p, ids: impact.pending)
                ForEach(issues.prefix(2)) { issue in Text(issue.message).font(.caption).foregroundStyle(issue.blocking ? .red : .orange) }
                HStack {
                    Button("返回编辑") { dismiss() }
                    Spacer()
                    Button("确认生成 \(impact.pending.count) 个片段") {
                        dismiss()
                        if audition, let id = state.selected.first { studio.generate(only: id, audition: true) }
                        else { studio.generate(scope: state.selected, force: state.force) }
                    }.buttonStyle(.borderedProminent).disabled(impact.pending.isEmpty || issues.contains(where: \.blocking) || studio.isWorking)
                }
            }
        }.padding(24).frame(width: 850, height: 650)
        .onAppear {
            state.force = initialForce
            state.selected = scope ?? Set(studio.project?.segments.map(\.id) ?? [])
        }
    }
    func scopedIssues(_ p: Project, ids: Set<UUID>) -> [PreflightIssue] { var copy = p; copy.segments = p.segments.filter { ids.contains($0.id) }; return ServicePreflight.inspect(copy, catalog: studio.catalog) }
    func label(_ s: Segment, _ p: Project) -> String {
        if !state.selected.contains(s.id) { return "不处理" }
        if studio.ready(s, in: p) && !state.force { return "复用" }
        if studio.hasRecovery(s) { return "恢复下载" }
        if studio.ready(s, in: p) { return "主动重做" }
        if s.current != nil { return "文稿/声音变更或文件缺失" }
        return "尚未生成或未采用"
    }
}
struct DictionaryMatches: View {
    let text: String
    let rules: [PronunciationRule]
    var body: some View {
        let matches = PronunciationDictionary.preview(text, rules: rules).matches
        let words = Set(matches.map { $0.rule.id })
        VStack(alignment: .leading, spacing: 4) {
            if matches.isEmpty { Text("本段无词典命中").foregroundStyle(.secondary) }
            ForEach(rules.filter { words.contains($0.id) }) { rule in
                Text("\(rule.category ?? "其他") · \(rule.word) → \(rule.reading) · 命中 \(matches.filter { $0.rule.id == rule.id }.count) 次")
            }
        }.font(.caption)
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
            Button("按当前文稿更新处理片段") { studio.prepareReview() }.disabled(studio.isWorking)
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
                            }.disabled(studio.isWorking || (p.isLongMode && p.needsLongPreparation))
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
            HStack { Button("检查当前项目") { studio.inspectAudio() }.disabled(studio.isWorking); Text(studio.qualitySummary).font(.caption) }
            List(studio.findings) { finding in
                HStack {
                    VStack(alignment: .leading) { Text("片段 \(finding.index + 1) · \(Studio.timeLabel(finding.seconds))").font(.headline); Text(finding.message) }
                    Spacer()
                    Button("修复 / 对比") { state.repairID = finding.segmentID; state.showRepair = true }.disabled(studio.isWorking)
                    Button("定位试听") { studio.playFinding(finding) }.disabled(studio.isWorking || studio.project?.segments.first(where: { $0.id == finding.segmentID })?.current == nil)
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
                    let done = p.segments.filter { studio.ready($0, in: p) }.count
                    ProgressView(value: Double(done), total: Double(max(1, p.segments.count)))
                    Text("\(done) / \(p.segments.count) 片段就绪").font(.caption)
                    if let message = p.taskMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                    HStack {
                        if p.id == studio.activeProject {
                            Button(studio.pauseRequested ? "等待当前片段完成…" : "本段完成后暂停") { if studio.queueRunning { studio.pauseQueue() } else { studio.pauseAfterSegment() } }.disabled(studio.pauseRequested)
                            Button("立即取消") { if studio.queueRunning { studio.pauseQueue() }; studio.cancel() }
                        } else {
                            Button("打开并检查生成范围") {
                                studio.stop(); studio.selected = p.id; studio.findings = []; studio.qualitySummary = "尚未检查"
                                studio.prepareReview(); state.chapterScope = nil; state.showReview = true
                            }.disabled(studio.isWorking)
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
    @Published var showPreview = false
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
                        Toggle("启用", isOn: Binding(get: { rule.isEnabled }, set: { rule.enabled = $0 })).labelsHidden()
                        Picker("类型", selection: Binding(get: { rule.category ?? "其他" }, set: { rule.category = $0 })) {
                            ForEach(["人名", "地名", "品牌", "多音字", "其他"], id: \.self) { Text($0) }
                        }.labelsHidden().frame(width: 85)
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
                Button("预览本篇命中") { state.showPreview = true }
                Text(state.saved).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(studio.isWorking).onAppear { load() }
        .sheet(isPresented: $state.showPreview) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("词典替换预览 · 尚未保存").font(.headline); Spacer(); Button("返回词典") { state.showPreview = false } }
                Text("只显示实际命中的词条；项目优先、长词优先，不连锁替换。确认无误后返回保存。停用项目同名词条会屏蔽全局同名词条。").font(.caption)
                if let p = preparedProject {
                    let globals = state.global && p.usesDictionarySnapshot != true ? state.rules : p.settings.globalPronunciationRules ?? []
                    let locals = state.global ? p.settings.pronunciationRules ?? [] : state.rules
                    List(p.segments) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(segment.spokenText).font(.caption).foregroundStyle(.secondary)
                            DictionaryMatches(text: segment.spokenText, rules: locals + globals)
                            Text("替换后：" + PronunciationDictionary.apply(segment.spokenText, rules: locals + globals)).textSelection(.enabled)
                        }
                    }
                }
            }.padding(24).frame(width: 760, height: 570)
        }
    }
    var preparedProject: Project? { var p = studio.project; if p?.isLongMode == true { p?.prepareLongDocument() }; return p }
    func load() { state.rules = state.global ? studio.globalDictionary : studio.project?.settings.pronunciationRules ?? []; state.saved = "" }
}
