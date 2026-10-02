import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version06Tests: XCTestCase {
    func testAnchoredEditingAndChapters() throws {
        var p = Project()
        let first = String(repeating: "甲", count: 120)
        let middle = String(repeating: "乙", count: 700)
        let last = String(repeating: "丙", count: 600)
        p.longText = first + middle + last; p.prepareLongDocument()
        let ids = p.segments.map(\.id)
        p.longText = first + "新增一句。" + middle + last; p.prepareLongDocument()
        XCTAssertEqual(p.segments.map(\.text).joined(), p.longText!)
        XCTAssertTrue(ids.allSatisfy { id in p.segments.contains { $0.id == id } })
        p.longText = first + String(repeating: "乙", count: 350) + "改" + String(repeating: "乙", count: 349) + last
        p.prepareLongDocument()
        XCTAssertEqual(p.segments.first?.id, ids.first)
        XCTAssertEqual(p.segments.last?.id, ids.last)
        XCTAssertEqual(p.segments.map(\.text).joined(), p.longText!)
        p.longText = "第一章 开始\n内容。\n## 第二部分\n后文。"; p.prepareLongDocument()
        XCTAssertEqual(p.chapters.count, 2)
        XCTAssertEqual(p.chapters.map { $0.segmentIDs.count }, [2, 2])
        XCTAssertEqual(Set(p.chapters.flatMap(\.segmentIDs)).count, p.segments.count)
        p.longText = "同一句。\n同一句。\n同一句。"; p.prepareLongDocument()
        XCTAssertEqual(Set(p.segments.map(\.id)).count, 3)
    }
    func testDictionaryPrecedenceAndFingerprints() throws {
        var settings = VoiceSettings()
        let affected = Segment(text: "重庆银行"), unchanged = Segment(text: "今天很好")
        let oldAffected = affected.fingerprint(settings), oldUnchanged = unchanged.fingerprint(settings)
        settings.globalPronunciationRules = [PronunciationRule(word: "重庆", reading: "崇庆"), PronunciationRule(word: "银行", reading: "银航")]
        settings.pronunciationRules = [PronunciationRule(word: "重庆", reading: "重晴"), PronunciationRule(word: "晴", reading: "不会连锁")]
        XCTAssertEqual(settings.reading(affected.spokenText), "重晴银航")
        XCTAssertFalse(affected.fingerprint(settings) == oldAffected)
        XCTAssertEqual(unchanged.fingerprint(settings), oldUnchanged)
        XCTAssertEqual(affected.text, "重庆银行")
        XCTAssertEqual(PronunciationDictionary.apply("重庆银行", rules: [PronunciationRule(word: "重庆", reading: "短"), PronunciationRule(word: "重庆银行", reading: "长")]), "长")
    }
    @MainActor func testPauseResumeDictionaryPersistenceAndScope() async throws {
        let dir = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        let studio = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        studio.selectService("openai")
        studio.edit { $0.longText = "第一章 开始\n重庆欢迎你。\n第二章 继续\n今天很好。" }
        studio.saveDictionary([PronunciationRule(word: "重庆", reading: "崇庆")], global: true)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generate()
        // Request pause before the first response; generation must still save that first result.
        studio.pauseRequested = true
        await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 1)
        XCTAssertEqual(studio.project?.taskState, "已暂停")
        XCTAssertEqual(studio.project?.segments.filter { $0.current != nil }.count, 1)
        let resumed = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        XCTAssertEqual(resumed.globalDictionary.count, 1)
        let chapter = resumed.project!.chapters[0]
        resumed.generate(scope: Set(chapter.segmentIDs)); await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, 2)
        XCTAssertEqual(resumed.project!.segments[1].current?.spokenText, "崇庆欢迎你。")
        XCTAssertEqual(resumed.project!.segments[2].takes.count, 0)
        resumed.generate(); await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, 4); XCTAssertTrue(resumed.fullAudioReady)
        let unaffectedTake = resumed.project!.segments.last!.current!.id
        resumed.saveDictionary([PronunciationRule(word: "重庆", reading: "重晴")], global: true)
        XCTAssertFalse(resumed.fullAudioReady)
        resumed.generate(); await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, 5)
        XCTAssertEqual(resumed.project!.segments.last!.current!.id, unaffectedTake)
        resumed.generate(scope: Set(chapter.segmentIDs), force: true); await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, 7)
        XCTAssertEqual(resumed.project!.segments[0].takes.count, 2)
        resumed.edit { $0.taskState = "生成中" }
        let recovered = Studio(root: dir)
        XCTAssertEqual(recovered.project?.taskState, "待继续")
        XCTAssertFalse(recovered.busy)
        let before = MockProtocol.count
        resumed.saveDictionary([PronunciationRule(word: "今天", reading: String(repeating: "长", count: 800))], global: false)
        resumed.generate(); await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, before)
        XCTAssertNotNil(resumed.error)
    }
    func testQualityFindings() throws {
        let dir = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var p = Project(); p.segments = [Segment(text: "正常"), Segment(text: "音量变化"), Segment(text: "静音"), Segment(text: "缺失")]
        let fixtures = [try Version05Tests().tone(amplitude: 0.02), try Version05Tests().tone(amplitude: 0.5), try Version05Tests().tone(amplitude: 0.1, silence: 48000)]
        for i in p.segments.indices {
            let take = Take(file: "\(i).wav", fingerprint: p.segments[i].fingerprint(p.settings))
            p.segments[i].takes = [take]; p.segments[i].selectedTake = take.id
            if i < fixtures.count { try fixtures[i].write(to: dir.appendingPathComponent("Audio/\(i).wav")) }
        }
        let findings = try AudioQuality.inspect(p, root: dir)
        XCTAssertTrue(findings.contains { $0.index == 1 && $0.message.contains("8 dB") })
        XCTAssertTrue(findings.contains { $0.index == 2 && $0.message.contains("1.5") && $0.seconds == 0 })
        XCTAssertTrue(findings.contains { $0.index == 3 && $0.message.contains("缺失") })
        XCTAssertFalse(findings.contains { $0.index == 0 })
    }
}
