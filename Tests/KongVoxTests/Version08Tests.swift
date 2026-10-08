import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version08Tests: XCTestCase {
    func testVolcengineRequestAndStream() async throws {
        var settings = VoiceSettings(); settings.service = .volcengine; settings.voice = ServiceProfile.volcengine.voices[0]; settings.speed = 1.2
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        let request = try client.request(text: "测试火山语音。", settings: settings, key: "fixture")
        XCTAssertEqual(request.url?.absoluteString, "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "seed-tts-2.0")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let params = body["req_params"] as! [String: Any], audio = params["audio_params"] as! [String: Any]
        XCTAssertEqual(audio["speech_rate"] as? Int, 20); XCTAssertEqual(audio["sample_rate"] as? Int, 24000)
        let pcm = Data([0,1,2,3])
        let stream = "event: message\r\ndata: {\"code\":0,\"data\":\"\(pcm.base64EncodedString())\"}\r\n\r\ndata: {\"code\":0,\"data\":\"\"}\n\ndata: {\"code\":20000000}\n\n"
        XCTAssertEqual(try VolcengineAudio.decode(Data(stream.utf8)), pcm)
        for invalid in ["data: {\"code\":0,\"data\":\"AAE=\"}\n\n", "data: {\"code\":20000000}\n\n", "data: {\"code\":0,\"data\":\"!\"}\n\ndata: {\"code\":20000000}\n\n", stream + "data: {\"code\":55000000,\"message\":\"secret\"}\n\n"] {
            XCTAssertThrowsError(try VolcengineAudio.decode(Data(invalid.utf8)))
        }
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil; MockProtocol.status = 200; MockProtocol.payload = Data(stream.utf8)
        let generated = try await client.generate(text: "测试", settings: settings, key: "fixture")
        XCTAssertEqual(generated, pcm)
        var legacy = settings; legacy.service?.volcAppID = "123456789"
        let legacyRequest = try client.request(text: "测试", settings: legacy, key: "legacy-token")
        XCTAssertEqual(legacyRequest.value(forHTTPHeaderField: "X-Api-App-Id"), "123456789")
        XCTAssertEqual(legacyRequest.value(forHTTPHeaderField: "X-Api-Access-Key"), "legacy-token")
        XCTAssertEqual(legacyRequest.value(forHTTPHeaderField: "X-Api-Key"), nil)
        XCTAssertFalse(legacy.resolvedService.keyAccount == settings.resolvedService.keyAccount)
        let restored = try JSONDecoder().decode(ServiceProfile.self, from: JSONEncoder().encode(legacy.resolvedService))
        XCTAssertEqual(restored.volcAppID, "123456789")
        let old = try JSONDecoder().decode(ServiceProfile.self, from: JSONEncoder().encode(ServiceProfile.volcengine))
        XCTAssertFalse(old.usesVolcLegacyAuth)
        legacy.service?.volcAppID = "bad\nID"
        XCTAssertThrowsError(try client.request(text: "测试", settings: legacy, key: "token"))
        let optionalCode = "\u{feff}: heartbeat\rdata: {\"data\":\"AAEC\"}\r\rdata: {\"code\":0,\"data\":\"Aw==\"}\r\rdata: {\"code\":20000000}\r\r"
        XCTAssertEqual(try VolcengineAudio.decode(Data(optionalCode.utf8)), Data([0, 1, 2, 3]))
        for httpStatus in [200, 401, 403] {
            MockProtocol.status = httpStatus
            MockProtocol.payload = Data(#"{"code":45000000,"message":"authentication failed secret-fixture"}"#.utf8)
            do { _ = try await client.generate(text: "测试", settings: settings, key: "fixture"); XCTFail("Must reject authentication failure") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("鉴权失败"))
                XCTAssertFalse(ServiceFailure.report(error).contains("secret-fixture"))
                XCTAssertTrue(ServiceFailure.report(error).contains("45000000"))
            }
        }
        let voiceFailure = VolcengineAudio.failure(body: Data(#"{"code":45000000,"message":"speaker resource mismatch"}"#.utf8))
        XCTAssertTrue(voiceFailure.hint.contains("资源 ID"))
        let mappedFailure = VolcengineAudio.failure(body: Data(#"{"code":45000030}"#.utf8), resourceID: "seed-tts-1.0", speaker: ServiceProfile.volcVVVoice)
        XCTAssertTrue(mappedFailure.hint.contains("seed-tts-1.0"))
        XCTAssertTrue(mappedFailure.hint.contains(ServiceProfile.volcVVVoice))
        var mismatched = settings
        mismatched.service?.model = "seed-tts-1.0"
        do { _ = try client.request(text: "测试", settings: mismatched, key: "fixture"); XCTFail("Must reject VV/1.0 mismatch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不能使用 VV 音色")) }
        MockProtocol.status = 200; MockProtocol.payload = Data([0, 0, 1, 0])
    }
    func testImportFormatsAndFiltering() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("示例.md")
        let text = "# 第一章\n\n**正文** [链接](https://example.com) [^1]\n\n[^1]: 脚注内容\n    续行脚注\n\n第二段。"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try DocumentImport.read(url), cleaned = DocumentImport.clean(document.text, options: ImportOptions())
        XCTAssertEqual(document.title, "示例")
        XCTAssertTrue(cleaned.contains("# 第一章")); XCTAssertTrue(cleaned.contains("正文 链接")); XCTAssertFalse(cleaned.contains("http")); XCTAssertFalse(cleaned.contains("脚注"))
        XCTAssertTrue(DocumentImport.clean(text, options: ImportOptions(omitURLs: false, omitFootnotes: false)).contains("https://"))
        let xml = Data("<w:document xmlns:w='w'><w:body><w:p><w:pPr><w:pStyle w:val='Heading1'/></w:pPr><w:r><w:t>第一章</w:t></w:r></w:p><w:p><w:r><w:t>正文&amp;保留</w:t></w:r><w:del><w:r><w:delText>删除内容</w:delText></w:r></w:del></w:p></w:body></w:document>".utf8)
        XCTAssertEqual(try DocumentImport.wordText(xml), "# 第一章\n\n正文&保留")
        XCTAssertThrowsError(try DocumentImport.wordText(Data("<!DOCTYPE doc [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><doc>&x;</doc>".utf8)))
        let word = root.appendingPathComponent("word"); try FileManager.default.createDirectory(at: word, withIntermediateDirectories: false)
        try xml.write(to: word.appendingPathComponent("document.xml"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.currentDirectoryURL = root; process.arguments = ["-q", "test.docx", "word/document.xml"]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(try DocumentImport.read(root.appendingPathComponent("test.docx")).text, "# 第一章\n\n正文&保留")
    }
    @MainActor func testPresetsAndImportPersistence() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root); studio.selectService("openai")
        studio.edit { $0.settings.speed = 1.2; $0.settings.pronunciationRules = [PronunciationRule(word: "a", reading: "b")] }
        studio.storePreset("我的旁白"); XCTAssertEqual(studio.presets.count, 1)
        XCTAssertTrue(studio.presets[0].settings.pronunciationRules == nil)
        studio.importDocuments([ImportedDocument(title: "文章一", text: "# 第一章\n\n完整正文。"), ImportedDocument(title: "文章二", text: "第二篇文章。")], options: ImportOptions())
        XCTAssertEqual(studio.projects.count, 3); XCTAssertEqual(studio.project!.title, "文章一")
        studio.applyPreset(studio.presets[0], create: false); XCTAssertEqual(studio.project!.settings.speed, 1.2)
        XCTAssertTrue(studio.project!.settings.pronunciationRules == nil)
        let restored = Studio(root: root); XCTAssertEqual(restored.presets.count, 1); XCTAssertEqual(restored.projects.count, 3)
        XCTAssertEqual(restored.projects.first!.fullText, "# 第一章\n\n完整正文。")
        studio.applyPreset(studio.presets[0], create: true); XCTAssertEqual(studio.projects.count, 4)
        var service = ServiceProfile.openAI; service.model = "changed"
        try studio.saveService(service, key: nil, makeDefault: false)
        studio.applyPreset(studio.presets[0], create: true); XCTAssertNotNil(studio.error); XCTAssertEqual(studio.projects.count, 4)
    }
    @MainActor func testMultiProjectQueueFailureResumeAndLocks() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let client = SpeechClient(session: URLSession(configuration: config))
        let studio = Studio(root: root, client: client, keyProvider: { _ in "fixture" })
        for _ in 0..<2 { studio.newProject(); studio.selectService("openai"); studio.edit { $0.longText = "生成一段。" }; studio.enqueue(studio.selected!) }
        MockProtocol.count = 0; MockProtocol.failOnRequest = 1; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.startQueue(skipFailures: true)
        let count = studio.projects.count; studio.newProject(); XCTAssertEqual(studio.projects.count, count)
        studio.generate(); XCTAssertTrue(studio.task == nil)
        await studio.queueTask?.value
        XCTAssertEqual(MockProtocol.count, 2); XCTAssertEqual(studio.queue.map(\.state), ["失败", "已完成"])
        let restored = Studio(root: root, client: client, keyProvider: { _ in "fixture" })
        XCTAssertFalse(restored.queueRunning); XCTAssertEqual(restored.queue.count, 2)
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil
        restored.startQueue(skipFailures: false); await restored.queueTask?.value
        XCTAssertEqual(MockProtocol.count, 1); XCTAssertTrue(restored.queue.allSatisfy { $0.state == "已完成" })
        restored.startQueue(skipFailures: false); await restored.queueTask?.value
        XCTAssertEqual(MockProtocol.count, 1)
        restored.queue[0].state = "生成中"; restored.saveQueue()
        XCTAssertEqual(Studio(root: root).queue[0].state, "已暂停")
    }
    @MainActor func testQueuePauseAndStopOnFailure() async throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        let studio = Studio(root: root, client: SpeechClient(session: URLSession(configuration: config)), keyProvider: { _ in "fixture" })
        for _ in 0..<2 { studio.newProject(); studio.selectService("openai"); studio.edit { $0.longText = "第一段。\n\n第二段。" }; studio.enqueue(studio.selected!) }
        MockProtocol.count = 0; MockProtocol.failOnRequest = 1; MockProtocol.status = 200; MockProtocol.payload = Data(repeating: 0, count: 4800)
        studio.startQueue(skipFailures: false); await studio.queueTask?.value
        XCTAssertEqual(MockProtocol.count, 1); XCTAssertEqual(studio.queue.map(\.state), ["失败", "等待"])
        MockProtocol.count = 0; MockProtocol.failOnRequest = nil
        studio.startQueue(skipFailures: false); studio.pauseQueue(); await studio.queueTask?.value
        XCTAssertEqual(MockProtocol.count, 0); XCTAssertFalse(studio.isWorking)
        studio.busy = true; studio.activeSegment = nil; studio.pauseQueue()
        XCTAssertTrue(studio.pauseRequested)
        studio.busy = false; studio.pauseRequested = false
        studio.startQueue(skipFailures: false); studio.skipQueueProject(); await studio.queueTask?.value
        XCTAssertEqual(studio.queue.map(\.state), ["已跳过", "已完成"])
        XCTAssertEqual(MockProtocol.count, 2)
    }
    func testBatchExportAndRollback() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try Version07Tests().fixture(root); p.title = "同名/文章"; p.longMode = false
        let dest = root.appendingPathComponent("delivery")
        try BatchExport.write([p, p], root: root, chapters: false, to: dest)
        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
        let wav = files.first { $0.pathExtension == "wav" }!, srt = wav.deletingPathExtension().appendingPathExtension("srt")
        XCTAssertEqual(try AudioFiles.extractPCM(Data(contentsOf: wav)).count, Int(2.35 * 48000))
        XCTAssertTrue(try String(contentsOf: srt, encoding: .utf8).contains("00:00:02,350"))
        XCTAssertThrowsError(try BatchExport.write([p], root: root, chapters: false, to: dest))
        let chapterDest = root.appendingPathComponent("chapters")
        try BatchExport.write([p], root: root, chapters: true, to: chapterDest)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Audio/" + p.segments[1].current!.file))
        let failed = root.appendingPathComponent("failed")
        XCTAssertThrowsError(try BatchExport.write([p], root: root, chapters: false, to: failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".kongvox-export-") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil).count, 5)
    }
}
