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
    static func render(urls: [URL], gaps: [Double], normalize: Bool, to destination: URL? = nil, seam: SeamOptions? = nil) throws -> [Int64] {
        guard !urls.isEmpty, urls.count == gaps.count, gaps.allSatisfy({ $0.isFinite && (0...3).contains($0) }) else { throw VoxError(message: "音频合并参数不完整。") }
        let seamOptions = seam.flatMap { $0.enabled ? $0 : nil }
        let temp = destination.map { $0.deletingLastPathComponent().appendingPathComponent(".\(UUID()).wav") }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        var output: FileHandle?
        if let temp { try AudioFiles.wavHeader(byteCount: 0).write(to: temp); output = try FileHandle(forWritingTo: temp); try output?.seekToEnd() }
        defer { try? output?.close() }
        var frames: [Int64] = [], total = 0
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            let joinedBefore = i > 0 && gaps[i - 1] == 0, joinedAfter = i < urls.count - 1 && gaps[i] == 0
            var pcm = try prepare(Data(contentsOf: url), trimStart: joinedBefore, trimEnd: joinedAfter, normalize: normalize)
            // Seam fades are applied per segment while streaming, so long mixes never sit in memory at once.
            if let seamOptions { pcm = applySeam(pcm, fadeIn: joinedBefore, fadeOut: joinedAfter, options: seamOptions) }
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

    /// Renders the mix through the streaming path and returns its PCM, for analyses such as local pause alignment.
    static func renderWithPCM(urls: [URL], gaps: [Double], normalize: Bool, seam: SeamOptions? = nil) throws -> (frames: [Int64], pcm: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("mix.wav")
        let frames = try render(urls: urls, gaps: gaps, normalize: normalize, to: wav, seam: seam)
        let pcm = try AudioFiles.extractPCM(Data(contentsOf: wav))
        return (frames, pcm)
    }

    /// Seam treatment for one prepared segment: overall gain, plus a fade-out / fade-in (no overlap) at gapless joins.
    /// Sample counts never change, so subtitle and playback timelines stay identical with or without seams.
    static func applySeam(_ data: Data, fadeIn: Bool, fadeOut: Bool, options: SeamOptions) -> Data {
        let fadeFrames = max(0, min(24000 / 2, options.crossfadeMilliseconds * 24))
        guard fadeFrames > 0 || abs(options.gainAdjustment) > 0.001 else { return data }
        let base = data.startIndex
        var samples = stride(from: 0, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[base + $0]) | UInt16(data[base + $0 + 1]) << 8) }
        let gain = pow(10.0, options.gainAdjustment / 20.0)
        for i in samples.indices {
            var value = Double(samples[i]) * gain
            if fadeIn && i < fadeFrames { value *= Double(i) / Double(max(1, fadeFrames)) }
            if fadeOut && i >= max(0, samples.count - fadeFrames) { value *= Double(samples.count - i) / Double(max(1, fadeFrames)) }
            samples[i] = Int16(max(-32768, min(32767, value.rounded())))
        }
        var output = Data(capacity: samples.count * 2)
        for sample in samples { let raw = UInt16(bitPattern: sample); output.append(UInt8(truncatingIfNeeded: raw)); output.append(UInt8(truncatingIfNeeded: raw >> 8)) }
        return output
    }
}

enum ExportBundle {
    static func write(urls: [URL], texts: [String], gaps: [Double], normalize: Bool, destination: URL, subtitleStyle: SubtitleStyle = .paragraph, captionProject: Project? = nil, seam: SeamOptions? = nil, root: URL? = nil) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("配音.wav")
        let frames = try AudioAssembly.render(urls: urls, gaps: gaps, normalize: normalize, to: audio, seam: seam)
        try (captionProject.map { try $0.captionContent(frames: frames, renderedAudio: audio, root: root) } ?? Subtitles.render(texts: texts, frames: frames, gaps: gaps, style: subtitleStyle)).write(to: folder.appendingPathComponent("配音.srt"), atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", folder.path, staging.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VoxError(message: "音频字幕打包失败，原文件未修改。") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
}
