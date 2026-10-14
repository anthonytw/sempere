import Foundation
import ImportTestSupport
import XCTest
@testable import SempereImport
@testable import SempereNotability

/// Seeded mutation fuzzing of the untrusted-input readers added for full
/// backups: the schema-less `.ntb` FlatBuffers reader and the shape-object
/// decoder. Every mutant must parse or throw, quickly; nothing may crash.
/// Synthetic inputs only.
final class NotabilityFuzzTests: XCTestCase {
    /// SplitMix64: a fixed seed gives the same mutants on every platform.
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let interesting: [UInt32] = [0, 1, 2, 3, 4, 7, 8, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF,
                                        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFC, 0xFFFF_FFFF]

    /// Applies 1–8 random byte flips, interesting 16/32-bit values, small
    /// offset nudges, truncations and insertions.
    static func mutate(_ seed: [UInt8], _ rng: inout RNG) -> [UInt8] {
        var b = seed
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            guard !b.isEmpty else { b = [0]; continue }
            let p = Int.random(in: 0..<b.count, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: b[p] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            case 1: b[p] = UInt8.random(in: 0...255, using: &rng)
            case 2:
                var v = interesting.randomElement(using: &rng) ?? 0
                if Bool.random(using: &rng) { v = UInt32(b.count) &+ UInt32.random(in: 0...8, using: &rng) &- 4 }
                for i in 0..<4 where p + i < b.count { b[p + i] = UInt8(v >> (8 * UInt32(i)) & 0xFF) }
            case 3:
                let v = UInt16(truncatingIfNeeded: interesting.randomElement(using: &rng) ?? 0)
                for i in 0..<2 where p + i < b.count { b[p + i] = UInt8(v >> (8 * UInt16(i)) & 0xFF) }
            case 4:
                // Nudge a little-endian word, as a slightly wrong offset would be.
                guard p + 4 <= b.count else { continue }
                let v = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
                let w = v &+ UInt32(bitPattern: Int32.random(in: -16...16, using: &rng))
                for i in 0..<4 { b[p + i] = UInt8(w >> (8 * UInt32(i)) & 0xFF) }
            case 5: b.removeSubrange(p..<min(b.count, p + Int.random(in: 1...16, using: &rng)))
            default:
                b.insert(contentsOf: (0..<Int.random(in: 1...8, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) },
                         at: p)
            }
        }
        return b
    }

    /// A bundle exercising every record kind the reader decodes.
    static func seedBundle() -> Data {
        let s1 = SyntheticBundle.StrokeSpec(origin: (100, 50), segments: [((1, 0), (2, 0), (3, 1), false),
                                                                           ((4, 1), (5, 2), (6, 3), false)])
        var s2 = SyntheticBundle.StrokeSpec(page: 1, origin: (200, 60), segments: [
            ((0, 1), (0, 2), (1, 3), false), ((0, 0), (0, 0), (10, 0), true), ((11, 1), (12, 2), (13, 3), false),
        ], rgba: [0xFF, 0xFF, 0, 0x6B], width: 6, highlighter: true, dashed: true)
        s2.wide = true
        return SyntheticBundle.noteBundle(strokes: [s1, s2], lines: [((50, 70), (100, 0))],
                                          extraRecords: [SyntheticBundle.record(50, type: 2, payload: [0: .u32(0)]),
                                                         SyntheticBundle.erase([7])])
    }

    func testBundleMutantsParseOrThrow() throws {
        let seed = [UInt8](Self.seedBundle())
        XCTAssertNoThrow(try NotabilityBundle.parse(bundle: Data(seed)))
        var rng = RNG(state: 0x1A7E_5EED)
        var parsed = 0, threw = 0, slowest = 0.0
        for _ in 0..<20_000 {
            let mutant = Data(Self.mutate(seed, &rng))
            let t = Date()
            if let note = try? NotabilityBundle.parse(bundle: mutant) {
                parsed += 1
                // Whatever parses must also convert.
                _ = NotabilityImporter.convert(note)
            } else {
                threw += 1
            }
            slowest = max(slowest, Date().timeIntervalSince(t))
        }
        print("ntb fuzz: \(parsed) parsed, \(threw) rejected, slowest \(slowest) s")
        XCTAssertGreaterThan(parsed, 0)
        XCTAssertGreaterThan(threw, 0)
        XCTAssertLessThan(slowest, 1)
    }

    /// Random geometry blobs straight into the stroke decoder.
    func testRandomGeometryBlobs() {
        var rng = RNG(state: 42)
        let seed = SyntheticBundle.geometry(.init(origin: (0, 0), segments: [((1, 0), (2, 0), (3, 1), false),
                                                                            ((0, 0), (0, 0), (9, 9), true)]))
        for i in 0..<20_000 {
            let blob = i % 2 == 0 ? Self.mutate(seed, &rng)
                : (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if let pieces = NotabilityBundle.geometry(Data(blob), x0: 1, y0: 2) {
                for g in pieces {
                    XCTAssertEqual((g.points.count - 1) % 3, 0)
                    XCTAssertEqual(g.fw.count, (g.points.count - 1) / 3 + 1)
                    XCTAssertTrue(g.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                }
            }
        }
    }

    /// A random plist value, biased towards the shapes the converter reads.
    static func randomValue(_ rng: inout RNG, depth: Int = 0) -> PlistValue {
        let reals: [Double] = [0, -1, 1e300, -1e300, .nan, .infinity, -.infinity, 2e6, 0.5, 400]
        switch Int.random(in: 0..<(depth > 2 ? 4 : 7), using: &rng) {
        case 0: return .real(reals.randomElement(using: &rng) ?? 0)
        case 1: return .int(Int64.random(in: -3...300, using: &rng))
        case 2: return .string(["line", "circle", "ellipse", "partialshape", ""].randomElement(using: &rng) ?? "")
        case 3: return .data(Data((0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        case 4, 5:
            return .array((0..<Int.random(in: 0...5, using: &rng)).map { _ in randomValue(&rng, depth: depth + 1) })
        default:
            let keys = ["startPt", "endPt", "rotatedRect", "corners", "strokePath", "appearance", "strokeWidth",
                        "strokeColor", "rgba", "style"]
            var d: [String: PlistValue] = [:]
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                d[keys.randomElement(using: &rng) ?? ""] = randomValue(&rng, depth: depth + 1)
            }
            return .dict(d)
        }
    }

    /// Replaces random nodes of `v` with random values.
    static func mutate(_ v: PlistValue, _ rng: inout RNG, depth: Int = 0) -> PlistValue {
        if Int.random(in: 0..<8, using: &rng) == 0 { return randomValue(&rng, depth: depth) }
        switch v {
        case .array(let a): return .array(a.map { mutate($0, &rng, depth: depth + 1) })
        case .dict(let d): return .dict(d.mapValues { mutate($0, &rng, depth: depth + 1) })
        case .data(let b) where Bool.random(using: &rng): return .data(Data(mutate([UInt8](b), &rng)))
        default: return v
        }
    }

    /// Shape objects with random values in place of any part, and serialized
    /// paths, mutated. (Byte-level mutation of the shapes plist itself
    /// exercises Foundation's plist parser, which the strict reader of
    /// fix/untrusted-input-hardening replaces; this targets the converter.)
    func testShapeMutantsConvert() throws {
        let seed = try PlistValue.parse(NotabilityBackupTests.shapesPlist())
        XCTAssertEqual(try NotabilityShapes.curves(plist: seed).curves.count, 3)
        var rng = RNG(state: 7)
        var converted = 0
        for _ in 0..<20_000 {
            let (curves, _) = try NotabilityShapes.curves(plist: Self.mutate(seed, &rng))
            converted += curves.count
            for c in curves {
                XCTAssertEqual((c.points.count - 1) % 3, 0)
                XCTAssertEqual(c.fractionalWidths.count, (c.points.count - 1) / 3 + 1)
                XCTAssertTrue(c.points.allSatisfy { $0.x.isFinite && $0.y.isFinite
                    && abs($0.x) <= NotabilityNote.maxCoordinate && abs($0.y) <= NotabilityNote.maxCoordinate })
                XCTAssertTrue(c.width.isFinite && c.width > 0)
            }
        }
        XCTAssertGreaterThan(converted, 0)
        // The path decoder alone, on random bytes and on mutants of a valid path.
        var path: [UInt8] = [0x25, 0xB3, 0xE5, 0x48, 4, 0, 0, 0, 0, 3, 1, 4]
        for v in [400.0, 400, 410, 390, 430, 390, 440, 400, 440, 420] { withUnsafeBytes(of: v.bitPattern.littleEndian) { path += $0 } }
        XCTAssertNotNil(NotabilityShapes.decodePath(Data(path)))
        for i in 0..<20_000 {
            let bytes = i % 2 == 0 ? Self.mutate(path, &rng)
                : (0..<Int.random(in: 0...48, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // A slice with a non-zero start index, as Data from a plist can be.
            let data = Data([0xAA] + bytes).dropFirst()
            for p in NotabilityShapes.decodePath(data) ?? [] { XCTAssertEqual((p.count - 1) % 3, 0) }
        }
    }
}

extension NotabilityFuzzTests {
    /// A bundle whose record vector holds `records` references to one stroke
    /// record with `segments` half-float segments (all offsets point forward,
    /// as FlatBuffers requires): `records × segments × 3` points from a buffer
    /// of `4 × records + 19 × segments` bytes.
    static func sharedRecordBundle(records: Int, segments: Int) -> Data {
        var b: [UInt8] = []
        func u16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) { for i in 0..<4 { b.append(UInt8(v >> (8 * i) & 0xFF)) } }
        func put32(_ p: Int, _ v: Int) { for i in 0..<4 { b[p + i] = UInt8(v >> (8 * i) & 0xFF) } }
        func pad() { while b.count % 4 != 0 { b.append(0) } }
        u32(0)                                              // root offset, patched
        let rootVT = b.count; u16(18); u16(8); for i in 0...6 { u16(i == 6 ? 4 : 0) }; pad()
        let root = b.count; u32(root - rootVT); u32(0)      // field 6: records, patched
        let vector = b.count; u32(records); let slots = b.count; b += [UInt8](repeating: 0, count: 4 * records)
        let recVT = b.count; u16(16); u16(12); for i in 0...5 { u16([0, 0, 0, 0, 8, 4][i]) }; pad()
        let rec = b.count; u32(rec - recVT); u32(0); b += [15, 0, 0, 0]
        let payVT = b.count; u16(24); u16(16); for i in 0...9 { u16(i == 1 ? 4 : i == 9 ? 12 : 0) }; pad()
        let pay = b.count; u32(pay - payVT); b += SyntheticBundle.f32(100) + SyntheticBundle.f32(100); u32(0)
        let geo = b.count
        let seg: [UInt8] = [0] + [SyntheticBundle.half(1), SyntheticBundle.half(0), SyntheticBundle.half(2),
                                  SyntheticBundle.half(0), SyntheticBundle.half(3), SyntheticBundle.half(0)].flatMap { $0 }
            + SyntheticBundle.half(1) + SyntheticBundle.half(1) + [0xFF, 0]
        let blob: [UInt8] = [0] + SyntheticBundle.le16(UInt16(segments + 1)) + [3, 0, 0, 0, 0]
            + SyntheticBundle.half(1) + SyntheticBundle.half(1) + [0xFF, 0]
            + Array([[UInt8]](repeating: seg, count: segments).joined())
        u32(blob.count); b += blob
        put32(0, root); put32(root + 4, vector - (root + 4))
        for k in 0..<records { put32(slots + 4 * k, rec - (slots + 4 * k)) }
        put32(rec + 4, pay - (rec + 4)); put32(pay + 12, geo - (pay + 12))
        return Data(b)
    }

    /// One stroke record referenced from every slot of the record vector
    /// must not multiply into gigabytes of points: decoding is budgeted by
    /// the buffer's size, and the bundle is rejected.
    func testSharedRecordReferencesDoNotAmplify() throws {
        // A single reference decodes normally.
        let one = try NotabilityBundle.parse(bundle: Self.sharedRecordBundle(records: 1, segments: 1000))
        XCTAssertEqual(one.curves.count, 1)
        XCTAssertEqual(one.curves[0].points.count, 3001)
        // 20 000 references to a 19 kB stroke: 60 million points from 100 kB.
        let bomb = Self.sharedRecordBundle(records: 20_000, segments: 1000)
        XCTAssertLessThan(bomb.count, 120_000)
        let t = Date()
        XCTAssertThrowsError(try NotabilityBundle.parse(bundle: bomb)) { error in
            XCTAssertTrue("\(error)".contains("budget"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
    }

    /// The same for erase records: one erase payload listing many ids,
    /// referenced from every record slot, is not re-read per reference.
    func testSharedEraseReferencesDoNotAmplify() throws {
        var bundle = [UInt8](Self.sharedRecordBundle(records: 20_000, segments: 1000))
        // Turn the shared stroke record into an erase record whose payload
        // field 0 is the (long) geometry vector read as 8-byte ids.
        let fb = FlatBuffer(Data(bundle))
        let vector = try fb.ref(XCTUnwrap(try fb.field(fb.root(), 6)))
        let rec = try fb.table(atRef: vector + 4)
        bundle[try XCTUnwrap(try fb.field(rec, 4))] = 25
        let pay = try fb.table(atRef: XCTUnwrap(try fb.field(rec, 5)))
        // Payload vtable slot 0 → the geometry reference (offset 12).
        let vt = pay - (try fb.i32(pay))
        bundle[vt + 4] = 12
        // Its count in 8-byte elements: about 2 400 ids, read per reference.
        let ids = try fb.ref(pay + 12)
        let n = Int(try fb.u32(ids)) / 8
        for i in 0..<4 { bundle[ids + i] = UInt8(n >> (8 * i) & 0xFF) }
        XCTAssertEqual(try FlatBuffer(Data(bundle)).vector(atRef: pay + 12, elementSize: 8).count, n)
        let t = Date()
        XCTAssertThrowsError(try NotabilityBundle.parse(bundle: Data(bundle))) { error in
            XCTAssertTrue("\(error)".contains("budget"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
    }
}
