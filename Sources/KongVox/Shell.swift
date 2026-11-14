import SwiftUI

// The main window since 0.15: projects on the left; one project worked through four steps,
// 文稿 → 声音 → 校对 → 导出, each with its own inspector; a fixed footer for playback and the next action.

enum WorkStep: Int, CaseIterable, Identifiable {
    case script, voice, review, export
    var id: Int { rawValue }
    var title: String { ["文稿", "声音", "校对", "导出"][rawValue] }
    var hint: String { ["写入或导入", "服务与音色", "试听与修正", "音频与字幕"][rawValue] }
}

enum Palette {
    /// The kong app family's blue.
    static let accent = Color(red: 0.14, green: 0.34, blue: 0.90)
    static let ready = Color(red: 0.08, green: 0.50, blue: 0.30)
    static let warn = Color(red: 0.66, green: 0.40, blue: 0.0)
    static let hairline = Color.primary.opacity(0.09)
    static var surface: Color { Color(nsColor: .textBackgroundColor) }
}

enum ProjectProgress {
    case empty, pending, ready, working
    var label: String {
        switch self { case .empty: return "空白"; case .pending: return "待生成"; case .ready: return "已就绪"; case .working: return "生成中" }
    }
    var color: Color {
        switch self { case .empty: return .secondary.opacity(0.5); case .pending: return .secondary; case .ready: return Palette.ready; case .working: return Palette.accent }
    }
}

extension Studio {
    func progressState(_ p: Project) -> ProjectProgress {
        if activeProject == p.id { return .working }
        if p.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && p.segments.isEmpty { return .empty }
        if p.isLongMode && p.needsLongPreparation { return .pending }
        return !p.segments.isEmpty && p.segments.allSatisfy { ready($0, in: p) } ? .ready : .pending
    }
    /// A binding into the selected project; writes are saved after typing pauses.
    func binding<T>(_ key: WritableKeyPath<Project, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project?[keyPath: key] ?? fallback }, set: { value in self.editLive { $0[keyPath: key] = value } })
    }
    func hasFinding(_ segmentID: UUID) -> Bool {
        findings.contains { $0.segmentID == segmentID } || (speechFindingsProject == selected && speechFindings.contains { $0.segmentID == segmentID })
    }
}

struct StudioView: View {
    @EnvironmentObject var studio: Studio
    @EnvironmentObject var updater: AppUpdater
    @StateObject private var state = ViewState()
    var body: some View {
        NavigationSplitView {
            ProjectSidebar(state: state).navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            Group {
                if let p = studio.project { ProjectWorkspace(state: state, project: p) }
                else { Text("选择或新建一个项目").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Palette.accent)
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
        .sheet(isPresented: $updater.showPanel) { UpdateView().environmentObject(updater).environmentObject(studio) }
        .task { updater.checkOnLaunch() }
        .onChange(of: studio.selected) { _ in studio.stop(); studio.findings = []; studio.qualitySummary = "尚未检查"; studio.clearSpeechFindings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in studio.flushPendingSave() }
        .modifier(MaintenanceDialogs(state: state))
        .alert("KongVox", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("知道了") { studio.error = nil }
            if !studio.diagnostic.isEmpty { Button("复制诊断") { studio.copyDiagnostic(); studio.error = nil } }
        } message: { Text(studio.error ?? "") }
    }
    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeSeen05"); state.showWelcome = false
    }
}

// MARK: Sidebar

private struct SidebarOrganization: Codable {
    struct Folder: Codable, Identifiable {
        var id = UUID()
        var name: String
        var collapsed = false
    }

    var folders: [Folder] = []
    var membership: [UUID: UUID] = [:]
    var projectsCollapsed = false
    var ungroupedCollapsed = false
}

struct ProjectSidebar: View {
    @EnvironmentObject var studio: Studio
    @EnvironmentObject var updater: AppUpdater
    @ObservedObject var state: ViewState
    @AppStorage("projectSidebarOrganization") private var savedOrganization = Data()
    @State private var managing = false
    @State private var checked: Set<UUID> = []
    @State private var editingName = false
    @State private var name = ""
    @State private var projectFolder: UUID?
    @State private var nameError: String?
    @State private var nameTarget: NameTarget = .folder(nil)
    @State private var confirmingDeletion = false

    private enum NameTarget {
        case folder(UUID?)
        case project(UUID?)
    }

    private var organization: SidebarOrganization {
        (try? JSONDecoder().decode(SidebarOrganization.self, from: savedOrganization)) ?? SidebarOrganization()
    }
    private var query: String { state.search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtered: [Project] {
        query.isEmpty ? studio.projects : studio.projects.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var visibleIDs: Set<UUID> { Set(filtered.map(\.id)) }
    private var selectedIDs: Set<UUID> { checked.intersection(studio.projects.map(\.id)) }
    private func updateOrganization(_ change: (inout SidebarOrganization) -> Void) {
        var value = organization
        change(&value)
        if let data = try? JSONEncoder().encode(value) { savedOrganization = data }
    }

    var queueDetail: String? {
        studio.queueRunning ? "进行中" : studio.queue.isEmpty ? nil : "\(studio.queue.count) 项"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIcon(size: 28)
                Text("KongVox").font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { editName(.project(nil)) }) { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help("新建项目（⌘N）").accessibilityLabel("新建配音").disabled(studio.isWorking)
            }
            .padding(.horizontal, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("搜索项目", text: $state.search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
            projectControls
            List(selection: managing ? .constant(nil) : $studio.selected) {
                if !organization.projectsCollapsed || !query.isEmpty || managing {
                    ForEach(organization.folders) { folder in
                        let projects = filtered.filter { organization.membership[$0.id] == folder.id }
                        if query.isEmpty || !projects.isEmpty {
                            Section {
                                if !folder.collapsed || !query.isEmpty || managing { projectRows(projects) }
                            } header: {
                                groupHeader(folder.name, count: projects.count, collapsed: folder.collapsed) {
                                    updateOrganization { value in
                                        if let i = value.folders.firstIndex(where: { $0.id == folder.id }) {
                                            value.folders[i].collapsed.toggle()
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button("在此分组新建项目…") { editName(.project(nil), folder: folder.id) }
                                    Button("编辑分组…") { editName(.folder(folder.id), current: folder.name) }
                                    Button("解散分组") {
                                        updateOrganization {
                                            $0.folders.removeAll { $0.id == folder.id }
                                            $0.membership = $0.membership.filter { $0.value != folder.id }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let ungrouped = filtered.filter { project in
                        !organization.folders.contains { $0.id == organization.membership[project.id] }
                    }
                    if query.isEmpty || !ungrouped.isEmpty {
                        Section {
                            if !organization.ungroupedCollapsed || !query.isEmpty || managing { projectRows(ungrouped) }
                        } header: {
                            groupHeader("未分组", count: ungrouped.count, collapsed: organization.ungroupedCollapsed) {
                                updateOrganization { $0.ungroupedCollapsed.toggle() }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar).disabled(studio.isWorking)
            VStack(spacing: 2) {
                if let release = updater.availableRelease {
                    SidebarLink(title: "有新版本 \(release.version)", icon: "arrow.down.circle", tint: .orange) { updater.showPanel = true }
                }
                SidebarLink(title: "批量队列", icon: "list.bullet.rectangle", detail: queueDetail) { state.showBatch = true }
                SidebarLink(title: "服务设置", icon: "gearshape", detail: AppInfo.version) { state.showSettings = true }
                    .disabled(studio.isWorking)
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
        .padding(.top, 12).padding(.horizontal, 10).padding(.bottom, 10)
        .onChange(of: state.search) { _ in if managing { checked = [] } }
        .onChange(of: studio.projects.map(\.id)) { ids in
            let existing = Set(ids)
            checked.formIntersection(existing)
            if organization.membership.keys.contains(where: { !existing.contains($0) }) {
                updateOrganization { $0.membership = $0.membership.filter { existing.contains($0.key) } }
            }
        }
        .focusedSceneValue(\.newSidebarProject, { editName(.project(nil)) })
        .sheet(isPresented: $editingName) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editorTitle).font(.headline)
                TextField("名称", text: $name)
                if case .project = nameTarget {
                    Picker("分组", selection: $projectFolder) {
                        Text("未分组").tag(nil as UUID?)
                        ForEach(organization.folders) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if let nameError { Text(nameError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("取消") { editingName = false }.keyboardShortcut(.cancelAction)
                    Button("保存", action: saveName).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.isWorking)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
        .alert("删除 \(selectedIDs.count) 个项目？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if studio.deleteProjects(selectedIDs) { checked = []; managing = false }
            }
        } message: {
            Text("所选项目会从列表移除，音频文件暂时保留。")
        }
    }

    private var projectControls: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    updateOrganization { $0.projectsCollapsed.toggle() }
                } label: {
                    Label("项目", systemImage: organization.projectsCollapsed && query.isEmpty && !managing ? "chevron.right" : "chevron.down")
                }
                .disabled(!query.isEmpty || managing)
                Spacer()
                Button { editName(.folder(nil)) } label: { Image(systemName: "folder.badge.plus") }
                    .help("新建分组").accessibilityLabel("新建分组")
                Button(managing ? "完成" : "多选") { managing.toggle(); checked = [] }
            }
            if managing {
                HStack {
                    Button(!visibleIDs.isEmpty && checked == visibleIDs ? "取消全选" : "全选") {
                        checked = checked == visibleIDs ? [] : visibleIDs
                    }.disabled(visibleIDs.isEmpty)
                    Text("已选 \(selectedIDs.count)").foregroundStyle(.secondary)
                    Spacer()
                    Menu("移组") { moveOptions(selectedIDs) }.disabled(selectedIDs.isEmpty)
                    Button(role: .destructive) { confirmingDeletion = true } label: { Image(systemName: "trash") }
                        .help("删除所选项目").accessibilityLabel("删除所选项目").disabled(selectedIDs.isEmpty)
                }
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(studio.isWorking)
        .padding(.horizontal, 6)
    }

    private func groupHeader(_ title: String, count: Int, collapsed: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: collapsed && query.isEmpty && !managing ? "chevron.right" : "chevron.down")
                Text(title).lineLimit(1)
                Spacer()
                Text(count, format: .number)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!query.isEmpty || managing)
    }

    private func projectRows(_ projects: [Project]) -> some View {
        ForEach(projects) { project in
            Group {
                if managing {
                    Toggle(isOn: Binding(get: { checked.contains(project.id) }, set: { value in
                        if value { checked.insert(project.id) } else { checked.remove(project.id) }
                    })) { ProjectRow(project: project) }
                } else {
                    ProjectRow(project: project)
                        .contextMenu {
                            Button("编辑项目…") { editName(.project(project.id), current: project.title, folder: organization.membership[project.id]) }
                            Menu("移到分组") { moveOptions([project.id]) }
                            Divider()
                            Button("删除项目…", role: .destructive) { state.deleteID = project.id }
                        }
                }
            }.tag(project.id)
        }
    }

    @ViewBuilder private func moveOptions(_ ids: Set<UUID>) -> some View {
        ForEach(organization.folders) { folder in
            Button(folder.name) {
                updateOrganization { value in
                    for id in ids { value.membership[id] = folder.id }
                    if let index = value.folders.firstIndex(where: { $0.id == folder.id }) {
                        value.folders[index].collapsed = false
                    }
                }
            }
        }
        Button("未分组") { updateOrganization { value in
            for id in ids { value.membership[id] = nil }
            value.ungroupedCollapsed = false
        } }
    }

    private var editorTitle: String {
        switch nameTarget {
        case .project(let id): return id == nil ? "新建项目" : "编辑项目"
        case .folder(let id): return id == nil ? "新建分组" : "编辑分组"
        }
    }

    private func editName(_ target: NameTarget, current: String = "", folder: UUID? = nil) {
        nameTarget = target; name = current; projectFolder = folder; nameError = nil; editingName = true
    }

    private func saveName() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !studio.isWorking else { return }
        switch nameTarget {
        case .project(let id):
            let projectID: UUID
            if let id {
                guard studio.renameProject(id, to: title) else { return }
                projectID = id
            } else {
                guard let id = studio.newProject(title: title) else { return }
                projectID = id
                state.search = ""
                state.step = .script
                managing = false
                checked = []
            }
            updateOrganization { value in
                value.membership[projectID] = projectFolder
                value.projectsCollapsed = false
                if let i = value.folders.firstIndex(where: { $0.id == projectFolder }) {
                    value.folders[i].collapsed = false
                } else {
                    value.ungroupedCollapsed = false
                }
            }
        case .folder(let id):
            guard !organization.folders.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
                nameError = "已有同名分组。"
                return
            }
            updateOrganization { value in
                if let index = value.folders.firstIndex(where: { $0.id == id }) {
                    value.folders[index].name = title
                } else {
                    value.folders.append(SidebarOrganization.Folder(name: title))
                    value.projectsCollapsed = false
                }
            }
        }
        editingName = false
    }
}

struct ProjectRow: View {
    @EnvironmentObject var studio: Studio
    let project: Project
    var body: some View {
        let progress = studio.progressState(project)
        VStack(alignment: .leading, spacing: 3) {
            Text(project.title.isEmpty ? "未命名配音" : project.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(progress.color).frame(width: 7, height: 7)
                Text("\(progress.label) · \(project.fullText.count) 字").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarLink: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var tint: Color = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .font(.system(size: 13)).foregroundStyle(tint)
            .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Workspace

struct ProjectWorkspace: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(state: state, project: project)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch state.step {
                    case .script: ScriptStep(state: state, project: project)
                    case .voice: VoiceStep(project: project)
                    case .review: ReviewStep(state: state, project: project)
                    case .export: ExportStep(state: state, project: project)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                StepInspector(state: state, project: project).frame(width: 280)
            }
            Divider()
            WorkspaceFooter(state: state, project: project)
        }
    }
}

struct WorkspaceHeader: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var meta: String { "\(project.isLongMode ? "整篇" : "逐段") · \(project.fullText.count) 字 · \(project.segments.count) 段" }
    func done(_ step: WorkStep) -> Bool {
        switch step {
        case .script: return !project.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .voice: return studio.fullAudioReady
        case .review, .export: return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("项目名称", text: studio.binding(\.title, fallback: ""))
                    .font(.system(size: 22, weight: .bold)).textFieldStyle(.plain).frame(maxWidth: 440)
                    .disabled(studio.isWorking)
                Text(meta).font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProjectMenu(state: state)
            }
            HStack(spacing: 10) {
                ForEach(WorkStep.allCases) { step in
                    StepTab(step: step, selected: state.step == step, done: done(step)) { state.step = step }
                    if step != .export { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 22, height: 1) }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 28).padding(.top, 16)
    }
}

struct StepTab: View {
    let step: WorkStep
    let selected: Bool
    let done: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(selected ? Palette.accent : Color.clear)
                    Circle().strokeBorder(selected ? Palette.accent : done ? Palette.ready : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if done && !selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.ready)
                    } else {
                        Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? Color.white : Color.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundStyle(selected ? Color.primary : Color.secondary)
                    Text(step.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4).frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Palette.accent : Color.clear).frame(height: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(step.rawValue + 1) 步：\(step.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProjectMenu: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    var body: some View {
        Menu {
            Button("项目版本与回滚…") { state.showVersions = true }
            Divider()
            Button("备份当前项目…") { studio.chooseBackup() }
            Button("从备份恢复为新项目…") { studio.chooseRestore() }
            Divider()
            Button("清理未引用音频…") {
                do {
                    let plan = try studio.audioCleanupPlan()
                    if plan.files.isEmpty { studio.status = "没有未引用的音频文件。" } else { state.cleanupPlan = plan }
                } catch { studio.error = error.localizedDescription }
            }
            Button("使用指南") { state.showWelcome = true }
            Divider()
            Button("删除项目…", role: .destructive) { state.deleteID = studio.selected }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("项目操作").accessibilityLabel("项目操作")
        .disabled(studio.isWorking)
    }
}

// MARK: Steps

struct ScriptStep: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var progressText: String {
        if studio.fullAudioReady { return "配音已就绪" }
        if project.isLongMode && project.needsLongPreparation { return "文稿有改动，待生成" }
        return "配音进度 \(Int(studio.fullProgress * 100))%"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("编辑方式", selection: Binding(get: { project.isLongMode }, set: { studio.setLongMode($0) })) {
                    Text("整篇").tag(true)
                    Text("逐段").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                .help("整篇：直接编辑全文，后台自动分段。逐段：逐段修改读法、单段重做和管理下载缓存。")
                Button { state.showBatch = true } label: { Label("导入文稿…", systemImage: "square.and.arrow.down") }
                    .help("读取 TXT、Markdown、Word 文件，每份文件建立一个项目")
                Spacer()
                Text(progressText).font(.caption).foregroundStyle(.secondary)
            }
            if project.isLongMode {
                TextEditor(text: Binding(get: { studio.project?.fullText ?? "" }, set: { text in studio.editLive { $0.longText = text } }))
                    .font(.system(size: 16)).lineSpacing(7)
                    .scrollContentBackground(.hidden).padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
                    .overlay(alignment: .topLeading) {
                        if project.fullText.isEmpty {
                            Text("粘贴整篇文章，或用「导入文稿」读取文件。生成时后台自动分段。")
                                .font(.system(size: 15)).foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.vertical, 22).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("完整文章编辑区")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(project.segments.enumerated()), id: \.element.id) { index, segment in
                            SegmentCard(index: index, segment: segment, settings: project.settings)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(project.segments.isEmpty ? "从一段文字开始" : "追加文稿").font(.headline)
                            Text("粘贴口播稿或长文章，按自然段拆分；长段会自动分句。").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: studio.binding(\.draft, fallback: ""))
                                .font(.body).frame(minHeight: 120).scrollContentBackground(.hidden).padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline))
                            Button("添加为配音段落") { studio.importDraft() }
                                .disabled(project.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .disabled(studio.isWorking)
    }
}

struct VoiceStep: View {
    @EnvironmentObject var studio: Studio
    let project: Project
    var service: ServiceProfile { project.settings.resolvedService }
    var expressionNote: String {
        switch service.kind {
        case .gptSoVITS: return "音色来自参考音频。支持语速设置。"
        case .localQwen: return "本机模型按提示理解表达与语速，效果为参考；留空时使用音色原本的读法。"
        case .volcengine: return "火山引擎当前不发送表达要求，只应用语速。"
        case .qwenTTS: return "Qwen Flash 使用默认语速；Instruct Flash 才支持表达与语速提示。"
        case .cosyVoice: return "CosyVoice 指令需符合音色要求，例如：你说话的情感是happy。留空使用预设。"
        case .gemini: return "Gemini 通过表达指令调整节奏，倍速为参考目标。"
        case .openAI: return "表达要求作为朗读指令发送；tts-1 系列模型不使用。"
        }
    }
    var body: some View {
        Form {
            Section("配音服务") {
                Picker("服务", selection: Binding(get: { service.id }, set: { studio.selectService($0) })) {
                    ForEach(studio.catalog.profiles.filter { $0.enabled || $0.id == service.id }) { profile in
                        Text(profile.name + (profile.enabled ? "" : "（已停用）")).tag(profile.id)
                    }
                }
                LabeledContent("模型") { Text(service.model).textSelection(.enabled).foregroundStyle(.secondary) }
                if service.kind == .volcengine && service.model != "seed-tts-2.0" && project.settings.voice == ServiceProfile.volcVVVoice {
                    Text("当前资源与 VV 音色不匹配，请在服务设置中切换 2.0 或填写对应 speaker。").font(.caption).foregroundStyle(Palette.warn)
                }
                if studio.catalog.profiles.first(where: { $0.id == service.id }) != service {
                    Button("应用最新服务配置") { studio.selectService(service.id) }
                }
            }
            Section("音色与节奏") {
                Picker("音色", selection: studio.binding(\.settings.voice, fallback: "")) {
                    ForEach(service.voices, id: \.self) { Text($0).tag($0) }
                }
                Picker("使用场景", selection: studio.binding(\.settings.mode, fallback: "短视频口播")) {
                    Text("短视频口播").tag("短视频口播")
                    Text("长文章").tag("长文章")
                }
                LabeledContent("语速") {
                    HStack(spacing: 10) {
                        Slider(value: studio.binding(\.settings.speed, fallback: 1), in: 0.7...1.3, step: 0.05).frame(maxWidth: 260)
                        Text(String(format: "%.2f×", project.settings.speed)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Picker("段间停顿", selection: studio.binding(\.settings.pause, fallback: 0.35)) {
                    Text("紧凑 · 0.15 秒").tag(0.15)
                    Text("标准 · 0.35 秒").tag(0.35)
                    Text("舒缓 · 0.7 秒").tag(0.7)
                }
            }
            Section {
                TextField("例如：像朋友聊天，重点处稍作强调", text: studio.binding(\.settings.direction, fallback: ""), axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("表达要求（可留空）")
            } footer: {
                Text(expressionNote).font(.caption).foregroundStyle(.secondary)
            }
            Section("合并与提醒") {
                Toggle("统一音量", isOn: Binding(get: { project.levelsEnabled }, set: { enabled in studio.edit { $0.normalizeVolume = enabled } }))
                    .help("只在合并试听和导出时调整，原始音频不变")
                Toggle("全文完成后通知我", isOn: Binding(get: { studio.notificationsEnabled }, set: { studio.setNotifications($0) }))
            }
        }
        .formStyle(.grouped)
        .disabled(studio.isWorking)
    }
}

struct ReviewStep: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var stale: Bool { project.isLongMode && project.needsLongPreparation }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(studio.fullAudioReady ? "点击任一段，从该处播放。" : "生成全文后才能逐段试听。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("逐句精修…") { state.showPrecision = true }.help("逐句填写读法、语速和句后停顿")
                Button("复听与版本对比…") { state.showFinishedReview = true }.help("跟随文稿播放，修复读音并比较新旧版本")
                Button("章节与词典…") { state.showTools = true }.help("按章生成和导出、发音词典、任务状态")
            }
            .disabled(studio.isWorking)
            if stale {
                Notice(icon: "exclamationmark.circle", text: "文稿在生成后有改动。回到「文稿」或点击下方「生成全文」更新后再校对。", color: Palette.warn)
                Spacer()
            } else if project.segments.isEmpty {
                Notice(icon: "text.alignleft", text: "还没有文稿。先在「文稿」中写入或导入。", color: .secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(project.segments.enumerated()), id: \.element.id) { index, segment in
                            ReviewRow(index: index, segment: segment, project: project)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }
}

struct ReviewRow: View {
    @EnvironmentObject var studio: Studio
    let index: Int
    let segment: Segment
    let project: Project
    var body: some View {
        let ready = studio.ready(segment, in: project)
        let flagged = studio.hasFinding(segment.id)
        let playing = studio.readingSegment == segment.id
        Button { studio.playAll(from: segment.id) } label: {
            HStack(alignment: .top, spacing: 14) {
                Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 3)
                Text(segment.text).font(.system(size: 14)).lineSpacing(5).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if playing { StatusBadge(text: "播放中", icon: "waveform", color: Palette.accent) }
                else if !ready { StatusBadge(text: "待生成", icon: "circle.dashed", color: .secondary) }
                else if flagged { StatusBadge(text: "有提示", icon: "exclamationmark.triangle", color: Palette.warn) }
                else { StatusBadge(text: "已就绪", icon: "checkmark", color: Palette.ready) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(playing ? Palette.accent.opacity(0.08) : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(playing ? Palette.accent : Palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!studio.fullAudioReady || studio.isWorking)
    }
}

struct ExportStep: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择导出内容").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ExportChoice(title: "音频 + 字幕", detail: "ZIP：WAV 与 SRT，同一时间轴", format: "zip", state: state)
                ExportChoice(title: "仅字幕", detail: "SRT，按当前字幕设置", format: "srt", state: state)
                ExportChoice(title: "WAV", detail: "无损，适合剪辑", format: "wav", state: state)
                ExportChoice(title: "M4A", detail: "体积小，便于分享", format: "m4a", state: state)
                ExportChoice(title: "MP3", detail: Studio.ffmpeg == nil ? "需先安装 FFmpeg" : "通用格式", format: "mp3", state: state)
                    .disabled(Studio.ffmpeg == nil)
            }
            .disabled(!studio.fullAudioReady || studio.isWorking)
            Text(studio.fullAudioReady
                 ? "选择后打开交付检查：核对缺失片段、候选版本和字幕状态，再选择保存位置。字幕样式与对齐方式在交付检查中设置。"
                 : "还有未生成或已过期的音频。先在「文稿」或「声音」中生成全文。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }
}

struct ExportChoice: View {
    let title: String
    let detail: String
    let format: String
    @ObservedObject var state: ViewState
    var body: some View {
        Button { state.exportFormat = format; state.showDelivery = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Inspector

struct StepInspector: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var service: ServiceProfile { project.settings.resolvedService }
    var costNote: String {
        service.kind == .localQwen ? "本机合成，不上传、不计费。"
            : "生成时文稿发送至 \(service.name)（\(service.endpointHost)），按服务商实际计费。试听已有音频与导出不计费。"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch state.step {
                case .script: scriptCards
                case .voice: voiceCards
                case .review: reviewCards
                case .export: exportCards
                }
            }
            .padding(16)
        }
        .background(Color.primary.opacity(0.025))
    }
    @ViewBuilder var scriptCards: some View {
        InspectorCard("声音", actionTitle: "调整", action: { state.step = .voice }) {
            InfoRow(label: "服务", value: service.name)
            InfoRow(label: "音色", value: project.settings.voice)
            InfoRow(label: "语速", value: String(format: "%.2f×", project.settings.speed))
        }
        usageCard
        InspectorCard("读音词典", actionTitle: "管理", action: { state.showTools = true }) {
            InfoRow(label: "本项目", value: "\((project.settings.pronunciationRules ?? []).count) 条")
            InfoRow(label: "全局", value: "\(studio.globalDictionary.count) 条")
            Text("生成时按词典替换读音，字幕仍用原文。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder var voiceCards: some View {
        InspectorCard("试听") {
            Text("先听开头约 20 秒，满意再生成全文。已生成的开头会复用。").font(.caption).foregroundStyle(.secondary)
            Button("试听开头") { studio.generateOpening() }
                .disabled(studio.isWorking || project.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        InspectorCard("音色收藏", actionTitle: "打开", action: { state.showPrecision = true }) {
            Text(studio.voiceFavorites.isEmpty ? "还没有收藏。可为常用音色起名，并用同一段文稿对比两个音色。" : "已收藏 \(studio.voiceFavorites.count) 个音色。")
                .font(.caption).foregroundStyle(.secondary)
        }
        InspectorCard("配音预设", actionTitle: "管理", action: { state.showBatch = true }) {
            Text(studio.presets.isEmpty ? "可把服务、音色、语速与停顿存为预设，用于新项目。" : "已保存 \(studio.presets.count) 个预设。")
                .font(.caption).foregroundStyle(.secondary)
        }
        InspectorCard("费用") { Text(costNote).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder var reviewCards: some View {
        InspectorCard("音频检查", actionTitle: "检查", action: { studio.inspectAudio() }) {
            Text(studio.qualitySummary).font(.caption)
            Text("检查缺失、长静音、音量差和异常时长。").font(.caption).foregroundStyle(.secondary)
        }
        InspectorCard("本机转写核对", actionTitle: "交付检查", action: { state.exportFormat = "zip"; state.showDelivery = true }) {
            Text(studio.speechFindingsProject == studio.selected ? studio.speechSummary : "尚未核对").font(.caption)
            Text("用 Mac 自带语音识别找疑似漏读、重读（需 macOS 26）。").font(.caption).foregroundStyle(.secondary)
        }
        InspectorCard("版本", actionTitle: "历史", action: { state.showVersions = true }) {
            Text("修改前可回到任一保存过的项目版本。").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder var exportCards: some View {
        InspectorCard("成品") {
            InfoRow(label: "片段", value: "\(project.segments.count) 段")
            InfoRow(label: "状态", value: studio.fullAudioReady ? "全部就绪" : "尚未就绪", color: studio.fullAudioReady ? Palette.ready : Palette.warn)
            InfoRow(label: "字幕", value: project.resolvedSubtitleStyle.rawValue)
        }
        InspectorCard("批量交付", actionTitle: "打开", action: { state.showBatch = true }) {
            Text("多个项目可在批量队列中按整篇或按章一起导出。").font(.caption).foregroundStyle(.secondary)
        }
    }
    var usageCard: some View {
        let usage = studio.usageEstimate
        return InspectorCard("本次生成") {
            InfoRow(label: "待生成", value: "\(usage.generate) 字")
            InfoRow(label: "可复用", value: "\(usage.reuse) 字", color: usage.reuse > 0 ? Palette.ready : nil)
            if usage.recover > 0 { InfoRow(label: "待恢复下载", value: "\(usage.recover) 字") }
            Text(costNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct InspectorCard<Content: View>: View {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
    let content: Content
    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.actionTitle = actionTitle; self.action = action; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.link).font(.caption) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).foregroundStyle(color ?? Color.primary).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 13))
    }
}

struct StatusBadge: View {
    let text: String
    let icon: String
    let color: Color
    var body: some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).fixedSize()
    }
}

struct Notice: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline))
    }
}

// MARK: Footer

struct WorkspaceFooter: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var state: ViewState
    let project: Project
    var textEmpty: Bool {
        project.isLongMode ? project.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : project.segments.isEmpty
    }
    var body: some View {
        HStack(spacing: 14) {
            Button {
                if studio.player != nil { studio.togglePause() } else { studio.playAll() }
            } label: {
                Image(systemName: studio.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .help(studio.playing ? "暂停" : "播放完整配音")
            .accessibilityLabel(studio.playing ? "暂停" : "播放完整配音")
            .disabled(studio.isWorking || (studio.player == nil && !studio.fullAudioReady))
            if studio.playbackDuration > 0 {
                PlaybackScrubber(clock: studio.clock, label: "播放进度").frame(maxWidth: 340).disabled(studio.isWorking)
                Button { studio.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("停止").accessibilityLabel("停止播放")
            }
            VStack(alignment: .leading, spacing: 3) {
                LocalModelProgressView()
                Text(studio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if studio.isWorking { ProgressView(value: studio.progress).frame(width: 180) }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(minHeight: 64)
    }
    @ViewBuilder var actions: some View {
        if studio.isWorking {
            if studio.activeSegment != nil {
                Button(studio.pauseRequested ? "等待暂停…" : "本段后暂停") {
                    if studio.queueRunning { studio.pauseQueue() } else { studio.pauseAfterSegment() }
                }
                .disabled(studio.pauseRequested)
                Button("取消生成") { if studio.queueRunning { studio.pauseQueue() }; studio.cancel() }
            }
        } else {
            switch state.step {
            case .script, .voice:
                Button("试听开头") { studio.generateOpening() }.disabled(textEmpty)
                generateButton.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            case .review:
                if !studio.fullAudioReady { generateButton }
                Button("去导出") { state.step = .export }.buttonStyle(.borderedProminent).disabled(!studio.fullAudioReady)
            case .export:
                Button("导出…") { state.exportFormat = "zip"; state.showDelivery = true }
                    .buttonStyle(.borderedProminent).disabled(!studio.fullAudioReady)
            }
        }
    }
    var generateButton: some View {
        Button(project.isLongMode ? "生成全文" : "生成待更新") { studio.prepareReview(); state.showReview = true }
            .help("确认生成范围后，生成所有待更新内容")
            .disabled(textEmpty)
    }
}
