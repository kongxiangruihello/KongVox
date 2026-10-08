import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

/// Regression tests for the 2026-10 code review fixes.
final class ReviewFixTests: XCTestCase {
    static func wave(_ seconds: Double, amplitude: Int16) -> [Int16] {
        (0..<Int(seconds * 24000)).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }
    static func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { let raw = UInt16(bitPattern: sample); data.append(UInt8(truncatingIfNeeded: raw)); data.append(UInt8(truncatingIfNeeded: raw >> 8)) }
        return data
    }
    static func sample(_ data: Data, _ index: Int) -> Int16 { Int16(bitPattern: UInt16(data[2 * index]) | UInt16(data[2 * index + 1]) << 8) }

    // Fix 1: stale manual captions no longer dead-lock the editor and exports.
    @MainActor func testStaleManualCaptionsCanBeReplacedOrCleared() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try Version010Tests().fixture(root); let frames: [Int64] = [96000, 96000]
        let studio = Studio(root: root, keyProvider: { _ in "" }); studio.projects = [p]; studio.selected = p.id
        var cues = try p.captionCues(frames: frames); cues[0].text = "手工字幕"
        try studio.saveCaptions(cues, signature: p.captionSignature, duration: 8350)
        // Current manual captions are used for export, but the automatic draft ignores them.
        XCTAssertTrue(try studio.project!.captionContent(frames: frames).contains("手工字幕"))
        XCTAssertFalse(try studio.project!.autoCaptionCues(frames: frames).contains { $0.text == "手工字幕" })
        studio.edit { $0.settings.pause = 0.7 }
        let stale = studio.project!
        XCTAssertTrue(stale.captionsStale)
        XCTAssertThrowsError(try stale.captionContent(frames: frames))
        XCTAssertEqual(try stale.autoCaptionCues(frames: frames).count, 2)
        studio.clearCaptionEdits()
        XCTAssertNil(studio.project!.captionEdits)
        XCTAssertTrue(try studio.project!.captionContent(frames: frames).contains("这是结尾"))
    }

    // Fix 2: boundaries move only to a clearly quieter point near the estimate; quiet commas far away are ignored.
    func testLocalPausesSearchNearEstimate() throws {
        let speech: Int16 = 8000
        let samples = Self.wave(1.0, amplitude: speech) + Self.wave(0.3, amplitude: 5) + Self.wave(1.0, amplitude: speech)
            + Self.wave(0.3, amplitude: 60) + Self.wave(2.0, amplitude: speech)
        let texts = ["甲甲甲甲，乙乙乙乙。丙丙丙丙丙丙。"], frames = [Int64(samples.count)], gaps = [0.0]
        let baseline = try Subtitles.cues(texts: texts, frames: frames, gaps: gaps, style: .sentence)
        XCTAssertEqual(baseline[0].end, 2706)
        let cues = try Version011Tools.localPauseCues(texts: texts, frames: frames, gaps: gaps, style: .sentence, pcm: Self.pcm(samples))
        // The real sentence pause is 2300–2600 ms; the quieter comma at 1000–1300 ms is outside the search window.
        XCTAssertTrue((2300...2600).contains(cues[0].end))
        XCTAssertEqual(cues[1].start, cues[0].end)
        // Without any pause the proportional estimate stays.
        let flat = Self.wave(4.6, amplitude: speech)
        let unchanged = try Version011Tools.localPauseCues(texts: texts, frames: [Int64(flat.count)], gaps: gaps, style: .sentence, pcm: Self.pcm(flat))
        XCTAssertEqual(unchanged.map(\.end), try Subtitles.cues(texts: texts, frames: [Int64(flat.count)], gaps: gaps, style: .sentence).map(\.end))
    }

    // Fix 3: one readiness rule everywhere, including context hints and non-selected projects.
    @MainActor func testReadinessIncludesContextEverywhere() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try Version010Tests().fixture(root)
        p.settings.contextHintEnabled = true
        for i in p.segments.indices { p.segments[i].takes[0].fingerprint = p.segments[i].fingerprint(p.settings) }
        XCTAssertTrue(p.segments[0].ready(p.settings))
        XCTAssertFalse(p.isReady(p.segments[0], root: root))
        XCTAssertEqual(try DeliveryReport.inspect(p, root: root).missing.count, 2)
        XCTAssertThrowsError(try BatchExport.write([p], root: root, chapters: false, to: root.appendingPathComponent("stale-batch")))
        for i in p.segments.indices { p.segments[i].contextFingerprint = p.contextFingerprint(for: p.segments[i].id) }
        XCTAssertTrue(p.isReady(p.segments[0], root: root))
        XCTAssertTrue(try DeliveryReport.inspect(p, root: root).audioReady)
        // A non-selected project is judged by its own context, so queue estimates no longer count it as pending.
        let studio = Studio(root: root, keyProvider: { _ in "" })
        let other = studio.makeProject(); studio.projects = [other, p]; studio.selected = other.id
        XCTAssertTrue(studio.ready(p.segments[0], in: p))
        XCTAssertEqual(studio.queueCharacters(p), 0)
    }

    // Fix 5: versions move out of projects.json; high-frequency edits are saved after a pause or on flush.
    @MainActor func testVersionsMigrateAndLiveEditsFlush() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var legacy = Project(); legacy.title = "迁移"
        let version = ProjectVersion(label: "旧版", payload: try JSONEncoder().encode(legacy))
        legacy.versions = [version]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("projects.json")
        try JSONEncoder().encode([legacy]).write(to: file)
        let studio = Studio(root: root, keyProvider: { _ in "" })
        XCTAssertNil(studio.project?.versions)
        XCTAssertEqual(studio.versions(for: legacy.id).map(\.id), [version.id])
        XCTAssertNil(try JSONDecoder().decode([Project].self, from: Data(contentsOf: file)).first?.versions)
        studio.editLive { $0.title = "防抖标题" }
        XCTAssertEqual(studio.project?.title, "防抖标题")
        XCTAssertEqual(try JSONDecoder().decode([Project].self, from: Data(contentsOf: file)).first?.title, "迁移")
        studio.flushPendingSave()
        XCTAssertEqual(try JSONDecoder().decode([Project].self, from: Data(contentsOf: file)).first?.title, "防抖标题")
        XCTAssertEqual(Studio(root: root).versions(for: legacy.id).count, 1)
    }

    // Fix 6: unreferenced audio cleanup keeps files used by versions; deleting a project removes its records.
    @MainActor func testCleanupKeepsReferencedAudioAndDeleteProject() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try Version010Tests().fixture(root)
        let studio = Studio(root: root, keyProvider: { _ in "" }); studio.projects = [p]; studio.selected = p.id
        let audio = root.appendingPathComponent("Audio")
        try AudioFiles.writePCM(Data(count: 4800), to: audio.appendingPathComponent("orphan.wav"))
        try AudioFiles.writePCM(Data(count: 4800), to: audio.appendingPathComponent("versioned.wav"))
        var snapshot = p; snapshot.segments[0].takes.append(Take(file: "versioned.wav", fingerprint: "older"))
        try studio.writeVersions([ProjectVersion(label: "旧版", payload: try JSONEncoder().encode(snapshot))], for: p.id)
        let plan = try studio.audioCleanupPlan()
        XCTAssertEqual(plan.files.map(\.lastPathComponent), ["orphan.wav"])
        studio.cleanUnreferencedAudio(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.appendingPathComponent("orphan.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("versioned.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("fixture-0.wav").path))
        let other = studio.makeProject(); studio.projects = [p, other]; studio.selected = p.id
        studio.queue = [QueueEntry(projectID: p.id)]
        studio.deleteProject(p.id)
        XCTAssertEqual(studio.projects.map(\.id), [other.id]); XCTAssertEqual(studio.selected, other.id)
        XCTAssertTrue(studio.queue.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: studio.versionsFile(p.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("fixture-0.wav").path))
    }

    // Fixes 4 and 8: seam preview uses the export treatment; streamed seams keep the same timeline.
    func testSeamPreviewMatchesExportTreatment() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try Version010Tests().fixture(root); p.segments[0].pauseOverride = 0
        let plain = try SeamPreview.pcm(p, after: 0, root: root)
        p.seamOptions = SeamOptions(crossfadeMilliseconds: 40, gainAdjustment: 0, loopSeamPreview: true)
        let faded = try SeamPreview.pcm(p, after: 0, root: root)
        XCTAssertEqual(plain.count, faded.count)
        // 500 samples before the join lies inside the 40 ms fade but outside the 5 ms trim fade.
        XCTAssertTrue(abs(Int(Self.sample(faded, 71500))) < abs(Int(Self.sample(plain, 71500))))
        let urls = p.segments.map { root.appendingPathComponent("Audio").appendingPathComponent($0.current!.file) }
        let streamed = root.appendingPathComponent("seamed.wav")
        let withSeams = try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: false, to: streamed, seam: p.resolvedSeam)
        XCTAssertEqual(withSeams, try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: false))
        XCTAssertEqual(try AudioFiles.extractPCM(Data(contentsOf: streamed)).count, Int(withSeams.reduce(0, +)) * 2)
    }

    // Fix 7 and minor items: ASS escaping, safe names, date reading after Chinese text, GB18030 import.
    func testExportTextAndImportDetails() throws {
        XCTAssertEqual(Version011Tools.assText("a{b}\\c\nd"), "a｛b｝＼c\\Nd")
        XCTAssertEqual(BatchExport.safeName("上/下:篇"), "上-下-篇")
        XCTAssertTrue(ReadingPreview.suggest("于2026-10-04发布").contains("二零二六年十月四日"))
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("旧稿.txt")
        try XCTUnwrapData("中文测试稿".data(using: DocumentImport.gb18030)).write(to: file)
        XCTAssertEqual(try DocumentImport.read(file).text, "中文测试稿")
        let existing = root.appendingPathComponent("已存在")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ShortVideoExport.write(Project(), urls: [], root: root, to: existing))
    }
    func XCTUnwrapData(_ value: Data?) throws -> Data {
        guard let value else { throw VoxError(message: "编码失败") }
        return value
    }
}
