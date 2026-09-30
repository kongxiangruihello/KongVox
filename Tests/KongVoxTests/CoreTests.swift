#if STANDALONE_TESTS
import Foundation
class XCTestCase {}
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "\(a) != \(b)") }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T) { precondition(a > b) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
func XCTFail(_ message: String) { fatalError(message) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) { do { _ = try expression(); fatalError("Expected error") } catch {} }
#else
import XCTest
#endif
import AVFoundation
#if !STANDALONE_TESTS
@testable import KongVox
#endif

final class CoreTests: XCTestCase {
    func testSplittingPreservesUnicodeAndLimits() {
        let text = String(repeating: "今天测试中文、English 和 👨‍👩‍👧‍👦。", count: 300)
        let chunks = TextSplitter.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 700 })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(TextSplitter.split(" \n\n"), [])
        XCTAssertEqual(TextSplitter.split("第一段\n\n第二段"), ["第一段", "第二段"])
    }
    func testStaleAudioAndRestore() {
        var s = Segment(text: "你好")
        var settings = VoiceSettings()
        let take = Take(file: "one.wav", fingerprint: s.fingerprint(settings))
        s.takes = [take]; s.selectedTake = take.id
        XCTAssertTrue(s.ready(settings))
        settings.pause = 0.7
        XCTAssertTrue(s.ready(settings))
        settings.voice = "cedar"
        XCTAssertFalse(s.ready(settings))
        settings.voice = "marin"
        s.pronunciation = "您好"
        XCTAssertFalse(s.ready(settings))
        s.pronunciation = ""
        XCTAssertTrue(s.ready(settings))
    }
    func testWavMergeAndConversion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav"), merged = dir.appendingPathComponent("merged.wav")
        try AudioFiles.writePCM(Data(repeating: 0, count: 48000), to: a)
        try AudioFiles.writePCM(Data(repeating: 0, count: 24000), to: b)
        try AudioFiles.merge([a, b], pause: 0.35, to: merged)
        let audio = try AVAudioFile(forReading: merged)
        XCTAssertEqual(audio.length, 44400)
        XCTAssertEqual(audio.fileFormat.sampleRate, 24000)
        let m4a = dir.appendingPathComponent("mix.m4a")
        try await AudioFiles.m4a(from: merged, to: m4a)
        XCTAssertGreaterThan(try Data(contentsOf: m4a).count, 100)
        // Replacement must work without deleting an existing output first.
        try AudioFiles.merge([b], pause: 0, to: merged)
        XCTAssertEqual(try AVAudioFile(forReading: merged).length, 12000)
    }
    func testInvalidInputDoesNotReplaceExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("bad.wav"), dest = dir.appendingPathComponent("out.wav")
        try Data(repeating: 7, count: 100).write(to: source)
        try Data("original".utf8).write(to: dest)
        XCTAssertThrowsError(try AudioFiles.merge([source], pause: 0, to: dest))
        XCTAssertEqual(try String(contentsOf: dest), "original")
    }
    @MainActor func testProjectPersistenceAndMissingAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let studio = Studio(root: dir)
        studio.edit { $0.title = "保存测试"; $0.draft = "第一段\n第二段" }
        studio.importDraft()
        let restored = Studio(root: dir)
        XCTAssertEqual(restored.project?.title, "保存测试")
        XCTAssertEqual(restored.project?.segments.count, 2)
        XCTAssertThrowsError(try restored.currentURLs())
        var s = Segment(text: "没有音频")
        let take = Take(file: "missing.wav", fingerprint: s.fingerprint(VoiceSettings()))
        s.takes = [take]; s.selectedTake = take.id
        XCTAssertFalse(restored.ready(s, settings: VoiceSettings()))
    }
    @MainActor func testCorruptProjectIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("projects.json")
        try Data("broken".utf8).write(to: file)
        let studio = Studio(root: dir)
        XCTAssertNotNil(studio.error)
        studio.save()
        XCTAssertEqual(try String(contentsOf: file), "broken")
    }
}
final class MockProtocol: URLProtocol {
    static var status = 200
    static var payload = Data([0,0,1,0])
    static var captured: URLRequest?
    static var count = 0
    static var failOnRequest: Int?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        Self.count += 1
        let responseStatus = Self.failOnRequest == Self.count ? 500 : Self.status
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: ["Content-Type":"audio/pcm"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SpeechTests: XCTestCase {
    @MainActor func testQueueFailureResumeAndCancel() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let studio = Studio(root: dir, client: client, keyProvider: { _ in "test-only" })
        studio.selectService("openai")
        studio.edit { $0.draft = "第一段。\n第二段。\n第三段。" }
        studio.importDraft()
        MockProtocol.count = 0; MockProtocol.failOnRequest = 2
        MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.generate()
        await studio.task?.value
        XCTAssertEqual(studio.project?.segments.filter { $0.current != nil }.count, 1)
        XCTAssertFalse(studio.busy)
        let resumed = Studio(root: dir, client: client, keyProvider: { _ in "test-only" })
        MockProtocol.failOnRequest = nil; MockProtocol.count = 0
        resumed.generate()
        await resumed.task?.value
        XCTAssertEqual(MockProtocol.count, 2)
        XCTAssertEqual(try resumed.currentURLs().count, 3)
        resumed.edit { $0.settings.voice = "cedar" }
        MockProtocol.count = 0
        resumed.generate(); resumed.cancel()
        await resumed.task?.value
        XCTAssertFalse(resumed.busy)
        XCTAssertEqual(MockProtocol.count, 0)
        XCTAssertThrowsError(try resumed.currentURLs())
    }
    func testRequestAndHTTPFailures() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        MockProtocol.status = 200; MockProtocol.payload = Data([0,0,1,0])
        let result = try await client.generate(text: "测试", settings: VoiceSettings(), key: "test-only-not-a-key")
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(MockProtocol.captured?.url?.path, "/v1/audio/speech")
        XCTAssertEqual(MockProtocol.captured?.httpMethod, "POST")
        for status in [401,403,429,500] {
            MockProtocol.status = status
            do { _ = try await client.generate(text: "测试", settings: VoiceSettings(), key: "test-only"); XCTFail("Must reject HTTP \(status)") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        MockProtocol.status = 200; MockProtocol.payload = Data()
        do { _ = try await client.generate(text: "测试", settings: VoiceSettings(), key: "test-only"); XCTFail("Must reject empty audio") } catch {}
    }
}

#if STANDALONE_TESTS
@main struct TestRunner {
    @MainActor static func main() async throws {
        let suite = CoreTests()
        suite.testSplittingPreservesUnicodeAndLimits()
        suite.testStaleAudioAndRestore()
        try await suite.testWavMergeAndConversion()
        try suite.testInvalidInputDoesNotReplaceExport()
        try suite.testProjectPersistenceAndMissingAudio()
        try suite.testCorruptProjectIsNotOverwritten()
        try await SpeechTests().testRequestAndHTTPFailures()
        try await SpeechTests().testQueueFailureResumeAndCancel()
        let services = ServiceTests()
        try services.testGeminiRequestFormats()
        try services.testCustomServiceAndCredentials()
        try services.testGeminiAudioAndFailures()
        try services.testWavChunksAndInvalidFormats()
        try services.testLegacyMigration()
        try services.testServicePersistenceAndSnapshots()
        try await services.testGeminiQueue()
        let cosy = CosyVoiceTests()
        try cosy.testRequest()
        try cosy.testSignedAudioURL()
        try await cosy.testRoundTrip()
        try await cosy.testDownloadFailure()
        try cosy.testCatalogUpgrade()
        let wav = WAVDecoderTests()
        try wav.testStreamingLengths()
        try wav.testNormalization()
        try wav.testMalformedAudio()
        print("PASS: 23 test groups; WAV streaming headers and normalization; CosyVoice request/download/errors/catalog migration; legacy migration, Gemini requests/decoding/queue, custom profiles, credential isolation, WAV/M4A, persistence and recovery")
    }
}
#endif
