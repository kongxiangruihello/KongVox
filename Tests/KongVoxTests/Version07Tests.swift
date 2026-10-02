import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version07Tests: XCTestCase {
    func fixture(_ root: URL) throws -> Project {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        var p = Project(); p.longText = "第一段。\n第二段。"; p.prepareLongDocument()
        p.settings.globalPronunciationRules = [PronunciationRule(word: "第一", reading: "第壹")]
        for i in p.segments.indices {
            for _ in 0..<2 {
                let take = Take(file: "\(UUID()).wav", fingerprint: p.segments[i].fingerprint(p.settings), settings: p.settings, spokenText: p.settings.reading(p.segments[i].text))
                try Version05Tests().tone(amplitude: 0.1).write(to: root.appendingPathComponent("Audio").appendingPathComponent(take.file))
                p.segments[i].takes.append(take)
            }
            p.segments[i].selectedTake = p.segments[i].takes.first!.id
        }
        return p
    }
    func testTimelineFromRenderedFrames() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try fixture(root), gaps = [0.35, 0.0]
        let output = root.appendingPathComponent("full.wav")
        let frames = try AudioAssembly.render(urls: p.segments.map { root.appendingPathComponent("Audio/" + $0.current!.file) }, gaps: gaps, normalize: true, to: output)
        let cues = try PlaybackTimeline.make(ids: p.segments.map(\.id), frames: frames, gaps: gaps)
        XCTAssertEqual(cues[1].start, 1.35)
        XCTAssertEqual(PlaybackTimeline.current(1.2, cues: cues), p.segments[0].id)
        XCTAssertEqual(PlaybackTimeline.current(1.35, cues: cues), p.segments[1].id)
        XCTAssertEqual(PlaybackTimeline.current(999, cues: cues), p.segments[1].id)
        XCTAssertTrue(PlaybackTimeline.current(.nan, cues: cues) == nil)
        XCTAssertEqual(Double(try AudioFiles.extractPCM(Data(contentsOf: output)).count) / 48000, cues.last!.end)
        XCTAssertThrowsError(try PlaybackTimeline.make(ids: [UUID()], frames: [], gaps: []))
    }
    @MainActor func testAuditionAndAdoption() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "fixture" })
        let p = try fixture(root); studio.projects = [p]; studio.selected = p.id
        let segment = p.segments[0], original = segment.selectedTake
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generate(only: segment.id, audition: true); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 1)
        XCTAssertEqual(studio.project!.segments[0].selectedTake, original)
        let candidate = studio.project!.segments[0].takes.first!
        studio.adoptTake(segmentID: segment.id, takeID: candidate.id)
        XCTAssertEqual(studio.project!.segments[0].selectedTake, candidate.id)
        studio.updatePronunciation(segment.id, text: "改读法。")
        studio.adoptTake(segmentID: segment.id, takeID: original!)
        XCTAssertNotNil(studio.error)
        XCTAssertEqual(studio.project!.segments[0].selectedTake, candidate.id)
        XCTAssertEqual(studio.project!.fullText, p.fullText)
        studio.stop()
        studio.updatePronunciation(segment.id, text: "")
        studio.playAll(from: p.segments[1].id); await studio.task?.value
        XCTAssertEqual(studio.readingSegment, p.segments[1].id)
        studio.seek(0); XCTAssertEqual(studio.readingSegment, p.segments[0].id)
        studio.stop(); XCTAssertTrue(studio.playbackCues.isEmpty)
    }
    @MainActor func testBackupRoundTripAndIsolation() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try fixture(root)
        let archive = root.appendingPathComponent("test.kongvox")
        try ProjectBackup.write(p, root: root, to: archive)
        let studio = Studio(root: root); studio.projects = [p]; studio.selected = p.id; studio.save()
        studio.restoreProject(from: archive); await studio.task?.value
        XCTAssertEqual(studio.projects.count, 2)
        let restored = studio.project!
        XCTAssertFalse(restored.id == p.id)
        XCTAssertEqual(restored.fullText, p.fullText)
        XCTAssertEqual(restored.segments.map { $0.takes.count }, [2,2])
        XCTAssertTrue(restored.segments.allSatisfy { $0.ready(restored.settings) })
        XCTAssertTrue(ProjectBackup.fileNames(p).isDisjoint(with: ProjectBackup.fileNames(restored)))
        XCTAssertTrue(ProjectBackup.fileNames(restored).allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio/" + $0).path) })
        studio.saveDictionary([PronunciationRule(word: "第一", reading: "changed")], global: true)
        XCTAssertEqual(studio.project!.settings.reading("第一"), "第壹")
        let reloaded = Studio(root: root)
        XCTAssertEqual(reloaded.projects.first!.settings.reading("第一"), "第壹")
        XCTAssertEqual(studio.projects.last!.id, p.id)
    }
    func testBackupRejectsCorruptionAndPaths() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try fixture(root), archive = root.appendingPathComponent("backup.kongvox")
        try ProjectBackup.write(p, root: root, to: archive)
        let original = try Data(contentsOf: archive)
        var truncated = original; truncated.removeLast(8); try truncated.write(to: archive)
        let staging = root.appendingPathComponent("stage")
        XCTAssertThrowsError(try ProjectBackup.read(archive, staging: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        var corrupted = original; corrupted[corrupted.count - 1] ^= 0xff; try corrupted.write(to: archive)
        XCTAssertThrowsError(try ProjectBackup.read(archive, staging: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        var unsafe = p; unsafe.segments[0].takes[0].file = "../outside.wav"
        XCTAssertThrowsError(try ProjectBackup.write(unsafe, root: root, to: archive))
        XCTAssertEqual(try Data(contentsOf: archive), corrupted)
        let manifest = try JSONEncoder().encode(ProjectBackup.Manifest(project: unsafe, audio: [ProjectBackup.AudioEntry(name: "../outside.wav", bytes: 1, sha256: "bad")]))
        var crafted = ProjectBackup.magic; var size = UInt64(manifest.count).littleEndian
        withUnsafeBytes(of: &size) { crafted.append(contentsOf: $0) }; crafted.append(manifest); try crafted.write(to: archive)
        XCTAssertThrowsError(try ProjectBackup.read(archive, staging: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
    @MainActor func testLongTextStress() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        for count in [10000, 30000] {
            let start = Date()
            let studio = Studio(root: root.appendingPathComponent("\(count)"), client: client, keyProvider: { _ in "fixture" })
            studio.selectService("openai")
            let article = String(repeating: "这是一段完整的长文。", count: count / 10)
            XCTAssertEqual(article.count, count)
            studio.edit { $0.longText = article }
            XCTAssertEqual(studio.usageEstimate.generate, count)
            // Repeated UI refreshes reuse the estimate rather than re-splitting the article.
            for _ in 0..<100 { XCTAssertEqual(studio.usageEstimate.total, count) }
            MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 48000)
            studio.generate(); studio.pauseRequested = true; await studio.task?.value
            XCTAssertEqual(MockProtocol.count, 1)
            let resumed = Studio(root: studio.root, client: client, keyProvider: { _ in "fixture" })
            resumed.generate(); await resumed.task?.value
            XCTAssertEqual(MockProtocol.count, resumed.project!.segments.count)
            XCTAssertTrue(resumed.fullAudioReady)
            let p = resumed.project!, urls = try resumed.currentURLs()
            let frames = try AudioAssembly.render(urls: urls, gaps: p.gaps, normalize: true, to: root.appendingPathComponent("\(count).wav"))
            XCTAssertEqual(frames.count, p.segments.count)
            XCTAssertEqual(p.segments.map(\.text).joined(), article)
            let ids = Set(p.segments.map(\.id)); resumed.edit { $0.longText = "插入一句。" + article }; resumed.prepareReview()
            XCTAssertTrue(ids.isSubset(of: Set(resumed.project!.segments.map(\.id))))
            print("STRESS: \(count) characters, \(frames.count) clips, pause/reload/resume/render/edit completed in \(String(format: "%.2f", Date().timeIntervalSince(start)))s (mock audio)")
        }
    }
    func testLongAudioStreaming() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("minute.wav")
        try AudioFiles.writePCM(Data(repeating: 0, count: 60 * 48000), to: source)
        let output = root.appendingPathComponent("twenty-minutes.wav")
        let frames = try AudioAssembly.render(urls: Array(repeating: source, count: 20), gaps: Array(repeating: 0, count: 20), normalize: true, to: output)
        XCTAssertEqual(frames.reduce(0,+), Int64(20 * 60 * 24000))
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        XCTAssertEqual(size, 20 * 60 * 48000 + 44)
        print("STRESS: 20-minute PCM render verified, 57.6 MB output; sequential per-clip assembly")
    }

}
