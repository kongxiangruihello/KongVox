import Foundation

extension Project {
    /// Text actually sent to the service for a segment (replacement reading and dictionary applied).
    func synthesisText(_ segment: Segment) -> String { settings.reading(segment.spokenText) }
    /// Cached on-device transcripts of the selected takes, by segment. Missing entries simply have not been transcribed yet.
    func speechTranscripts(root: URL) -> [UUID: SpeechTranscript] {
        var result: [UUID: SpeechTranscript] = [:]
        for segment in segments {
            guard let take = segment.current else { continue }
            if let transcript = SpeechCache.load(take, root: root) { result[segment.id] = transcript }
        }
        return result
    }
}

/// Transcripts are cached per take file. A take's audio never changes, so its transcript never goes stale.
enum SpeechCache {
    static func url(_ take: Take, root: URL) -> URL { root.appendingPathComponent("Transcripts").appendingPathComponent(take.file + ".json") }
    static func load(_ take: Take, root: URL) -> SpeechTranscript? {
        guard let data = try? Data(contentsOf: url(take, root: root)),
              let transcript = try? JSONDecoder().decode(SpeechTranscript.self, from: data), transcript.version == 1 else { return nil }
        return transcript
    }
    static func save(_ transcript: SpeechTranscript, take: Take, root: URL) throws {
        let file = url(take, root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: file, options: .atomic)
    }
}

extension Studio {
    var speechCheckSupported: Bool { LocalSpeech.isSupported }
    func clearSpeechFindings(_ summary: String = "尚未核对") {
        speechFindings = []; speechFindingsProject = nil; speechSummary = summary
    }
    func transcribedCount(_ p: Project) -> Int { p.speechTranscripts(root: root).count }

    /// Transcribes every ready segment on this Mac (reusing cached transcripts) and reports suspected missing or extra reading.
    func runSpeechCheck() {
        guard !isWorking, let p = project else { return }
        guard speechCheckSupported else { error = LocalSpeech.unavailableReason; return }
        guard !(p.isLongMode && p.needsLongPreparation) else { error = "请先更新处理片段，再核对当前文稿。"; return }
        let segments = p.segments.filter { ready($0, in: p) }
        guard !segments.isEmpty else { error = "还没有可核对的音频，请先生成配音。"; return }
        stop(); busy = true; speechChecking = true; progress = 0; clearSpeechFindings("正在本机转写…")
        let folder = root
        task = Task {
            defer { busy = false; speechChecking = false; task = nil }
            var found: [SpeechFinding] = [], transcribed = 0
            do {
                for (index, segment) in segments.enumerated() {
                    try Task.checkCancellation()
                    guard let take = segment.current else { continue }
                    status = "本机转写核对 \(index + 1) / \(segments.count)…"
                    let transcript: SpeechTranscript
                    if let cached = SpeechCache.load(take, root: folder) { transcript = cached }
                    else {
                        transcript = try await LocalSpeech.transcribe(audioURL(take))
                        try SpeechCache.save(transcript, take: take, root: folder)
                        transcribed += 1
                    }
                    found += SpeechCheck.findings(expected: p.synthesisText(segment), transcript: transcript, segmentID: segment.id)
                    progress = Double(index + 1) / Double(segments.count)
                }
                speechFindings = found; speechFindingsProject = p.id
                speechSummary = (found.isEmpty ? "未发现疑似漏读或重读" : "发现 \(found.count) 处疑似漏读或重读，请定位复听") + "（核对 \(segments.count) 段，新转写 \(transcribed) 段）"
                status = "本机转写核对完成，音频未上传。"
            } catch {
                if Task.isCancelled || error is CancellationError { speechSummary = "核对已取消，已转写的片段会复用"; status = speechSummary }
                else { speechSummary = "核对未完成"; self.error = "本机转写失败：\(error.localizedDescription)" }
            }
        }
    }
    func speechFindings(for segmentID: UUID) -> [SpeechFinding] {
        guard speechFindingsProject == selected else { return [] }
        return speechFindings.filter { $0.segmentID == segmentID }
    }
    func playSpeechFinding(_ finding: SpeechFinding) {
        guard !isWorking, let take = project?.segments.first(where: { $0.id == finding.segmentID })?.current else { return }
        play(audioURL(take)); seek(max(0, finding.seconds - 1))
    }
}
