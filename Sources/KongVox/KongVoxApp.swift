import SwiftUI

@main struct KongVoxApp: App {
    @StateObject private var studio = Studio()
    var body: some Scene {
        WindowGroup("KongVox") {
            StudioView().environmentObject(studio).frame(minWidth: 1060, minHeight: 700)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { CommandGroup(replacing: .newItem) { Button("新建配音") { studio.newProject() }.keyboardShortcut("n").disabled(studio.isWorking) } }
    }
}
final class ViewState: ObservableObject {
    @Published var showPrecision = false
    @Published var showDelivery = false
    @Published var showVersions = false
    @Published var exportFormat = "zip"
    @Published var showBatch = false
    @Published var showFinishedReview = false
    @Published var showTools = false
    @Published var showReview = false
    @Published var showSettings = false
    @Published var showWelcome = false
    var configureAfterWelcome = false
    @Published var deleteID: UUID?
    @Published var cleanupPlan: AudioCleanupPlan?
    @Published var key = ""
    @Published var message = ""
}
struct StudioView: View {
    @EnvironmentObject var studio: Studio
    @StateObject private var state = ViewState()
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) { BrandIcon(size: 38); Text("KongVox") }.font(.system(size: 25, weight: .bold)).foregroundStyle(.indigo)
                Text("让文字，有自己的声音。 ").font(.caption).foregroundStyle(.secondary)
                Button(action: studio.newProject) { Label("新建配音", systemImage: "plus").frame(maxWidth: .infinity) }.controlSize(.large).disabled(studio.isWorking)
                List(selection: $studio.selected) {
                    ForEach(studio.projects) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.title).font(.headline).lineLimit(1)
                            Text(p.isLongMode ? "长文 · \(p.fullText.count) 字" : "段落 · \(p.segments.count) 段").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(p.id)
                        .contextMenu { Button("删除项目…", role: .destructive) { state.deleteID = p.id } }
                    }
                }.listStyle(.sidebar).disabled(studio.isWorking)
                Button { state.showSettings = true } label: { Label("服务设置", systemImage: "key") }.disabled(studio.isWorking)
                Button("成品交付检查") { state.exportFormat = "zip"; state.showDelivery = true }.disabled(studio.isWorking)
                Button("项目版本与回滚") { state.showVersions = true }.disabled(studio.isWorking)
                Button("成品检查 / 对比") { state.showFinishedReview = true }
                Menu("项目备份与整理") {
                    Button("备份当前项目…") { studio.chooseBackup() }
                    Button("从备份恢复为新项目…") { studio.chooseRestore() }
                    Divider()
                    Button("删除当前项目…") { state.deleteID = studio.selected }
                    Button("清理未引用音频…") {
                        do {
                            let plan = try studio.audioCleanupPlan()
                            if plan.files.isEmpty { studio.status = "没有未引用的音频文件。" } else { state.cleanupPlan = plan }
                        } catch { studio.error = error.localizedDescription }
                    }
                }.disabled(studio.isWorking)
                Button("长文精修 / 音色收藏") { state.showPrecision = true }
                Button("文稿导入 / 批量工作台") { state.showBatch = true }
                Button("长文工作台 / 任务") { state.showTools = true }
                Button("使用指南") { state.showWelcome = true }.font(.caption)
                Text("KongVox \(AppInfo.version) · AI 生成配音").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).navigationSplitViewColumnWidth(230)
        } detail: {
            VStack(spacing: 0) {
                if let p = studio.project {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            TextField("项目名称", text: bind(\.title, fallback: "")).font(.system(size: 28, weight: .bold)).textFieldStyle(.plain)
                            HStack(spacing: 12) {
                                Picker("编辑方式", selection: Binding(get: { p.isLongMode }, set: { studio.setLongMode($0) })) {
                                    Text("长文模式").tag(true)
                                    Text("段落精调").tag(false)
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                                Button(p.isLongMode ? "生成全文" : "生成待更新") {
                                    studio.prepareReview(); state.showReview = true
                                }.buttonStyle(.borderedProminent).fixedSize()
                                    .help("检查生成范围后，生成所有待更新内容")
                                    .disabled(p.isLongMode ? p.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : p.segments.isEmpty)
                                Button { studio.playAll() } label: { Label("播放", systemImage: "play.fill") }
                                    .fixedSize().help("播放完整配音").disabled(!studio.fullAudioReady)
                                Spacer(minLength: 0)
                            }
                            if p.isLongMode {
                                HStack {
                                    Text("完整文章").font(.headline)
                                    Spacer()
                                    Text("\(p.fullText.count) 字").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("粘贴整篇文章，点击「生成全文」。后台自动处理，完成后试听或导出一份完整音频。").font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: Binding(get: { studio.project?.fullText ?? "" }, set: { text in studio.editLive { $0.longText = text } }))
                                    .font(.system(size: 16)).lineSpacing(6).padding(12)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("完整文章编辑区")
                                HStack {
                                    ProgressView(value: studio.fullProgress).frame(width: 150)
                                    Text(studio.fullAudioReady ? "全文配音已就绪" : p.needsLongPreparation ? "文稿待生成" : "全文进度 \(Int(studio.fullProgress * 100))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("需要发音修正、单段重做或处理下载缓存时，可切换「段落精调」。").font(.caption2).foregroundStyle(.secondary)
                            } else {
                            HStack { Text("配音文稿").font(.headline); Spacer(); Text("\(p.segments.reduce(0) { $0 + $1.spokenText.count }) 字 · \(p.segments.filter { studio.ready($0, in: p) }.count)/\(p.segments.count) 段就绪").font(.caption).foregroundStyle(.secondary) }
                            ScrollView {
                                LazyVStack(spacing: 14) {
                                    ForEach(Array(p.segments.enumerated()), id: \.element.id) { index, segment in
                                        SegmentCard(index: index, segment: segment, settings: p.settings)
                                    }
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(p.segments.isEmpty ? "从一段文字开始" : "追加文稿").font(.headline)
                                        Text("粘贴口播稿或长文章，按自然段拆分；长段会自动分句。").font(.caption).foregroundStyle(.secondary)
                                        TextEditor(text: bind(\.draft, fallback: "")).font(.body).frame(minHeight: 130).padding(8).background(.background).clipShape(RoundedRectangle(cornerRadius: 8))
                                        Button("添加为配音段落") { studio.importDraft() }.disabled(p.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                                }
                            }
                            }
                        }.padding(26).disabled(studio.isWorking)
                        Divider()
                        settingsPanel(p).frame(width: 250).padding(22).disabled(studio.isWorking)
                    }
                    Divider()
                    footer(p)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.indigo)
        .onAppear { state.showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen05") }
        .sheet(isPresented: $state.showWelcome, onDismiss: {
            if state.configureAfterWelcome { state.configureAfterWelcome = false; state.showSettings = true }
        }) {
            WelcomeView(configure: { state.configureAfterWelcome = true; finishWelcome() }, start: { finishWelcome() })
        }
        .sheet(isPresented: $state.showDelivery) { DeliveryView(initialFormat: state.exportFormat).environmentObject(studio) }
        .sheet(isPresented: $state.showVersions) { VersionHistoryView().environmentObject(studio) }
        .sheet(isPresented: $state.showPrecision) { PrecisionWorkbench().environmentObject(studio) }
        .sheet(isPresented: $state.showBatch) { BatchWorkbench().environmentObject(studio) }
        .sheet(isPresented: $state.showFinishedReview) { FinishedReview().environmentObject(studio) }
        .sheet(isPresented: $state.showTools) { LongFormWorkbench().environmentObject(studio) }
        .sheet(isPresented: $state.showReview) { GenerationReview().environmentObject(studio) }
        .sheet(isPresented: $state.showSettings) { ServiceSettings().environmentObject(studio) }
        .onChange(of: studio.selected) { _ in studio.stop(); studio.findings = []; studio.qualitySummary = "尚未检查"; studio.clearSpeechFindings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in studio.flushPendingSave() }
        .modifier(MaintenanceDialogs(state: state))
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil }; if !studio.diagnostic.isEmpty { Button("复制诊断") { studio.copyDiagnostic(); studio.error = nil } } } message: { Text(studio.error ?? "") }
    }
    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeSeen05"); state.showWelcome = false
    }
    func bind<T>(_ key: WritableKeyPath<Project,T>, fallback: T) -> Binding<T> {
        Binding(get: { studio.project?[keyPath: key] ?? fallback }, set: { value in studio.editLive { $0[keyPath: key] = value } })
    }
    func settingsPanel(_ p: Project) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Label("声音工作台", systemImage: "slider.horizontal.3").font(.headline)
            Picker("配音服务", selection: Binding(get: { p.settings.resolvedService.id }, set: { studio.selectService($0) })) {
                ForEach(studio.catalog.profiles.filter { $0.enabled || $0.id == p.settings.resolvedService.id }) { service in
                    Text(service.name + (service.enabled ? "" : "（已停用）")).tag(service.id)
                }
            }
            Text(p.settings.resolvedService.model).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if p.settings.resolvedService.kind == .volcengine {
                Text("资源 \(p.settings.resolvedService.model) · speaker \(p.settings.voice)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if p.settings.resolvedService.model != "seed-tts-2.0" && p.settings.voice == ServiceProfile.volcVVVoice {
                    Text("当前资源与 VV 音色不匹配，请在服务设置中切换 2.0 或填写对应 speaker。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if studio.catalog.profiles.first(where: { $0.id == p.settings.resolvedService.id }) != p.settings.resolvedService {
                Button("应用最新服务配置") { studio.selectService(p.settings.resolvedService.id) }.font(.caption)
            }
            Picker("使用场景", selection: bind(\.settings.mode, fallback: "短视频口播")) { Text("短视频口播").tag("短视频口播"); Text("长文章").tag("长文章") }
            Picker("声音", selection: bind(\.settings.voice, fallback: "marin")) {
                ForEach(p.settings.resolvedService.voices, id: \.self) { Text($0).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("语速  \(p.settings.speed, specifier: "%.2f")×")
                Slider(value: bind(\.settings.speed, fallback: 1), in: 0.7...1.3, step: 0.05)
                if p.settings.resolvedService.kind == .gemini { Text("Gemini 通过表达指令调整节奏，倍速为参考目标。").font(.caption2).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("表达要求")
                if p.settings.resolvedService.kind == .volcengine { Text("火山引擎使用资源 ID 选择模型，支持语速；本版暂不应用表达要求。").font(.caption2).foregroundStyle(.secondary) }
                if p.settings.resolvedService.kind == .qwenTTS {
                    Text("Qwen Flash 使用默认语速；Instruct Flash 才支持表达与语速提示。每段最多 600 字。").font(.caption2).foregroundStyle(.secondary)
                }
                if p.settings.resolvedService.kind == .cosyVoice {
                    Text("CosyVoice 指令需符合音色要求，例如：你说话的情感是happy。留空使用预设；不支持指令的模型仅使用声音和语速。").font(.caption2).foregroundStyle(.secondary)
                }
                TextField("例如：像朋友聊天，重点轻微强调", text: bind(\.settings.direction, fallback: ""), axis: .vertical).lineLimit(3...6)
            }
            Picker("段间停顿", selection: bind(\.settings.pause, fallback: 0.35)) { Text("紧凑 · 0.15 秒").tag(0.15); Text("标准 · 0.35 秒").tag(0.35); Text("舒缓 · 0.7 秒").tag(0.7) }
            Toggle("统一音量", isOn: Binding(get: { p.levelsEnabled }, set: { enabled in studio.edit { $0.normalizeVolume = enabled } }))
            Text("仅在合并试听和导出时调整，保留原始音频。自然段保留停顿，后台切分处减少多余空白。").font(.caption2).foregroundStyle(.secondary)
            Toggle("全文完成后通知我", isOn: Binding(get: { studio.notificationsEnabled }, set: { studio.setNotifications($0) }))
            Divider()
            Text(p.isLongMode ? "全文会自动分批合成并合并。中断后点击「生成全文」继续，已完成且未修改的内容会复用。" : "每段可保留多个版本。改变声音、语速或表达要求后，需要重新生成。").font(.caption).foregroundStyle(.secondary)
            Text("生成时，朗读文本将发送至 \(p.settings.resolvedService.name)（\(p.settings.resolvedService.endpointHost)），并按你的 API 账户计费。试听已有音频与导出不产生生成费用。").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.textFieldStyle(.roundedBorder) }
    }
    func footer(_ p: Project) -> some View {
        let usage = studio.usageEstimate
        return VStack(alignment: .leading, spacing: 10) {
            if studio.playbackDuration > 0 {
                PlaybackScrubber(clock: studio.clock, label: "播放进度").disabled(studio.isWorking)
            }
            Text("预计本次合成 \(usage.generate) 字 · 可复用 \(usage.reuse) 字 · 待恢复 \(usage.recover) 字（按服务商实际计费）").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 14) {
            if studio.player != nil {
                Button(studio.playing ? "暂停" : "继续") { studio.togglePause() }
                Button("停止") { studio.stop() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(studio.status).font(.caption).lineLimit(2)
                if studio.isWorking { ProgressView(value: studio.progress).frame(width: 180) }
            }
            Spacer()
            if studio.isWorking {
                if studio.activeSegment != nil { Button(studio.pauseRequested ? "等待暂停…" : "本段后暂停") { if studio.queueRunning { studio.pauseQueue() } else { studio.pauseAfterSegment() } }.disabled(studio.pauseRequested); Button("取消生成") { if studio.queueRunning { studio.pauseQueue() }; studio.cancel() } }
            } else {
                Menu(p.isLongMode ? "导出完整音频" : "导出音频") {
                    Button("音频 + 字幕组合包 · ZIP") { state.exportFormat = "zip"; state.showDelivery = true }
                    Divider()
                    Button("SRT · 按字幕设置") { state.exportFormat = "srt"; state.showDelivery = true }
                    Divider()
                    Button("WAV · 无损剪辑") { state.exportFormat = "wav"; state.showDelivery = true }
                    Button("M4A · 小体积") { state.exportFormat = "m4a"; state.showDelivery = true }
                    Button(Studio.ffmpeg == nil ? "MP3 · 需安装 FFmpeg" : "MP3 · 通用分享") { state.exportFormat = "mp3"; state.showDelivery = true }.disabled(Studio.ffmpeg == nil)
                }.fixedSize().disabled(!studio.fullAudioReady)
                Button("试听开头") { studio.generateOpening() }.disabled(p.isLongMode ? p.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : p.segments.isEmpty)
            }
        }
        }.padding(18)
    }
}
/// Confirmations for deleting a project and for removing unreferenced audio files.
struct MaintenanceDialogs: ViewModifier {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    var deleteTitle: String { studio.projects.first { $0.id == state.deleteID }?.title ?? "" }
    func body(content: Content) -> some View {
        content
            .confirmationDialog("删除这个项目？", isPresented: Binding(get: { state.deleteID != nil }, set: { if !$0 { state.deleteID = nil } })) {
                Button("删除项目", role: .destructive) {
                    if let id = state.deleteID { studio.deleteProject(id) }
                    state.deleteID = nil
                }
            } message: {
                Text("「\(deleteTitle)」将从列表移除，版本快照和下载缓存一并删除，无法撤销，建议先备份。音频文件暂时保留，可再用「清理未引用音频」释放空间。")
            }
            .confirmationDialog("清理未引用的音频？", isPresented: Binding(get: { state.cleanupPlan != nil }, set: { if !$0 { state.cleanupPlan = nil } })) {
                Button("删除 \(state.cleanupPlan?.files.count ?? 0) 个文件", role: .destructive) {
                    if let plan = state.cleanupPlan { studio.cleanUnreferencedAudio(plan) }
                    state.cleanupPlan = nil
                }
            } message: {
                Text("共约 \(state.cleanupPlan?.sizeLabel ?? "")。这些文件不属于任何项目、归档片段或已保存版本，删除后无法恢复；已导出的成品和备份文件不受影响。")
            }
    }
}
/// Observes only the playhead clock, so 20 Hz updates re-render this bar and nothing else.
struct PlaybackScrubber: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var clock: PlaybackClock
    var label: String
    var body: some View {
        HStack(spacing: 12) {
            Button { studio.skip(-10) } label: { Image(systemName: "gobackward.10") }.help("后退 10 秒")
            Text(Studio.timeLabel(clock.time)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { clock.time }, set: { studio.seek($0) }), in: 0...max(0.01, studio.playbackDuration)).accessibilityLabel(label)
            Text(Studio.timeLabel(studio.playbackDuration)).monospacedDigit().font(.caption)
            Button { studio.skip(10) } label: { Image(systemName: "goforward.10") }.help("前进 10 秒")
        }
    }
}
@MainActor final class SegmentControls: ObservableObject { @Published var discardCache = false; @Published var showRepair = false; @Published var showGenerate = false; @Published var confirmDelete = false }
struct SegmentCard: View {
    @StateObject private var controls = SegmentControls()
    @EnvironmentObject var studio: Studio
    let index: Int
    let segment: Segment
    let settings: VoiceSettings
    func binding(_ key: WritableKeyPath<Segment,String>) -> Binding<String> {
        Binding(get: { studio.project?.segments.first { $0.id == segment.id }?[keyPath: key] ?? "" }, set: { value in studio.editLive { p in if let i = p.segments.firstIndex(where: { $0.id == segment.id }) { p.segments[i][keyPath: key] = value } } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: "%02d", index + 1)).font(.system(.headline, design: .monospaced)).foregroundStyle(.secondary)
                Text(studio.activeSegment == segment.id ? "生成中" : studio.ready(segment, settings: settings) ? "已就绪" : segment.current == nil ? "未生成" : "待更新")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(studio.ready(segment, settings: settings) ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                Spacer()
                Text("\(segment.spokenText.count) 字").font(.caption).foregroundStyle(.secondary)
                Button { controls.confirmDelete = true } label: { Image(systemName: "trash") }.help("移除这个段落")
            }
            TextField("文稿", text: binding(\.text), axis: .vertical).textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(6)
            DisclosureGroup("发音修正（可选，不改原稿）") { TextField("输入这一段的完整朗读替代文本", text: binding(\.pronunciation), axis: .vertical).textFieldStyle(.roundedBorder) }.font(.caption).foregroundStyle(.secondary)
            if let take = segment.current, let service = take.service {
                Text("此版本：\(service.name) · \(service.model) · \(take.settings?.voice ?? "")").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if studio.hasRecovery(segment) { Button("放弃下载缓存") { controls.discardCache = true } }
                Button("读音 / 停顿精调") { controls.showRepair = true }
                Button(studio.hasRecovery(segment) ? "继续下载" : segment.current == nil ? "生成并试听" : "重新生成") { controls.showGenerate = true }
                if let take = segment.current {
                    Button("试听此版本") { studio.play(studio.audioURL(take)) }
                    Menu("历史 · \(segment.takes.count) 版") {
                        ForEach(segment.takes) { t in
                            Button("\(t.date.formatted(date: .omitted, time: .standard))\(t.id == segment.selectedTake ? " ✓" : "")") {
                                studio.edit { p in if let i = p.segments.firstIndex(where: { $0.id == segment.id }) { p.segments[i].selectedTake = t.id } }
                            }
                        }
                    }.fixedSize()
                }
                Spacer()
            }.controlSize(.small)
        }.sheet(isPresented: $controls.showGenerate) { GenerationReview(scope: [segment.id], initialForce: true).environmentObject(studio) }
        .sheet(isPresented: $controls.showRepair) { SegmentRepair(segmentID: segment.id).environmentObject(studio) }
        .confirmationDialog("放弃已生成的下载结果？", isPresented: $controls.discardCache) {
            Button("放弃缓存", role: .destructive) { studio.discardRecovery(segment) }
        } message: { Text("之后点击生成将重新请求服务，可能再次计费。") }
        .confirmationDialog("移除这个段落？", isPresented: $controls.confirmDelete) {
            Button("移除段落", role: .destructive) { studio.edit { $0.segments.removeAll { $0.id == segment.id } } }
        } message: { Text("文稿和该段的历史版本会从项目中移除，只能通过之前保存的项目版本找回。") }
        .padding(18).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
