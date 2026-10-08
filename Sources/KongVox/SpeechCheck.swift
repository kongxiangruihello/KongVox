import Foundation

/// Result of transcribing one take on this Mac. Cached per audio file, so it never needs recomputing.
struct SpeechTranscript: Codable, Equatable {
    struct Run: Codable, Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Double?
    }
    var version = 1
    var text: String
    var runs: [Run]
}

/// A suspected reading problem in one segment, located in that segment's own audio.
struct SpeechFinding: Identifiable, Equatable {
    enum Kind: String { case missing = "疑似漏读", extra = "疑似多读或重读" }
    var id = UUID()
    var segmentID: UUID
    var kind: Kind
    /// Manuscript text that seems to be missing, or heard text that seems to be extra.
    var text: String
    var syllables: Int
    var seconds: Double
    var message: String { "\(kind.rawValue) \(syllables) 个音节：「\(text)」" }
}

/// Compares what should be read with what was heard by pronunciation (toneless pinyin), not by characters.
/// Speech recognisers often pick a common homophone for rare characters (陬→邹, 飨→想), which is not a reading error.
enum SpeechCheck {
    struct Token: Equatable {
        var key: String
        /// Character offsets in the source string this token came from.
        var source: Range<Int>
    }
    struct HeardToken: Equatable {
        var key: String
        var text: String
        var start: Double
        var end: Double
    }
    /// Differences of at least this many syllables in one place are reported (validated on real takes: no false alarms).
    static let minimumSyllables = 2

    // MARK: Pronunciation keys

    private static let syllableLock = NSLock()
    private static var syllableCache: [Character: String] = [:]
    /// Toneless pinyin of one Han character via the system transliterator (ICU Han-Latin), or nil for other characters.
    static func syllable(_ c: Character) -> String? {
        guard let scalar = c.unicodeScalars.first, scalar.value >= 0x2E80, c.isLetter else { return nil }
        syllableLock.lock(); defer { syllableLock.unlock() }
        if let cached = syllableCache[c] { return cached }
        let s = NSMutableString(string: String(c))
        guard CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false),
              CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false) else { return nil }
        let value = (s as String).lowercased().trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != String(c), value.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        syllableCache[c] = value
        return value
    }

    private static let digits = Array("零一二三四五六七八九")
    /// How a number is read aloud: 22 → 二十二, 3.14 → 三点一四; longer numbers digit by digit.
    static func reading(ofNumber text: String) -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        func digitByDigit(_ s: String) -> String { String(s.compactMap { $0.wholeNumberValue.map { digits[$0] } }) }
        let whole = parts[0]
        var result: String
        // Both the manuscript and the recogniser's digits go through this same rule, so it only has to be consistent.
        if whole.count > 4 || whole.count > 1 && whole.hasPrefix("0") {
            result = digitByDigit(whole)
        } else {
            var n = Int(whole) ?? 0, out = ""
            for (value, unit) in [(1000, "千"), (100, "百"), (10, "十")] {
                let q = n / value; n %= value
                if q > 0 { out += (value == 10 && q == 1 && out.isEmpty ? "" : String(digits[q])) + unit }
                else if !out.isEmpty && n > 0 && !out.hasSuffix("零") { out += "零" }
            }
            if n > 0 { out += String(digits[n]) }
            result = out.isEmpty ? "零" : out
        }
        if parts.count == 2 { result += "点" + digitByDigit(parts[1]) }
        return result
    }

    /// Pronunciation tokens of a text, each pointing back to the characters it came from.
    /// Punctuation and spaces are ignored; digits are expanded to how they are read; Latin letters stay as letters.
    static func tokens(_ text: String) -> [Token] {
        let chars = Array(text)
        var result: [Token] = [], i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isASCII && c.isNumber {
                var j = i
                while j < chars.count, chars[j].isASCII && chars[j].isNumber || (chars[j] == "." && j + 1 < chars.count && chars[j + 1].isASCII && chars[j + 1].isNumber && j > i) { j += 1 }
                let number = String(chars[i..<j])
                var spoken = reading(ofNumber: number)
                if j < chars.count, chars[j] == "%" || chars[j] == "％" { spoken = "百分之" + spoken; j += 1 }
                for ch in spoken { if let key = syllable(ch) { result.append(Token(key: key, source: i..<j)) } }
                i = j; continue
            }
            if let key = syllable(c) { result.append(Token(key: key, source: i..<(i + 1))) }
            else if c.isASCII && c.isLetter { result.append(Token(key: c.lowercased(), source: i..<(i + 1))) }
            i += 1
        }
        return result
    }

    /// Heard tokens with times; a multi-character recognition run shares its time range evenly.
    static func heardTokens(_ transcript: SpeechTranscript) -> [HeardToken] {
        var result: [HeardToken] = []
        for run in transcript.runs {
            let pieces = tokens(run.text)
            guard !pieces.isEmpty else { continue }
            let chars = Array(run.text)
            let step = max(0, run.end - run.start) / Double(pieces.count)
            for (k, piece) in pieces.enumerated() {
                let text = String(chars[piece.source.clamped(to: 0..<chars.count)])
                result.append(HeardToken(key: piece.key, text: text, start: run.start + step * Double(k), end: run.start + step * Double(k + 1)))
            }
        }
        return result
    }

    // MARK: Alignment

    enum Step: Equatable { case match(Int, Int), substitute(Int, Int), delete(Int), insert(Int) }
    /// Minimum edit alignment between expected and heard keys (segments are at most a few hundred syllables).
    static func align(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count, width = m + 1
        var d = [Int](repeating: 0, count: (n + 1) * width)
        for i in 0...n { d[i * width] = i }
        for j in 0...m { d[j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    d[i * width + j] = min(d[(i - 1) * width + j - 1] + cost, d[(i - 1) * width + j] + 1, d[i * width + j - 1] + 1)
                }
            }
        }
        // Walking back from the end, a gap is taken in preference to an equally good match, so a skipped
        // phrase is reported after the last correctly read word ("有朋自远方来" rather than "乎？有朋自远方").
        var steps: [Step] = [], i = n, j = m
        while i > 0 || j > 0 {
            let diagonal = i > 0 && j > 0 && d[i * width + j] == d[(i - 1) * width + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            let isMatch = diagonal && a[i - 1] == b[j - 1]
            let deletion = i > 0 && d[i * width + j] == d[(i - 1) * width + j] + 1
            let insertion = j > 0 && d[i * width + j] == d[i * width + j - 1] + 1
            if deletion && (!diagonal || isMatch) { steps.append(.delete(i - 1)); i -= 1 }
            else if insertion && (!diagonal || isMatch) { steps.append(.insert(j - 1)); j -= 1 }
            else if diagonal { steps.append(isMatch ? .match(i - 1, j - 1) : .substitute(i - 1, j - 1)); i -= 1; j -= 1 }
            else if deletion { steps.append(.delete(i - 1)); i -= 1 }
            else { steps.append(.insert(j - 1)); j -= 1 }
        }
        return steps.reversed()
    }

    /// Suspected missing or extra reading in one segment. `expected` is the text that was sent for synthesis.
    static func findings(expected: String, transcript: SpeechTranscript, segmentID: UUID, minimum: Int = minimumSyllables) -> [SpeechFinding] {
        let want = tokens(expected), heard = heardTokens(transcript)
        let steps = align(want.map(\.key), heard.map(\.key))
        let chars = Array(expected)
        var result: [SpeechFinding] = []
        var block: [Step] = [], lastHeardEnd = 0.0
        func flush() {
            defer { block = [] }
            let deleted = block.compactMap { if case .delete(let i) = $0 { return i } else { return nil } }
            let inserted = block.compactMap { if case .insert(let j) = $0 { return j } else { return nil } }
            let heardInBlock = block.compactMap { step -> Int? in
                switch step { case .substitute(_, let j), .insert(let j): return j; default: return nil }
            }
            let at = heardInBlock.first.map { heard[$0].start } ?? lastHeardEnd
            if deleted.count - inserted.count >= minimum, let first = deleted.first, let last = deleted.last {
                let range = want[first].source.lowerBound..<want[last].source.upperBound
                result.append(SpeechFinding(segmentID: segmentID, kind: .missing, text: String(chars[range]), syllables: deleted.count - inserted.count, seconds: at))
            } else if inserted.count - deleted.count >= minimum {
                result.append(SpeechFinding(segmentID: segmentID, kind: .extra, text: inserted.map { heard[$0].text }.joined(), syllables: inserted.count - deleted.count, seconds: heard[inserted[0]].start))
            }
        }
        for step in steps {
            if case .match(_, let j) = step {
                if !block.isEmpty { flush() }
                lastHeardEnd = heard[j].end
            } else { block.append(step) }
        }
        if !block.isEmpty { flush() }
        return result
    }

    /// Time (seconds in the segment's audio) at which each expected token was heard, or nil when it was not matched.
    static func timing(expected: String, transcript: SpeechTranscript) -> (tokens: [Token], start: [Double?]) {
        let want = tokens(expected), heard = heardTokens(transcript)
        var start = [Double?](repeating: nil, count: want.count)
        for step in align(want.map(\.key), heard.map(\.key)) {
            if case .match(let i, let j) = step { start[i] = heard[j].start }
        }
        return (want, start)
    }
}

/// Subtitle timing from on-device transcription: sentence boundaries inside a segment move to the time the next
/// sentence's first syllable was actually heard. Segment boundaries already come from real audio and stay as they are.
/// Segments without a cached transcript keep the proportional timing.
enum SpeechAlignment {
    static func cues(texts: [String], spoken: [String], frames: [Int64], gaps: [Double], style: SubtitleStyle, transcripts: [SpeechTranscript?]) throws -> [CaptionCue] {
        var cues = try Subtitles.cues(texts: texts, frames: frames, gaps: gaps, style: style)
        guard style != .paragraph, texts.count == transcripts.count, texts.count == spoken.count else { return cues }
        var cursor: Int64 = 0, k = 0
        for i in frames.indices {
            let segmentStart = CaptionTimeline.milliseconds(cursor), segmentEnd = CaptionTimeline.milliseconds(cursor + frames[i])
            var group: [Int] = []
            while k < cues.count, cues[k].end <= segmentEnd { group.append(k); k += 1 }
            cursor += frames[i] + Int64(gaps[i] * 24000)
            guard group.count > 1, let transcript = transcripts[i] else { continue }
            let source = Array(texts[i].filter { $0 != "\n" })
            let reading = String(spoken[i].filter { $0 != "\n" })
            let timing = SpeechCheck.timing(expected: reading, transcript: transcript)
            let readingCount = reading.count
            // Where each cue's text starts in the manuscript.
            var offsets: [Int?] = [], from = 0
            for index in group {
                let piece = Array(cues[index].text.filter { $0 != "\n" })
                var found: Int?
                if !piece.isEmpty, piece.count <= source.count {
                    var start = from
                    while start + piece.count <= source.count {
                        if Array(source[start..<(start + piece.count)]) == piece { found = start; break }
                        start += 1
                    }
                }
                offsets.append(found); if let found { from = found + piece.count }
            }
            for n in 1..<group.count {
                guard let offset = offsets[n] else { continue }
                // Replacement readings change the length; map manuscript positions proportionally in that case.
                let target = source.count == readingCount && String(source) == reading ? offset : offset * readingCount / max(1, source.count)
                guard let first = timing.tokens.firstIndex(where: { $0.source.lowerBound >= target }),
                      let heard = timing.start[first...].lazy.compactMap({ $0 }).first else { continue }
                let boundary = segmentStart + Int64((heard * 1000).rounded())
                let previous = group[n - 1], current = group[n]
                guard boundary > cues[previous].start, boundary < cues[current].end, boundary <= segmentEnd else { continue }
                cues[previous].end = boundary; cues[current].start = boundary
            }
        }
        try CaptionTimeline.validate(cues, duration: CaptionTimeline.duration(frames: frames, gaps: gaps))
        return cues
    }
}
