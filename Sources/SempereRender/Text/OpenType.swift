import Foundation
import Sempere

/// Why a font could not be used. Text falls back to another font (or the
/// missing-glyph box) and the export reports it.
public enum FontError: Error, Equatable, Sendable {
    /// Not an OpenType, TrueType or TrueType Collection file.
    case notAFont
    /// A table or record is out of bounds or inconsistent (the string says which).
    case malformed(String)
    /// A valid font this reader does not handle (CFF2, bitmap-only, ...).
    case unsupported(String)
}

/// Bounds-checked big-endian reads over font bytes (every font may be
/// hostile: fonts come from the user's font directories).
struct FontBytes: Sendable {
    let b: [UInt8]

    @inline(__always) func u8(_ o: Int) throws -> Int {
        guard o >= 0, o < b.count else { throw FontError.malformed("read past the end") }
        return Int(b[o])
    }
    @inline(__always) func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= b.count else { throw FontError.malformed("read past the end") }
        return Int(b[o]) << 8 | Int(b[o + 1])
    }
    @inline(__always) func i16(_ o: Int) throws -> Int { Int(Int16(truncatingIfNeeded: try u16(o))) }
    @inline(__always) func u24(_ o: Int) throws -> Int {
        guard o >= 0, o + 3 <= b.count else { throw FontError.malformed("read past the end") }
        return Int(b[o]) << 16 | Int(b[o + 1]) << 8 | Int(b[o + 2])
    }
    @inline(__always) func u32(_ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= b.count else { throw FontError.malformed("read past the end") }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    func tag(_ o: Int) throws -> String {
        guard o >= 0, o + 4 <= b.count else { throw FontError.malformed("read past the end") }
        return String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }
    func slice(_ r: Range<Int>) throws -> ArraySlice<UInt8> {
        guard r.lowerBound >= 0, r.upperBound <= b.count else { throw FontError.malformed("range past the end") }
        return b[r]
    }
}

/// A segment of a glyph outline, in font units (y up).
public enum OutlineSegment: Hashable, Sendable {
    case move(Point)
    case line(Point)
    case quad(Point, Point)
    case cubic(Point, Point, Point)
    case close
}

/// One face of an OpenType / TrueType font (a `.ttf`, `.otf`, or one face
/// of a `.ttc`): the tables text layout, rendering and subsetting need.
///
/// Parsing is lazy where it is costly (outlines, layout tables) and every
/// read is bounds-checked; limits keep work proportional to the file.
public struct OpenTypeFont: Sendable {
    /// The whole file (shared by the faces of a collection).
    let bytes: FontBytes
    /// Table tag → byte range in `bytes`.
    let tables: [String: Range<Int>]
    public let unitsPerEm: Int
    public let numGlyphs: Int
    public let ascender: Int
    public let descender: Int
    let numberOfHMetrics: Int
    let longLoca: Bool
    /// True for CFF outlines (`OTTO`), false for `glyf`.
    public let isCFF: Bool
    /// Names from the `name` table.
    public let family: String
    public let subfamily: String
    public let postScriptName: String
    /// `usWeightClass` (400 regular, 700 bold) and the italic bit, from `OS/2`.
    public let weight: Int
    public let italic: Bool
    /// The Unicode cmap.
    let cmap: CharacterMap
    let advances: [UInt16]
    /// The parsed `CFF ` table of a CFF font.
    let cffTable: CFFFont?

    /// Most tables in one face, glyphs, cmap groups.
    static let maxTables = 512
    static let maxGlyphs = 65_536

    /// Number of faces in a font file (1 for a `.ttf`/`.otf`).
    public static func faceCount(_ data: [UInt8]) throws -> Int {
        let b = FontBytes(b: data)
        guard try b.tag(0) == "ttcf" else { return 1 }
        let n = try b.u32(8)
        guard n >= 1, n <= 256 else { throw FontError.malformed("collection face count") }
        return n
    }

    /// Parses face `face` of a font file.
    public init(data: [UInt8], face: Int = 0) throws {
        let b = FontBytes(b: data)
        var offset = 0
        if try b.tag(0) == "ttcf" {
            let n = try Self.faceCount(data)
            guard face >= 0, face < n else { throw FontError.malformed("no face \(face)") }
            offset = try b.u32(12 + 4 * face)
        } else if face != 0 {
            throw FontError.malformed("no face \(face)")
        }
        let version = try b.u32(offset)
        guard version == 0x0001_0000 || version == 0x4F54_544F || version == 0x7472_7565 else {
            throw version == 0x7766_4F46 || version == 0x774F_4632 ? FontError.unsupported("WOFF") : FontError.notAFont
        }
        let count = try b.u16(offset + 4)
        guard count <= Self.maxTables else { throw FontError.malformed("table count") }
        var t: [String: Range<Int>] = [:]
        for i in 0..<count {
            let r = offset + 12 + 16 * i
            let tag = try b.tag(r)
            let start = try b.u32(r + 8), length = try b.u32(r + 12)
            guard start + length <= data.count else { throw FontError.malformed("table \(tag) past the end") }
            t[tag] = start..<(start + length)
        }
        bytes = b
        tables = t
        isCFF = t["CFF "] != nil
        guard t["glyf"] != nil || isCFF else {
            throw t["CFF2"] != nil ? FontError.unsupported("CFF2 outlines") : FontError.unsupported("no outlines")
        }
        func table(_ tag: String) throws -> Int {
            guard let r = t[tag] else { throw FontError.malformed("no \(tag) table") }
            return r.lowerBound
        }
        let head = try table("head")
        unitsPerEm = try b.u16(head + 18)
        guard (16...16_384).contains(unitsPerEm) else { throw FontError.malformed("unitsPerEm") }
        longLoca = try b.i16(head + 50) == 1
        let maxp = try table("maxp")
        numGlyphs = try b.u16(maxp + 4)
        guard numGlyphs > 0 else { throw FontError.malformed("no glyphs") }
        let hhea = try table("hhea")
        var asc = try b.i16(hhea + 4), desc = try b.i16(hhea + 6)
        numberOfHMetrics = try b.u16(hhea + 34)
        guard numberOfHMetrics >= 1, numberOfHMetrics <= numGlyphs else { throw FontError.malformed("numberOfHMetrics") }
        let hmtx = try table("hmtx")
        guard (t["hmtx"]?.count ?? 0) >= 4 * numberOfHMetrics else { throw FontError.malformed("short hmtx") }
        var adv = [UInt16](repeating: 0, count: numberOfHMetrics)
        for g in 0..<numberOfHMetrics { adv[g] = UInt16(try b.u16(hmtx + 4 * g)) }
        advances = adv
        // OS/2: weight, italic, and typographic metrics when present.
        var w = 400, it = false
        if let os2 = t["OS/2"], os2.count >= 64 {
            w = try b.u16(os2.lowerBound + 4)
            it = try b.u16(os2.lowerBound + 62) & 1 != 0
            if os2.count >= 72 {
                let ta = try b.i16(os2.lowerBound + 68), td = try b.i16(os2.lowerBound + 70)
                if ta > 0 && (asc <= 0) { asc = ta; desc = td }
            }
        }
        weight = w
        let macStyle = try b.u16(head + 44)
        italic = it || macStyle & 2 != 0
        ascender = asc
        descender = desc
        cmap = try CharacterMap(b, t["cmap"])
        cffTable = try t["CFF "].map { try CFFFont(Array(data[$0])) }
        let names = try Self.names(b, t["name"])
        family = names[16] ?? names[1] ?? ""
        subfamily = names[17] ?? names[2] ?? ""
        postScriptName = names[6] ?? family.replacingOccurrences(of: " ", with: "")
    }

    /// Reads a font file from disk (at most 64 MiB) and parses face `face`.
    ///
    /// Regular files only (`BoundedRead`): a FIFO or device named `*.ttf` in
    /// a font directory is refused instead of blocking the export (format.md §9).
    public init(contentsOf url: URL, face: Int = 0) throws {
        let d: Data
        do { d = try BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes) } catch VaultError.fileTooLarge {
            throw FontError.unsupported("font file over 64 MiB")
        }
        try self.init(data: [UInt8](d), face: face)
    }

    /// The largest font file read.
    public static let maxFileBytes = 64 << 20

    /// Glyph for a code point (0, `.notdef`, when the font lacks it).
    public func glyph(for scalar: UInt32, variation: UInt32? = nil) -> Int {
        let g = cmap.glyph(scalar, variation: variation)
        return g < numGlyphs ? g : 0
    }

    /// True when the font has a glyph for `scalar`.
    public func covers(_ scalar: UInt32) -> Bool { glyph(for: scalar) != 0 }

    /// Advance width in font units.
    public func advance(_ glyph: Int) -> Int {
        guard !advances.isEmpty else { return 0 }
        return Int(advances[min(max(glyph, 0), advances.count - 1)])
    }

    /// The raw bytes of a table.
    func table(_ tag: String) -> ArraySlice<UInt8>? {
        guard let r = tables[tag] else { return nil }
        return bytes.b[r]
    }

    /// Name-table strings by name id (Windows Unicode or Mac Roman, English first).
    static func names(_ b: FontBytes, _ r: Range<Int>?) throws -> [Int: String] {
        guard let r else { return [:] }
        let base = r.lowerBound
        let count = try b.u16(base + 2), strings = base + (try b.u16(base + 4))
        var out: [Int: (String, Int)] = [:]
        for i in 0..<min(count, 1024) {
            let rec = base + 6 + 12 * i
            let platform = try b.u16(rec), encoding = try b.u16(rec + 2), language = try b.u16(rec + 4)
            let id = try b.u16(rec + 6), length = try b.u16(rec + 8), off = try b.u16(rec + 10)
            guard [1, 2, 4, 6, 16, 17].contains(id) else { continue }
            let raw = try b.slice((strings + off)..<(strings + off + length))
            var s: String?
            var rank = 0
            if platform == 3 && (encoding == 1 || encoding == 10) || platform == 0 {
                var units: [UInt16] = []
                var j = raw.startIndex
                while j + 1 < raw.endIndex { units.append(UInt16(raw[j]) << 8 | UInt16(raw[j + 1])); j += 2 }
                s = String(decoding: units, as: UTF16.self)
                rank = platform == 3 && language == 0x409 ? 3 : 2
            } else if platform == 1 && encoding == 0 {
                s = String(decoding: raw.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
                rank = 1
            }
            if let s, rank > (out[id]?.1 ?? 0) { out[id] = (s, rank) }
        }
        return out.mapValues(\.0)
    }

    // MARK: - TrueType outlines

    /// The `glyf` data of a glyph (empty for a glyph without contours).
    func glyfRange(_ glyph: Int) throws -> Range<Int> {
        guard let loca = tables["loca"], let glyf = tables["glyf"] else { throw FontError.malformed("no loca/glyf") }
        guard glyph >= 0, glyph < numGlyphs else { throw FontError.malformed("glyph id") }
        let a: Int, z: Int
        if longLoca {
            a = try bytes.u32(loca.lowerBound + 4 * glyph); z = try bytes.u32(loca.lowerBound + 4 * glyph + 4)
        } else {
            a = 2 * (try bytes.u16(loca.lowerBound + 2 * glyph)); z = 2 * (try bytes.u16(loca.lowerBound + 2 * glyph + 2))
        }
        guard a <= z, glyf.lowerBound + z <= glyf.upperBound else { throw FontError.malformed("loca") }
        return (glyf.lowerBound + a)..<(glyf.lowerBound + z)
    }

    /// The outline of a glyph in font units, y up (TrueType or CFF).
    public func outline(_ glyph: Int) throws -> [OutlineSegment] {
        if isCFF { return try cff().outline(glyph) }
        var out: [OutlineSegment] = []
        var budget = 1 << 16
        try trueTypeOutline(glyph, transform: .identity, depth: 0, budget: &budget, into: &out)
        return out
    }

    private func trueTypeOutline(_ glyph: Int, transform m: Affine, depth: Int, budget: inout Int,
                                 into out: inout [OutlineSegment]) throws {
        guard depth <= 8 else { throw FontError.malformed("composite glyph nesting") }
        let r = try glyfRange(glyph)
        guard r.count >= 10 else { return }
        let b = bytes
        let contours = try b.i16(r.lowerBound)
        if contours >= 0 {
            var p = r.lowerBound + 10
            var ends: [Int] = []
            for _ in 0..<contours { ends.append(try b.u16(p)); p += 2 }
            let n = (ends.last ?? -1) + 1
            budget -= n
            guard budget >= 0 else { throw FontError.malformed("too many outline points") }
            guard zip(ends, ends.dropFirst()).allSatisfy({ $0 < $1 }) else { throw FontError.malformed("contour ends") }
            p += 2 + (try b.u16(p))   // instructions
            var flags = [UInt8](repeating: 0, count: n)
            var i = 0
            while i < n {
                let f = UInt8(try b.u8(p)); p += 1
                flags[i] = f; i += 1
                if f & 8 != 0 {
                    let rep = try b.u8(p); p += 1
                    for _ in 0..<rep where i < n { flags[i] = f; i += 1 }
                }
            }
            var xs = [Int](repeating: 0, count: n), ys = [Int](repeating: 0, count: n)
            var v = 0
            for k in 0..<n {
                let f = flags[k]
                if f & 2 != 0 { let d = try b.u8(p); p += 1; v += f & 16 != 0 ? d : -d }
                else if f & 16 == 0 { v += try b.i16(p); p += 2 }
                xs[k] = v
            }
            v = 0
            for k in 0..<n {
                let f = flags[k]
                if f & 4 != 0 { let d = try b.u8(p); p += 1; v += f & 32 != 0 ? d : -d }
                else if f & 32 == 0 { v += try b.i16(p); p += 2 }
                ys[k] = v
            }
            guard p <= r.upperBound + 3 else { throw FontError.malformed("glyph data past its end") }
            var start = 0
            for e in ends {
                let pts = (start...e).map { (m.apply(Point(x: Double(xs[$0]), y: Double(ys[$0]))), flags[$0] & 1 != 0) }
                start = e + 1
                Self.quadContour(pts, into: &out)
            }
            return
        }
        // Composite.
        var p = r.lowerBound + 10
        while true {
            let flags = try b.u16(p), component = try b.u16(p + 2)
            p += 4
            var dx = 0.0, dy = 0.0
            if flags & 1 != 0 {
                if flags & 2 != 0 { dx = Double(try b.i16(p)); dy = Double(try b.i16(p + 2)) }
                p += 4
            } else {
                if flags & 2 != 0 { dx = Double(Int8(truncatingIfNeeded: try b.u8(p))); dy = Double(Int8(truncatingIfNeeded: try b.u8(p + 1))) }
                p += 2
            }
            func f2(_ o: Int) throws -> Double { Double(try b.i16(o)) / 16384 }
            var c = Affine.identity
            if flags & 8 != 0 { let s = try f2(p); c.a = s; c.d = s; p += 2 }
            else if flags & 0x40 != 0 { c.a = try f2(p); c.d = try f2(p + 2); p += 4 }
            else if flags & 0x80 != 0 { c.a = try f2(p); c.b = try f2(p + 2); c.c = try f2(p + 4); c.d = try f2(p + 6); p += 8 }
            // Point-matching (ARGS_ARE_XY_VALUES clear) is rare; offsets are then ignored.
            if flags & 2 != 0 { c.tx = dx; c.ty = dy }
            try trueTypeOutline(component, transform: m.after(c), depth: depth + 1, budget: &budget, into: &out)
            guard flags & 0x20 != 0 else { break }
        }
    }

    /// A TrueType contour (on/off-curve points) as segments.
    static func quadContour(_ pts: [(Point, Bool)], into out: inout [OutlineSegment]) {
        guard !pts.isEmpty else { return }
        func mid(_ a: Point, _ b: Point) -> Point { Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let n = pts.count
        // Start on an on-curve point, or the midpoint of the first two off-curve points.
        let onCurve = pts.firstIndex { $0.1 }
        let start = onCurve.map { pts[$0].0 } ?? mid(pts[0].0, pts[n - 1].0)
        out.append(.move(start))
        let s0 = onCurve ?? 0
        var control: Point?
        for k in 1...n {
            let (pt, on) = pts[(s0 + k) % n]
            if on {
                if let c = control { out.append(.quad(c, pt)) } else { out.append(.line(pt)) }
                control = nil
            } else {
                if let c = control { let m = mid(c, pt); out.append(.quad(c, m)) }
                control = pt
            }
        }
        if let c = control { out.append(.quad(c, start)) }
        out.append(.close)
    }

    /// The CFF table, parsed.
    func cff() throws -> CFFFont {
        guard let cffTable else { throw FontError.malformed("no CFF table") }
        return cffTable
    }
}

/// A Unicode cmap: format 4 or 12 for code points, 14 for variation sequences.
struct CharacterMap: Sendable {
    /// Sorted, disjoint `(first, last, glyph of first, delta-encoded)` groups.
    private var groups: [(first: UInt32, last: UInt32, glyph: Int, direct: [UInt16]?)] = []
    /// Non-default variation sequences: (base, selector) → glyph.
    private var variations: [UInt64: Int] = [:]

    init(_ b: FontBytes, _ range: Range<Int>?) throws {
        guard let range else { return }
        let base = range.lowerBound
        let n = try b.u16(base + 2)
        var best: (rank: Int, offset: Int)?
        var uvs: Int?
        for i in 0..<min(n, 256) {
            let rec = base + 4 + 8 * i
            let platform = try b.u16(rec), encoding = try b.u16(rec + 2), off = base + (try b.u32(rec + 4))
            let format = try b.u16(off)
            if format == 14 && platform == 0 && encoding == 5 { uvs = off; continue }
            var rank = 0
            if format == 12 && (platform == 3 && encoding == 10 || platform == 0) { rank = 4 }
            else if format == 4 && (platform == 3 && encoding == 1 || platform == 0) { rank = 3 }
            if rank > (best?.rank ?? 0) { best = (rank, off) }
        }
        if let best {
            let o = best.offset
            if try b.u16(o) == 12 {
                let count = try b.u32(o + 12)
                guard count <= 1 << 20, o + 16 + 12 * count <= range.upperBound else { throw FontError.malformed("cmap 12") }
                for k in 0..<count {
                    let g = o + 16 + 12 * k
                    let first = UInt32(try b.u32(g)), last = UInt32(try b.u32(g + 4))
                    guard first <= last, last <= 0x10FFFF else { continue }
                    groups.append((first, last, try b.u32(g + 8), nil))
                }
            } else {
                let segX2 = try b.u16(o + 6)
                let segs = segX2 / 2
                var directBudget = 1 << 20
                let ends = o + 14, starts = ends + segX2 + 2, deltas = starts + segX2, rangeOffs = deltas + segX2
                for k in 0..<segs {
                    let end = try b.u16(ends + 2 * k), start = try b.u16(starts + 2 * k)
                    let delta = try b.u16(deltas + 2 * k), ro = try b.u16(rangeOffs + 2 * k)
                    guard start <= end, !(start == 0xFFFF && end == 0xFFFF) else { continue }
                    if ro == 0 {
                        groups.append((UInt32(start), UInt32(end), (start + delta) & 0xFFFF, nil))
                    } else {
                        var direct: [UInt16] = []
                        directBudget -= end - start + 1
                        guard directBudget >= 0 else { throw FontError.malformed("cmap 4 ranges") }
                        for c in start...end {
                            let addr = rangeOffs + 2 * k + ro + 2 * (c - start)
                            var g = (try? b.u16(addr)) ?? 0
                            if g != 0 { g = (g + delta) & 0xFFFF }
                            direct.append(UInt16(g))
                        }
                        groups.append((UInt32(start), UInt32(end), 0, direct))
                    }
                }
            }
            groups.sort { $0.first < $1.first }
        }
        if let o = uvs {
            let count = try b.u32(o + 6)
            for k in 0..<min(count, 1024) {
                let rec = o + 10 + 11 * k
                let selector = UInt32(try b.u24(rec))
                let nonDefault = try b.u32(rec + 7)
                guard nonDefault != 0 else { continue }
                let t = o + nonDefault
                let m = try b.u32(t)
                for j in 0..<min(m, 1 << 16) {
                    let base = UInt32(try b.u24(t + 4 + 5 * j))
                    variations[UInt64(base) << 32 | UInt64(selector)] = try b.u16(t + 7 + 5 * j)
                }
            }
        }
    }

    func glyph(_ c: UInt32, variation: UInt32? = nil) -> Int {
        if let v = variation, let g = variations[UInt64(c) << 32 | UInt64(v)] { return g }
        var lo = 0, hi = groups.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let g = groups[mid]
            if c < g.first { hi = mid - 1 } else if c > g.last { lo = mid + 1 } else {
                if let d = g.direct { return Int(d[Int(c - g.first)]) }
                return g.glyph + Int(c - g.first)
            }
        }
        return 0
    }

    /// Every mapped code point (for coverage scans), at most `limit`.
    func scalars(limit: Int = 1 << 20) -> [UInt32] {
        var out: [UInt32] = []
        for g in groups {
            for c in g.first...g.last where out.count < limit { out.append(c) }
        }
        return out
    }
}
