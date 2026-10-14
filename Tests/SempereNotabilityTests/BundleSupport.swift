import Foundation
import ImportTestSupport
@testable import SempereImport
@testable import SempereNotability

// MARK: - FlatBuffers writer (tests only)

/// A FlatBuffers value for `FBWriter`: inline scalars and structs, or
/// references to tables, vectors and strings.
indirect enum FBValue {
    case u8(UInt8)
    case u32(UInt32)
    case f32(Float)
    case i64(Int64)
    /// An inline struct: raw little-endian bytes (a multiple of 4 long).
    case structBytes([UInt8])
    case table([Int: FBValue])
    case tables([[Int: FBValue]])
    case bytes([UInt8])
    /// A vector of 8-byte structs, given as raw bytes (count = bytes / 8).
    case structVector([UInt8])
    case string(String)
}

/// Minimal FlatBuffers writer: vtable then table, children after their
/// parent (references are unsigned forward offsets), 4-byte alignment.
final class FBWriter {
    private(set) var out: [UInt8] = [0, 0, 0, 0]

    static func buffer(root: [Int: FBValue]) -> Data {
        let w = FBWriter()
        let r = w.table(root)
        w.put32(at: 0, UInt32(r))
        return Data(w.out)
    }

    private func align() { while out.count % 4 != 0 { out.append(0) } }
    private func put32(at p: Int, _ v: UInt32) {
        for i in 0..<4 { out[p + i] = UInt8(v >> (8 * UInt32(i)) & 0xFF) }
    }
    private func append32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) } }

    /// Writes a table (vtable first) and its children; returns the table's position.
    func table(_ fields: [Int: FBValue]) -> Int {
        let maxIndex = fields.keys.max() ?? -1
        // Inline layout after the 4-byte vtable offset.
        var layout: [Int: Int] = [:]
        var size = 4
        for i in fields.keys.sorted() {
            guard let v = fields[i] else { continue }
            let n: Int
            switch v {
            case .u8: n = 1
            case .u32, .f32: n = 4
            case .i64: n = 8
            case .structBytes(let b): n = b.count
            case .table, .tables, .bytes, .string, .structVector: n = 4
            }
            if n >= 4 { while size % 4 != 0 { size += 1 } }
            layout[i] = size
            size += n
        }
        while size % 4 != 0 { size += 1 }
        align()
        let vtSize = 4 + 2 * (maxIndex + 1)
        let vt = out.count
        out += [UInt8(vtSize & 0xFF), UInt8(vtSize >> 8), UInt8(size & 0xFF), UInt8(size >> 8)]
        for i in 0...max(maxIndex, 0) where maxIndex >= 0 {
            let o = layout[i] ?? 0
            out += [UInt8(o & 0xFF), UInt8(o >> 8)]
        }
        align()
        let t = out.count
        out += [UInt8](repeating: 0, count: size)
        put32(at: t, UInt32(t - vt))   // soffset: vtable = table - value
        var refs: [(Int, FBValue)] = []
        for (i, v) in fields {
            guard let o = layout[i] else { continue }
            let p = t + o
            switch v {
            case .u8(let x): out[p] = x
            case .u32(let x): put32(at: p, x)
            case .f32(let x): put32(at: p, x.bitPattern)
            case .i64(let x):
                put32(at: p, UInt32(truncatingIfNeeded: x)); put32(at: p + 4, UInt32(truncatingIfNeeded: x >> 32))
            case .structBytes(let b): for (k, byte) in b.enumerated() { out[p + k] = byte }
            case .table, .tables, .bytes, .string, .structVector: refs.append((p, v))
            }
        }
        for (p, v) in refs.sorted(by: { $0.0 < $1.0 }) {
            let target: Int
            switch v {
            case .table(let f): target = table(f)
            case .tables(let list):
                align()
                let start = out.count
                append32(UInt32(list.count))
                out += [UInt8](repeating: 0, count: 4 * list.count)
                for (k, f) in list.enumerated() {
                    let child = table(f)
                    put32(at: start + 4 + 4 * k, UInt32(child - (start + 4 + 4 * k)))
                }
                target = start
            case .bytes(let b):
                align(); target = out.count; append32(UInt32(b.count)); out += b
            case .structVector(let b):
                align(); target = out.count; append32(UInt32(b.count / 8)); out += b
            case .string(let s):
                align(); target = out.count; append32(UInt32(s.utf8.count)); out += Array(s.utf8); out.append(0)
            default: continue
            }
            put32(at: p, UInt32(target - p))
        }
        return t
    }
}

// MARK: - Synthetic .ntb

/// Builds `.ntb` packages shaped like Notability 16's: a document record
/// (title, page size and margins, paper) and stroke records. Nothing in them
/// comes from a real note.
enum SyntheticBundle {
    static let width: Float = 716.8, height: Float = 940.8, margin: Float = 18.666666
    static let createdMs: Int64 = 1_700_000_000_123

    /// One stroke: page-relative origin, Bézier offsets from the origin per
    /// segment (`nil` segment = a jump to the given point, flags 3).
    struct StrokeSpec {
        var page: UInt32 = 0
        var origin: (Float, Float)
        /// (c1, c2, end) offsets per segment, or a jump (`jump` set).
        var segments: [(c1: (Float, Float), c2: (Float, Float), end: (Float, Float), jump: Bool)]
        var rgba: [UInt8] = [0, 0, 0, 255]
        var width: Float = 1.4
        var highlighter = false
        var dashed = false
        var wide = false
        var kind: UInt8 = 3
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func half(_ x: Float) -> [UInt8] { le16(Float16Bits.encode(Double(x))) }
    static func f32(_ x: Float) -> [UInt8] {
        let b = x.bitPattern
        return [UInt8(b & 0xFF), UInt8(b >> 8 & 0xFF), UInt8(b >> 16 & 0xFF), UInt8(b >> 24)]
    }

    static func geometry(_ s: StrokeSpec) -> [UInt8] {
        let n = UInt16(s.segments.count + 1)
        var g: [UInt8] = [s.wide ? 1 : 0] + le16(n) + [s.kind, 0, 0, 0, 0]
        if s.wide { g += [0, 0, 0, 0] }
        func value(_ v: Float) -> [UInt8] { s.wide ? f32(v) : half(v) }
        let node: [UInt8] = half(1) + half(1) + [0xFF, 0]
        g += node
        for seg in s.segments {
            if seg.jump {
                g += [3] + value(seg.end.0) + value(seg.end.1)
            } else {
                g += [0] + value(seg.c1.0) + value(seg.c1.1) + value(seg.c2.0) + value(seg.c2.1)
                    + value(seg.end.0) + value(seg.end.1)
            }
            g += node
        }
        return g
    }

    /// An erase record removing the records with these sequence numbers.
    static func erase(_ seqs: [UInt32]) -> [Int: FBValue] {
        // A vector of 8-byte structs (0, seq), written as a byte vector of the same layout.
        record(500, type: 25, payload: [0: .structVector(seqs.flatMap { [0, 0, 0, 0] + f32(Float(bitPattern: $0)) })])
    }

    static func record(_ seq: UInt32, type: UInt8, payload: [Int: FBValue], ms: Int64 = createdMs) -> [Int: FBValue] {
        [0: .structBytes([0, 0, 0, 0] + f32(Float(bitPattern: seq))), 1: .i64(ms), 4: .u8(type), 5: .table(payload)]
    }

    static func noteBundle(title: String = "Synthetic bundle", strokes: [StrokeSpec], lines: [((Float, Float), (Float, Float))] = [],
                           extraRecords: [[Int: FBValue]] = [], createdMs: Int64 = createdMs,
                           pageWidth: Float = width, pageHeight: Float = height, margin: Float = margin) -> Data {
        var records: [[Int: FBValue]] = []
        let paper: [Int: FBValue] = [0: .u8(1), 1: .f32(16.6)]
        let layout: [Int: FBValue] = [0: .table(paper), 3: .structBytes(f32(pageWidth) + f32(pageHeight)),
                                      4: .structBytes(f32(0) + f32(0) + f32(margin) + f32(margin))]
        records.append(record(0, type: 1, payload: [0: .table([0: .string(title)]), 1: .table([0: .table(layout)])]))
        for (i, s) in strokes.enumerated() {
            var p: [Int: FBValue] = [
                0: .structBytes([0, 0, 0, 0, 1, 0, 0, 0] + [UInt8(s.page & 0xFF), UInt8(s.page >> 8 & 0xFF), 0, 0]),
                1: .structBytes(f32(s.origin.0) + f32(s.origin.1)),
                7: .structBytes(s.rgba), 8: .f32(s.width), 9: .bytes(geometry(s)),
            ]
            if s.highlighter { p[4] = .u8(2) }
            if s.dashed { p[5] = .u8(1) }
            records.append(record(UInt32(i + 1), type: 15, payload: p, ms: createdMs + Int64(i) * 1000))
        }
        for (a, d) in lines {
            records.append(record(99, type: 18, payload: [
                0: .structBytes([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]), 1: .structBytes(f32(a.0) + f32(a.1)),
                4: .u8(1), 5: .table([3: .structBytes(f32(d.0) + f32(d.1))]),
                9: .structBytes([0xED, 0x36, 0x24, 0xFF]), 10: .f32(2),
            ]))
        }
        records += extraRecords
        return FBWriter.buffer(root: [3: .string("00000000-0000-4000-8000-000000000000"), 4: .i64(createdMs),
                                      6: .tables(records)])
    }

    /// The `.ntb` zip around a bundle, optionally with `ios/HandwritingIndex.fb`.
    static func package(_ bundle: Data, handwritingIndex: Data? = nil, extra: [(String, Data)] = []) -> Data {
        var entries: [TestZip.File] = [
            .init(path: "version", data: Data("1".utf8), deflate: false),
            .init(path: "noteBundle", data: bundle, deflate: false),
            .init(path: "manifest.json", data: Data("{\"appVersion\":\"16.0\"}".utf8), deflate: false),
        ]
        if let handwritingIndex { entries.append(.init(path: "ios/HandwritingIndex.fb", data: handwritingIndex, deflate: true)) }
        entries += extra.map { .init(path: $0.0, data: $0.1, deflate: true) }
        return TestZip.write(entries)
    }

    /// One recognised page of a synthetic `ios/HandwritingIndex.fb`: its
    /// 0-based index, text, and one page-coordinate box per UTF-16 unit
    /// (nil for whitespace, stored as infinities like Notability).
    struct RecognizedPage {
        var index: UInt32
        var text: String
        var boxes: [(Double, Double, Double, Double)?]
    }

    /// A handwriting index shaped like Notability 16's (layout in
    /// `docs/import-notability.md`). The text is synthetic.
    static func handwritingIndex(_ pages: [RecognizedPage]) -> Data {
        func box(_ b: (Double, Double, Double, Double)?) -> [UInt8] {
            let v = b.map { [$0.0, $0.1, $0.2, $0.3] } ?? [.infinity, .infinity, 0, 0]
            return v.flatMap { x -> [UInt8] in
                let h = x.isInfinite ? UInt16(0x7C00) : Float16Bits.encode(x)
                return [UInt8(h & 0xFF), UInt8(h >> 8)]
            }
        }
        func word(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * UInt32($0)) & 0xFF) } }
        let tables: [[Int: FBValue]] = pages.map { p in
            [0: .structBytes(word(0) + word(1) + word(p.index)), 1: .string(p.text),
             2: .structVector(p.boxes.flatMap(box)), 3: .bytes([UInt8](repeating: 0xAB, count: 32))]
        }
        return FBWriter.buffer(root: [0: .u8(4), 1: .u8(5), 2: .table([0: .tables(tables), 1: .tables(tables)]),
                                      3: .i64(1378 << 32)])
    }

    /// The synthetic `.note`'s first two curves as bundle strokes: page
    /// coordinates (x + margin), offsets from the first point.
    static func strokesMatchingSyntheticNote() -> [StrokeSpec] {
        SyntheticNote.curves.prefix(2).map { c in
            let o = c.points[0]
            var segs: [(c1: (Float, Float), c2: (Float, Float), end: (Float, Float), jump: Bool)] = []
            var i = 1
            while i + 2 < c.points.count {
                func off(_ p: (Float, Float)) -> (Float, Float) { (p.0 - o.0, p.1 - o.1) }
                segs.append((off(c.points[i]), off(c.points[i + 1]), off(c.points[i + 2]), false))
                i += 3
            }
            return StrokeSpec(origin: (o.0 + margin, o.1), segments: segs, rgba: c.rgba, width: c.width)
        }
    }
}
