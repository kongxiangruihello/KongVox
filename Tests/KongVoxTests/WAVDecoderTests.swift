import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import KongVox
#endif

final class WAVDecoderTests: XCTestCase {
    static func fixture(rate: Int = 24000, channels: Int = 1, bits: Int = 16, floating: Bool = false, extended: Bool = false) -> Data {
        func le(_ value: UInt32, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        let block = channels * bits / 8
        var fmt = le(extended ? 65534 : floating ? 3 : 1, 2)
        fmt.append(le(UInt32(channels), 2)); fmt.append(le(UInt32(rate), 4))
        fmt.append(le(UInt32(rate * block), 4)); fmt.append(le(UInt32(block), 2)); fmt.append(le(UInt32(bits), 2))
        if extended {
            fmt.append(le(22, 2)); fmt.append(le(UInt32(bits), 2)); fmt.append(le(0, 4))
            fmt.append(le(floating ? 3 : 1, 4)); fmt.append(Data([0,0,16,0,128,0,0,170,0,56,155,113]))
        }
        let value: UInt32 = floating ? Float(0.25).bitPattern : bits == 8 ? 160 : UInt32(1) << (bits - 3)
        var pcm = Data()
        for _ in 0..<rate * channels { pcm.append(le(value, bits / 8)) }
        var wav = Data("RIFF".utf8); wav.append(le(UInt32(20 + fmt.count + pcm.count), 4)); wav.append(Data("WAVEfmt ".utf8))
        wav.append(le(UInt32(fmt.count), 4)); wav.append(fmt); wav.append(Data("data".utf8)); wav.append(le(UInt32(pcm.count), 4)); wav.append(pcm)
        return wav
    }
    func testStreamingLengths() throws {
        let regular = Self.fixture()
        let expected = try AudioFiles.extractPCM(regular)
        for sentinel: UInt8 in [0, 255] {
            var wav = regular
            wav.replaceSubrange(4..<8, with: Data(repeating: sentinel, count: 4))
            wav.replaceSubrange(40..<44, with: Data(repeating: sentinel, count: 4))
            XCTAssertEqual(try AudioFiles.extractPCM(wav), expected)
        }
    }
    func testCosyObservedHeader() throws {
        var wav = Self.fixture()
        wav.replaceSubrange(4..<8, with: Data([0xbf,0xff,0xff,0x7f]))
        wav.replaceSubrange(40..<44, with: Data([0x9b,0xff,0xff,0x7f]))
        XCTAssertEqual(try AudioFiles.extractPCM(wav), try AudioFiles.extractPCM(Self.fixture()))
        var wrong = wav; wrong[40] = 0x9a
        XCTAssertThrowsError(try AudioFiles.extractPCM(wrong))
        wav.removeLast()
        XCTAssertThrowsError(try AudioFiles.extractPCM(wav))
    }
    func testNormalization() throws {
        for (rate, channels, bits, floating, extended) in [(48000,2,16,false,false), (22050,1,16,false,false), (24000,1,24,false,false), (24000,1,32,true,false), (24000,2,16,false,true), (24000,1,8,false,false), (24000,1,32,false,false)] {
            let pcm = try AudioFiles.extractPCM(Self.fixture(rate: rate, channels: channels, bits: bits, floating: floating, extended: extended))
            XCTAssertTrue(abs(pcm.count - 48000) <= 4)
            let center = Int16(bitPattern: UInt16(pcm[24000]) | UInt16(pcm[24001]) << 8)
            XCTAssertTrue(abs(Int(center) - 8192) < 100)
        }
    }
    func testMalformedAudio() throws {
        var truncated = Self.fixture(); truncated.removeLast()
        XCTAssertThrowsError(try AudioFiles.extractPCM(truncated))
        var invalidBlock = Self.fixture(); invalidBlock[32] = 4
        XCTAssertThrowsError(try AudioFiles.extractPCM(invalidBlock))
        var badGUID = Self.fixture(extended: true); badGUID[59] = 0
        XCTAssertThrowsError(try AudioFiles.extractPCM(badGUID))
        var nan = Self.fixture(bits: 32, floating: true)
        nan.replaceSubrange(44..<48, with: Data([0,0,192,127]))
        XCTAssertThrowsError(try AudioFiles.extractPCM(nan))
    }
}
