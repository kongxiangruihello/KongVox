import SwiftUI

final class PrecisionViewState: ObservableObject {
    @Published var tab = "按句精修"
    @Published var confirmSplit = false
    @Published var localID: UUID?
    @Published var confirmLocal = false
    @Published var confirmContext = false
    @Published var showCaptions = false
    @Published var showDelivery = false
    @Published var repairID: UUID?
    @Published var showRepair = false
    @Published var name = ""
    @Published var tags = ""
    @Published var selected = Set<UUID>()
    @Published var sample = "你好，欢迎收听今天的分享。让我们用自然的声音，把一个完整的故事讲清楚。"
    @Published var confirmCompare = false
    @Published var confirmClearCaptions = false
}
struct PrecisionWorkbench: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = PrecisionViewState()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("长文精修").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Picker("工具", selection: $state.tab) {
                ForEach(["按句精修", "字幕设置", "音色收藏", "生成与成品检查"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            if state.tab == "按句精修" { sentenceView }
            else if state.tab == "字幕设置" { subtitlesView }
            else if state.tab == "音色收藏" { favoritesView }
            else { checkView }
            Text(studio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(24).frame(width: 890, height: 690)
        .sheet(isPresented: $state.showCaptions) { CaptionEditor().environmentObject(studio) }
        .sheet(isPresented: $state.showDelivery) { DeliveryView().environmentObject(studio) }
        .sheet(isPresented: $state.showRepair) { if let id = state.repairID { SegmentRepair(segmentID: id).environmentObject(studio) } }
        .confirmationDialog("只拆分这一段用于局部精修？", isPresented: $state.confirmLocal) {
            Button("仅拆所选段落") { if let id = state.localID { studio.splitLocal(id) } }
        } message: { Text("本段原音频保留在历史，新拆出的句子需确认后重新生成并计费。其他段落保持原状，局部语气衔接需试听。") }
        .confirmationDialog("恢复上下文分批？", isPresented: $state.confirmContext) {
            Button("恢复并检查范围") { studio.restoreContext() }
        } message: { Text("按自然段与服务长度重新分批，开头保留短预览段。仅完全匹配的历史音频复用，其他内容需重新生成。已有精修需先备份并处理。") }
        .confirmationDialog("将当前文稿改为按句精修？", isPresented: $state.confirmSplit) {
            Button("开启按句精修") { studio.enableSentenceEditing() }
        } message: { Text("会调整处理范围，无法直接拆用旧的整段音频；已生成的多句段落可能需要重新计费生成。历史音频保留。已有读法、语速或停顿精修时，请先备份并清除精修。") }
        .confirmationDialog("清除已保存的手工字幕？", isPresented: $state.confirmClearCaptions) {
            Button("清除并改用自动字幕", role: .destructive) { studio.clearCaptionEdits() }
        } message: { Text("音频和文稿不受影响。清除后无法撤销，除非恢复之前保存的项目版本。") }
        .confirmationDialog("生成所选音色的对比试听？", isPresented: $state.confirmCompare) {
            Button("确认生成对比") { studio.compareFavorites(ids: state.selected, text: state.sample) }
        } message: { Text("向所列服务发送相同文稿，每个未缓存音色最多 \(state.sample.count) 字，共 \(state.selected.count) 个音色，按各服务实际计费。失败不自动重试。") }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
    var sentenceView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = studio.project {
                Text(p.sentenceMode ? "按句精修已开启。修改一句后，其他未变化句子的音频会复用。超长句仍需分批。" : "上下文分批：普通长文保留较完整语境。需要修正时可只拆所选段落；也可将全文改为按句精修。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !p.sentenceMode { Button("开启按句精修…") { state.confirmSplit = true } }
                    Button("恢复上下文分批…") { state.confirmContext = true }
                    Button("更新文稿处理范围") { studio.prepareReview() }
                    Text("待合成 \(studio.usageEstimate.generate) 字 · 可复用 \(studio.usageEstimate.reuse) 字").font(.caption)
                }.disabled(studio.isWorking)
                Toggle("重做时参考前后句语气（只生成当前句）", isOn: Binding(get: { p.settings.contextHintEnabled == true }, set: { studio.contextAware($0) }))
                    .toggleStyle(.checkbox).disabled(studio.isWorking)
                Text("会把相邻句作为节奏参考发送给所选服务，目标句单独生成；支持程度取决于服务模型，可能增加请求内容长度。").font(.caption2).foregroundStyle(.secondary)
                List {
                    ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(alignment: .top) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(segment.text).lineLimit(3)
                                Text("\(p.settings.reading(segment.spokenText).count) 字 · \(studio.ready(segment, in: p) ? "复用已有音频" : "需要生成")" + (segment.speedOverride.map { " · \(String(format: "%.2f", $0))×" } ?? "") + (segment.pauseOverride.map { " · 停顿 \(String(format: "%.2f", $0)) 秒" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                if SentenceText.chunks(segment.text, limit: p.chunkLimit).count > 1 {
                                    Button("仅拆此段…") { state.localID = segment.id; state.confirmLocal = true }.disabled(studio.isWorking || (p.isLongMode && p.needsLongPreparation))
                                }
                                if index + 1 < p.segments.count { Button("试听接缝") { studio.playSeam(after: segment.id) }.disabled(studio.isWorking) }
                            }
                            Button("精修 / 对比") { state.repairID = segment.id; state.showRepair = true }.disabled(studio.isWorking || (p.isLongMode && p.needsLongPreparation))
                        }.padding(.vertical, 5)
                    }
                }
                if studio.player != nil { Button("停止接缝试听") { studio.stop() } }
                Text("只调整句后停顿不重新合成；调整读法或语速需要生成对应句子的新版音频，再选择采用。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var subtitlesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = studio.project {
                Picker("导出字幕", selection: Binding(get: { p.resolvedSubtitleStyle }, set: { value in studio.edit { $0.subtitleStyle = value } })) {
                    ForEach(SubtitleStyle.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(studio.isWorking)
                Picker("时间对齐", selection: Binding(get: { p.resolvedAlignment }, set: { value in studio.edit { $0.subtitleAlignment = value } })) {
                    ForEach(SubtitleAlignmentMode.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(studio.isWorking)
                if p.resolvedAlignment == .localPauses { Text("本地分析音频能量，只在同一片段内的分句边界前后 0.4 秒寻找明显停顿；片段之间的边界和停顿保持不变，段落字幕不受影响。音频不上传，也不是逐字语音识别。") .font(.caption2).foregroundStyle(.secondary) }
                if p.resolvedAlignment == .speech {
                    let done = studio.transcribedCount(p), total = p.segments.count
                    Text(studio.speechCheckSupported
                         ? "用本机语音识别的逐字时间确定分句字幕的起点；只用已转写的片段（\(done) / \(total)），其余仍按字数分配。在「成品交付检查」运行「本机转写核对」即可转写。段落字幕不受影响。"
                         : "本机语音识别对齐：\(LocalSpeech.unavailableReason)导出时按字数分配。").font(.caption2).foregroundStyle(.secondary)
                }
                Button("打开字幕编辑器…") { state.showCaptions = true }.disabled(studio.isWorking || !studio.fullAudioReady)
                if p.captionEdits != nil {
                    HStack {
                        Text(p.captionsStale ? "手工字幕已过期：可在字幕编辑器中按当前音频重新核对保存，或清除后改用自动字幕。" : "已保存手工字幕，导出优先使用手工版本。改变样式后需重新核对。").font(.caption).foregroundStyle(.orange)
                        Button("清除手工字幕…") { state.confirmClearCaptions = true }.font(.caption).disabled(studio.isWorking)
                    }
                }
                Text("设置同时用于单独 SRT、音频字幕 ZIP 和批量导出。字幕保留原稿，替代读法不会写进字幕。").font(.caption)
                Text("每个已合成片段的起止时间来自真实音频；同片段内的分句和竖屏拆条按字数分配时间，未使用语音识别。需要在剪辑软件中复核精确入点。").font(.caption).foregroundStyle(.orange)
                let sample = p.segments.first?.text ?? "这是一段字幕示例。可以选择分句，或使用适合竖屏的视频断行。"
                Text("排版预览（示例时长 10 秒）").font(.headline)
                ScrollView { Text((try? Subtitles.render(texts: [sample], frames: [240000], gaps: [0], style: p.resolvedSubtitleStyle)) ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
    var favoritesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("音色中文昵称", text: $state.name)
                TextField("用途标签，例如：旁白、新闻", text: $state.tags)
                Button("收藏当前音色") { studio.favoriteCurrentVoice(name: state.name, tags: state.tags); state.name = ""; state.tags = "" }.disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).disabled(studio.isWorking)
            Text("收藏当前服务、音色及语速表达设置，不包含密钥与词典。最多选两项，用相同文稿对比。").font(.caption).foregroundStyle(.secondary)
            List(studio.voiceFavorites) { favorite in
                HStack {
                    Toggle("选择", isOn: Binding(get: { state.selected.contains(favorite.id) }, set: { value in
                        if value { if state.selected.count < 2 { state.selected.insert(favorite.id) } }
                        else { state.selected.remove(favorite.id) }
                    })).labelsHidden().disabled(studio.isWorking)
                    VStack(alignment: .leading) {
                        Text(favorite.name).font(.headline)
                        Text("\(favorite.tags) · \(favorite.settings.resolvedService.name) · \(favorite.settings.voice)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("用于当前项目") { studio.useFavorite(favorite) }.disabled(studio.isWorking)
                    Button("试听缓存") { studio.play(studio.voiceSampleURL(favorite, text: state.sample)) }.disabled(studio.isWorking || !studio.hasVoiceSample(favorite, text: state.sample))
                    Button("移除收藏") { studio.saveFavorites(studio.voiceFavorites.filter { $0.id != favorite.id }); state.selected.remove(favorite.id) }.disabled(studio.isWorking)
                }.padding(.vertical, 5)
            }
            TextField("共同试听文稿，最多 300 字", text: $state.sample, axis: .vertical).lineLimit(3...4).textFieldStyle(.roundedBorder).disabled(studio.isWorking)
            HStack {
                Text("\(state.sample.count) / 300 字 · 已选 \(state.selected.count) 个音色").font(.caption)
                Spacer()
                if studio.comparingVoices { Button("取消对比") { studio.cancel() } }
                else { Button("生成对比试听…") { state.confirmCompare = true }.buttonStyle(.borderedProminent).disabled(studio.isWorking || state.selected.isEmpty || state.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.sample.count > 300) }
            }
        }
    }
    var checkView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("打开成品交付检查…") { state.showDelivery = true }.disabled(studio.isWorking)
                if let p = studio.project {
                    Text("接缝与短视频").font(.headline)
                    Toggle("启用接缝淡化", isOn: Binding(get: { p.resolvedSeam.enabled }, set: { enabled in studio.edit { $0.seamOptions = enabled ? (p.seamOptions ?? SeamOptions(crossfadeMilliseconds: 40, gainAdjustment: 0, loopSeamPreview: true)) : SeamOptions() } })).toggleStyle(.checkbox)
                    HStack { Text("淡化毫秒"); Slider(value: Binding(get: { Double(p.resolvedSeam.crossfadeMilliseconds) }, set: { value in studio.editLive { $0.seamOptions = SeamOptions(crossfadeMilliseconds: Int(value.rounded()), gainAdjustment: p.resolvedSeam.gainAdjustment, loopSeamPreview: p.resolvedSeam.loopSeamPreview) } }), in: 0...120, step: 5); Text("\(p.resolvedSeam.crossfadeMilliseconds) ms").monospacedDigit() }.disabled(!p.resolvedSeam.enabled)
                    Text("只作用于没有停顿的接缝：前段淡出、后段淡入，两段不重叠混合。「试听接缝」与导出使用同一处理。").font(.caption2).foregroundStyle(.secondary)
                    Picker("短视频模板", selection: Binding(get: { p.resolvedTemplate }, set: { value in studio.edit { $0.shortVideoTemplate = value } })) { ForEach(ShortVideoTemplate.allCases) { Text($0.rawValue).tag($0) } }
                }
                Text("服务配置").font(.headline)
                Button("检查配置与已存密钥（不计费）") { studio.checkConfiguration() }.disabled(studio.isWorking)
                Text(studio.preflightMessage).font(.callout).textSelection(.enabled)
                Divider()
                Text("长文完成度").font(.headline)
                if let p = studio.project {
                    ForEach(Array(CompletionReport.make(p, root: studio.root).lines.enumerated()), id: \.offset) { _, line in Text(line).font(.callout) }
                }
                HStack {
                    Button("检查音频异常") { studio.inspectAudio() }.disabled(studio.isWorking)
                    Text(studio.qualitySummary).font(.caption)
                }
                ForEach(studio.findings) { finding in
                    HStack { Text("片段 \(finding.index + 1)：\(finding.message)").font(.caption); Spacer(); Button("定位精修") { state.repairID = finding.segmentID; state.showRepair = true }.disabled(studio.isWorking) }
                }
                Text("本版做本地文件、章节、静音、音量和时长检查；不上传音频，不进行语音识别或自动判定漏读。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
