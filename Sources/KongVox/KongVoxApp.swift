import SwiftUI

@main enum KongVoxMain {
    @MainActor static func main() {
        // Headless check of the on-device engine; see LocalSpeechSelfTest. Exits without opening a window.
        if CommandLine.arguments.contains("--local-speech-selftest") {
            Task.detached {
                let code = await LocalSpeechSelfTest.run(CommandLine.arguments)
                exit(code)
            }
            dispatchMain()
        }
        KongVoxApp.main()
    }
}
private struct NewSidebarProject: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var newSidebarProject: (() -> Void)? {
        get { self[NewSidebarProject.self] }
        set { self[NewSidebarProject.self] = newValue }
    }
}

struct KongVoxApp: App {
    @FocusedValue(\.newSidebarProject) private var newSidebarProject
    @StateObject private var studio = Studio()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("KongVox") {
            StudioView().environmentObject(studio).environmentObject(updater).frame(minWidth: 1060, minHeight: 700)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { Button("新建项目…") { newSidebarProject?() }.keyboardShortcut("n").disabled(studio.isWorking || newSidebarProject == nil) }
            CommandGroup(after: .appInfo) { Button("检查更新…") { updater.check(manual: true) } }
        }
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
    /// The step shown in the workspace: 文稿 → 声音 → 校对 → 导出.
    @Published var step: WorkStep = .script
    @Published var search = ""
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
