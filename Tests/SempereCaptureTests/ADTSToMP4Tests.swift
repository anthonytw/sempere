import Crypto
import Foundation
@testable import Sempere
@testable import SempereCapture
import XCTest

/// `ADTSToMP4`: the pure-Swift remux of voice note segments (docs/design/1.1-watch.md §3.5, D4).
final class ADTSToMP4Tests: XCTestCase {
    // MARK: Output

    /// The boxes at the top level of `data`: type and body range.
    static func boxes(_ data: Data, in range: Range<Int>? = nil) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var o = range?.lowerBound ?? 0
        let end = range?.upperBound ?? data.count
        while o + 8 <= end {
            let size = data[o..<o + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: data[o + 4..<o + 8], as: UTF8.self)
            guard size >= 8, o + size <= end else { break }
            out.append((type, o + 8..<o + size))
            o += size
        }
        return out
    }

    /// The sample sizes (`stsz`) and the first chunk offset (`stco`) of `mp4`.
    static func sampleTable(_ mp4: Data) -> (sizes: [Int], firstOffset: Int)? {
        let bytes = [UInt8](mp4)
        func find(_ tag: String) -> Int? { bytes.indices.first { bytes[$0...].starts(with: Array(tag.utf8)) } }
        func u32(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        guard let z = find("stsz"), let c = find("stco") else { return nil }
        let count = u32(z + 12)
        guard z + 16 + count * 4 <= bytes.count, u32(c + 8) > 0 else { return nil }
        return ((0..<count).map { u32(z + 16 + $0 * 4) }, u32(c + 12))
    }

    func testGoldenBytes() throws {
        // Three frames of 10, 20 and 30 payload bytes at 24 kHz, mono.
        var stream = Data()
        for (i, n) in [10, 20, 30].enumerated() { stream.append(ADTS.frame(payload: n, seed: UInt8(i * 50))) }
        let (mp4, info) = try ADTSToMP4.remux(stream)
        XCTAssertEqual(info.frames, 3)
        XCTAssertEqual(info.sampleRate, 24000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.duration, 3 * 1024 / 24000.0, accuracy: 1e-9)
        // The file's structure: ftyp, moov, mdat.
        XCTAssertEqual(Self.boxes(mp4).map(\.type), ["ftyp", "moov", "mdat"])
        XCTAssertEqual(mp4.prefix(12).map { String(format: "%02x", $0) }.joined(), "0000001c667479704d344120")   // ftyp, M4A
        // A pinned digest: any change to the bytes written is deliberate.
        XCTAssertEqual(SHA256.hash(data: mp4).map { String(format: "%02x", $0) }.joined(), Self.goldenDigest)
    }

    static let goldenDigest = "668d43cc6ddc5c26b0cf1f8e9bc3f25b5e98e01068399f6ff53e2b1d6ea2c293"

    func testSamplesAreTheFramesWithoutTheirHeaders() throws {
        let stream = ADTS.stream(frames: 150)
        let (mp4, info) = try ADTSToMP4.remux(stream)
        XCTAssertEqual(info.frames, 150)
        let mdat = try XCTUnwrap(Self.boxes(mp4).first { $0.type == "mdat" })
        XCTAssertEqual(mp4[mdat.body], ADTS.payloads(frames: 150))
    }

    func testTheContainerReadsBackThroughAudioProbe() throws {
        let (mp4, info) = try ADTSToMP4.remux(ADTS.stream(frames: 200))
        let probed = try AudioProbe.probe(mp4)
        XCTAssertEqual(probed.codec, "aac")
        XCTAssertEqual(probed.sampleRate, 24000)
        XCTAssertEqual(probed.channels, 1)
        XCTAssertEqual(try XCTUnwrap(probed.duration), info.duration, accuracy: 0.001)
        XCTAssertEqual(info.duration, 200 * 1024 / 24000.0, accuracy: 1e-9)
    }

    func testChunkTableCoversEveryFrame() throws {
        // 130 frames: two chunks of 64 and one of 2.
        let (mp4, _) = try ADTSToMP4.remux(ADTS.stream(frames: 130))
        let s = String(decoding: mp4, as: UTF8.self)
        XCTAssertTrue(s.contains("stco"))
        let moov = try XCTUnwrap(Self.boxes(mp4).first { $0.type == "moov" })
        let mdat = try XCTUnwrap(Self.boxes(mp4).first { $0.type == "mdat" })
        // Find stco: its first entry is the start of mdat's data.
        let bytes = [UInt8](mp4[moov.body])
        let at = try XCTUnwrap(bytes.indices.first { bytes[$0...].starts(with: Array("stco".utf8)) })
        let count = bytes[at + 8..<at + 12].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(count, 3)
        let first = bytes[at + 12..<at + 16].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(first, mdat.body.lowerBound)
    }

    func testSegmentsJoin() throws {
        let a = ADTS.stream(frames: 30, seed: 1), b = ADTS.stream(frames: 20, seed: 9)
        let (mp4, info) = try ADTSToMP4.remux([a, b])
        XCTAssertEqual(info.frames, 50)
        let mdat = try XCTUnwrap(Self.boxes(mp4).first { $0.type == "mdat" })
        XCTAssertEqual(mp4[mdat.body], ADTS.payloads(frames: 30, seed: 1) + ADTS.payloads(frames: 20, seed: 9))
    }

    func testBitRateIsTheAverageOfTheFrames() throws {
        let (_, info) = try ADTSToMP4.remux(ADTS.stream(frames: 100))
        let payload = ADTS.payloads(frames: 100).count
        XCTAssertEqual(info.bitRate, Int((Double(payload) * 8 / info.duration).rounded()))
    }

    func testCRCHeadersAreSkipped() throws {
        var stream = Data()
        for i in 0..<5 { stream.append(ADTS.frame(payload: 12 + i, seed: UInt8(i), crc: true)) }
        let (mp4, info) = try ADTSToMP4.remux(stream)
        XCTAssertEqual(info.frames, 5)
        let mdat = try XCTUnwrap(Self.boxes(mp4).first { $0.type == "mdat" })
        XCTAssertEqual(mp4[mdat.body].count, (0..<5).reduce(0) { $0 + 12 + $1 })
    }

    func testOtherRatesAndStereo() throws {
        var stream = Data()
        for i in 0..<4 { stream.append(ADTS.frame(payload: 40, seed: UInt8(i), rateIndex: 4, channels: 2)) }   // 44.1 kHz stereo
        let (mp4, info) = try ADTSToMP4.remux(stream)
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(try AudioProbe.probe(mp4).channels, 2)
    }

    // MARK: Failures are typed

    func testJunkFailsTyped() {
        XCTAssertThrowsError(try ADTSToMP4.remux(Data("not audio at all, just text".utf8))) {
            XCTAssertEqual($0 as? ADTSError, .badHeader(offset: 0))
        }
        XCTAssertThrowsError(try ADTSToMP4.remux(Data())) { XCTAssertEqual($0 as? ADTSError, .noFrames) }
        XCTAssertThrowsError(try ADTSToMP4.remux([Data(), Data()])) { XCTAssertEqual($0 as? ADTSError, .noFrames) }
        // Junk after good frames.
        var d = ADTS.stream(frames: 3)
        let junkAt = d.count
        d.append(Data(repeating: 0x55, count: 40))
        XCTAssertThrowsError(try ADTSToMP4.remux(d)) { XCTAssertEqual($0 as? ADTSError, .badHeader(offset: junkAt)) }
        XCTAssertThrowsError(try ADTSToMP4.remux(d, tail: .dropPartial), "junk is not a cut-off frame") {
            XCTAssertEqual($0 as? ADTSError, .badHeader(offset: junkAt))
        }
    }

    func testTruncatedHeaderFailsTyped() {
        let d = ADTS.stream(frames: 2)
        let cut = d + d.prefix(4)
        XCTAssertThrowsError(try ADTSToMP4.remux(cut)) { XCTAssertEqual($0 as? ADTSError, .truncatedHeader(offset: d.count)) }
        XCTAssertThrowsError(try ADTSToMP4.remux(Data([0xFF, 0xF1, 0x58]))) {
            XCTAssertEqual($0 as? ADTSError, .truncatedHeader(offset: 0))
        }
    }

    func testFrameLengthOverTheInputFailsTyped() {
        var d = ADTS.stream(frames: 2)
        let at = d.count
        d.append(Data(ADTS.header(length: 500)) + Data(count: 30))   // claims 500, holds 37
        XCTAssertThrowsError(try ADTSToMP4.remux(d)) { XCTAssertEqual($0 as? ADTSError, .badFrameLength(offset: at)) }
        // A frame shorter than its own header.
        XCTAssertThrowsError(try ADTSToMP4.remux(Data(ADTS.header(length: 5)) + Data(count: 20))) {
            XCTAssertEqual($0 as? ADTSError, .badFrameLength(offset: 0))
        }
        // No payload at all.
        XCTAssertThrowsError(try ADTSToMP4.remux(Data(ADTS.header(length: 7)))) {
            XCTAssertEqual($0 as? ADTSError, .badFrameLength(offset: 0))
        }
    }

    func testChangingParametersFailTyped() {
        var d = ADTS.frame(payload: 20)
        let at = d.count
        d.append(ADTS.frame(payload: 20, rateIndex: 3))
        XCTAssertThrowsError(try ADTSToMP4.remux(d)) { XCTAssertEqual($0 as? ADTSError, .parametersChanged(offset: at)) }
        // Across segments too.
        XCTAssertThrowsError(try ADTSToMP4.remux([ADTS.frame(payload: 20), ADTS.frame(payload: 20, channels: 2)])) {
            XCTAssertEqual($0 as? ADTSError, .parametersChanged(offset: 0))
        }
    }

    func testUnsupportedStreamsFailTyped() {
        for (stream, what) in [(ADTS.frame(payload: 20, profile: 0), "profile"), (ADTS.frame(payload: 20, profile: 3), "profile"),
                               (ADTS.frame(payload: 20, blocks: 1), "raw data blocks"),
                               (ADTS.frame(payload: 20, channels: 0), "channel")] {
            XCTAssertThrowsError(try ADTSToMP4.remux(stream)) {
                guard case .unsupported(let why)? = $0 as? ADTSError else { return XCTFail("\($0)") }
                XCTAssertTrue(why.contains(what), why)
            }
        }
        // A reserved sample rate index and a layer other than 0.
        XCTAssertThrowsError(try ADTSToMP4.remux(ADTS.frame(payload: 20, rateIndex: 13))) {
            XCTAssertEqual($0 as? ADTSError, .badHeader(offset: 0))
        }
        var layer = ADTS.frame(payload: 20)
        layer[1] |= 0x02
        XCTAssertThrowsError(try ADTSToMP4.remux(layer)) { XCTAssertEqual($0 as? ADTSError, .badHeader(offset: 0)) }
    }

    func testTooMuchInputFailsBeforeTheWalk() {
        let big = Data(count: ADTSToMP4.maxInputBytes + 1)
        XCTAssertThrowsError(try ADTSToMP4.remux(big)) { XCTAssertEqual($0 as? ADTSError, .tooLarge(ADTSToMP4.maxInputBytes)) }
        XCTAssertEqual(ADTSToMP4.audio(in: big), .undecodable)
    }

    // MARK: A crash's cut-off tail

    func testACutOffLastFrameIsDroppedOnlyWhenAsked() throws {
        let whole = ADTS.stream(frames: 10)
        let cut = whole.dropLast(7)   // the tenth frame loses its end
        XCTAssertThrowsError(try ADTSToMP4.remux(Data(cut)))
        let (mp4, info) = try ADTSToMP4.remux(Data(cut), tail: .dropPartial)
        XCTAssertEqual(info.frames, 9)
        XCTAssertEqual(try AudioProbe.probe(mp4).sampleRate, 24000)
        // Cut inside the last header.
        let cutHeader = ADTS.stream(frames: 10) + ADTS.stream(frames: 1).prefix(3)
        XCTAssertEqual(try ADTSToMP4.remux(Data(cutHeader), tail: .dropPartial).info.frames, 10)
        // Nothing whole at all stays an error.
        XCTAssertThrowsError(try ADTSToMP4.remux(Data(whole.prefix(5)), tail: .dropPartial)) {
            XCTAssertEqual($0 as? ADTSError, .noFrames)
        }
    }

    // MARK: What a segment holds

    func testAudioClassification() {
        XCTAssertEqual(ADTSToMP4.audio(in: Data()), .none)
        XCTAssertEqual(ADTSToMP4.audio(in: ADTS.stream(frames: 4)), .audio)
        XCTAssertEqual(ADTSToMP4.audio(in: ADTS.stream(frames: 4).dropLast(3)), .audio, "a cut-off last frame is the crash's")
        XCTAssertEqual(ADTSToMP4.audio(in: Data("not audio".utf8)), .undecodable)
        XCTAssertEqual(ADTSToMP4.audio(in: Data(ADTS.header(length: 100)) + Data(count: 10)), .undecodable, "no whole frame")
        XCTAssertEqual(ADTSToMP4.audio(in: Data([0xFF, 0xF1])), .undecodable)
    }
}

extension ADTSToMP4Tests {
    /// Frames are bounded before they are held: a stream of the smallest frames does not build a table of millions.
    func testTheFrameCountIsBounded() {
        // The smallest legal frame is 8 bytes (a header and one byte).
        let frame = Data(ADTS.header(length: 8)) + Data([1])
        let n = ADTSToMP4.maxFrames + 1
        var big = Data()
        big.reserveCapacity(n * 8)
        for _ in 0..<n { big.append(frame) }
        XCTAssertThrowsError(try ADTSToMP4.remux(big)) { XCTAssertEqual($0 as? ADTSError, .tooManyFrames) }
        XCTAssertEqual(ADTSToMP4.audio(in: big), .undecodable)
    }
}
