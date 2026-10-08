import Foundation
import Speech
import AVFoundation
import CoreMedia

// Usage:
//   asr-probe locales
//   asr-probe transcribe <manifest.tsv> <output.jsonl> [locale]
// manifest.tsv: one "id<TAB>absolute wav path" per line. Output: one JSON object per file.

struct Run: Encodable { var text: String; var start: Double?; var end: Double?; var confidence: Double? }
struct Item: Encodable {
    var id: String; var file: String; var duration: Double?; var seconds: Double
    var text: String; var runs: [Run]; var error: String?
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func transcriber(_ locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
}

func transcribe(_ url: URL, locale: Locale) async throws -> (String, [Run], Double?) {
    let module = transcriber(locale)
    let analyzer = SpeechAnalyzer(modules: [module])
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let collector = Task { () -> [SpeechTranscriber.Result] in
        var all: [SpeechTranscriber.Result] = []
        for try await result in module.results { all.append(result) }
        return all
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    let results = try await collector.value
    var text = "", runs: [Run] = []
    for result in results where result.isFinal {
        text += String(result.text.characters)
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            let range = run.audioTimeRange
            runs.append(Run(text: piece,
                            start: range.map { $0.start.seconds },
                            end: range.map { $0.end.seconds },
                            confidence: run.transcriptionConfidence))
        }
    }
    return (text, runs, duration)
}

@main struct Probe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { log("usage: asr-probe locales | transcribe <manifest.tsv> <out.jsonl> [locale]"); exit(2) }
        log("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
        if args[1] == "locales" {
            let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
            let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
            print("supported: \(supported.joined(separator: " "))")
            print("installed: \(installed.joined(separator: " "))")
            return
        }
        guard args[1] == "transcribe", args.count >= 4 else { log("bad arguments"); exit(2) }
        let wanted = Locale(identifier: args.count >= 5 ? args[4] : "zh-CN")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            log("locale \(wanted.identifier) not supported"); exit(3)
        }
        log("using locale \(locale.identifier)")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) {
                log("downloading speech model…")
                try await request.downloadAndInstall()
                log("model installed")
            }
        } catch { log("asset install failed: \(error)"); exit(4) }
        let manifest = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
        FileManager.default.createFile(atPath: args[3], contents: nil)
        guard let out = FileHandle(forWritingAtPath: args[3]) else { log("cannot write \(args[3])"); exit(5) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for line in manifest.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let started = Date()
            var item = Item(id: parts[0], file: parts[1], duration: nil, seconds: 0, text: "", runs: [], error: nil)
            do {
                let (text, runs, duration) = try await transcribe(URL(fileURLWithPath: parts[1]), locale: locale)
                item.text = text; item.runs = runs; item.duration = duration
            } catch { item.error = String(describing: error) }
            item.seconds = Date().timeIntervalSince(started)
            log("\(item.id): \(item.error ?? "\(item.text.count) chars in \(String(format: "%.1f", item.seconds))s")")
            if let data = try? encoder.encode(item) { out.write(data); out.write(Data("\n".utf8)) }
        }
        try? out.close()
    }
}
