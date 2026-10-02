import SwiftUI

final class ReviewState: ObservableObject {
    @Published var repairID: UUID?
    @Published var showRepair = false
    @Published var follow = true
}
struct FinishedReview: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ReviewState()
    var initialSegment: UUID?
    var body: some View {
        let canPlay = studio.fullAudioReady
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("成品检查").font(.title2.bold()); Spacer()
                Toggle("跟随播放", isOn: $state.follow).toggleStyle(.checkbox)
                Button("完成") { dismiss() }
            }
            Text("点击文稿从对应片段播放；高亮按片段时间轴跟随，不是逐字对齐。修改原稿前请返回主界面。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("播放全文") { studio.playAll() }.disabled(studio.busy || !canPlay)
                Button(studio.playing ? "暂停" : "继续") { studio.togglePause() }.disabled(studio.player == nil || studio.busy)
                Button("停止") { studio.stop() }.disabled(studio.busy)
                Spacer()
                Button("检查音频") { studio.inspectAudio() }.disabled(studio.busy)
                Text(studio.qualitySummary).font(.caption).lineLimit(1)
            }
            if studio.playbackDuration > 0 {
                HStack {
                    Button("−10 秒") { studio.skip(-10) }
                    Text(Studio.timeLabel(studio.playbackTime)).monospacedDigit()
                    Slider(value: Binding(get: { studio.playbackTime }, set: { studio.seek($0) }), in: 0...max(0.01, studio.playbackDuration)).accessibilityLabel("成品播放进度")
                    Text(Studio.timeLabel(studio.playbackDuration)).monospacedDigit()
                    Button("+10 秒") { studio.skip(10) }
                }.disabled(studio.busy)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let p = studio.project {
                            ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("片段 \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                        if studio.readingSegment == segment.id { Label("当前播放", systemImage: "speaker.wave.2.fill").font(.caption).foregroundStyle(.indigo) }
                                        Spacer()
                                        Button("修复 / 版本对比") { state.repairID = segment.id; state.showRepair = true }.disabled(studio.busy)
                                    }
                                    Button { studio.playAll(from: segment.id) } label: {
                                        Text(segment.text).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).lineSpacing(5)
                                    }.buttonStyle(.plain).disabled(studio.busy || !canPlay)
                                    ForEach(studio.findings.filter { $0.segmentID == segment.id }) { finding in
                                        HStack(alignment: .top) {
                                            Label(finding.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                            Spacer()
                                            Button("复听") { studio.playFinding(finding) }.disabled(studio.busy || segment.current == nil)
                                        }
                                    }
                                }.padding(14)
                                .background(studio.readingSegment == segment.id ? Color.indigo.opacity(0.1) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .id(segment.id)
                            }
                        }
                    }
                }
                .onChange(of: studio.readingSegment) { id in
                    if state.follow, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear { if let initialSegment { proxy.scrollTo(initialSegment, anchor: .center) } }
            }
            Text(studio.status).font(.caption).foregroundStyle(.secondary)
            if studio.project?.isLongMode == true && studio.project?.needsLongPreparation == true {
                Text("全文已修改，请先返回生成范围更新处理片段，再检查最新内容。").font(.caption).foregroundStyle(.orange)
            }
        }.padding(24).frame(width: 880, height: 650)
        .sheet(isPresented: $state.showRepair) {
            if let id = state.repairID { SegmentRepair(segmentID: id).environmentObject(studio) }
        }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
}
final class RepairState: ObservableObject { @Published var pronunciation = "" }
struct SegmentRepair: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = RepairState()
    let segmentID: UUID
    var segment: Segment? { studio.project?.segments.first { $0.id == segmentID } }
    var dirty: Bool { state.pronunciation != segment?.pronunciation }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("修复与版本对比").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(studio.busy) }
            if let segment, let p = studio.project {
                Text("原文 / 字幕").font(.headline)
                ScrollView { Text(segment.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 100)
                Text("完整替代读法（留空恢复按原文朗读）").font(.headline)
                TextEditor(text: $state.pronunciation).frame(height: 90).border(.quaternary).disabled(studio.busy)
                HStack {
                    Button("保存读法") { studio.updatePronunciation(segmentID, text: state.pronunciation) }.disabled(studio.busy || !dirty)
                    Button("生成新版本并试听") {
                        studio.updatePronunciation(segmentID, text: state.pronunciation)
                        studio.generate(only: segmentID, audition: true)
                    }.disabled(studio.busy || (p.isLongMode && p.needsLongPreparation))
                    if studio.busy && studio.activeSegment == segmentID { Button("取消") { studio.cancel() } }
                }
                Text("新版本先保留供对比，点击「采用」才进入成品。旧版本即使不匹配当前设置，仍可试听；关闭前请保存读法。").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(Array(segment.takes.enumerated()), id: \.element.id) { index, take in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(index == 0 ? "最新版本" : "历史版本 \(segment.takes.count - index)").font(.headline)
                                Text(take.date.formatted(date: .abbreviated, time: .standard)).font(.caption)
                                Spacer()
                                if take.id == segment.selectedTake { Text("已采用").foregroundStyle(.green) }
                                Button("试听") { studio.play(studio.audioURL(take)) }.disabled(studio.busy)
                                Button("采用") { studio.adoptTake(segmentID: segmentID, takeID: take.id) }
                                    .disabled(studio.busy || dirty || take.fingerprint != segment.fingerprint(p.settings) || take.id == segment.selectedTake)
                            }
                            Text("\(take.settings?.voice ?? p.settings.voice) · \(take.service?.name ?? "历史服务")").font(.caption).foregroundStyle(.secondary)
                            Text(take.spokenText ?? segment.spokenText).font(.caption).lineLimit(2)
                        }.padding(.vertical, 5)
                    }
                }
            }
            HStack {
                if studio.player != nil { Button(studio.playing ? "暂停试听" : "继续试听") { studio.togglePause() }; Button("停止试听") { studio.stop() } }
                Text(studio.status).font(.caption).foregroundStyle(.secondary)
            }.disabled(studio.busy)
        }.padding(24).frame(width: 780, height: 620)
        .onAppear { state.pronunciation = segment?.pronunciation ?? "" }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
}
