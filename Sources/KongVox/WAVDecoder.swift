import Foundation
import AVFoundation

/// Validates RIFF chunks, tolerates streaming length sentinels, then normalizes audio for the studio.
enum WAVDecoder {
    static func decode(_ data: Data) throws -> Data {
        func failure(_ detail: String) -> VoxError { VoxError(message: "无法读取 WAV：" + detail) }
        func uint(_ start: Int, _ count: Int) throws -> UInt32 {
            guard start >= 0, count <= 4, start + count <= data.count else { throw failure("文件头不完整。") }
            return (0..<count).reduce(UInt32(0)) { $0 | UInt32(data[start + $1]) << (8 * $1) }
        }
        guard data.count >= 44, data.count <= 256 * 1024 * 1024, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { throw failure("服务返回的内容不是可识别的 WAV 文件。") }
        let declared = try uint(4, 4)
        // Observed CosyVoice streaming WAV header: paired fixed length placeholders.
        // Match the exact canonical header pair, not arbitrary oversized/truncated WAVs.
        let initialDataLength = try uint(40, 4)
        let cosyStreaming = declared == 0x7fffffbf && data[36..<40] == Data("data".utf8) && initialDataLength == 0x7fffff9b
        let end = declared == 0 || declared == UInt32.max || cosyStreaming ? data.count : Int(declared) + 8
        guard end <= data.count, end >= 44 else { throw failure("音频下载不完整。") }
        var offset = 12, format: Data?, samples = Data()
        while offset + 8 <= end {
            let name = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let rawSize = try uint(offset + 4, 4), start = offset + 8
            let streamingData = name == "data" && (rawSize == 0 || rawSize == UInt32.max || (cosyStreaming && offset == 36 && rawSize == 0x7fffff9b))
            let size = streamingData ? end - start : Int(rawSize)
            guard size <= end - start else { throw failure("音频数据块被截断。") }
            if name == "fmt " {
                guard format == nil, size >= 16 else { throw failure("格式描述缺失或重复。") }
                format = Data(data[start..<start + size])
            } else if name == "data" { samples.append(data[start..<start + size]) }
            offset = start + size + size % 2
            if streamingData { break }
        }
        guard let fmt = format, !samples.isEmpty else { throw failure("没有有效的声音数据。") }
        func f(_ start: Int, _ count: Int) -> UInt32 { (0..<count).reduce(UInt32(0)) { $0 | UInt32(fmt[start + $1]) << (8 * $1) } }
        var encoding = f(0, 2)
        let channels = Int(f(2, 2)), rate = Int(f(4, 4)), bits = Int(f(14, 2)), block = Int(f(12, 2))
        if encoding == 65534 {
            guard fmt.count >= 40, f(16, 2) >= 22, Int(f(18, 2)) == bits,
                  Array(fmt[26..<40]) == [0,0,0,0,16,0,128,0,0,170,0,56,155,113] else { throw failure("不支持此扩展 WAV 格式。") }
            encoding = f(24, 2)
        }
        guard (1...8).contains(channels), (8000...192000).contains(rate),
              (encoding == 1 && [8,16,24,32].contains(bits)) || (encoding == 3 && bits == 32),
              block == channels * bits / 8, Int(f(8, 4)) == rate * block,
              samples.count % block == 0 else { throw failure("采样格式无效或数据不完整。") }
        if encoding == 1 && channels == 1 && rate == 24000 && bits == 16 { return samples }
        let frames = samples.count / block
        guard frames <= 24_000_000,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { throw failure("无法初始化音频转换。") }
        input.frameLength = AVAudioFrameCount(frames)
        let stride = bits / 8
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let base = frame * block + channel * stride
                let raw = (0..<stride).reduce(UInt32(0)) { $0 | UInt32(samples[base + $1]) << (8 * $1) }
                let value: Float
                if encoding == 3 { value = Float(bitPattern: raw) }
                else if bits == 8 { value = (Float(raw) - 128) / 128 }
                else {
                    let signed = Int32(bitPattern: raw << (32 - bits)) >> (32 - bits)
                    value = Float(signed) / Float(pow(2.0, Double(bits - 1)))
                }
                guard value.isFinite else { throw failure("包含无效的浮点音频采样。") }
                sum += value
            }
            input.floatChannelData![0][frame] = max(-1, min(1, sum / Float(channels)))
        }
        let capacity = Int(ceil(Double(frames) * 24000 / Double(rate))) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else { throw failure("无法分配音频转换缓冲。") }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { throw failure("系统音频转换失败。") }
        return Data(bytes: pointer, count: Int(output.frameLength) * 2)
    }
}
