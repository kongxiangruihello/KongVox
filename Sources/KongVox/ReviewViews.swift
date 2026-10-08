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
                Button("播放全文") { studio.playAll() }.disabled(studio.isWorking || !canPlay)
                Button(studio.playing ? "暂停" : "继续") { studio.togglePause() }.disabled(studio.player == nil || studio.isWorking)
                Button("停止") { studio.stop() }.disabled(studio.isWorking)
                Spacer()
                Button("检查音频") { studio.inspectAudio() }.disabled(studio.isWorking)
                Text(studio.qualitySummary).font(.caption).lineLimit(1)
            }
            if studio.playbackDuration > 0 {
                HStack {
                    Button("−10 秒") { studio.skip(-10) }
                    Text(Studio.timeLabel(studio.playbackTime)).monospacedDigit()
                    Slider(value: Binding(get: { studio.playbackTime }, set: { studio.seek($0) }), in: 0...max(0.01, studio.playbackDuration)).accessibilityLabel("成品播放进度")
                    Text(Studio.timeLabel(studio.playbackDuration)).monospacedDigit()
                    Button("+10 秒") { studio.skip(10) }
                }.disabled(studio.isWorking)
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
                                        Button("修复 / 版本对比") { state.repairID = segment.id; state.showRepair = true }.disabled(studio.isWorking)
                                    }
                                    Button { studio.playAll(from: segment.id) } label: {
                                        Text(segment.text).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).lineSpacing(5)
                                    }.buttonStyle(.plain).disabled(studio.isWorking || !canPlay)
                                    ForEach(studio.findings.filter { $0.segmentID == segment.id }) { finding in
                                        HStack(alignment: .top) {
                                            Label(finding.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                                            Spacer()
                                            Button("复听") { studio.playFinding(finding) }.disabled(studio.isWorking || segment.current == nil)
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
final class RepairState: ObservableObject {
    @Published var pronunciation = ""
    @Published var customSpeed = false
    @Published var speed = 1.0
    @Published var customPause = false
    @Published var pause = 0.35
    @Published var suggestion = ""
    @Published var showGenerate = false
}
struct SegmentRepair: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = RepairState()
    let segmentID: UUID
    var segment: Segment? { studio.project?.segments.first { $0.id == segmentID } }
    var dirty: Bool {
        state.pronunciation != segment?.pronunciation ||
        (state.customSpeed ? state.speed : nil) != segment?.speedOverride ||
        (state.customPause ? state.pause : nil) != segment?.pauseOverride
    }
    func savePrecision() { studio.savePrecision(segmentID, pronunciation: state.pronunciation, speed: state.customSpeed ? state.speed : nil, pause: state.customPause ? state.pause : nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("读音、停顿与版本对比").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(studio.isWorking) }
            if let segment, let p = studio.project {
                Text("原文 / 字幕").font(.headline)
                ScrollView { Text(segment.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 100)
                Text("完整替代读法（留空恢复按原文朗读）").font(.headline)
                TextEditor(text: $state.pronunciation).frame(height: 90).border(.quaternary).disabled(studio.isWorking)
                HStack {
                    Toggle("单独语速", isOn: $state.customSpeed)
                    Slider(value: $state.speed, in: 0.7...1.3, step: 0.05).frame(width: 130).disabled(!state.customSpeed)
                    Text(String(format: "%.2f×", state.speed)).monospacedDigit()
                    Toggle("句后停顿", isOn: $state.customPause)
                    Slider(value: $state.pause, in: 0...3, step: 0.05).frame(width: 130).disabled(!state.customPause)
                    Text(String(format: "%.2f 秒", state.pause)).monospacedDigit()
                }.disabled(studio.isWorking)
                Text("语速更改需要重新生成；停顿只作用于合并音频。当前服务是否支持语速请查看服务说明。最后一句后的停顿不导出。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("预览数字 / 日期 / 缩写读法") { state.suggestion = ReadingPreview.suggest(state.pronunciation.isEmpty ? segment.text : state.pronunciation) }
                    if !state.suggestion.isEmpty { Button("填入替代读法") { state.pronunciation = state.suggestion; state.suggestion = "" } }
                }.disabled(studio.isWorking)
                if !state.suggestion.isEmpty {
                    Text(state.suggestion).font(.caption).textSelection(.enabled).lineLimit(3)
                    Text("这是规则建议；年份、号码和多音字需人工核对，可在上方编辑。不会自动覆盖原稿。").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存精修") { savePrecision() }.disabled(studio.isWorking || !dirty)
                    Button("生成新版本并试听") {
                        savePrecision()
                        state.showGenerate = true
                    }.disabled(studio.isWorking || (p.isLongMode && p.needsLongPreparation))
                    if studio.isWorking && studio.activeSegment == segmentID { Button("取消") { studio.cancel() } }
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
                                Button("试听") { studio.play(studio.audioURL(take)) }.disabled(studio.isWorking)
                                Button("采用") { studio.adoptTake(segmentID: segmentID, takeID: take.id) }
                                    .disabled(studio.isWorking || dirty || take.fingerprint != segment.fingerprint(p.settings) || take.id == segment.selectedTake)
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
            }.disabled(studio.isWorking)
        }.padding(24).frame(width: 820, height: 770)
        .sheet(isPresented: $state.showGenerate) { GenerationReview(scope: [segmentID], initialForce: true, audition: true).environmentObject(studio) }
        .onAppear {
            state.pronunciation = segment?.pronunciation ?? ""
            state.customSpeed = segment?.speedOverride != nil; state.speed = segment?.speedOverride ?? studio.project?.settings.speed ?? 1
            state.customPause = segment?.pauseOverride != nil; state.pause = segment?.pauseOverride ?? studio.project?.settings.pause ?? 0.35
        }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
}
