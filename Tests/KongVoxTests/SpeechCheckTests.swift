import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

/// 0.12 on-device transcription check. Recognition itself needs real hardware; these tests use fixed transcripts.
final class SpeechCheckTests: XCTestCase {
    /// A transcript where every character is heard 0.25 s after the previous one, optionally starting later.
    static func transcript(_ text: String, from start: Double = 0) -> SpeechTranscript {
        let runs = Array(text).enumerated().map { i, c in
            SpeechTranscript.Run(text: String(c), start: start + Double(i) * 0.25, end: start + Double(i + 1) * 0.25, confidence: 0.9)
        }
        return SpeechTranscript(text: text, runs: runs)
    }

    func testPronunciationKeysAndNumbers() throws {
        XCTAssertEqual(SpeechCheck.tokens("孔子").map(\.key), ["kong", "zi"])
        XCTAssertEqual(SpeechCheck.reading(ofNumber: "22"), "二十二")
        XCTAssertEqual(SpeechCheck.reading(ofNumber: "105"), "一百零五")
        XCTAssertEqual(SpeechCheck.reading(ofNumber: "3.14"), "三点一四")
        XCTAssertEqual(SpeechCheck.tokens("80%").map(\.key), SpeechCheck.tokens("百分之八十").map(\.key))
        XCTAssertEqual(SpeechCheck.tokens("鲁昌平22年").map(\.key), SpeechCheck.tokens("鲁昌平二十二年").map(\.key))
        XCTAssertEqual(SpeechCheck.tokens("API，").map(\.key), ["a", "p", "i"])
        // Digits keep pointing at the characters they came from.
        XCTAssertEqual(SpeechCheck.tokens("年22").last?.source, 1..<3)
    }

    func testHomophonesAreNotReported() throws {
        // Real recogniser output for rare characters in 《史记》: different characters, same reading.
        let id = UUID()
        XCTAssertTrue(SpeechCheck.findings(expected: "孔子生鲁昌平乡陬邑。其先宋人也，曰孔防叔。", transcript: Self.transcript("孔子生鲁昌平相邹邑其先宋人也曰孔房书"), segmentID: id).isEmpty)
        XCTAssertTrue(SpeechCheck.findings(expected: "鲁襄公二十二年而孔子生。", transcript: Self.transcript("鲁相公22年而孔子生"), segmentID: id).isEmpty)
        // A single misheard or missing syllable stays below the reporting threshold.
        XCTAssertTrue(SpeechCheck.findings(expected: "学而时习之，不亦说乎？", transcript: Self.transcript("学而时之不亦说乎"), segmentID: id).isEmpty)
    }

    func testMissingAndRepeatedReadingAreLocated() throws {
        let id = UUID()
        let expected = "学而时习之，不亦说乎？有朋自远方来，不亦乐乎？人不知而不愠，不亦君子乎？"
        let missing = SpeechCheck.findings(expected: expected, transcript: Self.transcript("学而时习之不亦说乎人不知而不愠不亦君子乎"), segmentID: id)
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.kind, .missing)
        XCTAssertEqual(missing.first?.syllables, 10)
        XCTAssertEqual(missing.first?.text, "有朋自远方来，不亦乐乎")
        // Located where the skipped words should have been: right after 不亦说乎 (9 characters × 0.25 s).
        XCTAssertEqual(missing.first?.seconds, 2.25)
        let repeated = SpeechCheck.findings(expected: "人不知而不愠，不亦君子乎？", transcript: Self.transcript("人不知而不愠人不知而不愠不亦君子乎"), segmentID: id)
        XCTAssertEqual(repeated.map(\.kind), [.extra])
        // A repeated phrase can be split by one coincidentally matching syllable; at least five are reported together.
        XCTAssertTrue((repeated.first?.syllables ?? 0) >= 5)
    }

    func testSpeechAlignedSentenceCaptions() throws {
        // One segment, two sentences; the second sentence is heard from 3.0 s instead of the proportional estimate.
        let text = "学而时习之。不亦说乎有朋自远方来。"
        var runs = SpeechCheckTests.transcript("学而时习之").runs
        runs += SpeechCheckTests.transcript("不亦说乎有朋自远方来", from: 3.0).runs
        let transcript = SpeechTranscript(text: "", runs: runs)
        let frames: [Int64] = [24000 * 6]
        let proportional = try Subtitles.cues(texts: [text], frames: frames, gaps: [0], style: .sentence)
        XCTAssertEqual(proportional.count, 2)
        XCTAssertTrue(proportional[0].end < 3000)
        let aligned = try SpeechAlignment.cues(texts: [text], spoken: [text], frames: frames, gaps: [0], style: .sentence, transcripts: [transcript])
        XCTAssertEqual(aligned[0].end, 3000); XCTAssertEqual(aligned[1].start, 3000)
        XCTAssertEqual(aligned[1].end, proportional[1].end)
        // Without a transcript, or for paragraph captions, timing is unchanged.
        XCTAssertEqual(try SpeechAlignment.cues(texts: [text], spoken: [text], frames: frames, gaps: [0], style: .sentence, transcripts: [nil]).map(\.end), proportional.map(\.end))
        XCTAssertEqual(try SpeechAlignment.cues(texts: [text], spoken: [text], frames: frames, gaps: [0], style: .paragraph, transcripts: [transcript]).map(\.end),
                       try Subtitles.cues(texts: [text], frames: frames, gaps: [0], style: .paragraph).map(\.end))
    }

    @MainActor func testTranscriptCacheFeedsExports() throws {
        let root = try Version03Tests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var p = try Version010Tests().fixture(root)
        p.subtitleStyle = .sentence; p.subtitleAlignment = .speech
        let frames: [Int64] = [96000, 96000]
        // No cached transcripts yet: same as proportional timing, and nothing fails.
        let fallback = try p.captionCues(frames: frames, root: root)
        p.subtitleAlignment = .proportional
        XCTAssertEqual(fallback.map(\.end), try p.captionCues(frames: frames).map(\.end))
        p.subtitleAlignment = .speech
        let first = p.segments[0]
        var runs = Self.transcript("这是第一句").runs
        runs += Self.transcript("接着是第二句", from: 2.5).runs
        try SpeechCache.save(SpeechTranscript(text: "", runs: runs), take: first.current!, root: root)
        XCTAssertEqual(p.speechTranscripts(root: root).count, 1)
        let aligned = try p.captionCues(frames: frames, root: root)
        XCTAssertEqual(aligned[0].end, 2500)
        XCTAssertTrue(try p.captionContent(frames: frames, root: root).contains("00:00:02,500"))
        // Findings come from the same cached transcript.
        XCTAssertTrue(SpeechCheck.findings(expected: p.synthesisText(first), transcript: SpeechCache.load(first.current!, root: root)!, segmentID: first.id).isEmpty)
    }

    /// Takes generated before 0.11 lack the context-hint marker in their fingerprint; they must stay current while hints are off.
    func testPre011TakesStayCurrent() throws {
        var settings = VoiceSettings(); settings.service = .gemini; settings.voice = "Kore"; settings.mode = "长文章"
        var segment = Segment(text: "孔子生鲁昌平乡陬邑。")
        let legacy = Take(file: "old.wav", fingerprint: segment.fingerprint(settings, legacyContext: true))
        segment.takes = [legacy]; segment.selectedTake = legacy.id
        XCTAssertFalse(legacy.fingerprint == segment.fingerprint(settings))
        XCTAssertTrue(segment.ready(settings))
        // Real changes still invalidate it, and so does turning context hints on.
        var changed = settings; changed.voice = "Puck"
        XCTAssertFalse(segment.ready(changed))
        var hinted = settings; hinted.contextHintEnabled = true
        XCTAssertFalse(segment.ready(hinted))
        // Current-format takes are unaffected.
        let current = Take(file: "new.wav", fingerprint: segment.fingerprint(settings))
        segment.takes = [current]; segment.selectedTake = current.id
        XCTAssertTrue(segment.ready(settings)); XCTAssertTrue(segment.matches(current, settings))
    }
}
