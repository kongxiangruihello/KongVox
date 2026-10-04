import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version09Tests: XCTestCase {
    func testSentenceEditingReuseAndLegacy() throws {
        let source = "价格3.14元。她说：“今天出发！” Next sentence. 最后一句。"
        XCTAssertEqual(SentenceText.split(source).joined(), source)
        XCTAssertTrue(SentenceText.split(source)[0].contains("3.14"))
        var p = Project(); p.longText = "第一句。第二句！第三句。"; p.sentenceEditing = true; p.prepareLongDocument()
        XCTAssertEqual(p.segments.map(\.text), ["第一句。", "第二句！", "第三句。"])
        for i in p.segments.indices {
            let take = Take(file: "\(i).wav", fingerprint: p.segments[i].fingerprint(p.settings))
            p.segments[i].takes = [take]; p.segments[i].selectedTake = take.id
        }
        let ids = p.segments.map(\.id)
        p.longText = "第一句。改了第二句！第三句。"; p.prepareLongDocument()
        XCTAssertEqual(p.segments[0].id, ids[0]); XCTAssertEqual(p.segments[2].id, ids[2])
        XCTAssertTrue(p.segments[0].ready(p.settings)); XCTAssertFalse(p.segments[1].ready(p.settings)); XCTAssertEqual(p.archivedSegments?.first?.id, ids[1])
        p.longText = "第一句。第二句！第三句。"; p.prepareLongDocument()
        XCTAssertEqual(p.segments.map(\.id), ids)
        XCTAssertTrue(p.segments.allSatisfy { $0.ready(p.settings) })
        var legacy = Project(); legacy.longText = "第一句。第二句！第三句。"; legacy.prepareLongDocument()
        XCTAssertEqual(legacy.segments.count, 1)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(legacy))
        XCTAssertFalse(restored.sentenceMode); XCTAssertFalse(restored.needsLongPreparation)
        let long = String(repeating: "长", count: 1600) + "。"
        XCTAssertTrue(SentenceText.chunks(long, limit: 500).allSatisfy { $0.text.count <= 500 })
    }
    @MainActor func testPrecisionSpeedPauseAndRequest() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "fixture" })
        studio.selectService("openai"); studio.edit { $0.longText = "第一句。第二句。"; $0.sentenceEditing = true }; studio.prepareReview()
        let first = studio.project!.segments[0], original = first.fingerprint(studio.project!.settings)
        studio.savePrecision(first.id, pronunciation: "", speed: nil, pause: 1.25)
        XCTAssertEqual(studio.project!.segments[0].fingerprint(studio.project!.settings), original)
        XCTAssertEqual(studio.project!.gaps[0], 1.25)
        studio.savePrecision(first.id, pronunciation: "替代读法。", speed: 1.2, pause: 1.25)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generate(only: first.id); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 1)
        let body = try JSONSerialization.jsonObject(with: MockProtocol.captured!.httpBody!) as! [String: Any]
        XCTAssertEqual(body["speed"] as? Double, 1.2); XCTAssertEqual(body["input"] as? String, "替代读法。")
        XCTAssertEqual(studio.project!.segments[0].current?.settings?.speed, 1.2)
        XCTAssertTrue(studio.project!.segments[0].ready(studio.project!.settings))
        XCTAssertEqual(studio.project!.segments[0].text, "第一句。")
        let reopened = Studio(root: root); XCTAssertEqual(reopened.project!.gaps[0], 1.25); XCTAssertEqual(reopened.project!.segments[0].speedOverride, 1.2)
        studio.savePrecision(first.id, pronunciation: "", speed: 5, pause: 1); XCTAssertNotNil(studio.error)
        studio.stop()
    }
    func testSentenceSubtitlesAndVerticalTiming() throws {
        let result = try Subtitles.render(texts: ["甲。乙。", "结尾。"], frames: [24000,24000], gaps: [0.35,0], style: .sentence)
        XCTAssertTrue(result.contains("00:00:00,000 --> 00:00:00,500"))
        XCTAssertTrue(result.contains("00:00:00,500 --> 00:00:01,000"))
        XCTAssertTrue(result.contains("00:00:01,350 --> 00:00:02,350"))
        let vertical = try Subtitles.render(texts: [String(repeating: "字", count: 80)], frames: [48000], gaps: [0], style: .vertical)
        let cues = vertical.components(separatedBy: "\n\n")
        XCTAssertEqual(cues.count, 3)
        for cue in cues {
            let lines = cue.components(separatedBy: "\n").dropFirst(2).filter { !$0.isEmpty }
            XCTAssertTrue(lines.count <= 2); XCTAssertTrue(lines.allSatisfy { $0.count <= 16 })
        }
        XCTAssertTrue(vertical.contains("00:00:02,000"))
        XCTAssertThrowsError(try Subtitles.render(texts: ["甲。乙。"], frames: [20], gaps: [0], style: .sentence))
        let tiny = try Subtitles.render(texts: ["甲。" + String(repeating: "乙", count: 100) + "。"], frames: [48], gaps: [0], style: .sentence)
        XCTAssertTrue(tiny.contains("00:00:00,000 --> 00:00:00,001"))
        XCTAssertTrue(tiny.contains("00:00:00,001 --> 00:00:00,002"))
    }
    @MainActor func testPreflightWithoutPaidRequests() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "" })
        studio.selectService("openai"); studio.edit { $0.longText = "正文。" }
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil
        studio.checkConfiguration(); XCTAssertTrue(studio.preflightMessage.contains("API Key")); XCTAssertEqual(MockProtocol.count, 0)
        studio.generate(); await studio.task?.value; XCTAssertEqual(MockProtocol.count, 0); XCTAssertNotNil(studio.error)
        var p = studio.project!; p.settings.voice = "missing"
        XCTAssertTrue(ServicePreflight.inspect(p, catalog: studio.catalog).contains { $0.blocking && $0.message.contains("声音") })
        p.settings.voice = "marin"; p.segments[0].speedOverride = .infinity
        XCTAssertTrue(ServicePreflight.inspect(p, catalog: studio.catalog).contains { $0.blocking && $0.message.contains("语速") })
        p.segments[0].speedOverride = nil; p.settings.service?.baseURL = "http://unsafe.example"
        XCTAssertTrue(ServicePreflight.inspect(p, catalog: studio.catalog).contains(where: \.blocking))
    }
    @MainActor func testVoiceFavoritesCacheAndIsolation() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "private-fixture-key" })
        studio.selectService("openai"); studio.favoriteCurrentVoice(name: "自然旁白", tags: "文章")
        studio.edit { $0.settings.voice = "cedar" }; studio.favoriteCurrentVoice(name: "另一种声音", tags: "比较")
        let original = studio.project!, ids = Set(studio.voiceFavorites.map(\.id))
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.compareFavorites(ids: ids, text: "同一句话。"); await studio.task?.value; XCTAssertEqual(MockProtocol.count, 2)
        studio.compareFavorites(ids: ids, text: "同一句话。"); await studio.task?.value; XCTAssertEqual(MockProtocol.count, 2)
        studio.compareFavorites(ids: ids, text: "另一句话。"); await studio.task?.value; XCTAssertEqual(MockProtocol.count, 4)
        XCTAssertEqual(studio.project!.segments.count, original.segments.count); XCTAssertEqual(studio.project!.settings, original.settings)
        let data = try String(contentsOf: root.appendingPathComponent("voices.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("private-fixture-key"))
        XCTAssertEqual(Studio(root: root).voiceFavorites.count, 2)
        studio.useFavorite(studio.voiceFavorites[0]); XCTAssertEqual(studio.project!.settings.voice, "marin")
    }
    func testReadingAndCompletionReport() throws {
        let reading = ReadingPreview.suggest("2026-10-04，API共3.14元。")
        XCTAssertTrue(reading.contains("二零二六年十月四日")); XCTAssertTrue(reading.contains("A P I")); XCTAssertTrue(reading.contains("三点一四"))
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try Version07Tests().fixture(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Audio/" + p.segments.last!.current!.file))
        let report = CompletionReport.make(p, root: root).lines.joined(separator: "\n")
        XCTAssertTrue(report.contains("开头：音频已保存")); XCTAssertTrue(report.contains("结尾：缺失或待更新")); XCTAssertTrue(report.contains("1 / 2"))
        var updated = p; updated.longText = "新插入一句。\n" + p.fullText
        XCTAssertTrue(CompletionReport.make(updated, root: root).lines.joined().contains("开头：缺失或待更新"))
    }
}
