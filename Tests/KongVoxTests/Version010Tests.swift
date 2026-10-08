import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version010Tests: XCTestCase {
    func fixture(_ root: URL) throws -> Project {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var p = Project(); p.longText = "这是第一句。接着是第二句。\n这是结尾。"; p.prepareLongDocument(); p.normalizeVolume = false
        for i in p.segments.indices {
            let take = Take(file: "fixture-\(i).wav", fingerprint: p.segments[i].fingerprint(p.settings))
            p.segments[i].takes = [take]; p.segments[i].selectedTake = take.id
            // Non-silent deterministic local audio, four seconds per original paragraph.
            var pcm = Data(); for j in 0..<96000 { let sample = Int16((j % 80 < 40) ? 1500 : -1500); let v = UInt16(bitPattern: sample); pcm.append(UInt8(truncatingIfNeeded: v)); pcm.append(UInt8(truncatingIfNeeded: v >> 8)) }
            try AudioFiles.writePCM(pcm, to: root.appendingPathComponent("Audio").appendingPathComponent(take.file))
        }
        return p
    }
    func testLocalRepairAndContextRestore() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try fixture(root); let original = p.segments
        try p.splitForLocalRepair(original[0].id)
        XCTAssertFalse(p.sentenceMode); XCTAssertEqual(p.segments.count, 3)
        XCTAssertEqual(p.segments.last?.id, original.last?.id); XCTAssertTrue(p.segments.last!.ready(p.settings))
        XCTAssertEqual(p.archivedSegments?.first?.selectedTake, original[0].selectedTake)
        let splitIDs = p.segments.map(\.id)
        p.longText! += "\n新末尾。"; p.prepareLongDocument()
        XCTAssertEqual(Array(p.segments.prefix(3)).map(\.id), splitIDs)
        try p.restoreContextGrouping(); XCTAssertEqual(p.segments[0].id, original[0].id); XCTAssertTrue(p.segments[0].ready(p.settings))
        p.segments[0].pronunciation = "替代读法"
        XCTAssertThrowsError(try p.splitForLocalRepair(p.segments[0].id)); XCTAssertThrowsError(try p.restoreContextGrouping())
    }
    func testSeamUsesRenderedEdgesAndGap() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try fixture(root)
        let pcm = try SeamPreview.pcm(p, after: 0, root: root)
        XCTAssertEqual(pcm.count, 6 * 48000 + Int(p.gaps[0] * 24000) * 2)
        XCTAssertTrue(pcm[(3 * 48000)..<(3 * 48000 + 16800)].allSatisfy { $0 == 0 })
        p.segments[0].pauseOverride = 0
        let noGap = try SeamPreview.pcm(p, after: 0, root: root)
        XCTAssertEqual(noGap.count, 6 * 48000)
        // Fade is present at the artificial join, while the original file remains intact.
        XCTAssertEqual(Array(noGap[(3 * 48000 - 2)..<(3 * 48000 + 2)]).suffix(2), [0, 0].suffix(2))
        XCTAssertThrowsError(try SeamPreview.pcm(p, after: 1, root: root))
    }
    @MainActor func testImpactMatchesSelectedRequests() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "fixture" })
        studio.selectService("openai"); studio.edit { $0.longText = "第一句。第二句。第三句。"; $0.sentenceEditing = true }; studio.prepareReview()
        let p = studio.project!, ids = p.segments.map(\.id), chosen: Set<UUID> = [ids[0], ids[2]]
        let impact = GenerationImpact(p, selected: chosen, force: false, ready: { _ in false }, recovery: { _ in false })
        XCTAssertEqual(impact.pending, chosen); XCTAssertEqual(impact.generate, 8); XCTAssertEqual(impact.untouched, 4)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generate(scope: chosen); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 2); XCTAssertEqual(studio.project!.segments[1].takes.count, 0)
        let after = studio.project!
        let reused = GenerationImpact(after, selected: chosen, force: false, ready: { studio.ready($0, settings: after.settings) }, recovery: { _ in false })
        XCTAssertEqual(reused.generate, 0); XCTAssertEqual(reused.reuse, 8)
        let cached = GenerationImpact(after, selected: Set(ids), force: true, ready: { _ in true }, recovery: { $0.id == ids[1] })
        XCTAssertEqual(cached.generate, 8); XCTAssertEqual(cached.recover, 4)
    }
    func testCaptionEditingValidationAndInvalidation() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try fixture(root); let frames: [Int64] = [96000, 96000]
        var cues = try p.captionCues(frames: frames)
        let split = try CaptionTimeline.split(cues[0], after: 7)
        XCTAssertEqual(split.first?.start, cues[0].start); XCTAssertEqual(split.last?.end, cues[0].end)
        let joined = CaptionTimeline.merge(split[0], split[1]); XCTAssertEqual(joined.end, cues[0].end)
        cues[0].text = "剪辑字幕，与朗读原稿不同。"; cues[0].start = 100
        p.captionEdits = CaptionEdits(signature: p.captionSignature, cues: cues)
        XCTAssertTrue(try p.captionContent(frames: frames).contains("00:00:00,100"))
        XCTAssertTrue(try p.captionContent(frames: frames).contains(cues[0].text))
        let originalKey = p.captionSignature
        p.title = "改标题"; XCTAssertEqual(p.captionSignature, originalKey)
        p.settings.pause = 0.7; XCTAssertTrue(p.captionsStale); XCTAssertThrowsError(try p.captionContent(frames: frames))
        p.settings.pause = 0.35; p.segments[0].text += "变更"; XCTAssertTrue(p.captionsStale)
        var invalid = cues; invalid[1].start = 0
        XCTAssertThrowsError(try CaptionTimeline.validate(invalid, duration: 8350))
        invalid = cues; invalid[0].end = invalid[0].start
        XCTAssertThrowsError(try CaptionTimeline.validate(invalid, duration: 8350))
        invalid = cues; invalid[1].end = 999999
        XCTAssertThrowsError(try CaptionTimeline.validate(invalid, duration: 8350))
        XCTAssertThrowsError(try CaptionTimeline.split(cues[0], after: 0))
    }
    @MainActor func testCaptionPersistenceBackupAndExports() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try fixture(root); var cues = try p.captionCues(frames: [96000, 96000]); cues[0].text = "手工字幕"; cues[0].start = 125
        let studio = Studio(root: root, keyProvider: { _ in "" }); studio.projects = [p]; studio.selected = p.id
        try studio.saveCaptions(cues, signature: p.captionSignature, duration: 8350)
        p = studio.project!; let reopened = Studio(root: root)
        XCTAssertEqual(reopened.project?.captionEdits?.cues[0].text, "手工字幕")
        let urls = p.segments.map { root.appendingPathComponent("Audio").appendingPathComponent($0.current!.file) }
        let zip = root.appendingPathComponent("edited.zip")
        try ExportBundle.write(urls: urls, texts: p.segments.map(\.text), gaps: p.gaps, normalize: false, destination: zip, captionProject: p)
        let extraction = root.appendingPathComponent("extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-x", "-k", zip.path, extraction.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let exported = try String(contentsOf: extraction.appendingPathComponent("配音.srt"), encoding: .utf8)
        XCTAssertTrue(exported.contains("手工字幕")); XCTAssertTrue(exported.contains("00:00:00,125"))
        let batch = root.appendingPathComponent("batch"); try BatchExport.write([p], root: root, chapters: false, to: batch)
        let srt = try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil).first { $0.pathExtension == "srt" }!
        XCTAssertEqual(try String(contentsOf: srt, encoding: .utf8), exported)
        XCTAssertThrowsError(try BatchExport.write([p], root: root, chapters: true, to: root.appendingPathComponent("chapters")))
        let backup = root.appendingPathComponent("backup.kongvox"); try ProjectBackup.write(p, root: root, to: backup)
        let restored = try ProjectBackup.read(backup, staging: root.appendingPathComponent("restore"))
        XCTAssertFalse(restored.captionsStale); XCTAssertEqual(restored.captionEdits?.cues[0].text, "手工字幕")
        studio.edit { $0.settings.pause = 0.7 }
        XCTAssertThrowsError(try studio.saveCaptions(cues, signature: p.captionSignature, duration: 8350))
    }
    func testDictionaryPreviewPrecedenceDisableAndCategories() throws {
        let local = PronunciationRule(word: "重庆", reading: "崇庆", category: "地名")
        let global = PronunciationRule(word: "重庆", reading: "错误读法", category: "地名")
        let longer = PronunciationRule(word: "重庆银行", reading: "崇庆银航", category: "品牌")
        let preview = PronunciationDictionary.preview("重庆银行在重庆。", rules: [local, global, longer])
        XCTAssertEqual(preview.text, "崇庆银航在崇庆。"); XCTAssertEqual(preview.matches.count, 2)
        XCTAssertEqual(preview.matches.map { $0.rule.id }, [longer.id, local.id])
        var disabled = local; disabled.enabled = false
        XCTAssertEqual(PronunciationDictionary.apply("重庆", rules: [disabled, global]), "重庆")
        XCTAssertTrue(PronunciationDictionary.preview("北京", rules: [local]).matches.isEmpty)
        let old = try JSONDecoder().decode(PronunciationRule.self, from: Data("{\"id\":\"\(UUID())\",\"word\":\"重庆\",\"reading\":\"崇庆\"}".utf8))
        XCTAssertTrue(old.isEnabled); XCTAssertEqual(old.category, nil)
    }
    func testDeliveryBlocksMissingStaleAndReportsCandidates() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try fixture(root)
        var report = try DeliveryReport.inspect(p, root: root)
        XCTAssertTrue(report.audioReady); XCTAssertEqual(report.duration, 8.35); XCTAssertTrue(report.findings.isEmpty)
        var candidate = p.segments[0].current!; candidate.id = UUID(); p.segments[0].takes.append(candidate)
        report = try DeliveryReport.inspect(p, root: root); XCTAssertEqual(report.candidates, [p.segments[0].id]); XCTAssertTrue(report.audioReady)
        p.captionEdits = CaptionEdits(signature: "stale", cues: [])
        report = try DeliveryReport.inspect(p, root: root); XCTAssertNotNil(report.subtitleError); XCTAssertTrue(report.audioReady)
        p.longText! += "新的内容"; report = try DeliveryReport.inspect(p, root: root); XCTAssertFalse(report.audioReady)
        p.longText = p.preparedLongText
        try FileManager.default.removeItem(at: root.appendingPathComponent("Audio").appendingPathComponent(p.segments[1].current!.file))
        report = try DeliveryReport.inspect(p, root: root); XCTAssertFalse(report.audioReady); XCTAssertEqual(report.missing, [p.segments[1].id])
    }
}
