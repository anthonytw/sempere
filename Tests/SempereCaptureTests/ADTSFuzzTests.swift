import Foundation
import FuzzSupport
@testable import SempereCapture
import XCTest

/// Seeded mutation fuzzing of `ADTSToMP4` (CLAUDE.md "Fuzzing"): a damaged segment is untrusted input, so every input
/// remuxes or fails with an `ADTSError`, and whatever remuxes is a well-formed MPEG-4 file whose samples add up.
final class ADTSFuzzTests: XCTestCase {
    /// `input` cut into one to three segments at places its own bytes choose (the same on every machine).
    static func split(_ input: Data) -> [Data] {
        guard input.count > 2 else { return [input] }
        let a = Int(input.reduce(UInt32(7)) { ($0 &* 31) &+ UInt32($1) }) % input.count
        let b = (a &* 7 &+ 3) % input.count
        let cuts = Array(Set([0, a, b, input.count])).sorted()
        return zip(cuts, cuts.dropFirst()).map { Data(input[$0..<$1]) }
    }

    static func exercise(_ input: Data) -> String? {
        for tail in [ADTSToMP4.Tail.strict, .dropPartial] {
            for segments in [[input], split(input)] {
            do {
                let (mp4, info) = try ADTSToMP4.remux(segments, tail: tail)
                guard info.frames > 0, info.duration > 0, info.sampleRate > 0, info.channels > 0 else { return "bad info \(info)" }
                let boxes = ADTSToMP4Tests.boxes(mp4)
                guard boxes.map(\.type) == ["ftyp", "moov", "mdat"] else { return "bad boxes \(boxes.map(\.type))" }
                guard let mdat = boxes.last, mdat.body.count <= input.count else { return "mdat larger than the input" }
                guard ADTSToMP4.audio(in: input) == .audio || tail == .strict || segments.count > 1 else { return "remuxed but not classified audio" }
                // The sample table agrees with the file: the sizes add up to the mdat body, which the first chunk starts.
                guard let table = ADTSToMP4Tests.sampleTable(mp4) else { return "no sample table" }
                guard table.sizes.count == info.frames else { return "stsz has \(table.sizes.count) samples, info \(info.frames)" }
                guard table.sizes.reduce(0, +) == mdat.body.count else { return "stsz sums to \(table.sizes.reduce(0, +)), mdat \(mdat.body.count)" }
                guard table.firstOffset == mdat.body.lowerBound else { return "stco[0] \(table.firstOffset) is not the mdat body at \(mdat.body.lowerBound)" }
            } catch is ADTSError {
            } catch {
                return "untyped error \(type(of: error)): \(error)"
            }
            }
        }
        _ = ADTSToMP4.audio(in: input)
        return nil
    }

    /// Valid streams with hostile headers.
    static func generate(_ rng: inout FuzzRNG) -> Data {
        var d = Data()
        for _ in 0..<(1 + rng.below(12)) {
            let payload = rng.pick([0, 1, 2, 20, 200, 2000, 8184])
            let lengthLie = rng.oneIn(4) ? rng.pick([0, 6, 7, 8, 9, 100, 8191]) : 7 + payload
            var h = ADTS.header(length: lengthLie, rateIndex: rng.pick([0, 3, 6, 6, 6, 12, 13, 15]),
                                channels: rng.pick([0, 1, 1, 1, 2, 7]), profile: rng.pick([0, 1, 1, 1, 2, 3]), crc: rng.oneIn(5),
                                blocks: rng.oneIn(8) ? rng.below(4) : 0)
            if rng.oneIn(10) { h[0] = UInt8(truncatingIfNeeded: rng.below(256)) }
            d.append(contentsOf: h)
            d.append(Data(count: payload))
        }
        return d
    }

    func testFuzzADTSToMP4() {
        let seeds = [ADTS.stream(frames: 8), ADTS.stream(frames: 1), ADTS.stream(frames: 40, rateIndex: 4),
                     ADTS.stream(frames: 5).dropLast(9), Data()]
        let report = Fuzz.run("adts", seeds: seeds, quick: 1500, text: false, maxSize: 64 << 10,
                              generate: Self.generate) { input in Self.exercise(input) }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
