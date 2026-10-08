import SwiftUI

@MainActor final class CaptionEditorState: ObservableObject {
    @Published var cues: [CaptionCue] = []
    @Published var selected: UUID?
    @Published var text = ""
    @Published var start = "0"
    @Published var end = "0"
    @Published var splitAt = 1
    @Published var message = "正在准备当前音频的字幕时间轴…"
    @Published var confirmClose = false
    @Published var confirmReset = false
    @Published var loaded = false
    var initial: [CaptionCue] = []
    var generated: [CaptionCue] = []
    var duration: Int64 = 0
    var signature = ""
    var preview: URL?
}
struct CaptionEditor: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = CaptionEditorState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("字幕编辑器").font(.title2.bold()); Spacer(); Button("关闭") { if dirty { state.confirmClose = true } else { dismiss() } }.disabled(studio.isWorking) }
            Text("初始时间按片段字数分配，非语音识别。修改字幕不会改变文稿或音频。保存后用于 SRT、ZIP 与整篇批量导出。").font(.caption).foregroundStyle(.secondary)
            Text(state.message).font(.caption).foregroundStyle(.orange)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(state.cues.enumerated()), id: \.element.id) { i, cue in
                            Button { choose(cue.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(i + 1) · \(String(format: "%.3f", Double(cue.start) / 1000))–\(String(format: "%.3f", Double(cue.end) / 1000)) 秒").font(.caption)
                                    Text(cue.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(10).background(state.selected == cue.id ? Color.indigo.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 330)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("字幕文字").font(.headline)
                    TextEditor(text: $state.text).frame(height: 150).border(.quaternary)
                    HStack {
                        Text("开始（秒）"); TextField("0.000", text: $state.start)
                        Text("结束（秒）"); TextField("1.000", text: $state.end)
                    }.textFieldStyle(.roundedBorder)
                    Button("应用文字与时间") { attempt { try applyDraft() } }
                    HStack {
                        Stepper("第 \(state.splitAt) 字后拆条", value: $state.splitAt, in: 1...max(1, state.text.count - 1))
                        Button("拆条") { attempt { try applyDraft(); try split() } }
                    }
                    Button("与下一条合并") { attempt { try applyDraft(); try merge() } }
                    HStack {
                        Button("循环试听此条") {
                            attempt {
                                try applyDraft()
                                if let cue = state.cues.first(where: { $0.id == state.selected }), let url = state.preview {
                                    studio.playRange(url, start: Double(cue.start) / 1000, end: Double(cue.end) / 1000, loop: true)
                                }
                            }
                        }
                        Button("停止试听") { studio.stop() }
                    }
                    Text("总时长 \(String(format: "%.3f", Double(state.duration) / 1000)) 秒 · 时间须递增且不重叠。拆条按文字比例分配时间，可再手动调整。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.disabled(!state.loaded || state.selected == nil || studio.isWorking)
            }
            HStack {
                Button("恢复自动字幕…") { state.confirmReset = true }.disabled(!state.loaded || studio.isWorking)
                Spacer()
                Text("\(state.cues.count) 条字幕").font(.caption)
                Button("保存字幕") {
                    attempt {
                        try applyDraft()
                        try studio.saveCaptions(state.cues, signature: state.signature, duration: state.duration)
                        state.initial = state.cues; state.message = "已保存。导出使用这一版字幕。"
                    }
                }.buttonStyle(.borderedProminent).disabled(!state.loaded || studio.isWorking)
            }
        }.padding(24).frame(width: 940, height: 680)
        .task { await load() }
        .onDisappear { studio.stop() }
        .confirmationDialog("放弃本次未保存的字幕修改？", isPresented: $state.confirmClose) { Button("放弃并关闭", role: .destructive) { dismiss() } }
        .confirmationDialog("用当前音频的自动字幕替换编辑草稿？", isPresented: $state.confirmReset) {
            Button("恢复自动字幕") { state.cues = state.generated; if let first = state.cues.first { select(first) }; state.message = "已恢复草稿；点击保存字幕后才替换已保存版本。" }
        }
    }
    var dirty: Bool {
        guard state.loaded else { return false }
        let cue = state.cues.first { $0.id == state.selected }
        return state.cues != state.initial || cue?.text != state.text || Double(state.start) != cue.map { Double($0.start) / 1000 } || Double(state.end) != cue.map { Double($0.end) / 1000 }
    }
    func attempt(_ work: () throws -> Void) { do { try work() } catch { state.message = error.localizedDescription } }
    func select(_ cue: CaptionCue) {
        state.selected = cue.id; state.text = cue.text
        state.start = String(format: "%.3f", Double(cue.start) / 1000); state.end = String(format: "%.3f", Double(cue.end) / 1000)
        state.splitAt = max(1, cue.text.count / 2)
    }
    func choose(_ id: UUID) { attempt { try applyDraft(); studio.stop(); if let cue = state.cues.first(where: { $0.id == id }) { select(cue) } } }
    func applyDraft() throws {
        guard let i = state.cues.firstIndex(where: { $0.id == state.selected }),
              let start = Double(state.start), let end = Double(state.end), start.isFinite, end.isFinite,
              start >= 0, end <= Double(state.duration) / 1000, end > start else { throw VoxError(message: "请输入有效的开始与结束秒数。") }
        var next = state.cues
        next[i].text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        next[i].start = Int64((start * 1000).rounded()); next[i].end = Int64((end * 1000).rounded())
        try CaptionTimeline.validate(next, duration: state.duration)
        state.cues = next; state.message = "草稿已更新，请试听并保存。"
    }
    func split() throws {
        guard let i = state.cues.firstIndex(where: { $0.id == state.selected }) else { return }
        let pieces = try CaptionTimeline.split(state.cues[i], after: state.splitAt)
        state.cues.replaceSubrange(i...i, with: pieces); select(pieces[0])
    }
    func merge() throws {
        guard let i = state.cues.firstIndex(where: { $0.id == state.selected }), i + 1 < state.cues.count else { throw VoxError(message: "已是最后一条。") }
        let merged = CaptionTimeline.merge(state.cues[i], state.cues[i + 1])
        state.cues.replaceSubrange(i...i + 1, with: [merged]); select(merged)
    }
    @MainActor func load() async {
        guard !studio.isWorking, let p = studio.project else { state.message = "请等待当前工作结束，再打开字幕编辑器。"; return }
        do {
            let urls = try studio.currentURLs(), url = studio.root.appendingPathComponent("caption-preview.wav")
            studio.stop(); studio.busy = true; defer { studio.busy = false }
            let frames = try await Task.detached { try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: p.levelsEnabled, to: url, seam: p.resolvedSeam) }.value
            state.duration = CaptionTimeline.duration(frames: frames, gaps: p.gaps)
            let pcm: Data? = try p.resolvedAlignment == .localPauses ? AudioFiles.extractPCM(Data(contentsOf: url)) : nil
            // Automatic captions never depend on saved manual captions, so stale edits can always be replaced here.
            state.generated = try p.autoCaptionCues(frames: frames, pcm: pcm, root: studio.root)
            state.signature = p.captionSignature; state.preview = url
            if p.captionsStale { state.cues = state.generated; state.message = "旧字幕对应的音频或设置已改变。已按当前音频重新生成草稿，请核对后保存；也可在交付检查中清除手工字幕。" }
            else { state.cues = try p.captionCues(frames: frames, pcm: pcm, root: studio.root); state.message = "可修改文字、时间、拆条或合并，循环试听核对后保存。" }
            state.initial = state.cues
            if let first = state.cues.first { select(first) }; state.loaded = true
        } catch { state.message = error.localizedDescription }
    }
}
