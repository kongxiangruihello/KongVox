import Foundation

/// A shared render pipeline keeps preview, audio export and subtitles on the same sample clock.
enum AudioAssembly {
    static func prepare(_ data: Data, trimStart: Bool, trimEnd: Bool, normalize: Bool) throws -> Data {
        let pcm = try AudioFiles.extractPCM(data)
        var samples = stride(from: 0, to: pcm.count, by: 2).map { Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8) }
        let edge = 480 // retain 20 ms around detected sound; never trim more than 200 ms per edge
        if let first = samples.firstIndex(where: { abs(Int($0)) > 32 }), let last = samples.lastIndex(where: { abs(Int($0)) > 32 }) {
            let start = trimStart ? min(4800, max(0, first - edge)) : 0
            let end = trimEnd ? max(start + 1, samples.count - min(4800, max(0, samples.count - 1 - last - edge))) : samples.count
            samples = Array(samples[start..<end])
        }
        if normalize {
            var sum = 0.0, count = 0, peak = 0.0
            for sample in samples {
                let value = abs(Double(sample)) / 32768
                peak = max(peak, value)
                if value > 0.001 { sum += value * value; count += 1 }
            }
            if count > 0, peak > 0 {
                let rms = sqrt(sum / Double(count))
                let gain = min(0.95 / peak, max(0.5, min(2, 0.1 / rms)))
                samples = samples.map { Int16(max(-32768, min(32767, (Double($0) * gain).rounded()))) }
            }
        }
        // Short fades reduce discontinuities at artificial joins without overlap or timeline drift.
        let fade = min(120, samples.count / 2)
        if fade > 0 {
            for i in 0..<fade {
                if trimStart { samples[i] = Int16(Double(samples[i]) * Double(i) / Double(fade)) }
                if trimEnd { let j = samples.count - 1 - i; samples[j] = Int16(Double(samples[j]) * Double(i) / Double(fade)) }
            }
        }
        var result = Data(capacity: samples.count * 2)
        for sample in samples { let raw = UInt16(bitPattern: sample); result.append(UInt8(truncatingIfNeeded: raw)); result.append(UInt8(truncatingIfNeeded: raw >> 8)) }
        return result
    }
    static func render(urls: [URL], gaps: [Double], normalize: Bool, to destination: URL? = nil) throws -> [Int64] {
        guard !urls.isEmpty, urls.count == gaps.count, gaps.allSatisfy({ $0.isFinite && (0...3).contains($0) }) else { throw VoxError(message: "音频合并参数不完整。") }
        let temp = destination.map { $0.deletingLastPathComponent().appendingPathComponent(".\(UUID()).wav") }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        var output: FileHandle?
        if let temp { try AudioFiles.wavHeader(byteCount: 0).write(to: temp); output = try FileHandle(forWritingTo: temp); try output?.seekToEnd() }
        defer { try? output?.close() }
        var frames: [Int64] = [], total = 0
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            let pcm = try prepare(Data(contentsOf: url), trimStart: i > 0 && gaps[i - 1] == 0, trimEnd: i < urls.count - 1 && gaps[i] == 0, normalize: normalize)
            frames.append(Int64(pcm.count / 2))
            let silence = i < urls.count - 1 ? Int(gaps[i] * 24000) * 2 : 0
            total += pcm.count + silence
            _ = try AudioFiles.wavHeader(byteCount: total)
            try output?.write(contentsOf: pcm)
            if silence > 0 { try output?.write(contentsOf: Data(count: silence)) }
        }
        if let temp, let destination, let output {
            try output.seek(toOffset: 0); try output.write(contentsOf: AudioFiles.wavHeader(byteCount: total)); try output.synchronize(); try output.close()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp) }
            else { try FileManager.default.moveItem(at: temp, to: destination) }
        }
        return frames
    }
}

enum ExportBundle {
    static func write(urls: [URL], texts: [String], gaps: [Double], normalize: Bool, destination: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: normalize, to: folder.appendingPathComponent("配音.wav"))
        try Subtitles.render(texts: texts, frames: frames, gaps: gaps).write(to: folder.appendingPathComponent("配音.srt"), atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", folder.path, staging.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoxError(message: "音频字幕打包失败，原文件未修改。") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
}
