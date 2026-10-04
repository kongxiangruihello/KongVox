import SwiftUI

final class PrecisionViewState: ObservableObject {
    @Published var tab = "按句精修"
    @Published var confirmSplit = false
    @Published var repairID: UUID?
    @Published var showRepair = false
    @Published var name = ""
    @Published var tags = ""
    @Published var selected = Set<UUID>()
    @Published var sample = "你好，欢迎收听今天的分享。让我们用自然的声音，把一个完整的故事讲清楚。"
    @Published var confirmCompare = false
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
        .sheet(isPresented: $state.showRepair) { if let id = state.repairID { SegmentRepair(segmentID: id).environmentObject(studio) } }
        .confirmationDialog("将当前文稿改为按句精修？", isPresented: $state.confirmSplit) {
            Button("开启按句精修") { studio.enableSentenceEditing() }
        } message: { Text("会调整处理范围，无法直接拆用旧的整段音频；已生成的多句段落可能需要重新计费生成。历史音频保留。已有读法、语速或停顿精修时，请先备份并清除精修。") }
        .confirmationDialog("生成所选音色的对比试听？", isPresented: $state.confirmCompare) {
            Button("确认生成对比") { studio.compareFavorites(ids: state.selected, text: state.sample) }
        } message: { Text("向所列服务发送相同文稿，每个未缓存音色最多 \(state.sample.count) 字，共 \(state.selected.count) 个音色，按各服务实际计费。失败不自动重试。") }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil } } message: { Text(studio.error ?? "") }
    }
    var sentenceView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = studio.project {
                Text(p.sentenceMode ? "按句精修已开启。修改一句后，其他未变化句子的音频会复用。超长句仍需分批。" : "原有分段保持不变。开启按句精修后，可分别设置每句读法、语速与句后停顿，减少后续重做范围。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !p.sentenceMode { Button("开启按句精修…") { state.confirmSplit = true } }
                    Button("更新文稿处理范围") { studio.prepareReview() }
                    Text("待合成 \(studio.usageEstimate.generate) 字 · 可复用 \(studio.usageEstimate.reuse) 字").font(.caption)
                }.disabled(studio.isWorking)
                List {
                    ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(alignment: .top) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(segment.text).lineLimit(3)
                                Text("\(p.settings.reading(segment.spokenText).count) 字 · \(studio.ready(segment, settings: p.settings) ? "复用已有音频" : "需要生成")" + (segment.speedOverride.map { " · \(String(format: "%.2f", $0))×" } ?? "") + (segment.pauseOverride.map { " · 停顿 \(String(format: "%.2f", $0)) 秒" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("精修 / 对比") { state.repairID = segment.id; state.showRepair = true }.disabled(studio.isWorking || (p.isLongMode && p.needsLongPreparation))
                        }.padding(.vertical, 5)
                    }
                }
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
