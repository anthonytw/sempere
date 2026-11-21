import Foundation
import XCTest

@testable import Sempere

/// `AudioMetadata` zeroes an MP4 recording's container times and blanks its tags without moving a byte, and refuses a
/// file it cannot read whole. Its fuzz target is `SempereFuzzTests.testFuzzAudioMetadata`.
final class AudioMetadataTests: XCTestCase {
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let n = UInt32(8 + body.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
    }

    static let stamp: [UInt8] = [0xE0, 0x1D, 0x2C, 0x3B]

    /// A full box of `version` whose times are `stamp` (version 1: 8 bytes each), padded with `rest` bytes of 0x11.
    static func timed(_ type: String, version: UInt8, rest: Int) -> [UInt8] {
        let times = version == 1 ? (Array(repeating: 0, count: 4) + stamp + Array(repeating: 0, count: 4) + stamp) : stamp + stamp
        return box(type, [version, 0, 0, 0] + times + Array(repeating: 0x11, count: rest))
    }

    /// ftyp, a moov with mvhd (v0), a trak with tkhd (v1), mdia/mdhd (v0) and a udta, a moov-level meta, then mdat.
    static func synthetic(mvhdVersion: UInt8 = 0) -> Data {
        let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0] + Array("isom".utf8))
        let trak = box("trak", timed("tkhd", version: 1, rest: 60)
            + box("mdia", timed("mdhd", version: 0, rest: 12))
            + box("udta", box("Cxyz", Array("+47.6062-122.3321/".utf8))))
        let moov = box("moov", timed("mvhd", version: mvhdVersion, rest: 88) + trak + box("meta", Array(repeating: 0x22, count: 20)))
        let mdat = box("mdat", Array(repeating: 0x5A, count: 64))
        return Data(ftyp + moov + mdat)
    }

    func testTimesAreZeroedAndTagsBlankedWithoutMovingAByte() throws {
        let input = Self.synthetic()
        let out = try XCTUnwrap(AudioMetadata.scrubbed(input))
        XCTAssertEqual(out.count, input.count)
        XCTAssertNil(out.range(of: Data(Self.stamp)), "no time is left")
        XCTAssertNil(out.range(of: Data("+47.6062".utf8)), "no tag is left")
        XCTAssertNil(out.range(of: Data("udta".utf8)))
        XCTAssertNil(out.range(of: Data("meta".utf8)))
        XCTAssertNotNil(out.range(of: Data("free".utf8)))
        XCTAssertEqual(out.suffix(64), Data(repeating: 0x5A, count: 64), "the samples are untouched")
        XCTAssertNotNil(out.range(of: Data(repeating: 0x11, count: 60)), "the rest of each header is untouched")
        XCTAssertEqual(AudioMetadata.scrubbed(out), out, "a second pass changes nothing")
    }

    func testARealRecordingPlaysTheSameAfterwards() throws {
        for name in ["tone-aac.m4a", "tone-aac-faststart.m4a", "tone-alac.m4a"] {
            let input = try AudioProbeTests.fixture(name)
            let out = try XCTUnwrap(AudioMetadata.scrubbed(input), name)
            XCTAssertEqual(out.count, input.count, name)
            XCTAssertEqual(try AudioProbe.probe(out), try AudioProbe.probe(input), name)
        }
    }

    func testAFileItCannotReadWholeIsRefused() {
        let good = Self.synthetic()
        XCTAssertNil(AudioMetadata.scrubbed(Self.synthetic(mvhdVersion: 2)), "an unknown header version")
        XCTAssertNil(AudioMetadata.scrubbed(good.dropFirst(32)), "no ftyp first")
        XCTAssertNil(AudioMetadata.scrubbed(Data()), "empty")
        // A box that claims more than its parent holds.
        var lying = good
        let moovAt = lying.range(of: Data("moov".utf8))!.lowerBound - 4
        lying[moovAt] = 0x7F
        XCTAssertNil(AudioMetadata.scrubbed(lying))
        // Two moov boxes: the second's times would stay.
        let moov = Self.box("moov", Self.timed("mvhd", version: 0, rest: 88))
        XCTAssertNil(AudioMetadata.scrubbed(good + Data(moov)))
        // A last mdat cut short is a recording that stopped: still read.
        XCTAssertNotNil(AudioMetadata.scrubbed(good.dropLast(10)))
    }
}
