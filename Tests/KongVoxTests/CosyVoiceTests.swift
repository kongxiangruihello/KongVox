import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class CosyProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var downloadStatus = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let synthesis = request.url?.host == "dashscope.aliyuncs.com"
        let status = synthesis ? 200 : Self.downloadStatus
        let data: Data
        if synthesis {
            data = Data(#"{"output":{"finish_reason":"stop","audio":{"url":"http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/test.wav?Signature=fixture"}}}"#.utf8)
        } else {
            var wav = WAVDecoderTests.fixture(rate: 48000, channels: 2)
            wav.replaceSubrange(4..<8, with: Data(repeating: 255, count: 4))
            wav.replaceSubrange(40..<44, with: Data(repeating: 255, count: 4)); data = wav
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": synthesis ? "application/json" : "audio/wav"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CosyVoiceTests: XCTestCase {
    func settings() -> VoiceSettings {
        var value = VoiceSettings(); value.service = .cosyVoice; value.voice = "longanyang"; return value
    }
    func testRequest() throws {
        var value = settings(); value.speed = 1.15
        let request = try SpeechClient().request(text: "测试中文口播。", settings: value, key: "test-key")
        XCTAssertEqual(request.url?.absoluteString, "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let input = body["input"] as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "cosyvoice-v3-flash")
        XCTAssertEqual(input["text"] as? String, "测试中文口播。")
        XCTAssertEqual(input["voice"] as? String, "longanyang")
        XCTAssertEqual(input["sample_rate"] as? Int, 24000)
        XCTAssertEqual(input["rate"] as? Double, 1.15)
        XCTAssertEqual(input["format"] as? String, "wav")
        XCTAssertEqual(input["instruction"] as? String, "你正在进行闲聊互动，你说话的情感是neutral。")
        value.direction = "你说话的情感是happy。"
        let custom = try SpeechClient().request(text: "测试", settings: value, key: "test")
        let customBody = try JSONSerialization.jsonObject(with: custom.httpBody!) as! [String: Any]
        XCTAssertEqual((customBody["input"] as! [String: Any])["instruction"] as? String, value.direction)
        value.service?.model = "cosyvoice-v3-plus"
        let plus = try SpeechClient().request(text: "测试", settings: value, key: "test")
        let plusBody = try JSONSerialization.jsonObject(with: plus.httpBody!) as! [String: Any]
        XCTAssertTrue((plusBody["input"] as! [String: Any])["instruction"] == nil)
    }
    func testSignedAudioURL() throws {
        func reply(_ url: String, reason: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["output": ["finish_reason": reason, "audio": ["url": url]]])
        }
        let raw = "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/a.wav?Signature=a%2Bb&Expires=1"
        let result = try SpeechClient.cosyVoiceAudioURL(reply(raw))
        XCTAssertEqual(result.scheme, "https")
        XCTAssertEqual(result.absoluteString, raw.replacingOccurrences(of: "http:", with: "https:"))
        for url in ["http://127.0.0.1/private", "https://evil.example/audio", "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com.evil.example/a", "https://user:pass@bucket.oss-cn-beijing.aliyuncs.com/a", "file:///tmp/a.wav"] {
            XCTAssertThrowsError(try SpeechClient.cosyVoiceAudioURL(reply(url)))
        }
        XCTAssertThrowsError(try SpeechClient.cosyVoiceAudioURL(reply(raw, reason: "null")))
        XCTAssertThrowsError(try SpeechClient.cosyVoiceAudioURL(Data(#"{"code":"InvalidApiKey"}"#.utf8)))
    }
    func client() -> SpeechClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CosyProtocol.self]
        return SpeechClient(session: URLSession(configuration: config))
    }
    func testRoundTrip() async throws {
        CosyProtocol.requests = []; CosyProtocol.downloadStatus = 200
        let audio = try await client().generate(text: "配音测试。", settings: settings(), key: "fixture-secret")
        XCTAssertTrue(abs(audio.count - 48000) <= 4)
        XCTAssertEqual(CosyProtocol.requests.count, 2)
        XCTAssertEqual(CosyProtocol.requests[1].url?.scheme, "https")
        XCTAssertEqual(CosyProtocol.requests[1].value(forHTTPHeaderField: "Authorization"), nil)
        XCTAssertEqual(CosyProtocol.requests[1].value(forHTTPHeaderField: "x-goog-api-key"), nil)
        XCTAssertEqual(CosyProtocol.requests[1].httpBody, nil)
    }
    func testDownloadFailure() async throws {
        CosyProtocol.requests = []; CosyProtocol.downloadStatus = 403
        do { _ = try await client().generate(text: "测试", settings: settings(), key: "fixture-secret"); XCTFail("Must reject failed audio download") }
        catch { XCTAssertTrue(error.localizedDescription.contains("下载失败")) }
        XCTAssertEqual(CosyProtocol.requests.count, 2)
        CosyProtocol.downloadStatus = 200
    }
    @MainActor func testCatalogUpgrade() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old: [String: Any] = ["profiles": try JSONSerialization.jsonObject(with: JSONEncoder().encode([ServiceProfile.openAI, .gemini])), "defaultID": "openai"]
        try JSONSerialization.data(withJSONObject: old).write(to: dir.appendingPathComponent("services.json"))
        let studio = Studio(root: dir)
        XCTAssertEqual(studio.catalog.profiles.count, 4)
        XCTAssertEqual(studio.catalog.defaultID, "openai")
        XCTAssertEqual(studio.catalog.profiles.last?.kind, .qwenTTS)
        XCTAssertEqual(Studio(root: dir).catalog.profiles.count, 4)
        try studio.deleteService(ServiceProfile.cosyVoice.id)
        XCTAssertEqual(Studio(root: dir).catalog.profiles.count, 3)
    }
}
