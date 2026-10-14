import Foundation
import FuzzSupport
import XCTest
@testable import Sempere

/// `FastRevisionDecoder`: the hand-written reader of stroke points must give
/// exactly what the Codable decoder gives (or fail exactly when it fails).
final class FastDecodeTests: XCTestCase {
    /// Both readers on `json`: equal revisions, or both errors.
    func agree(_ json: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let slow = Result { try InkJSON.decoder().decode(Revision.self, from: json) }
        let fast = Result { try FastRevisionDecoder.decode(json) }
        switch (slow, fast) {
        case (.success(let s), .success(let f)):
            XCTAssertEqual(f, s, label, file: file, line: line)
            // `==` on Double treats 0 and -0 alike: compare the bits too.
            let bits = { (r: Revision) in allStrokes(r).flatMap { $0.points.flatMap { p in
                [p.x, p.y, p.t, p.w, p.h, p.o, p.f, p.az, p.al].map(\.bitPattern) } } }
            XCTAssertEqual(bits(f), bits(s), label, file: file, line: line)
        case (.failure, .failure): break
        case (.success, .failure(let e)): XCTFail("\(label): only the fast reader fails: \(e)", file: file, line: line)
        case (.failure(let e), .success): XCTFail("\(label): only the Codable reader fails: \(e)", file: file, line: line)
        }
    }

    /// One `addStroke` revision whose stroke's `points` value is `points` (raw JSON).
    func revision(points: String) throws -> Data {
        let stroke = Stroke(id: UUID(uuidString: "f1c70000-0000-4000-8000-000000000001")!,
                            ink: Ink(tool: .pen, color: .black, width: 2),
                            points: [StrokePoint(x: 1, y: 2, w: 3, h: 3)])
        let rev = Revision(noteId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, device: DeviceID("a1b2c3d4")!,
                           seq: 1, hlc: HLC(millis: 1_780_000_000_000, counter: 0)!,
                           wall: Date(timeIntervalSince1970: 1_780_000_000), app: "test/1",
                           body: .delta(ops: [.addStroke(page: UUID(uuidString: "f1c70000-0000-4000-8000-000000000101")!,
                                                          stroke: stroke)]))
        let json = String(decoding: try InkJSON.encoder().encode(rev), as: UTF8.self)
        let template = #""points":[[1,2,0,3,3,1,0,0,1.571]]"#
        XCTAssertTrue(json.contains(template), json)
        return Data(json.replacingOccurrences(of: template, with: #""points":"# + points).utf8)
    }

    /// Every revision of the fuzz seed log and of random histories.
    func testRandomHistoriesDecodeAlike() throws {
        var rng = SeededRNG(11)
        var revs = try SempereFuzzTests.seedLog()
        for _ in 0..<60 { revs += try SyntheticVault.randomHistory(note: UUID.random(&rng), rng: &rng) }
        for n in 0..<6 {
            revs.append(SyntheticVault.importedNote(index: n, strokes: 40, points: 30, rng: &rng, baseMillis: 1_780_000_000_000))
        }
        var marked = 0
        for r in revs {
            let json = try InkJSON.encoder().encode(r)
            if StrokePointsFilter.extract(json) != nil { marked += 1 }
            agree(json, "\(r.name.filename)")
        }
        XCTAssertGreaterThan(marked, 50, "the fast path was taken")
    }

    /// Point values written every way JSON allows.
    func testEdgeCases() throws {
        let p = "[1,2,3,4,5,6,7,8,9]"
        let cases: [(String, String)] = [
            ("plain", "[\(p),\(p)]"),
            ("empty", "[]"),
            ("negatives and zeros", "[[-1,-0,0,-0.0,0.0,-12.5,-0.001,7,-9]]"),
            ("integers", "[[1,22,333,4444,55555,666666,7777777,88888888,999999999]]"),
            ("whitespace", "[ [ 1 ,\n2,\t3 ,4,5,6,7,8,9 ] ,\r\n[1,2,3,4,5,6,7,8,9]]"),
            ("15 to 17 digits", "[[0.123456789012345,1.2345678901234567,12345678901234567,0.1,0.2,0.3,"
                + "9007199254740993,1.7976931348623157,4.9406564584124654]]"),
            ("long fraction", "[[0.00000000000000000000000123,1,2,3,4,5,6,7,8]]"),
            ("300-digit integer", "[[\(String(repeating: "9", count: 300)),1,2,3,4,5,6,7,8]]"),
            ("301-digit integer", "[[\(String(repeating: "9", count: 301)),1,2,3,4,5,6,7,8]]"),
            ("exponents", "[[1e2,2E-3,3e+4,-4.5e1,5,6,7,8,9]]"),
            ("exponent overflow", "[[1e400,2,3,4,5,6,7,8,9]]"),
            ("null", "[[null,2,3,4,5,6,7,8,9]]"),
            ("null array", "null"),
            ("eight numbers", "[[1,2,3,4,5,6,7,8]]"),
            ("ten numbers", "[[1,2,3,4,5,6,7,8,9,10]]"),
            ("NaN", "[[NaN,2,3,4,5,6,7,8,9]]"),
            ("Infinity", "[[Infinity,2,3,4,5,6,7,8,9]]"),
            ("string", "[[\"1\",2,3,4,5,6,7,8,9]]"),
            ("leading zero", "[[01,2,3,4,5,6,7,8,9]]"),
            ("plus sign", "[[+1,2,3,4,5,6,7,8,9]]"),
            ("bare dot", "[[1.,2,3,4,5,6,7,8,9]]"),
            ("trailing comma", "[[1,2,3,4,5,6,7,8,9],]"),
            ("a marker-like value", "[[0,0,0,0,0,0,0,0,-1e300]]"),
            ("a marker with our spelling", "[[0,0,0,0,0,0,0,0,-1000000000000000000000000000000000000000000]]"),
        ]
        for (label, points) in cases { agree(try revision(points: points), label) }
    }

    /// `"points"` members that are not a stroke's: the result is discarded
    /// and the ordinary decoder reads the JSON.
    func testPointsOutsideStrokesAndOddKeys() throws {
        let p = "[[1,2,3,4,5,6,7,8,9]]"
        let base = String(decoding: try revision(points: p), as: UTF8.self)
        // A duplicate key in the stroke object.
        agree(Data(base.replacingOccurrences(of: #""points":"#, with: #""points":\#(p),"points":"#).utf8), "duplicate key")
        // An escaped spelling of the key.
        agree(Data(base.replacingOccurrences(of: #""points":"#, with: "\"p\\u006fints\":").utf8), "escaped key")
        // A member named points at the revision's top level (ignored by the decoder).
        agree(Data(base.replacingOccurrences(of: #"{"app""#, with: #"{"points":\#(p),"app""#).utf8), "extra member")
        XCTAssertTrue(base.hasPrefix(#"{"app""#), base)
        // Extract's own output is never mistaken for input it made.
        let marked = try XCTUnwrap(StrokePointsFilter.extract(Data(base.utf8)))
        XCTAssertNil(StrokePointsFilter.extract(marked.json), "markers have an exponent: never parsed again")
    }

    /// A value spelled like a marker (exponent: never extracted) next to a real
    /// one: the decoder keeps one of a duplicate key, and the forged marker
    /// must not be filled with the other value's points.
    func testAForgedMarkerIsNeverFilled() throws {
        let p = "[[1,2,3,4,5,6,7,8,9]]"
        let base = String(decoding: try revision(points: p), as: UTF8.self)
        for forged in ["[[0,0,0,0,0,0,0,0,-1e300]]", "[[0,1,0,0,0,0,0,0,-1E300]]", "[[0.0,4503599627370495,0,0,0,0,0,0,-10e299]]"] {
            agree(Data(base.replacingOccurrences(of: #""points":"#, with: #""points":\#(p),"points":"#)
                .replacingOccurrences(of: #""points":\#(p)}"#, with: #""points":\#(forged)}"#).utf8), "forged after")
            agree(Data(base.replacingOccurrences(of: #""points":"#, with: #""points":\#(forged),"points":"#).utf8),
                  "forged before")
        }
    }

    /// Numbers: the fast parse is bit-identical to the decoder's.
    func testNumbersParseLikeTheDecoder() throws {
        var rng = SeededRNG(3)
        var texts: [String] = ["0", "-0", "0.0", "-0.0", "1", "-1", "0.5", "1.000", "123456789012345",
                               "1234567890123456", "0.1", "0.7", "2.675", "1.0000000000000002", "9007199254740993"]
        for _ in 0..<4000 {
            let v = Double.random(in: -5000...5000, using: &rng)
            texts.append("\(InkJSON.round3(v))")
            texts.append(String(format: "%.\(Int(rng.next() % 20))f", v))
            let digits = Int(rng.next() % 25) + 1
            var s = rng.next() % 2 == 0 ? "-" : ""
            s += "\(rng.next() % 9 + 1)" + (0..<digits).map { _ in "\(rng.next() % 10)" }.joined()
            let point = Int(rng.next() % UInt64(s.count + 1))
            if point > 1 && point < s.count { s.insert(".", at: s.index(s.startIndex, offsetBy: point)) }
            texts.append(s)
        }
        for t in texts {
            let reference = try InkJSON.decoder().decode([Double].self, from: Data("[\(t)]".utf8))[0]
            let parsed = Data(t.utf8).withUnsafeBytes { raw in
                StrokePointsFilter.parseNumber(raw.bindMemory(to: UInt8.self), from: 0)
            }
            XCTAssertEqual(parsed?.0, t.utf8.count, t)
            XCTAssertEqual(parsed?.1.bitPattern, reference.bitPattern, t)
        }
    }

    /// Mutated revisions: both readers agree on every input.
    func testFuzzFastReaderAgreesWithTheDecoder() throws {
        let seeds = try SempereFuzzTests.seedLog().map(SempereFuzzTests.json)
        let report = Fuzz.run("fast-points", seeds: seeds, quick: 1200, text: true) { input in
            let slow = Result { try InkJSON.decoder().decode(Revision.self, from: input) }
            let fast = Result { try FastRevisionDecoder.decode(input) }
            switch (slow, fast) {
            case (.success(let s), .success(let f)): return s == f ? nil : "revisions differ"
            case (.failure, .failure): return nil
            case (.success, .failure(let e)): return "only the fast reader fails: \(e)"
            case (.failure(let e), .success): return "only the Codable reader fails: \(e)"
            }
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
