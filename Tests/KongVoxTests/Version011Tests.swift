import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class Version011Tests: XCTestCase {
    func testContextHintsAndRequestPayload() throws {
        var project = Project()
        project.settings.contextHintEnabled = true
        project.segments = [Segment(text: "开头"), Segment(text: "目标句"), Segment(text: "结尾")]
        let target = project.segments[1].id
        let context = project.context(for: target)
        XCTAssertTrue(context?.contains("前文：开头") == true)
        XCTAssertTrue(context?.contains("后文：结尾") == true)
        XCTAssertNotNil(project.contextFingerprint(for: target))
        var settings = project.settings
        settings.service = .openAI
        let request = try SpeechClient().request(text: "目标句", settings: settings, key: "fixture", context: context)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertTrue((body["instructions"] as? String)?.contains("前文：开头") == true)
    }

    @MainActor func testVersionRoundTripAndBudget() throws {
        let root = try Version03Tests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        studio.edit { p in
            p.title = "版本测试"
            p.longText = "第一段\n第二段"
            p.prepareLongDocument()
        }
        studio.saveVersion("第一版")
        let saved = studio.project!.versions!.last!
        studio.edit { $0.title = "改过的标题" }
        studio.restoreVersion(saved)
        XCTAssertEqual(studio.project?.title, "版本测试")
        studio.projects = [studio.project!]
        studio.queue = [QueueEntry(projectID: studio.project!.id)]
        XCTAssertEqual(studio.estimatedQueueCharacters(), 6)
        studio.batchBudget.maxCharacters = 5
        studio.saveBatchBudget()
        let reopened = Studio(root: root)
        XCTAssertEqual(reopened.batchBudget.maxCharacters, 5)
    }

    func testLocalPauseCuesAndASS() throws {
        let texts = ["第一句", "第二句"]
        let frames: [Int64] = [24000, 24000]
        let gaps = [0.35, 0.0]
        let pcm = Data(repeating: 0, count: 56400 * 2)
        let cues = try Version011Tools.localPauseCues(texts: texts, frames: frames, gaps: gaps, style: .paragraph, pcm: pcm)
        XCTAssertEqual(cues.count, 2)
        XCTAssertTrue(cues[0].end == cues[1].start)
        let ass = try Version011Tools.ass(cues: cues, duration: 2350, style: .headline)
        XCTAssertTrue(ass.contains("[Events]"))
        XCTAssertTrue(ass.contains("Dialogue: 0"))
    }

    func testSeamRenderAndShortVideoPackage() throws {
        let root = try Version03Tests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var project = Project(); project.title = "短视频测试"; project.subtitleAlignment = .localPauses; project.shortVideoTemplate = .headline
        for index in 0..<2 {
            let file = "fixture-\(index).wav"
            try AudioFiles.writePCM(Data(repeating: index == 0 ? 80 : 120, count: 24000 * 2), to: audio.appendingPathComponent(file))
            var segment = Segment(text: index == 0 ? "第一句" : "第二句")
            let take = Take(file: file, fingerprint: segment.fingerprint(project.settings))
            segment.takes = [take]; segment.selectedTake = take.id; project.segments.append(segment)
        }
        project.segments[0].paragraphEnd = true; project.segments[1].paragraphEnd = true
        project.seamOptions = SeamOptions(crossfadeMilliseconds: 30, gainAdjustment: -1, loopSeamPreview: true)
        let urls = project.segments.map { audio.appendingPathComponent($0.current!.file) }
        let rendered = root.appendingPathComponent("rendered.wav")
        let frames = try AudioAssembly.render(urls: urls, gaps: project.gaps, normalize: false, to: rendered, seam: project.resolvedSeam)
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(try AudioFiles.extractPCM(Data(contentsOf: rendered)).count, 100)
        let destination = root.appendingPathComponent("package")
        try ShortVideoExport.write(project, urls: urls, root: root, to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("字幕.ass").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("项目.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("交付清单.txt").path))
    }
}

