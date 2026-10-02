import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version05Tests: XCTestCase {
    func tone(amplitude: Double, silence: Int = 0) throws -> Data {
        var pcm = Data(repeating: 0, count: silence * 2)
        for i in 0..<24000 {
            let value = Int16((sin(Double(i) * 2 * .pi * 440 / 24000) * amplitude * 32767).rounded())
            let raw = UInt16(bitPattern: value); pcm.append(UInt8(truncatingIfNeeded: raw)); pcm.append(UInt8(truncatingIfNeeded: raw >> 8))
        }
        pcm.append(Data(repeating: 0, count: silence * 2))
        var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm); return wav
    }
    func rms(_ pcm: Data) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: pcm.count, by: 2) {
            let value = Double(Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)) / 32768
            sum += value * value
        }
        return sqrt(sum / Double(pcm.count / 2))
    }
    func testNaturalBoundariesAndLevelMatching() throws {
        let chunks = LongChunker.split(String(repeating: "甲", count: 1500) + "\n自然段。", limit: 500)
        XCTAssertTrue(chunks.first!.text.count <= 120)
        XCTAssertFalse(chunks.first!.paragraphEnd)
        XCTAssertEqual(chunks.filter(\.paragraphEnd).count, 2)
        XCTAssertEqual(chunks.map(\.text).joined(), String(repeating: "甲", count: 1500) + "自然段。")
        var old = Project(); old.longText = String(repeating: "甲", count: 1500) + "\n自然段。"
        old.segments = TextSplitter.split(old.longText!, limit: old.chunkLimit).map { Segment(text: $0) }
        XCTAssertEqual(old.paragraphEnds.filter { $0 }.count, 2)
        XCTAssertEqual(old.gaps.first, 0)
        let soft = try AudioAssembly.prepare(tone(amplitude: 0.08), trimStart: false, trimEnd: false, normalize: true)
        let loud = try AudioAssembly.prepare(tone(amplitude: 0.2), trimStart: false, trimEnd: false, normalize: true)
        XCTAssertTrue(abs(rms(soft) - rms(loud)) < 0.001)
        let natural = try AudioAssembly.prepare(tone(amplitude: 0.1, silence: 7200), trimStart: false, trimEnd: false, normalize: false)
        let artificial = try AudioAssembly.prepare(tone(amplitude: 0.1, silence: 7200), trimStart: true, trimEnd: true, normalize: false)
        XCTAssertEqual(natural.count - artificial.count, 4800 * 4)
        XCTAssertEqual(try AudioAssembly.prepare(tone(amplitude: 0.1), trimStart: false, trimEnd: false, normalize: false), try AudioFiles.extractPCM(tone(amplitude: 0.1)))
    }
    func testBundleAndTimeline() throws {
        let dir = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let urls = (0..<3).map { dir.appendingPathComponent("\($0).wav") }
        for url in urls { try tone(amplitude: 0.1, silence: 7200).write(to: url) }
        let gaps = [0.0, 0.35, 0.0]
        let dest = dir.appendingPathComponent("mix.wav")
        let frames = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: true, to: dest)
        XCTAssertEqual(frames, [33600, 33600, 38400])
        XCTAssertEqual(try AudioFiles.extractPCM(Data(contentsOf: dest)).count / 2, Int(frames.reduce(0,+)) + 8400)
        let srt = try Subtitles.render(texts: ["一", "二", "三"], frames: frames, gaps: gaps)
        XCTAssertTrue(srt.contains("00:00:01,400 --> 00:00:02,800"))
        XCTAssertTrue(srt.contains("00:00:03,150 --> 00:00:04,750"))
        let archive = dir.appendingPathComponent("bundle.zip")
        try ExportBundle.write(urls: urls, texts: ["一", "二", "三"], gaps: gaps, normalize: true, destination: archive)
        let extracted = dir.appendingPathComponent("unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("配音.srt"), encoding: .utf8), srt)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("配音.wav")), try Data(contentsOf: dest))
        let original = try Data(contentsOf: archive)
        XCTAssertThrowsError(try ExportBundle.write(urls: urls, texts: ["不匹配"], gaps: gaps, normalize: true, destination: archive))
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }
    @MainActor func testOpeningReuseEstimatesAndSeek() async throws {
        let dir = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: dir, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "fixture" })
        studio.selectService("openai")
        studio.edit { $0.longText = String(repeating: "这是全文。", count: 400) }
        XCTAssertEqual(studio.usageEstimate.generate, 2000)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generateOpening(); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 1)
        XCTAssertTrue(studio.project!.segments.first!.text.count <= 120)
        let openingCharacters = studio.project!.segments[0].spokenText.count
        XCTAssertEqual(studio.usageEstimate.reuse, openingCharacters)
        XCTAssertEqual(studio.usageEstimate.generate, 2000 - openingCharacters)
        studio.generateOpening(); XCTAssertEqual(MockProtocol.count, 1)
        studio.seek(999); XCTAssertTrue(studio.playbackTime <= studio.playbackDuration)
        studio.skip(-999); XCTAssertEqual(studio.playbackTime, 0)
        studio.stop()
        studio.generate(); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, studio.project!.segments.count)
        XCTAssertEqual(studio.usageEstimate.generate, 0)
        XCTAssertEqual(studio.usageEstimate.reuse, 2000)
        XCTAssertEqual(Studio.timeLabel(3671), "1:01:11")
    }
}
