import Foundation
import AVFoundation
import Speech

/// On-device transcription with the macOS 26 Speech framework. Audio never leaves this Mac and nothing is billed.
/// On earlier systems, or Macs without the required hardware, the feature reports itself unavailable.
enum LocalSpeech {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }
    static var unavailableReason: String {
        if #available(macOS 26.0, *) { return "这台 Mac 暂不支持本机语音识别。" }
        return "本机转写核对需要 macOS 26 或更高版本。"
    }
    static func transcribe(_ url: URL) async throws -> SpeechTranscript {
        guard #available(macOS 26.0, *) else { throw VoxError(message: unavailableReason) }
        return try await LocalSpeech26.transcribe(url)
    }
}

@available(macOS 26.0, *)
private enum LocalSpeech26 {
    static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
    static func prepare() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw VoxError(message: LocalSpeech.unavailableReason) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw VoxError(message: "系统语音识别不支持简体中文。")
        }
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier == locale.identifier }) { _ = try await AssetInventory.reserve(locale: locale) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
            try await request.downloadAndInstall()
        }
        return locale
    }
    static func transcribe(_ url: URL) async throws -> SpeechTranscript {
        let locale = try await prepare()
        let transcriber = module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task { () -> [SpeechTranscriber.Result] in
            var all: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { all.append(result) }
            return all
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        } catch {
            collector.cancel(); await analyzer.cancelAndFinishNow(); throw error
        }
        var text = "", runs: [SpeechTranscript.Run] = []
        for result in try await collector.value where result.isFinal {
            text += String(result.text.characters)
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let piece = String(result.text[run.range].characters)
                guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                runs.append(SpeechTranscript.Run(text: piece, start: range.start.seconds, end: range.end.seconds, confidence: run.transcriptionConfidence))
            }
        }
        return SpeechTranscript(text: text, runs: runs)
    }
}
