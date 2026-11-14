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
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var studio: Studio
    @EnvironmentObject var updater: AppUpdater
    @StateObject private var state = ViewState()
    @AppStorage("KongVox.lastRecording") private var lastRecording = ""
    @AppStorage("KongVox.lastStep") private var lastStep = 0
    @State private var restoredWorkspace = false
    @AppStorage("KongVox.sidebarWidth") private var savedSidebarWidth = 240.0
    @GestureState private var sidebarDrag: CGFloat = 0

    private func sidebarWidth(_ width: CGFloat) -> CGFloat {
        min(420, max(200, width))
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: 10)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($sidebarDrag) { value, offset, _ in offset = value.translation.width }
                    .onEnded { value in savedSidebarWidth = sidebarWidth(savedSidebarWidth + value.translation.width) }
            )
            .accessibilityHidden(true)
    }
    var body: some View {
        NavigationSplitView {
            ProjectSidebar(state: state)
                .overlay(alignment: .trailing) { sidebarResizeHandle }
                .navigationSplitViewColumnWidth(sidebarWidth(savedSidebarWidth + sidebarDrag))
        } detail: {
            Group {
                if let p = studio.project { ProjectWorkspace(state: state, project: p) }
                else { Text("选择或新建一个项目").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Palette.accent)
        .onAppear {
            guard !restoredWorkspace else { return }
            restoredWorkspace = true
            if let id = UUID(uuidString: lastRecording), studio.projects.contains(where: { $0.id == id }) { studio.selected = id }
            state.step = WorkStep(rawValue: lastStep) ?? .script
            state.showWelcome = !UserDefaults.standard.bool(forKey: "welcomeSeen05")
        }
        .onChange(of: state.step) { step in lastStep = step.rawValue; studio.flushPendingSave() }
        .onChange(of: scenePhase) { phase in if phase != .active { studio.flushPendingSave(); studio.rememberPlayback() } }
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
        .onChange(of: studio.selected) { id in lastRecording = id?.uuidString ?? ""; studio.flushPendingSave(); studio.stop(); studio.findings = []; studio.qualitySummary = "尚未检查"; studio.clearSpeechFindings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in studio.flushPendingSave(); studio.rememberPlayback() }
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
        var pinned: Bool?
    }

    var projects: [Folder]?
    var archivedProjects: [Folder]?
    var archivedRecordings: [UUID: Set<UUID>]?
    var legacyProjectID: UUID?
    var parents: [UUID: UUID]?
    var folders: [Folder] = []
    var membership: [UUID: UUID] = [:]
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
    @State private var narrationText = ""
    @State private var nameTarget: NameTarget = .folder(nil)
    @State private var confirmingDeletion = false
    @State private var projectToDelete: UUID?

    private enum NameTarget {
        case narration
        case audio(UUID)
        case folder(UUID?)
        case project(UUID?)
    }

    private var organization: SidebarOrganization {
        var value = (try? JSONDecoder().decode(SidebarOrganization.self, from: savedOrganization)) ?? SidebarOrganization()
        if value.projects == nil {
            // Preserve legacy group IDs and every audio document's membership.
            let archive = SidebarOrganization.Folder(name: "已有配音")
            value.projects = [archive]
            value.legacyProjectID = archive.id
            value.parents = Dictionary(uniqueKeysWithValues: value.folders.map { ($0.id, archive.id) })
        }
        if value.legacyProjectID == nil { value.legacyProjectID = value.projects?.first?.id }
        return value
    }
    @State private var parentProject: UUID?
    @State private var currentContainer: UUID?
    @State private var currentGroup: UUID?
    @State private var showRecent = false
    @State private var showTrash = false
    @State private var trashSearch = ""
    @State private var trashSelection: Set<UUID> = []
    @State private var dropTarget: UUID?
    @State private var previousGroups: [UUID: UUID?] = [:]
    private var projectNodes: [SidebarOrganization.Folder] { (organization.projects ?? []).filter { $0.pinned == true } + (organization.projects ?? []).filter { $0.pinned != true } }
    private var activeContainer: UUID? {
        if let currentContainer, projectNodes.contains(where: { $0.id == currentContainer }) { return currentContainer }
        if let selected = studio.selected, let group = organization.membership[selected],
           let parent = organization.parents?[group] { return parent }
        return projectNodes.first?.id
    }

    private var query: String { state.search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filtered: [Project] {
        query.isEmpty ? studio.projects : studio.projects.filter { ($0.title + " " + path(for: $0.id)).localizedCaseInsensitiveContains(query) }
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
                addMenu
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
            ScrollViewReader { proxy in
            List(selection: managing ? .constant(nil) : $studio.selected) {
                ForEach(projectNodes) { node in
                        groupHeader(node.pinned == true ? "📌 " + node.name : node.name, count: filtered.filter { item in
                            (organization.membership[item.id].flatMap { organization.parents?[$0] } ?? organization.legacyProjectID) == node.id
                        }.count, collapsed: node.collapsed) {
                            currentContainer = node.id; currentGroup = nil
                            guard query.isEmpty, !managing else { return }
                            updateOrganization { value in
                                if let i = value.projects?.firstIndex(where: { $0.id == node.id }) { value.projects?[i].collapsed.toggle() }
                            }
                        }
                        .contextMenu {
                            Button("在此项目新建分组…") { editName(.folder(nil), parent: node.id) }
                            Button(node.pinned == true ? "取消置顶" : "置顶项目") {
                                updateOrganization { value in
                                    if let i = value.projects?.firstIndex(where: { $0.id == node.id }) { value.projects?[i].pinned = node.pinned != true }
                                }
                            }
                            Button("编辑项目…") { editName(.project(node.id), current: node.name) }
                            Button("删除项目…", role: .destructive) { projectToDelete = node.id }
                                .disabled(projectNodes.count == 1)
                        }
                        if !node.collapsed || !query.isEmpty || managing {
                            ForEach(organization.folders.filter { organization.parents?[$0.id] == node.id }) { folder in
                                let items = filtered.filter { organization.membership[$0.id] == folder.id }
                                if query.isEmpty || !items.isEmpty {
                                    groupHeader(folder.name, count: items.count, collapsed: folder.collapsed) {
                                        currentContainer = node.id; currentGroup = folder.id
                                        guard query.isEmpty, !managing else { return }
                                        updateOrganization { value in
                                            if let i = value.folders.firstIndex(where: { $0.id == folder.id }) { value.folders[i].collapsed.toggle() }
                                        }
                                    }
                                    .padding(.leading, 12)
                                    .background(dropTarget == folder.id ? Palette.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .help(groupLabel(folder))
                                    .dropDestination(for: String.self) { values, _ in
                                        let ids = Set(values.compactMap(UUID.init(uuidString:))).intersection(studio.projects.map(\.id))
                                        guard !studio.isWorking, !ids.isEmpty else { return false }
                                        move(ids, to: folder.id)
                                        return true
                                    } isTargeted: { targeted in
                                        if targeted { dropTarget = folder.id }
                                        else if dropTarget == folder.id { dropTarget = nil }
                                    }
                                    .contextMenu {
                                        Button("在此分组新建配音…") { editName(.narration, folder: folder.id) }
                                        Button("编辑分组…") { editName(.folder(folder.id), current: folder.name) }
                                        Button("解散分组") { dissolve(folder.id) }
                                    }
                                    if !folder.collapsed || !query.isEmpty || managing { projectRows(items, grouped: true) }
                                }
                            }
                            if node.id == organization.legacyProjectID {
                                let loose = filtered.filter { organization.membership[$0.id] == nil }
                                if !loose.isEmpty {
                                    Label("未分组", systemImage: "folder").padding(.leading, 12)
                                    projectRows(loose, grouped: true)
                                }
                            }
                        }
                }
            }
            .listStyle(.sidebar).disabled(studio.isWorking)
            .onChange(of: state.sidebarReveal) { _ in
                guard let id = studio.selected else { return }
                state.search = ""
                expandPath(id)
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
            }
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
        .onAppear {
            if (try? JSONDecoder().decode(SidebarOrganization.self, from: savedOrganization))?.projects == nil {
                updateOrganization { _ in }
            }
        }
        .onChange(of: state.search) { _ in if managing { checked = [] } }
        .onAppear { updateBreadcrumb(studio.selected) }
        .onChange(of: savedOrganization) { _ in updateBreadcrumb(studio.selected) }
        .onChange(of: studio.selected) { id in
            updateBreadcrumb(id)
            currentGroup = id.flatMap { organization.membership[$0] }
            currentContainer = currentGroup.flatMap { organization.parents?[$0] } ?? organization.legacyProjectID
        }
        .onChange(of: studio.projects.map(\.id)) { ids in checked.formIntersection(ids) }
        .sheet(isPresented: $showRecent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("近期工作").font(.headline); Spacer(); Button("完成") { showRecent = false } }
                List(recentRecordings) { item in
                    Button {
                        studio.selected = item.id
                        state.sidebarReveal = UUID()
                        showRecent = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(path(for: item.id) + " · " + recentStatus(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(20).frame(width: 460, height: 360)
        }
        .sheet(isPresented: $showTrash) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("回收站").font(.headline); Spacer(); Button("完成") { showTrash = false } }
                TextField("搜索原路径或配音名称", text: $trashSearch)
                if studio.trashedProjects.isEmpty && (organization.archivedProjects ?? []).isEmpty {
                    Text("回收站为空。").foregroundStyle(.secondary)
                }
                ForEach(organization.archivedProjects ?? []) { node in
                    HStack {
                        Label(node.name, systemImage: "folder")
                        Spacer()
                        Button("恢复项目") {
                            let ids = (organization.archivedRecordings?[node.id] ?? []).intersection(studio.trashedProjects.map(\.id))
                            guard ids.isEmpty || studio.restoreProjects(ids) else { return }
                            updateOrganization { value in
                                value.projects?.append(node)
                                value.archivedProjects?.removeAll { $0.id == node.id }
                                value.archivedRecordings?[node.id] = nil
                            }
                            showTrash = false
                        }
                    }
                }
                List(studio.trashedProjects.filter { item in
                    let parent = organization.membership[item.id].flatMap { organization.parents?[$0] } ?? organization.legacyProjectID
                    return !(organization.archivedProjects ?? []).contains { $0.id == parent } &&
                        (trashSearch.isEmpty || (path(for: item.id) + " / " + item.title).localizedCaseInsensitiveContains(trashSearch))
                }, selection: $trashSelection) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(path(for: item.id)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复") {
                            if studio.restoreProject(item.id) {
                                move([item.id], to: organization.membership[item.id])
                                showTrash = false
                            }
                        }
                    }
                    .tag(item.id)
                }
                if !trashSelection.isEmpty {
                    Text("同名配音保留为独立条目。").font(.caption).foregroundStyle(.secondary)
                    Button("恢复所选 \(trashSelection.count) 条") {
                        if studio.restoreProjects(trashSelection) {
                            if let id = studio.selected { expandPath(id) }
                            trashSelection = []
                        }
                    }
                }
            }.padding(20).frame(width: 440, height: 340)
        }
        .focusedSceneValue(\.newSidebarProject, { editName(.project(nil)) })
        .sheet(isPresented: $editingName) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editorTitle).font(.headline)
                TextField("名称", text: $name)
                if case .narration = nameTarget {
                    Text("配音文稿").font(.caption)
                    TextEditor(text: $narrationText).frame(minHeight: 130).accessibilityLabel("配音文稿")
                }
                if editorChoosesProject {
                    Picker("所属项目", selection: $parentProject) {
                        ForEach(projectNodes) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: parentProject) { project in
                        if let group = projectFolder, organization.parents?[group] != project { projectFolder = nil }
                    }
                }
                if editorShowsFolder {
                    Picker("分组", selection: $projectFolder) {
                        Text(editorChoosesProject ? "默认分组" : "未分组").tag(nil as UUID?)
                        ForEach(organization.folders.filter { folder in
                            let owner = organization.parents?[folder.id]
                            return projectNodes.contains { $0.id == owner } && (!editorChoosesProject || owner == parentProject)
                        }) {
                            Text(groupLabel($0)).tag(Optional($0.id))
                        }
                    }
                }
                if let nameError { Text(nameError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("取消") { editingName = false }.keyboardShortcut(.cancelAction)
                    Button(editorActionTitle, action: saveName).keyboardShortcut(.defaultAction)
                        .disabled(!canSaveName)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
        .confirmationDialog("将项目移到回收站？", isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })) {
            Button("移到回收站", role: .destructive) {
                guard let id = projectToDelete, projectNodes.count > 1,
                      let node = projectNodes.first(where: { $0.id == id }) else { return }
                let ids = recordings(in: id).intersection(studio.projects.map(\.id))
                guard ids.isEmpty || studio.trashProjects(ids) else { return }
                updateOrganization { value in
                    value.archivedProjects = (value.archivedProjects ?? []) + [node]
                    var recorded = value.archivedRecordings ?? [:]
                    recorded[id] = ids
                    value.archivedRecordings = recorded
                    value.projects?.removeAll { $0.id == id }
                }
                projectToDelete = nil
            }
        } message: {
            if let id = projectToDelete {
                Text("包含 \(organization.folders.filter { organization.parents?[$0.id] == id }.count) 个分组、\(recordings(in: id).intersection(studio.projects.map(\.id)).count) 条配音。可从回收站恢复。")
            }
        }
        .alert("删除 \(selectedIDs.count) 条配音？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) {}
            Button("移到回收站", role: .destructive) {
                if studio.trashProjects(selectedIDs) { checked = []; managing = false }
            }
        } message: {
            Text("所选配音会从列表移除，音频文件暂时保留。")
        }
    }

    private var addMenu: some View {
        Menu {
            Button("新建项目…", systemImage: "doc.badge.plus") { editName(.project(nil)) }
            Button("新建分组…", systemImage: "folder.badge.plus") { editName(.folder(nil)) }
            Button("新建配音…", systemImage: "waveform") {
                editName(.narration, folder: currentGroup, parent: activeContainer)
            }
            Divider()
            if let project = studio.project {
                Button("编辑当前配音…", systemImage: "pencil") {
                    editName(.audio(project.id), current: project.title, folder: organization.membership[project.id])
                }
                Button("删除当前配音…", systemImage: "trash", role: .destructive) { state.deleteID = project.id }
            }
            Menu("管理分组") {
                ForEach(organization.folders.filter { folder in projectNodes.contains { $0.id == organization.parents?[folder.id] } }) { folder in
                    Menu(groupLabel(folder)) {
                        Button("编辑分组…") { editName(.folder(folder.id), current: folder.name) }
                        Button("解散分组", role: .destructive) { dissolve(folder.id) }
                    }
                }
            }.disabled(!organization.folders.contains { folder in projectNodes.contains { $0.id == organization.parents?[folder.id] } })
            if !previousGroups.isEmpty { Button("撤销移组") { undoMove() } }
            Button("近期工作…") { showRecent = true }
            Button("回收站…") { trashSearch = ""; trashSelection = []; showTrash = true }
            Button(managing ? "结束多选" : "多选配音") { managing.toggle(); checked = [] }
        } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建与管理")
        .accessibilityLabel("新建与管理")
        .disabled(studio.isWorking)
    }

    private func dissolve(_ id: UUID) {
        updateOrganization {
            $0.folders.removeAll { $0.id == id }
            $0.parents?[id] = nil
            $0.membership = $0.membership.filter { $0.value != id }
        }
    }

    private var projectControls: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()
                Button { editName(.folder(nil)) } label: { Image(systemName: "folder.badge.plus") }
                    .help("新建分组").accessibilityLabel("新建分组")
                Button(managing ? "完成" : "多选") { managing.toggle(); checked = [] }
            }
            if managing {
                HStack {
                    Button(!visibleIDs.isEmpty && checked == visibleIDs ? "取消全选" : "全选") {
                        checked = checked == visibleIDs ? [] : visibleIDs
                    }.keyboardShortcut("a", modifiers: .command).disabled(visibleIDs.isEmpty)
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
    }

    private func projectRows(_ projects: [Project], grouped: Bool = false) -> some View {
        ForEach(projects) { project in
            Group {
                if managing {
                    Toggle(isOn: Binding(get: { checked.contains(project.id) }, set: { value in
                        if value { checked.insert(project.id) } else { checked.remove(project.id) }
                    })) { ProjectRow(project: project) }
                } else {
                    VStack(alignment: .leading) {
                        ProjectRow(project: project)
                        if !query.isEmpty { Text(path(for: project.id)).font(.caption2).foregroundStyle(.secondary) }
                    }
                        .draggable(project.id.uuidString)
                        .contextMenu {
                            Button("编辑配音…") { editName(.audio(project.id), current: project.title, folder: organization.membership[project.id]) }
                            Menu("复制配音") {
                                Button("复制文稿与设置") { duplicate(project.id, includeAudio: false) }
                                Button("同时复用已生成音频") { duplicate(project.id, includeAudio: true) }
                            }
                            Menu("移到分组") { moveOptions([project.id]) }
                            Divider()
                            Button("删除配音…", role: .destructive) { state.deleteID = project.id }
                        }
                }
            }.padding(.leading, grouped ? 28 : 0).tag(project.id).id(project.id)
        }
    }

    private func groupLabel(_ folder: SidebarOrganization.Folder) -> String {
        let parent = (projectNodes + (organization.archivedProjects ?? [])).first { $0.id == organization.parents?[folder.id] }
        return parent.map { $0.name + " / " + folder.name } ?? folder.name
    }

    private func recordings(in project: UUID) -> Set<UUID> {
        Set((studio.projects + studio.trashedProjects).filter { item in
            (organization.membership[item.id].flatMap { organization.parents?[$0] } ?? organization.legacyProjectID) == project
        }.map(\.id))
    }

    private func path(for id: UUID) -> String {
        guard let group = organization.folders.first(where: { $0.id == organization.membership[id] }) else {
            return (projectNodes.first { $0.id == organization.legacyProjectID }?.name ?? "已有配音") + " / 未分组"
        }
        return groupLabel(group)
    }

    private var recentRecordings: [Project] {
        let dates = studio.projects.map { item in
            let file = studio.root.appendingPathComponent("Projects/\(item.id.uuidString).json")
            return (item, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dates.sorted { $0.1 > $1.1 }.prefix(25).map { $0.0 }
    }

    private func recentStatus(_ item: Project) -> String {
        if let state = item.taskState, state.contains("失败") { return state }
        if studio.progressState(item) == .ready && studio.lastDelivery(for: item.id) == nil { return "待导出" }
        return studio.progressState(item).label
    }

    private func duplicate(_ id: UUID, includeAudio: Bool) {
        let group = organization.membership[id]
        guard let copy = studio.duplicateRecording(id, includeAudio: includeAudio) else { return }
        move([copy], to: group)
        state.search = ""
        state.step = .script
        state.sidebarReveal = UUID()
    }

    private func updateBreadcrumb(_ id: UUID?) {
        state.sidebarPath = id.map { path(for: $0) } ?? ""
    }

    private func expandPath(_ id: UUID) {
        updateOrganization { value in
            let group = value.membership[id]
            let parent = group.flatMap { value.parents?[$0] } ?? value.legacyProjectID
            if let i = value.projects?.firstIndex(where: { $0.id == parent }) { value.projects?[i].collapsed = false }
            if let i = value.folders.firstIndex(where: { $0.id == group }) { value.folders[i].collapsed = false }
        }
    }

    private func undoMove() {
        updateOrganization { value in
            for (id, group) in previousGroups where studio.projects.contains(where: { $0.id == id }) {
                value.membership[id] = group.flatMap { groupID in value.folders.contains { $0.id == groupID } ? groupID : nil }
            }
        }
        previousGroups = [:]
        if studio.selected != nil { state.sidebarReveal = UUID() }
    }

    private func move(_ ids: Set<UUID>, to folder: UUID?) {
        let changes = ids.filter { organization.membership[$0] != folder }
        if !changes.isEmpty { previousGroups = Dictionary(uniqueKeysWithValues: changes.map { ($0, organization.membership[$0]) }) }
        updateOrganization { value in
            let destination = value.folders.firstIndex { $0.id == folder }
            for id in ids { value.membership[id] = destination.map { value.folders[$0].id } }
            if let destination {
                value.folders[destination].collapsed = false
                if let parent = value.parents?[value.folders[destination].id],
                   let index = value.projects?.firstIndex(where: { $0.id == parent }) {
                    value.projects?[index].collapsed = false
                }
            }
        }
    }

    @ViewBuilder private func moveOptions(_ ids: Set<UUID>) -> some View {
        ForEach(organization.folders.filter { folder in projectNodes.contains { $0.id == organization.parents?[folder.id] } }) { folder in
            Button(groupLabel(folder)) { move(ids, to: folder.id) }
        }
        Button("未分组") { move(ids, to: nil) }
    }

    private var editorChoosesProject: Bool {
        switch nameTarget {
        case .narration, .folder(nil): return true
        default: return false
        }
    }

    private var editorShowsFolder: Bool {
        switch nameTarget {
        case .narration, .audio: return true
        default: return false
        }
    }

    private var editorActionTitle: String {
        switch nameTarget {
        case .narration, .project(nil), .folder(nil): return "创建"
        default: return "保存"
        }
    }

    private var canSaveName: Bool {
        guard !studio.isWorking else { return false }
        if case .project(nil) = nameTarget { return true }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .narration = nameTarget { return !narrationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    private var editorTitle: String {
        switch nameTarget {
        case .narration: return "新建配音"
        case .audio: return "编辑配音"
        case .project(let id): return id == nil ? "新建项目" : "编辑项目"
        case .folder(let id): return id == nil ? "新建分组" : "编辑分组"
        }
    }

    private func editName(_ target: NameTarget, current: String = "", folder: UUID? = nil, parent: UUID? = nil) {
        parentProject = parent ?? folder.flatMap { organization.parents?[$0] } ?? activeContainer
        nameTarget = target; name = current; projectFolder = folder; nameError = nil; narrationText = ""; editingName = true
    }

    private func saveName() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveName else { return }
        switch nameTarget {
        case .narration:
            guard let id = studio.newProject(title: title, narration: narrationText) else { return }
            if projectFolder == nil, let parentProject {
                if let group = organization.folders.first(where: { $0.name == "默认分组" && organization.parents?[$0.id] == parentProject }) {
                    projectFolder = group.id
                } else {
                    let group = SidebarOrganization.Folder(name: "默认分组")
                    updateOrganization { value in
                        value.folders.append(group)
                        value.parents?[group.id] = parentProject
                    }
                    projectFolder = group.id
                }
            }
            revealNewProject(id, step: .voice)
        case .audio(let id):
            guard studio.renameProject(id, to: title) else { return }
            placeProject(id)
        case .project(let id):
            updateOrganization { value in
                if let i = value.projects?.firstIndex(where: { $0.id == id }) {
                    value.projects?[i].name = title
                } else {
                    value.projects?.append(.init(name: title.isEmpty ? "未命名项目" : title))
                }
            }
            state.search = ""
        case .folder(let id):
            guard !organization.folders.contains(where: { $0.id != id && organization.parents?[$0.id] == (id.flatMap { organization.parents?[$0] } ?? parentProject) && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }) else {
                nameError = "已有同名分组。"
                return
            }
            updateOrganization { value in
                if let index = value.folders.firstIndex(where: { $0.id == id }) {
                    value.folders[index].name = title
                } else {
                    guard let parentProject else { return }
                    let folder = SidebarOrganization.Folder(name: title)
                    value.folders.append(folder)
                    value.parents?[folder.id] = parentProject
                    if let i = value.projects?.firstIndex(where: { $0.id == parentProject }) { value.projects?[i].collapsed = false }
                }
            }
        }
        editingName = false
    }

    private func revealNewProject(_ id: UUID, step: WorkStep) {
        state.search = ""
        state.step = step
        managing = false
        checked = []
        placeProject(id)
    }

    private func placeProject(_ id: UUID) {
        move([id], to: projectFolder)
        currentGroup = projectFolder
        currentContainer = projectFolder.flatMap { organization.parents?[$0] } ?? projectNodes.first?.id
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
            if !state.sidebarPath.isEmpty {
                Button { state.sidebarReveal = UUID() } label: {
                    Label(state.sidebarPath + " / " + project.title, systemImage: "sidebar.left")
                        .lineLimit(1)
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 10)
                    .help("在左栏定位此配音")
            }
            WorkspaceHeader(state: state, project: project)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch state.step {
                    case .script: ScriptStep(state: state, project: project)
                    case .voice: VoiceStep(project: project).id(project.id)
                    case .review: ReviewStep(state: state, project: project)
                    case .export: ExportStep(state: state, project: project)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                StepInspector(state: state, project: project).frame(width: 280)
            }
            Divider()
            if let failed = studio.failedSegments[project.id],
               let index = project.segments.firstIndex(where: { $0.id == failed }), !studio.isWorking {
                HStack {
                    Text("第 \(index + 1) 段生成未完成").foregroundStyle(.orange)
                    Spacer()
                    Button("重试本段") { studio.generate(only: failed) }
                    Button("继续剩余段落") { studio.prepareReview(); state.showReview = true }
                    if !studio.diagnostic.isEmpty { Button("复制诊断") { studio.copyDiagnostic() } }
                }.padding(10)
            }
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
    @State private var showingReplace = false
    @State private var showingDiff = false
    @State private var diff = [ManuscriptChange]()
    @State private var manuscriptJump: Int?
    @State private var find = ""
    @State private var replacement = ""
    private var matches: [String] {
        guard !find.isEmpty else { return [] }
        return project.fullText.components(separatedBy: "\n").filter { $0.contains(find) }
    }
    private var oversizedLines: Int {
        guard project.isLongMode else { return 0 }
        return project.fullText.split(whereSeparator: \.isNewline).filter {
            $0.count > project.chunkLimit
        }.count
    }
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
                if project.isLongMode { Button("查找与替换…") { showingReplace = true }.disabled(studio.isWorking) }
                if let baseline = project.lastGeneratedManuscript, project.isLongMode {
                    Button("与上次生成对比…") {
                        diff = ManuscriptChange.compare(baseline, project.fullText)
                        showingDiff = true
                    }
                }
                Text(progressText).font(.caption).foregroundStyle(.secondary)
            }
            if oversizedLines > 0 {
                HStack {
                    Text("\(oversizedLines) 行超过当前服务的 \(project.chunkLimit) 字分段上限。").foregroundStyle(.orange)
                    Button("预览分段…") { studio.prepareReview(); state.showReview = true }
                }.font(.caption)
            }
            if project.isLongMode {
                ScriptTextEditor(projectID: project.id, text: Binding(get: { project.fullText }, set: { text in
                    guard studio.selected == project.id else { return }
                    studio.editLive { $0.longText = text }
                }), jumpTo: $manuscriptJump)
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
        .sheet(isPresented: $showingDiff) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("与上次生成的文稿对比").font(.headline)
                    Spacer(); Button("完成") { showingDiff = false }
                }
                if diff.isEmpty { Text("文稿没有改动。") }
                List(Array(diff.enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .top) {
                        Label(change.added ? "新增" : "删除", systemImage: change.added ? "plus.circle" : "minus.circle")
                            .foregroundStyle(change.added ? .green : .red)
                        Text(change.text).textSelection(.enabled)
                        Spacer()
                        if let offset = change.offset {
                            Button(change.added ? "定位原文" : "定位删除处") {
                                showingDiff = false
                                manuscriptJump = offset
                            }
                        }
                    }
                }
                Button("查看生成影响…") {
                    showingDiff = false
                    studio.prepareReview()
                    DispatchQueue.main.async { state.showReview = true }
                }
            }.padding(20).frame(width: 620, height: 420)
        }
        .sheet(isPresented: $showingReplace) {
            VStack(alignment: .leading, spacing: 10) {
                Text("查找与替换").font(.headline)
                TextField("查找文字", text: $find)
                TextField("替换为（留空则移除）", text: $replacement)
                Text("命中 \(matches.count) 行").font(.caption)
                List(Array(matches.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading) {
                        Text(line)
                        Text(line.replacingOccurrences(of: find, with: replacement)).foregroundStyle(.secondary)
                    }.font(.caption)
                }
                HStack {
                    Button("取消") { showingReplace = false }
                    Spacer()
                    Button("全部替换") { replaceAll() }.disabled(matches.isEmpty || studio.isWorking)
                    Button("替换并预览生成") { replaceAll(preview: true) }.disabled(matches.isEmpty || studio.isWorking)
                }
            }.padding(20).frame(width: 490, height: 380)
        }

    }
    func replaceAll(preview: Bool = false) {
        guard !find.isEmpty, studio.selected == project.id, !studio.isWorking else { return }
        let old = project.fullText
        let new = old.replacingOccurrences(of: find, with: replacement)
        let affected = project.segments.filter { $0.text.contains(find) }.count
        studio.edit { $0.longText = new }
        studio.status = "已替换文稿；原有 \(affected) 段命中。可打开生成预览核对实际受影响段落。"
        showingReplace = false
        if preview { studio.prepareReview(); state.showReview = true }
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
    @State private var chosenPreset: VoicePreset?
    @State private var proposedService: ServiceProfile?
    var body: some View {
        Form {
            Section("配音服务") {
                Picker("服务", selection: Binding(get: { proposedService?.id ?? service.id }, set: { id in
                    proposedService = studio.catalog.profiles.first { $0.id == id && $0.enabled && $0.id != service.id }
                })) {
                    ForEach(studio.catalog.profiles.filter { $0.enabled || $0.id == service.id }) { profile in
                        Text(profile.name + (profile.enabled ? "" : "（已停用）")).tag(profile.id)
                    }
                }
                if let proposedService {
                    let before = service.voiceCapabilities(voice: project.settings.voice, direction: project.settings.direction)
                    let after = proposedService.voiceCapabilities(voice: proposedService.voices.first ?? "", direction: project.settings.direction)
                    LabeledContent("语速", value: before.speed + " → " + after.speed)
                    LabeledContent("前后文", value: before.context + " → " + after.context)
                    LabeledContent("表达", value: before.expression + " → " + after.expression)
                    LabeledContent("音色", value: project.settings.voice + " → " + (proposedService.voices.first ?? "未配置"))
                    HStack {
                        Button("取消切换") { self.proposedService = nil }
                        Button("确认切换") { studio.selectService(proposedService.id); self.proposedService = nil }
                            .disabled(studio.isWorking)
                    }
                }
                Text(expressionNote).font(.caption).foregroundStyle(.secondary)
                LabeledContent("模型") { Text(service.model).textSelection(.enabled).foregroundStyle(.secondary) }
                if service.kind == .volcengine && service.model != "seed-tts-2.0" && project.settings.voice == ServiceProfile.volcVVVoice {
                    Text("当前资源与 VV 音色不匹配，请在服务设置中切换 2.0 或填写对应 speaker。").font(.caption).foregroundStyle(Palette.warn)
                }
                if studio.catalog.profiles.first(where: { $0.id == service.id }) != service {
                    Button("应用最新服务配置") { studio.selectService(service.id) }
                }
            }
            if !studio.presets.isEmpty {
                Section("常用预设") {
                    Menu("选择配音预设") {
                        ForEach(studio.presets) { preset in Button(preset.name) { chosenPreset = preset } }
                    }.disabled(studio.isWorking)
                    if let preset = chosenPreset {
                        LabeledContent("服务", value: "\(service.name) → \(preset.settings.resolvedService.name)")
                        LabeledContent("音色", value: "\(project.settings.voice) → \(preset.settings.voice)")
                        LabeledContent("语速", value: "\(project.settings.speed)× → \(preset.settings.speed)×")
                        LabeledContent("段间停顿", value: "\(project.settings.pause) 秒 → \(preset.settings.pause) 秒")
                        LabeledContent("场景", value: "\(project.settings.mode) → \(preset.settings.mode)")
                        if project.settings.direction != preset.settings.direction { Text("表达指令也会更新。").font(.caption) }
                        if project.levelsEnabled != preset.normalize { Text("响度匹配也会更新。").font(.caption) }
                        Button("应用预设") { studio.applyPreset(preset, create: false); chosenPreset = nil }
                            .disabled(studio.isWorking)
                    }
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
                if studio.player != nil { studio.togglePause() } else { studio.playAll(resume: true) }
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
                if let active = studio.activeSegment, let index = project.segments.firstIndex(where: { $0.id == active }) {
                    Text("第 \(index + 1) / \(project.segments.count) 段" + (studio.pauseRequested ? " · 保存后暂停" : " · 正在处理")).font(.caption2)
                } else if let failed = studio.failedSegments[project.id], let index = project.segments.firstIndex(where: { $0.id == failed }) {
                    Text("第 \(index + 1) 段待重试").font(.caption2).foregroundStyle(.orange)
                }
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
