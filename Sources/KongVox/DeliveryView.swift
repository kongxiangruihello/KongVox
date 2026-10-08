import SwiftUI

extension Project {
    var deliveryRevision: Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return (try? e.encode(self)) ?? Data() }
}
@MainActor final class DeliveryState: ObservableObject {
    @Published var report: DeliveryReport?
    @Published var message = "正在核对当前项目…"
    @Published var checked = false
    @Published var format = "zip"
    @Published var repairID: UUID?
    @Published var showRepair = false
    @Published var showCaptions = false
    @Published var showGenerate = false
    var revision = Data()
}
struct DeliveryView: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = DeliveryState()
    var initialFormat = "zip"
    var current: Bool { studio.project?.deliveryRevision == state.revision }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("成品交付检查").font(.title2.bold()); Spacer(); Button("关闭") { studio.stop(); dismiss() }.disabled(studio.isWorking) }
            Text("核对未完成内容、候选版本、字幕和音频提示后，再导出。全部检查在本地进行，规则检查不能判定漏读。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重新检查") { Task { await refresh() } }.disabled(studio.isWorking)
                Button("生成范围…") { studio.prepareReview(); state.showGenerate = true }.disabled(studio.isWorking)
                Button("编辑字幕…") { state.showCaptions = true }.disabled(studio.isWorking || !studio.fullAudioReady)
                if studio.player != nil { Button("停止试听") { studio.stop() } }
            }
            Text(current ? state.message : "内容已改变，请重新检查后导出。").font(.caption).foregroundStyle(.orange)
            if let p = studio.project, let report = state.report {
                Text("\(p.title) · \(p.segments.count) 个片段 · \(report.duration.map { Studio.timeLabel($0) } ?? "时长待就绪")").font(.headline)
                Text("未完成 \(report.missing.count) 段 · 有未采用匹配版本 \(report.candidates.count) 段 · 音频提示 \(report.findings.count) 条").font(.callout)
                Text("字幕：\(p.resolvedSubtitleStyle.rawValue)\(p.captionEdits == nil ? " · 自动" : " · 手工编辑")").font(.caption)
                if report.needsPreparation { Text("文稿为空、尚有未加入的草稿或处理范围待更新。请返回编辑或检查生成范围。").foregroundStyle(.red).font(.caption) }
                if let message = report.renderError { Text(message).foregroundStyle(.red).font(.caption) }
                if let message = report.subtitleError { Text(message).foregroundStyle(.red).font(.caption) }
                List {
                    ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(index + 1). \(segment.text)").lineLimit(2)
                                Spacer()
                                Button("定位 / 版本对比") { state.repairID = segment.id; state.showRepair = true }.disabled(studio.isWorking)
                            }
                            if report.missing.contains(segment.id) { Text("未生成、待更新、未采用或文件缺失").font(.caption).foregroundStyle(.red) }
                            if report.candidates.contains(segment.id) { Text("有其他匹配版本尚未采用；可对比后保留当前选择。").font(.caption).foregroundStyle(.orange) }
                            ForEach(report.findings.filter { $0.segmentID == segment.id }) { finding in
                                HStack { Text(finding.message).font(.caption); Spacer(); Button("定位试听") { studio.playFinding(finding) }.disabled(studio.isWorking || segment.current == nil) }
                            }
                            if index + 1 < p.segments.count { Button("循环试听与下一段接缝") { studio.playSeam(after: segment.id) }.font(.caption).disabled(studio.isWorking) }
                        }.padding(.vertical, 5)
                    }
                }
                HStack {
                    Picker("交付格式", selection: $state.format) {
                        Text("音频 + 字幕 ZIP").tag("zip"); Text("SRT 字幕").tag("srt")
                        Text("WAV").tag("wav"); Text("M4A").tag("m4a")
                        Text("短视频交付包").tag("short-video")
                        if Studio.ffmpeg != nil { Text("MP3").tag("mp3") }
                    }.frame(width: 310)
                    Toggle("已核对以上提示", isOn: $state.checked)
                    Spacer()
                    Button("确认并导出…") {
                        if state.format == "zip" { studio.exportBundle() }
                        else if state.format == "srt" { studio.exportSubtitles() }
                        else if state.format == "short-video" { studio.exportShortVideoPackage() }
                        else { studio.export(format: state.format) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!current || !state.checked || !report.audioReady || studio.isWorking || ((state.format == "zip" || state.format == "srt") && report.subtitleError != nil))
                }
            } else { Spacer() }
            Text(studio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 940, height: 700)
        .task { state.format = initialFormat; await refresh() }
        .sheet(isPresented: $state.showRepair) { if let id = state.repairID { SegmentRepair(segmentID: id).environmentObject(studio) } }
        .sheet(isPresented: $state.showCaptions) { CaptionEditor().environmentObject(studio) }
        .sheet(isPresented: $state.showGenerate) { GenerationReview().environmentObject(studio) }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
    @MainActor func refresh() async {
        guard !studio.isWorking, let p = studio.project else { return }
        state.checked = false; studio.stop(); studio.busy = true; defer { studio.busy = false }
        let folder = studio.root
        do {
            state.report = try await Task.detached { try DeliveryReport.inspect(p, root: folder) }.value
            state.revision = p.deliveryRevision; state.message = "检查完成；候选版本和音频提示请人工核对，导出仍使用已采用版本。"
        } catch { state.message = error.localizedDescription; state.report = nil }
    }
}
