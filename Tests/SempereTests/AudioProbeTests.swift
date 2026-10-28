import FuzzSupport
import Foundation
import XCTest

@testable import Sempere

/// `AudioProbe` reads real MPEG-4 audio written by ffmpeg (Fixtures/audio) and
/// refuses damaged or hostile files with a typed error.
final class AudioProbeTests: XCTestCase {
    static let audio = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/audio")

    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: audio.appendingPathComponent(name)) }

    func testAACLCWithMoovAfterTheSamples() throws {
        let info = try AudioProbe.probe(file: Self.audio.appendingPathComponent("tone-aac.m4a"))
        XCTAssertEqual(info.codec, "aac")
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(try XCTUnwrap(info.duration), 2.5, accuracy: 0.05)
        // Average over the whole file: about 69 kbit/s (64 kbit/s payload plus framing).
        XCTAssertEqual(Double(try XCTUnwrap(info.bitRate)), 69_000, accuracy: 6_000)
    }

    func testFaststartFileGivesTheSameAnswer() throws {
        XCTAssertEqual(try AudioProbe.probe(try Self.fixture("tone-aac-faststart.m4a")),
                       try AudioProbe.probe(try Self.fixture("tone-aac.m4a")))
    }

    func testALAC() throws {
        let info = try AudioProbe.probe(try Self.fixture("tone-alac.m4a"))
        XCTAssertEqual(info.codec, "alac")
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(try XCTUnwrap(info.duration), 1.0, accuracy: 0.05)
    }

    /// A zero `mdhd` duration falls back to `mvhd` (as for video), and a
    /// version-1 duration of 0xFFFFFFFF ticks is a real one: only all ones
    /// of the box version's own width means "unknown".
    func testDurationFallbackAndUnknownSentinel() throws {
        var bytes = [UInt8](try Self.fixture("tone-aac-faststart.m4a"))
        let at = try XCTUnwrap((0..<bytes.count - 4).first { Array(bytes[$0..<$0 + 4]) == Array("mdhd".utf8) }) + 4
        XCTAssertEqual(bytes[at], 0, "a version-0 mdhd in the fixture")
        bytes.replaceSubrange(at + 16..<at + 20, with: [0, 0, 0, 0])
        XCTAssertEqual(try XCTUnwrap(try AudioProbe.probe(Data(bytes)).duration), 2.5, accuracy: 0.05)

        let v1: [UInt8] = [1, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + [0, 0, 0x03, 0xE8] + [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(VideoProbe.duration(v1), 4_294_967.295)
        XCTAssertNil(VideoProbe.duration(Array(v1.prefix(24)) + [UInt8](repeating: 0xFF, count: 8)))
        let v0: [UInt8] = [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8) + [0, 0, 0x03, 0xE8] + [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertNil(VideoProbe.duration(v0))
    }

    func testNotMPEG4() {
        XCTAssertThrowsError(try AudioProbe.probe(Data("RIFF....WAVEfmt ".utf8))) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
        XCTAssertThrowsError(try AudioProbe.probe(Data())) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
        XCTAssertThrowsError(try AudioProbe.probe(Data(repeating: 0, count: 7))) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
    }

    func testTruncatedAndLyingFiles() throws {
        let good = try Self.fixture("tone-aac-faststart.m4a")
        // Cut inside moov, inside ftyp and right after ftyp: typed errors, never a trap.
        for cut in [20, 28, 40, 100, 500, 1200] {
            XCTAssertThrowsError(try AudioProbe.probe(good.prefix(cut)), "cut at \(cut)") { XCTAssertTrue($0 is AudioProbeError, "\($0)") }
        }
        // A moov box claiming 4 GiB, and a box smaller than its own header.
        var big = Array(good.prefix(28)) + [0xFF, 0xFF, 0xFF, 0xF0] + Array("moov".utf8) + [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try AudioProbe.probe(Data(big))) { XCTAssertEqual($0 as? AudioProbeError, .malformed("moov box too large or cut off")) }
        big = Array(good.prefix(28)) + [0, 0, 0, 4] + Array("free".utf8)
        XCTAssertThrowsError(try AudioProbe.probe(Data(big))) { XCTAssertTrue($0 is AudioProbeError) }
        // An MP4 with only a file type box is an unfinished recording.
        XCTAssertThrowsError(try AudioProbe.probe(good.prefix(28)))
    }

    /// A box after the first with a 64-bit size near 2^64: `pos + size`
    /// overflowed (a trap, not an error). Now the file simply ends there.
    func testHugeSixtyFourBitBoxSizeDoesNotOverflow() throws {
        let good = try Self.fixture("tone-aac-faststart.m4a")
        for size: UInt64 in [.max, .max - 7, 1 << 63] {
            let be = (0..<8).map { UInt8(truncatingIfNeeded: size >> (56 - 8 * $0)) }
            let hostile = Array(good.prefix(28)) + [0, 0, 0, 1] + Array("free".utf8) + be + [UInt8](repeating: 0, count: 16)
            XCTAssertThrowsError(try AudioProbe.probe(Data(hostile)), "size \(size)") {
                XCTAssertTrue($0 is AudioProbeError, "\($0)")
            }
        }
    }

    func testATruncatedSampleBoxStillHasItsHeader() throws {
        // moov comes first: a recording cut off inside mdat is still described.
        let good = try Self.fixture("tone-aac-faststart.m4a")
        XCTAssertEqual(try AudioProbe.probe(good.prefix(1300)).codec, "aac")
    }

    func testFlippedBytesNeverTrap() throws {
        let good = try Self.fixture("tone-aac-faststart.m4a")
        for i in 0..<400 {   // the headers and moov
            var d = good
            d[i] ^= 0xFF
            _ = try? AudioProbe.probe(d)
        }
    }

    func testFuzz() throws {
        let seeds = try ["tone-aac.m4a", "tone-aac-faststart.m4a", "tone-alac.m4a"].map(Self.fixture)
        let report = Fuzz.run("audio-probe", seeds: seeds, quick: 400, maxSize: 64 << 10) { input in
            do { _ = try AudioProbe.probe(input) } catch is AudioProbeError {} catch { return "untyped error: \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
