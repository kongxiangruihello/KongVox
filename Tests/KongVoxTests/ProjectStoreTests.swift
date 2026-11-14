import Foundation
import XCTest
@testable import KongVox

final class ProjectStoreTests: XCTestCase {
    func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func project(_ title: String) -> Project { var p = Project(); p.title = title; p.longText = "正文 " + title; return p }
    func modified(_ url: URL) throws -> Date { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) }

    @MainActor func testSidebarRenameAndDeleteProjects() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        let named = try XCTUnwrap(studio.newProject(title: "新建项目"))
        XCTAssertEqual(Studio(root: root).projects.first { $0.id == named }?.title, "新建项目")
        let narration = try XCTUnwrap(studio.newProject(title: "试音", narration: "第一段。\n\n第二段。"))
        let savedNarration = try XCTUnwrap(Studio(root: root).projects.first { $0.id == narration })
        XCTAssertEqual(savedNarration.longText, "第一段。\n\n第二段。")
        XCTAssertFalse(savedNarration.segments.isEmpty)
        let retained = try XCTUnwrap(studio.projects.last)
        let deleted = Set(studio.projects.dropLast().map(\.id))
        studio.renameProject(retained.id, to: "保留项目")
        XCTAssertTrue(studio.deleteProjects(deleted))
        XCTAssertEqual(studio.selected, retained.id)
        let reopened = Studio(root: root)
        XCTAssertEqual(reopened.projects.map(\.id), [retained.id])
        XCTAssertEqual(reopened.project?.title, "保留项目")
        XCTAssertTrue(reopened.deleteProjects([retained.id]))
        XCTAssertEqual(reopened.projects.count, 1)
        XCTAssertNotEqual(reopened.selected, retained.id)
        XCTAssertEqual(Studio(root: root).selected, reopened.selected)
    }

    @MainActor func testTrashSurvivesRestartAndProtectsAudio() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        let id = try XCTUnwrap(studio.newProject(title: "待恢复", narration: "测试文稿。"))
        let take = Take(file: "retained.wav", fingerprint: "fixture")
        try AudioFiles.writePCM(Data(count: 480), to: studio.audioURL(take))
        studio.edit { $0.segments[0].takes = [take] }
        XCTAssertTrue(studio.trashProjects([id]))
        let reopened = Studio(root: root)
        XCTAssertEqual(reopened.trashedProjects.map(\.id), [id])
        XCTAssertTrue(try reopened.audioCleanupPlan().files.isEmpty)
        XCTAssertTrue(reopened.restoreProject(id))
        let restored = Studio(root: root)
        XCTAssertEqual(restored.projects.first { $0.id == id }?.longText, "测试文稿。")
        XCTAssertTrue(restored.trashedProjects.isEmpty)
    }

    @MainActor func testDuplicateAndLargeLibraryRoundTrip() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        studio.projects = (0..<100).map { project("配音 \($0)") }
        studio.selected = studio.projects.first?.id
        let id = try XCTUnwrap(studio.selected)
        let manuscript = String(repeating: "这一段用于长文生成预览。", count: 2500)
        studio.edit {
            $0.longText = manuscript
            $0.prepareLongDocument()
            let take = Take(file: "shared.wav", fingerprint: $0.segments[0].fingerprint($0.settings))
            $0.segments[0].takes = [take]
            $0.segments[0].selectedTake = take.id
        }
        let shared = try XCTUnwrap(studio.duplicateRecording(id, includeAudio: true))
        let clean = try XCTUnwrap(studio.duplicateRecording(id, includeAudio: false))
        let reopened = Studio(root: root)
        XCTAssertEqual(reopened.projects.count, 102)
        XCTAssertEqual(reopened.projects.first { $0.id == shared }?.segments.first?.current?.file, "shared.wav")
        XCTAssertTrue(reopened.projects.first { $0.id == clean }?.segments.allSatisfy { $0.takes.isEmpty } == true)
        let long = try XCTUnwrap(reopened.projects.first { $0.id == id })
        XCTAssertEqual(long.fullText, manuscript)
        let impact = GenerationImpact(long, selected: Set(long.segments.map(\.id)), force: false, ready: { _ in false }, recovery: { _ in false })
        XCTAssertEqual(impact.pending.count, long.segments.count)
    }

    func testManuscriptDiffWithUnicodeAndDeletedTail() {
        let changes = ManuscriptChange.compare("👋你好\n旧句\n保留\n删尾", "👋你好\n新句\n保留")
        XCTAssertEqual(changes.map(\.text), ["旧句", "新句", "删尾"])
        XCTAssertEqual(changes.map(\.added), [false, true, false])
        XCTAssertEqual(changes.map(\.offset), [5, 5, 10])
    }

    func testLegacyFileMigratesOnceAndIsKeptAsBackup() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = [project("甲"), project("乙"), project("丙")]
        let bytes = try JSONEncoder().encode(legacy)
        try bytes.write(to: root.appendingPathComponent("projects.json"))
        var seen = 0
        var store = ProjectStore(root: root)
        let loaded = try store.load(beforeMigrating: { projects, _ in seen = projects.count })
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(loaded.map(\.title), ["甲", "乙", "丙"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyFile.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("projects-before-0.14.json")), bytes)
        for p in legacy { XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(p.id).path)) }
        // A fresh store reads the new layout, in the same order, without migrating again.
        var again = ProjectStore(root: root)
        var migratedAgain = false
        let reloaded = try again.load(beforeMigrating: { _, _ in migratedAgain = true })
        XCTAssertFalse(migratedAgain)
        XCTAssertEqual(reloaded.map(\.id), legacy.map(\.id))
        XCTAssertEqual(reloaded.map(\.longText), legacy.map(\.longText))
    }
    func testSaveRewritesOnlyChangedProjectsAndTracksOrderAndDeletion() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var store = ProjectStore(root: root)
        XCTAssertTrue(try store.load().isEmpty)
        var projects = [project("甲"), project("乙")]
        try store.save(projects)
        let untouched = try modified(store.file(projects[0].id)), index = try modified(store.indexFile)
        Thread.sleep(forTimeInterval: 0.05)
        projects[1].title = "乙改"
        try store.save(projects)
        XCTAssertEqual(try modified(store.file(projects[0].id)), untouched)
        XCTAssertEqual(try modified(store.indexFile), index)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: Data(contentsOf: store.file(projects[1].id))).title, "乙改")
        // Reordering rewrites only the index; removing a project removes its file.
        projects.swapAt(0, 1)
        try store.save(projects)
        XCTAssertEqual(try modified(store.file(projects[1].id)), untouched)
        var reopened = ProjectStore(root: root)
        XCTAssertEqual(try reopened.load().map(\.title), ["乙改", "甲"])
        let removed = projects.removeLast()
        try store.save(projects)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(removed.id).path))
        var last = ProjectStore(root: root)
        XCTAssertEqual(try last.load().map(\.title), ["乙改"])
    }
    func testUnreadableOrMissingProjectFileFailsTheWholeLoad() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var store = ProjectStore(root: root)
        let projects = [project("甲"), project("乙")]
        try store.save(projects)
        try Data("broken".utf8).write(to: store.file(projects[1].id))
        var damaged = ProjectStore(root: root)
        XCTAssertThrowsError(try damaged.load())
        try FileManager.default.removeItem(at: store.file(projects[1].id))
        var missing = ProjectStore(root: root)
        XCTAssertThrowsError(try missing.load())
    }
    func testProjectFilesSurviveALostOrStaleIndex() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var store = ProjectStore(root: root)
        let projects = [project("甲"), project("乙")]
        try store.save(projects)
        // Index knows only the first project.
        try JSONEncoder().encode([projects[0].id]).write(to: store.indexFile)
        var stale = ProjectStore(root: root)
        let recovered = try stale.load()
        XCTAssertEqual(Set(recovered.map(\.id)), Set(projects.map(\.id)))
        XCTAssertEqual(recovered.first?.id, projects[0].id)
        try stale.save(recovered)
        XCTAssertEqual(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: store.indexFile)), recovered.map(\.id))
        // Index gone entirely: the files are still found, and an old projects.json is not migrated over them.
        try FileManager.default.removeItem(at: store.indexFile)
        try JSONEncoder().encode([project("旧")]).write(to: store.legacyFile)
        var lost = ProjectStore(root: root)
        XCTAssertEqual(Set(try lost.load().map(\.id)), Set(projects.map(\.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.legacyFile.path))
    }
    @MainActor func testStudioDoesNotSaveOverAProjectItCouldNotRead() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var store = ProjectStore(root: root)
        let projects = [project("甲"), project("乙")]
        try store.save(projects)
        try Data("broken".utf8).write(to: store.file(projects[1].id))
        let good = try Data(contentsOf: store.file(projects[0].id))
        let studio = Studio(root: root, keyProvider: { _ in "" })
        XCTAssertNotNil(studio.error)
        XCTAssertFalse(studio.save())
        XCTAssertEqual(try String(contentsOf: store.file(projects[1].id), encoding: .utf8), "broken")
        XCTAssertEqual(try Data(contentsOf: store.file(projects[0].id)), good)
    }
}
