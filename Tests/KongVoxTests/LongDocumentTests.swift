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
        let resumed = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil
        resumed.generate(); await resumed.task?.value
        let urls = try resumed.currentURLs()
        XCTAssertEqual(MockProtocol.count, urls.count - 1)
        XCTAssertTrue(urls.count > 1)
        XCTAssertEqual(resumed.fullProgress, 1)
        let output = dir.appendingPathComponent("full.wav")
        try AudioFiles.merge(urls, pause: 0, to: output)
        XCTAssertEqual(try AudioFiles.extractPCM(Data(contentsOf: output)).count, urls.count * 4800)
        resumed.edit { $0.longText = article + "修改。" }
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
