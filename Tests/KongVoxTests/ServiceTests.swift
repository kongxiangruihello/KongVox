import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class ServiceTests: XCTestCase {
    func settings(_ profile: ServiceProfile = .gemini) -> VoiceSettings {
        var settings = VoiceSettings(); settings.service = profile; settings.voice = profile.voices[0]; return settings
    }
    func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func response(_ audio: Data, mime: String = "audio/wav", reason: String = "STOP") throws -> Data {
        try json(["candidates": [["finishReason": reason, "content": ["parts": [["inlineData": ["mimeType": mime, "data": audio.base64EncodedString()]]]]]]])
    }
    func testGeminiRequestFormats() throws {
        let client = SpeechClient()
        let request = try client.request(text: "逐字朗读。", settings: settings(), key: "fixture-key")
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash-tts:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let contents = body["contents"] as! [[String: Any]], parts = contents[0]["parts"] as! [[String: Any]]
        XCTAssertEqual(parts[0]["text"] as? String, "逐字朗读。")
        XCTAssertNotNil(parts[0]["speech_metadata"])
        let config = body["generationConfig"] as! [String: Any]
        XCTAssertEqual(config["responseModalities"] as? [String], ["AUDIO"])
        var old = ServiceProfile.gemini; old.model = "gemini-2.5-pro-preview-tts"
        let legacy = try client.request(text: "正文", settings: settings(old), key: "fixture-key")
        let legacyBody = try JSONSerialization.jsonObject(with: legacy.httpBody!) as! [String: Any]
        let speech = (legacyBody["generationConfig"] as! [String: Any])["speechConfig"] as! [String: Any]
        XCTAssertNotNil((speech["voiceConfig"] as! [String: Any])["prebuiltVoiceConfig"])
        XCTAssertThrowsError(try client.request(text: "测试", settings: settings(), key: "gen-lang-client-example"))
    }
    func testCustomServiceAndCredentials() throws {
        var profile = ServiceProfile.openAI; profile.id = "custom"; profile.baseURL = "https://example.com/custom/v1/"; profile.model = "tts-model"
        let request = try SpeechClient().request(text: "测试", settings: settings(profile), key: "fixture-key")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/custom/v1/audio/speech")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertEqual(ServiceProfile.openAI.keyAccount, "openai")
        XCTAssertFalse(profile.keyAccount == ServiceProfile.openAI.keyAccount)
        let keyAccount = profile.keyAccount; profile.baseURL = "https://other.example.com/v1"
        XCTAssertFalse(keyAccount == profile.keyAccount)
        for invalid in ["http://example.com", "https://user:pass@example.com", "https://example.com?key=secret", "https://example.com/#secret"] {
            profile.baseURL = invalid; XCTAssertThrowsError(try profile.validated())
        }
        profile.baseURL = "https://example.com/v1"; profile.model = "../../bad?key=secret"
        XCTAssertThrowsError(try profile.validated())
    }
    func testGeminiAudioAndFailures() throws {
        let pcm = Data([1,0,2,0,3,0,4,0])
        var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm)
        XCTAssertEqual(try SpeechClient.geminiPCM(response(wav)), pcm)
        XCTAssertEqual(try SpeechClient.geminiPCM(response(pcm, mime: "audio/L16;codec=pcm;rate=24000")), pcm)
        XCTAssertThrowsError(try SpeechClient.geminiPCM(response(wav, reason: "MAX_TOKENS")))
        XCTAssertThrowsError(try SpeechClient.geminiPCM(json(["promptFeedback": ["blockReason": "SAFETY"]])))
        XCTAssertThrowsError(try SpeechClient.geminiPCM(json(["candidates": []])))
        XCTAssertThrowsError(try SpeechClient.geminiPCM(json(["candidates": [["content": ["parts": [["text": "not audio"]]]]]])))
        XCTAssertThrowsError(try SpeechClient.geminiPCM(json(["candidates": [["content": ["parts": [["inlineData": ["mimeType": "audio/pcm", "data": "bad base64!"]]]]]]])))
        XCTAssertThrowsError(try SpeechClient.audioPCM(pcm, mime: "audio/l16;rate=48000"))
        XCTAssertThrowsError(try SpeechClient.audioPCM(pcm, mime: "text/html"))
        XCTAssertThrowsError(try SpeechClient.audioPCM(Data([1]), mime: "audio/pcm"))
    }
    func testWavChunksAndInvalidFormats() throws {
        let pcm = Data(repeating: 0, count: 100)
        var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm)
        let extra = Data([74,85,78,75,1,0,0,0,9,0]) // Odd-sized JUNK chunk with padding.
        wav.insert(contentsOf: extra, at: 36)
        var size = UInt32(wav.count - 8).littleEndian
        withUnsafeBytes(of: &size) { wav.replaceSubrange(4..<8, with: $0) }
        XCTAssertEqual(try AudioFiles.extractPCM(wav), pcm)
        var bad = wav; bad[24] = 0
        XCTAssertThrowsError(try AudioFiles.extractPCM(bad))
        XCTAssertThrowsError(try AudioFiles.extractPCM(Data(wav.dropLast())))
        bad = wav; bad[40] = 255; bad[41] = 255
        XCTAssertThrowsError(try AudioFiles.extractPCM(bad))
    }
    @MainActor func testLegacyMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var project = Project(); var segment = Segment(text: "旧文稿")
        let take = Take(file: "old.wav", fingerprint: segment.fingerprint(project.settings))
        segment.takes = [take]; segment.selectedTake = take.id; project.segments = [segment]
        let encoded = try JSONEncoder().encode([project])
        try encoded.write(to: dir.appendingPathComponent("projects.json"))
        let studio = Studio(root: dir)
        XCTAssertEqual(studio.project?.settings.resolvedService, .openAI)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("projects-before-0.2.json")), encoded)
        try AudioFiles.writePCM(Data(repeating: 0, count: 100), to: studio.audioURL(take))
        XCTAssertEqual(try studio.currentURLs().count, 1)
        var explicit = project.settings; explicit.service = .openAI
        XCTAssertTrue(segment.ready(explicit))
        explicit.service = .gemini
        XCTAssertFalse(segment.ready(explicit))
        studio.save()
        XCTAssertEqual(Studio(root: dir).project?.segments.first?.takes.count, 1)
    }
    @MainActor func testServicePersistenceAndSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let studio = Studio(root: dir)
        var custom = ServiceProfile.openAI; custom.id = "custom"; custom.name = "测试服务"
        try studio.saveService(custom, key: nil, makeDefault: true)
        studio.newProject()
        XCTAssertEqual(studio.project?.settings.resolvedService.id, "custom")
        XCTAssertThrowsError(try studio.deleteService("custom"))
        custom.model = "new-model"
        try studio.saveService(custom, key: nil, makeDefault: false)
        XCTAssertEqual(studio.project?.settings.resolvedService.model, "gpt-4o-mini-tts")
        studio.selectService("custom")
        XCTAssertEqual(studio.project?.settings.resolvedService.model, "new-model")
        let restored = Studio(root: dir)
        XCTAssertEqual(restored.catalog.defaultID, "custom")
        XCTAssertEqual(restored.catalog.profiles.count, 5)
        let saved = try String(contentsOf: dir.appendingPathComponent("services.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("API Key"))
    }
    @MainActor func testGeminiQueue() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var accounts: [String] = []
        let studio = Studio(root: dir, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { accounts.append($0.keyAccount); return "fixture-key" })
        studio.selectService("gemini")
        studio.edit { $0.draft = "第一段。\n第二段。" }; studio.importDraft()
        let pcm = Data(repeating: 0, count: 4800)
        var wav = try AudioFiles.wavHeader(byteCount: pcm.count); wav.append(pcm)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = try response(wav)
        studio.generate(); await studio.task?.value
        XCTAssertEqual(MockProtocol.count, 2)
        XCTAssertEqual(accounts, [ServiceProfile.gemini.keyAccount])
        XCTAssertEqual(try studio.currentURLs().count, 2)
        XCTAssertEqual(studio.project?.segments.first?.current?.service?.kind, .gemini)
        XCTAssertEqual(studio.project?.segments.first?.current?.spokenText, "第一段。")
        studio.selectService("openai")
        XCTAssertThrowsError(try studio.currentURLs())
        MockProtocol.payload = Data([0,0,1,0])
    }
}
