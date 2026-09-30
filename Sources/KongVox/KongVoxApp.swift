import SwiftUI

@main struct KongVoxApp: App {
    @StateObject private var studio = Studio()
    var body: some Scene {
        WindowGroup("KongVox") {
            StudioView().environmentObject(studio).frame(minWidth: 1060, minHeight: 700)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { CommandGroup(replacing: .newItem) { Button("新建配音") { studio.newProject() }.keyboardShortcut("n").disabled(studio.busy) } }
    }
}
final class ViewState: ObservableObject {
    @Published var showSettings = false
    @Published var key = ""
    @Published var message = ""
}
struct StudioView: View {
    @EnvironmentObject var studio: Studio
    @StateObject private var state = ViewState()
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("KongVox", systemImage: "waveform.circle.fill").font(.system(size: 25, weight: .bold)).foregroundStyle(.indigo)
                Text("让文字，有自己的声音。 ").font(.caption).foregroundStyle(.secondary)
                Button(action: studio.newProject) { Label("新建配音", systemImage: "plus").frame(maxWidth: .infinity) }.controlSize(.large).disabled(studio.busy)
                List(selection: $studio.selected) {
                    ForEach(studio.projects) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.title).font(.headline).lineLimit(1)
                            Text("\(p.settings.mode) · \(p.segments.count) 段").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(p.id)
                    }
                }.listStyle(.sidebar).disabled(studio.busy)
                Button { state.showSettings = true } label: { Label("服务设置", systemImage: "key") }.disabled(studio.busy)
                Text("KongVox 0.3 · AI 生成配音").font(.caption2).foregroundStyle(.tertiary)
            }.padding(18).navigationSplitViewColumnWidth(230)
        } detail: {
            VStack(spacing: 0) {
                if let p = studio.project {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            TextField("项目名称", text: bind(\.title, fallback: "")).font(.system(size: 28, weight: .bold)).textFieldStyle(.plain)
                            HStack { Text("配音文稿").font(.headline); Spacer(); Text("\(p.segments.reduce(0) { $0 + $1.spokenText.count }) 字 · \(p.segments.filter { studio.ready($0, settings: p.settings) }.count)/\(p.segments.count) 段就绪").font(.caption).foregroundStyle(.secondary) }
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
                        }.padding(26).disabled(studio.busy)
                        Divider()
                        settingsPanel(p).frame(width: 250).padding(22).disabled(studio.busy)
                    }
                    Divider()
                    footer(p)
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.indigo)
        .sheet(isPresented: $state.showSettings) { ServiceSettings().environmentObject(studio) }
        .onChange(of: studio.selected) { _ in studio.stop() }
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) { Button("知道了") { studio.error = nil }; if !studio.diagnostic.isEmpty { Button("复制诊断") { studio.copyDiagnostic(); studio.error = nil } } } message: { Text(studio.error ?? "") }
    }
    func bind<T>(_ key: WritableKeyPath<Project,T>, fallback: T) -> Binding<T> {
        Binding(get: { studio.project?[keyPath: key] ?? fallback }, set: { value in studio.edit { $0[keyPath: key] = value } })
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
                if p.settings.resolvedService.kind == .cosyVoice {
                    Text("CosyVoice 指令需符合音色要求，例如：你说话的情感是happy。留空使用预设；不支持指令的模型仅使用声音和语速。").font(.caption2).foregroundStyle(.secondary)
                }
                TextField("例如：像朋友聊天，重点轻微强调", text: bind(\.settings.direction, fallback: ""), axis: .vertical).lineLimit(3...6)
            }
            Picker("段间停顿", selection: bind(\.settings.pause, fallback: 0.35)) { Text("紧凑 · 0.15 秒").tag(0.15); Text("标准 · 0.35 秒").tag(0.35); Text("舒缓 · 0.7 秒").tag(0.7) }
            Divider()
            Text("先生成一段试听，再生成全文。每段可保留多个版本。改变声音、语速或表达要求后，需要重新生成。").font(.caption).foregroundStyle(.secondary)
            Text("生成时，朗读文本将发送至 \(p.settings.resolvedService.name)（\(p.settings.resolvedService.endpointHost)），并按你的 API 账户计费。试听已有音频与导出不产生生成费用。").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.textFieldStyle(.roundedBorder) }
    }
    func footer(_ p: Project) -> some View {
        HStack(spacing: 14) {
            Button { studio.playAll() } label: { Image(systemName: "play.circle.fill").font(.title) }.buttonStyle(.plain).disabled(studio.busy || p.segments.isEmpty)
            if studio.player != nil {
                Button(studio.playing ? "暂停" : "继续") { studio.togglePause() }
                Button("停止") { studio.stop() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(studio.status).font(.caption).lineLimit(2)
                if studio.busy { ProgressView(value: studio.progress).frame(width: 180) }
            }
            Spacer()
            if studio.busy {
                if studio.activeSegment != nil { Button("取消生成") { studio.cancel() } }
            } else {
                Menu("导出音频") {
                    Button("SRT · 段落字幕") { studio.exportSubtitles() }
                    Divider()
                    Button("WAV · 无损剪辑") { studio.export(format: "wav") }
                    Button("M4A · 小体积") { studio.export(format: "m4a") }
                    Button(Studio.ffmpeg == nil ? "MP3 · 需安装 FFmpeg" : "MP3 · 通用分享") { studio.export(format: "mp3") }.disabled(Studio.ffmpeg == nil)
                }.fixedSize().disabled(p.segments.isEmpty)
                Button("生成待更新段落") { studio.generate() }.buttonStyle(.borderedProminent).disabled(p.segments.isEmpty)
            }
        }.padding(18)
    }
}
@MainActor final class SegmentControls: ObservableObject { @Published var discardCache = false }
struct SegmentCard: View {
    @StateObject private var controls = SegmentControls()
    @EnvironmentObject var studio: Studio
    let index: Int
    let segment: Segment
    let settings: VoiceSettings
    func binding(_ key: WritableKeyPath<Segment,String>) -> Binding<String> {
        Binding(get: { studio.project?.segments.first { $0.id == segment.id }?[keyPath: key] ?? "" }, set: { value in studio.edit { p in if let i = p.segments.firstIndex(where: { $0.id == segment.id }) { p.segments[i][keyPath: key] = value } } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: "%02d", index + 1)).font(.system(.headline, design: .monospaced)).foregroundStyle(.secondary)
                Text(studio.activeSegment == segment.id ? "生成中" : studio.ready(segment, settings: settings) ? "已就绪" : segment.current == nil ? "未生成" : "待更新")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(studio.ready(segment, settings: settings) ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                Spacer()
                Text("\(segment.spokenText.count) 字").font(.caption).foregroundStyle(.secondary)
                Button { studio.edit { $0.segments.removeAll { $0.id == segment.id } } } label: { Image(systemName: "trash") }.help("移除这个段落")
            }
            TextField("文稿", text: binding(\.text), axis: .vertical).textFieldStyle(.plain).font(.system(size: 16)).lineSpacing(6)
            DisclosureGroup("发音修正（可选，不改原稿）") { TextField("输入这一段的完整朗读替代文本", text: binding(\.pronunciation), axis: .vertical).textFieldStyle(.roundedBorder) }.font(.caption).foregroundStyle(.secondary)
            if let take = segment.current, let service = take.service {
                Text("此版本：\(service.name) · \(service.model) · \(take.settings?.voice ?? "")").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if studio.hasRecovery(segment) { Button("放弃下载缓存") { controls.discardCache = true } }
                Button(studio.hasRecovery(segment) ? "继续下载" : segment.current == nil ? "生成并试听" : "重新生成") { studio.generate(only: segment.id) }
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
        }.confirmationDialog("放弃已生成的下载结果？", isPresented: $controls.discardCache) {
            Button("放弃缓存", role: .destructive) { studio.discardRecovery(segment) }
        } message: { Text("之后点击生成将重新请求服务，可能再次计费。") }
        .padding(18).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
