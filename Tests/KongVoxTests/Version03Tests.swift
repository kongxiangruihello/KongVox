import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version03Tests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testRetryWithoutSynthesis() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("receipt.json")
        let helper = CosyVoiceTests()
        CosyProtocol.requests = []; CosyProtocol.downloadStatus = 503
        do { _ = try await helper.client().generate(text: "测试", settings: helper.settings(), key: "secret", recoveryFile: file); XCTFail("download must fail") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        CosyProtocol.downloadStatus = 200
        // A fresh client models restarting the app. Retry requires no synthesis request.
        let pcm = try await helper.client().generate(text: "测试", settings: helper.settings(), key: "", recoveryFile: file)
        XCTAssertTrue(abs(pcm.count - 48000) <= 4)
        XCTAssertEqual(CosyProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(CosyProtocol.requests.count, 3)
        XCTAssertEqual(CosyProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), nil)
        _ = try await helper.client().generate(text: "测试", settings: helper.settings(), key: "", recoveryFile: file)
        XCTAssertEqual(CosyProtocol.requests.count, 3)
        try DownloadReceipt.clear(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadReceipt.audioFile(file).path))
    }
    func testUnsafeRecoveryAndInvalidAudio() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("receipt.json"), helper = CosyVoiceTests()
        try DownloadReceipt(url: URL(string: "https://evil.example/private")!).save(to: file)
        CosyProtocol.requests = []
        do { _ = try await helper.client().generate(text: "测试", settings: helper.settings(), key: "secret", recoveryFile: file); XCTFail("unsafe URL") } catch {}
        XCTAssertEqual(CosyProtocol.requests.count, 0)
        try DownloadReceipt(url: URL(string: "https://bucket.oss-cn-beijing.aliyuncs.com/a.wav")!).save(to: file)
        try Data("broken".utf8).write(to: DownloadReceipt.audioFile(file))
        do { _ = try await helper.client().generate(text: "测试", settings: helper.settings(), key: "secret", recoveryFile: file); XCTFail("invalid audio") }
        catch { XCTAssertEqual((error as? ServiceFailure)?.category, "audio") }
        XCTAssertEqual(CosyProtocol.requests.count, 0)
    }
    @MainActor func testStudioResumeAndIsolation() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let client = CosyVoiceTests().client()
        let studio = Studio(root: dir, client: client, keyProvider: { _ in "test" })
        studio.selectService(ServiceProfile.cosyVoice.id)
        studio.edit { $0.segments = [Segment(text: "第一段"), Segment(text: "第二段")] }
        let segment = studio.project!.segments[0], project = studio.project!
        let file = studio.recoveryFile(segment, project: project)
        var changed = project; changed.settings.speed = 1.2
        XCTAssertFalse(file == studio.recoveryFile(segment, project: changed))
        var revised = segment; revised.text = "修改文稿"
        XCTAssertFalse(file == studio.recoveryFile(revised, project: project))
        CosyProtocol.requests = []; CosyProtocol.downloadStatus = 503
        studio.generate(); await studio.task?.value
        XCTAssertTrue(studio.hasRecovery(segment))
        XCTAssertTrue(studio.diagnostic.contains("download"))
        let resumed = Studio(root: dir, client: client, keyProvider: { _ in "test" })
        CosyProtocol.downloadStatus = 200
        resumed.generate(); await resumed.task?.value
        XCTAssertEqual(try resumed.currentURLs().count, 2)
        XCTAssertEqual(CosyProtocol.requests.filter { $0.httpMethod == "POST" }.count, 2)
        XCTAssertFalse(resumed.hasRecovery(segment))
    }
    func testSubtitlesTimingAndValidation() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("one.wav"), two = dir.appendingPathComponent("two.wav")
        try AudioFiles.writePCM(Data(repeating: 0, count: 48000), to: one)
        try AudioFiles.writePCM(Data(repeating: 0, count: 24000), to: two)
        let srt = try Subtitles.render(texts: ["第一段", "第二段\n\n字幕"], audio: [one, two], pause: 0.35)
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:01,000\n第一段\n\n2\n00:00:01,350 --> 00:00:01,850\n第二段\n字幕\n")
        XCTAssertThrowsError(try Subtitles.render(texts: ["一段"], audio: [one, two], pause: 0))
        try Data("broken".utf8).write(to: two)
        XCTAssertThrowsError(try Subtitles.render(texts: ["第一段", "第二段"], audio: [one, two], pause: 0))
    }
    @MainActor func testQwenModelsAndMigration() async throws {
        var settings = VoiceSettings(); settings.service = .qwenTTS; settings.voice = "Cherry"
        let client = CosyVoiceTests().client()
        for model in ServiceProfile.qwenTTS.modelPresets {
            settings.service?.model = model
            let request = try client.request(text: "测试", settings: settings, key: "fixture")
            XCTAssertEqual(request.url?.path, "/api/v1/services/aigc/multimodal-generation/generation")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let input = body["input"] as! [String: Any]
            XCTAssertEqual(input["voice"] as? String, "Cherry")
            XCTAssertEqual(input["language_type"] as? String, "Auto")
            XCTAssertEqual(input["instructions"] != nil, model.contains("instruct"))
        }
        XCTAssertThrowsError(try client.request(text: String(repeating: "字", count: 601), settings: settings, key: "fixture"))
        let response = Data(#"{"code":"","output":{"finish_reason":"stop","audio":{"url":"https://bucket.oss-cn-beijing.aliyuncs.com/a.wav"}}}"#.utf8)
        XCTAssertEqual(try SpeechClient.cosyVoiceAudioURL(response).host, "bucket.oss-cn-beijing.aliyuncs.com")
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        var old = ServiceCatalog(); old.builtinsRevision = 1; old.profiles.removeAll { $0.kind == .qwenTTS }
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("services.json"))
        let studio = Studio(root: dir, client: client, keyProvider: { _ in "fixture" })
        XCTAssertEqual(studio.catalog.profiles.filter { $0.kind == .qwenTTS }.count, 1)
        XCTAssertEqual(studio.catalog.defaultID, old.defaultID)
        studio.selectService(ServiceProfile.qwenTTS.id)
        studio.edit { $0.draft = String(repeating: "字", count: 1100) }
        studio.importDraft()
        XCTAssertEqual(studio.project?.segments.count, 3)
        XCTAssertTrue(studio.project!.segments.allSatisfy { $0.text.count <= 500 })
        CosyProtocol.requests = []; CosyProtocol.downloadStatus = 200
        studio.generate(); await studio.task?.value
        XCTAssertEqual(try studio.currentURLs().count, 3)
        XCTAssertEqual(CosyProtocol.requests.filter { $0.httpMethod == "POST" }.count, 3)
    }
    func testSafeDiagnostics() throws {
        for (status, code, category) in [(401,"InvalidApiKey","credentials"),(400,"InvalidParameter","configuration"),(429,"insufficient_quota","quota"),(429,"RateLimit","rate_or_quota"),(403,"Forbidden","permission")] {
            let body = try JSONSerialization.data(withJSONObject: ["code": code, "message": "SECRET 文稿 https://example.com/?Signature=SECRET"])
            let error = ServiceFailure.http(status, body: body)
            XCTAssertEqual(error.category, category)
            XCTAssertFalse(error.report.contains("SECRET"))
            XCTAssertFalse(error.report.contains("example.com"))
        }
        let network = ServiceFailure.network(URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "SECRET"]), download: true)
        XCTAssertFalse(ServiceFailure.report(network).contains("SECRET"))
    }
}
