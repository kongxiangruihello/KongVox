import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class LongDocumentTests: XCTestCase {
    func testLegacyAndModeSwitching() throws {
        var legacy = Project(); legacy.segments = [Segment(text: "第一段"), Segment(text: "第二段")]; legacy.draft = "尚未导入的文字"
        let data = try JSONEncoder().encode(legacy)
        var p = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertTrue(p.isLongMode)
        XCTAssertEqual(p.fullText, "第一段\n\n第二段\n\n尚未导入的文字")
        let ids = p.segments.map(\.id)
        p.prepareLongDocument()
        XCTAssertEqual(Array(p.segments.prefix(2)).map(\.id), ids)
        XCTAssertEqual(p.segments.count, 3)
        XCTAssertTrue(p.draft.isEmpty)
        XCTAssertFalse(p.needsLongPreparation)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)).fullText, p.fullText)
    }
    func testReuseAndServiceLimits() throws {
        var p = Project(); p.longText = "原文一。\n\n原文二。\n\n原文一。"
        p.prepareLongDocument()
        let ids = p.segments.map(\.id)
        let take = Take(file: "test.wav", fingerprint: p.segments[0].fingerprint(p.settings))
        p.segments[0].takes = [take]; p.segments[0].selectedTake = take.id
        p.longText = "原文一。\n\n修改二。\n\n原文一。"
        p.prepareLongDocument()
        XCTAssertEqual(p.segments[0].id, ids[0]); XCTAssertEqual(p.segments[2].id, ids[2])
        XCTAssertEqual(p.segments[0].current?.id, take.id)
        XCTAssertEqual(p.archivedSegments?.first?.id, ids[1])
        p.longText = "原文一。\n\n原文二。\n\n原文一。"; p.prepareLongDocument()
        XCTAssertEqual(p.segments.map(\.id), ids)
        let original = String(repeating: "这是长文。", count: 300)
        p.longText = original; p.prepareLongDocument()
        p.settings.service = .qwenTTS
        XCTAssertTrue(p.needsLongPreparation)
        p.prepareLongDocument()
        XCTAssertTrue(p.segments.allSatisfy { $0.text.count <= 500 })
        XCTAssertEqual(p.segments.map(\.text).joined(), original)
        XCTAssertEqual(p.fullText, original)
    }
    @MainActor func testLegacyLongManuscriptDownloadRecoveryAndOverwrite() async throws {
        let root = try Version03Tests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let fixture = CosyVoiceTests()
        var legacy = Project()
        legacy.settings = fixture.settings()
        let first = String(repeating: "第一章内容。", count: 28)
        let old = String(repeating: "第二章旧稿。", count: 28)
        let revised = String(repeating: "第二章新稿。", count: 28)
        legacy.segments = [Segment(text: first), Segment(text: old)]
        for index in legacy.segments.indices {
            let take = Take(file: "old-\(index).wav", fingerprint: legacy.segments[index].fingerprint(legacy.settings),
                            spokenText: legacy.segments[index].text)
            try AudioFiles.writePCM(Data(count: 48000), to: audio.appendingPathComponent(take.file))
            legacy.segments[index].takes = [take]
            legacy.segments[index].selectedTake = take.id
        }
        try JSONEncoder().encode([legacy]).write(to: root.appendingPathComponent("projects.json"))
        let studio = Studio(root: root, client: fixture.client(), keyProvider: { _ in "fixture" })
        let destination = root.appendingPathComponent("交付.zip")
        try ExportBundle.write(urls: studio.currentURLs(), texts: [first, old], gaps: legacy.gaps,
                               normalize: false, destination: destination)
        let previous = try Data(contentsOf: destination)
        studio.edit { $0.longText = first + "\n\n" + revised }
        CosyProtocol.requests = []
        CosyProtocol.downloadStatus = 503
        defer { CosyProtocol.downloadStatus = 200 }
        studio.generate(); await studio.task?.value
        XCTAssertEqual(studio.project?.segments.first?.current?.file, "old-0.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("old-1.wav").path))
        let reopened = Studio(root: root, client: fixture.client(), keyProvider: { _ in "" })
        CosyProtocol.downloadStatus = 200
        reopened.generate(); await reopened.task?.value
        XCTAssertEqual(CosyProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        let current = try XCTUnwrap(reopened.project)
        let output = try reopened.currentURLs()
        XCTAssertEqual(current.segments.map(\.text), [first, revised])
        try ExportBundle.write(urls: output, texts: current.segments.map(\.text), gaps: current.gaps,
                               normalize: false, destination: destination)
        XCTAssertNotEqual(try Data(contentsOf: destination), previous)
        let extracted = root.appendingPathComponent("export-check")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", destination.path, extracted.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let subtitles = try String(contentsOf: extracted.appendingPathComponent("配音.srt"), encoding: .utf8)
        XCTAssertTrue(subtitles.contains(revised))
        XCTAssertFalse(subtitles.contains(old))
    }

    @MainActor func testFullGenerationResumeAndExport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        let studio = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        studio.selectService("openai")
        let article = String(repeating: "这是一篇完整文章。", count: 240)
        studio.edit { $0.longText = article }
        MockProtocol.payload = Data(repeating: 0, count: 4800); MockProtocol.status = 200
        MockProtocol.count = 0; MockProtocol.failOnRequest = 2
        studio.generate(); await studio.task?.value
        XCTAssertEqual(studio.project?.fullText, article)
        XCTAssertEqual(studio.project?.segments.filter { $0.current != nil }.count, 1)
        XCTAssertThrowsError(try studio.currentURLs())
        let failed = try XCTUnwrap(studio.project?.segments.dropFirst().first?.id)
        let resumed = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        XCTAssertEqual(resumed.project?.failedSegmentID, failed)
        XCTAssertEqual(resumed.selected.flatMap { resumed.failedSegments[$0] }, failed)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil
        resumed.generate(); await resumed.task?.value
        XCTAssertNil(resumed.project?.failedSegmentID)
        let urls = try resumed.currentURLs()
        XCTAssertEqual(MockProtocol.count, urls.count - 1)
        XCTAssertTrue(urls.count > 1)
        XCTAssertEqual(resumed.fullProgress, 1)
        let output = dir.appendingPathComponent("full.wav")
        try AudioFiles.merge(urls, pause: 0, to: output)
        XCTAssertEqual(try AudioFiles.extractPCM(Data(contentsOf: output)).count, urls.count * 4800)
        resumed.rememberDelivery(output, format: "wav", projectID: resumed.selected!)
        XCTAssertEqual(resumed.lastDelivery(for: resumed.selected!)?.signature, resumed.project?.exportSignature)
        resumed.edit {
            $0.reviewNotes = [ $0.segments[0].id: "只改备注" ]
            $0.completedReview = [ $0.segments[0].id ]
        }
        XCTAssertEqual(resumed.lastDelivery(for: resumed.selected!)?.signature, resumed.project?.exportSignature)
        resumed.edit { $0.longText = article + "修改。" }
        XCTAssertEqual(resumed.lastDelivery(for: resumed.selected!)?.changes(from: resumed.project!), ["正文已改"])
        XCTAssertFalse(resumed.fullAudioReady)
        XCTAssertThrowsError(try resumed.currentURLs())
        resumed.setLongMode(false)
        XCTAssertFalse(resumed.project!.isLongMode)
        resumed.edit { $0.segments[0].text = "精调后的第一段。" }
        resumed.setLongMode(true)
        XCTAssertTrue(resumed.project!.fullText.hasPrefix("精调后的第一段。"))
        resumed.generate(); resumed.cancel(); await resumed.task?.value
        XCTAssertFalse(resumed.busy)
    }
}
