import Foundation

/// The parts of a CFF font (the `CFF ` table of an OpenType font) that text
/// export needs: charstrings and their subroutines, per-glyph Private dicts
/// (CID-keyed fonts select one per glyph through FDSelect), outlines from a
/// Type 2 charstring interpreter, and the pieces the subsetter rewrites.
struct CFFFont: Sendable {
    let data: [UInt8]
    /// Charstring of each glyph (ranges in `data`).
    let charStrings: [Range<Int>]
    let globalSubrs: [Range<Int>]
    /// Per Font DICT: its Private DICT's entries and local subrs.
    let privates: [PrivateDict]
    /// Glyph → Font DICT index (all 0 for a name-keyed font).
    let fdSelect: [UInt8]
    /// Font DICT entries (CID-keyed), or nil for a name-keyed font.
    let fontDicts: [[DictEntry]]?
    /// Top DICT entries.
    let topDict: [DictEntry]
    let isCID: Bool

    struct DictEntry: Sendable {
        var op: Int          // 0–21, or 1200 + b for escaped operators
        var operands: [Double]
    }

    struct PrivateDict: Sendable {
        var entries: [DictEntry]
        var subrs: [Range<Int>]
        var defaultWidth: Double
        var nominalWidth: Double
    }

    init(_ d: [UInt8]) throws {
        data = d
        let b = FontBytes(b: d)
        guard d.count >= 4, try b.u8(0) == 1 else { throw FontError.unsupported("CFF version") }
        let hdrSize = try b.u8(2)
        let (_, afterName) = try Self.index(b, hdrSize)
        let (topDicts, afterTop) = try Self.index(b, afterName)
        let (_, afterStrings) = try Self.index(b, afterTop)
        (globalSubrs, _) = try Self.index(b, afterStrings)
        guard let top = topDicts.first else { throw FontError.malformed("no Top DICT") }
        topDict = try Self.dict(b, top)
        func value(_ entries: [DictEntry], _ op: Int) -> [Double]? { entries.first { $0.op == op }?.operands }
        guard let cs = value(topDict, 17)?.first, cs > 0, cs < Double(d.count) else { throw FontError.malformed("no CharStrings") }
        (charStrings, _) = try Self.index(b, Int(cs))
        guard !charStrings.isEmpty, charStrings.count <= OpenTypeFont.maxGlyphs else { throw FontError.malformed("glyph count") }
        func privateDict(_ entries: [DictEntry]) throws -> PrivateDict {
            guard let p = value(entries, 18), p.count == 2, p[0] >= 0, p[1] >= 0, p[0] + p[1] <= Double(d.count) else {
                return PrivateDict(entries: [], subrs: [], defaultWidth: 0, nominalWidth: 0)
            }
            let start = Int(p[1]), size = Int(p[0])
            let entries = try Self.dict(b, start..<(start + size))
            var subrs: [Range<Int>] = []
            if let s = value(entries, 19)?.first, s > 0, Double(start) + s < Double(d.count) {
                (subrs, _) = try Self.index(b, start + Int(s))
            }
            return PrivateDict(entries: entries, subrs: subrs, defaultWidth: value(entries, 20)?.first ?? 0,
                               nominalWidth: value(entries, 21)?.first ?? 0)
        }
        isCID = value(topDict, 1230) != nil
        if isCID {
            guard let fda = value(topDict, 1236)?.first, fda > 0, fda < Double(d.count),
                  let fds = value(topDict, 1237)?.first, fds > 0, fds < Double(d.count) else {
                throw FontError.malformed("CID font without FDArray/FDSelect")
            }
            let (fdRanges, _) = try Self.index(b, Int(fda))
            guard !fdRanges.isEmpty, fdRanges.count <= 256 else { throw FontError.malformed("FDArray") }
            let dicts = try fdRanges.map { try Self.dict(b, $0) }
            fontDicts = dicts
            privates = try dicts.map(privateDict)
            fdSelect = try Self.fdSelect(b, Int(fds), glyphs: charStrings.count, fds: dicts.count)
        } else {
            fontDicts = nil
            privates = [try privateDict(topDict)]
            fdSelect = [UInt8](repeating: 0, count: charStrings.count)
        }
    }

    /// An INDEX at `offset`: its items' ranges and the offset after it.
    static func index(_ b: FontBytes, _ offset: Int) throws -> ([Range<Int>], Int) {
        let count = try b.u16(offset)
        guard count > 0 else { return ([], offset + 2) }
        let offSize = try b.u8(offset + 2)
        guard (1...4).contains(offSize) else { throw FontError.malformed("INDEX offSize") }
        func off(_ i: Int) throws -> Int {
            let p = offset + 3 + i * offSize
            switch offSize {
            case 1: return try b.u8(p)
            case 2: return try b.u16(p)
            case 3: return try b.u24(p)
            default: return try b.u32(p)
            }
        }
        let dataStart = offset + 3 + (count + 1) * offSize - 1
        var out: [Range<Int>] = []
        out.reserveCapacity(count)
        var prev = try off(0)
        for i in 1...count {
            let o = try off(i)
            guard o >= prev, dataStart + o <= b.b.count else { throw FontError.malformed("INDEX offsets") }
            out.append((dataStart + prev)..<(dataStart + o))
            prev = o
        }
        return (out, dataStart + prev)
    }

    /// A DICT's entries.
    static func dict(_ b: FontBytes, _ r: Range<Int>) throws -> [DictEntry] {
        guard r.upperBound <= b.b.count else { throw FontError.malformed("DICT past the end") }
        var out: [DictEntry] = []
        var operands: [Double] = []
        var p = r.lowerBound
        while p < r.upperBound {
            let v = try b.u8(p)
            if v <= 21 {
                var op = v
                p += 1
                if v == 12 { op = 1200 + (try b.u8(p)); p += 1 }
                out.append(DictEntry(op: op, operands: operands))
                operands = []
                guard out.count <= 512 else { throw FontError.malformed("DICT too long") }
                continue
            }
            let (n, len) = try number(b, p)
            operands.append(n)
            guard operands.count <= 48 else { throw FontError.malformed("DICT operands") }
            p += len
        }
        return out
    }

    /// A DICT operand at `p`: value and encoded length.
    static func number(_ b: FontBytes, _ p: Int) throws -> (Double, Int) {
        let v = try b.u8(p)
        switch v {
        case 28: return (Double(Int16(truncatingIfNeeded: try b.u16(p + 1))), 3)
        case 29: return (Double(Int32(truncatingIfNeeded: try b.u32(p + 1))), 5)
        case 30:
            var s = ""
            var q = p + 1
            loop: while true {
                let byte = try b.u8(q)
                for nib in [byte >> 4, byte & 15] {
                    switch nib {
                    case 0...9: s.append(String(nib))
                    case 0xA: s.append(".")
                    case 0xB: s.append("E")
                    case 0xC: s.append("E-")
                    case 0xE: s.append("-")
                    case 0xF: q += 1; break loop
                    default: break
                    }
                }
                q += 1
                guard q - p < 64 else { throw FontError.malformed("real operand") }
            }
            return (Double(s) ?? 0, q - p)
        case 32...246: return (Double(v - 139), 1)
        case 247...250: return (Double((v - 247) * 256 + (try b.u8(p + 1)) + 108), 2)
        case 251...254: return (Double(-(v - 251) * 256 - (try b.u8(p + 1)) - 108), 2)
        default: throw FontError.malformed("DICT operand \(v)")
        }
    }

    static func fdSelect(_ b: FontBytes, _ o: Int, glyphs: Int, fds: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: glyphs)
        switch try b.u8(o) {
        case 0:
            for g in 0..<glyphs { out[g] = UInt8(min(try b.u8(o + 1 + g), fds - 1)) }
        case 3:
            let n = try b.u16(o + 1)
            for i in 0..<n {
                let first = try b.u16(o + 3 + 3 * i), fd = try b.u8(o + 5 + 3 * i)
                let next = try b.u16(o + 6 + 3 * i)
                guard first <= next else { throw FontError.malformed("FDSelect") }
                // A range may start past the last glyph: nothing to assign (an empty, not inverted, range).
                let end = min(next, glyphs)
                if first < end { for g in first..<end { out[g] = UInt8(min(fd, fds - 1)) } }
            }
        default:
            throw FontError.unsupported("FDSelect format")
        }
        return out
    }

    static func bias(_ count: Int) -> Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }

    // MARK: - Type 2 charstrings

    /// The outline of a glyph in font units, y up.
    func outline(_ glyph: Int) throws -> [OutlineSegment] {
        guard glyph >= 0, glyph < charStrings.count else { throw FontError.malformed("glyph id") }
        var interp = Interpreter(font: self, priv: privates[Int(fdSelect[glyph])])
        try interp.run(charStrings[glyph], depth: 0)
        interp.closeContour()
        return interp.out
    }

    struct Interpreter {
        let font: CFFFont
        let priv: PrivateDict
        var stack: [Double] = []
        var out: [OutlineSegment] = []
        var x = 0.0, y = 0.0
        var open = false
        var stems = 0
        var widthDone = false
        var ended = false
        var budget = 1 << 16
        var transient = [Double](repeating: 0, count: 32)

        init(font: CFFFont, priv: PrivateDict) { self.font = font; self.priv = priv }

        mutating func closeContour() {
            if open { out.append(.close); open = false }
        }

        mutating func moveTo(_ dx: Double, _ dy: Double) {
            closeContour()
            x += dx; y += dy
            out.append(.move(Point(x: x, y: y)))
            open = true
        }

        mutating func lineTo(_ dx: Double, _ dy: Double) {
            x += dx; y += dy
            out.append(.line(Point(x: x, y: y)))
        }

        mutating func curveTo(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
            let p1 = Point(x: x + a, y: y + b)
            let p2 = Point(x: p1.x + c, y: p1.y + d)
            x = p2.x + e; y = p2.y + f
            out.append(.cubic(p1, p2, Point(x: x, y: y)))
        }

        /// Drops the width (an odd leading operand) the first time a
        /// width-carrying operator runs.
        mutating func width(_ even: Bool) {
            if !widthDone {
                widthDone = true
                if (stack.count % 2 == 1) == even, !stack.isEmpty { stack.removeFirst() }
            }
        }

        mutating func run(_ r: Range<Int>, depth: Int) throws {
            guard depth <= 10 else { throw FontError.malformed("subroutine nesting") }
            let d = font.data
            var p = r.lowerBound
            while p < r.upperBound && !ended {
                budget -= 1
                guard budget >= 0 else { throw FontError.malformed("charstring too long") }
                let v = Int(d[p])
                if v >= 32 || v == 28 {
                    var n: Double
                    switch v {
                    case 28:
                        guard p + 2 < d.count else { throw FontError.malformed("charstring") }
                        n = Double(Int16(bitPattern: UInt16(d[p + 1]) << 8 | UInt16(d[p + 2]))); p += 3
                    case 32...246: n = Double(v - 139); p += 1
                    case 247...250:
                        guard p + 1 < d.count else { throw FontError.malformed("charstring") }
                        n = Double((v - 247) * 256 + Int(d[p + 1]) + 108); p += 2
                    case 251...254:
                        guard p + 1 < d.count else { throw FontError.malformed("charstring") }
                        n = Double(-(v - 251) * 256 - Int(d[p + 1]) - 108); p += 2
                    default:
                        guard p + 4 < d.count else { throw FontError.malformed("charstring") }
                        let i = Int32(bitPattern: UInt32(d[p + 1]) << 24 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 8 | UInt32(d[p + 4]))
                        n = Double(i) / 65536; p += 5
                    }
                    guard stack.count < 48 else { throw FontError.malformed("charstring stack") }
                    stack.append(n)
                    continue
                }
                p += 1
                var op = v
                if v == 12 {
                    guard p < r.upperBound else { throw FontError.malformed("charstring") }
                    op = 1200 + Int(d[p]); p += 1
                }
                func arg(_ i: Int) -> Double { i < stack.count ? stack[i] : 0 }
                switch op {
                case 1, 3, 18, 23:   // hstem, vstem, hstemhm, vstemhm
                    width(true)
                    stems += stack.count / 2
                    stack.removeAll()
                case 19, 20:         // hintmask, cntrmask
                    width(true)
                    stems += stack.count / 2
                    stack.removeAll()
                    p += (stems + 7) / 8
                case 21:             // rmoveto
                    width(true)
                    moveTo(arg(0), arg(1)); stack.removeAll()
                case 22:             // hmoveto
                    width(false)
                    moveTo(arg(0), 0); stack.removeAll()
                case 4:              // vmoveto
                    width(false)
                    moveTo(0, arg(0)); stack.removeAll()
                case 5:              // rlineto
                    var i = 0
                    while i + 1 < stack.count { lineTo(stack[i], stack[i + 1]); i += 2 }
                    stack.removeAll()
                case 6, 7:           // hlineto, vlineto
                    var horizontal = op == 6
                    for v in stack { if horizontal { lineTo(v, 0) } else { lineTo(0, v) }; horizontal.toggle() }
                    stack.removeAll()
                case 8:              // rrcurveto
                    var i = 0
                    while i + 5 < stack.count {
                        curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]); i += 6
                    }
                    stack.removeAll()
                case 24:             // rcurveline
                    var i = 0
                    while i + 5 < stack.count - 2 {
                        curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]); i += 6
                    }
                    if i + 1 < stack.count { lineTo(stack[i], stack[i + 1]) }
                    stack.removeAll()
                case 25:             // rlinecurve
                    var i = 0
                    while i + 1 < stack.count - 6 { lineTo(stack[i], stack[i + 1]); i += 2 }
                    if i + 5 < stack.count {
                        curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5])
                    }
                    stack.removeAll()
                case 26:             // vvcurveto
                    var i = 0
                    var dx1 = 0.0
                    if stack.count % 4 == 1 { dx1 = stack[0]; i = 1 }
                    while i + 3 < stack.count {
                        curveTo(dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]); dx1 = 0; i += 4
                    }
                    stack.removeAll()
                case 27:             // hhcurveto
                    var i = 0
                    var dy1 = 0.0
                    if stack.count % 4 == 1 { dy1 = stack[0]; i = 1 }
                    while i + 3 < stack.count {
                        curveTo(stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0); dy1 = 0; i += 4
                    }
                    stack.removeAll()
                case 30, 31:         // vhcurveto, hvcurveto
                    var horizontal = op == 31
                    var i = 0
                    while i + 3 < stack.count {
                        let last = i + 4 >= stack.count - 1
                        let extra = last && stack.count - i == 5 ? stack[i + 4] : 0
                        if horizontal {
                            curveTo(stack[i], 0, stack[i + 1], stack[i + 2], extra, stack[i + 3])
                        } else {
                            curveTo(0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], extra)
                        }
                        horizontal.toggle()
                        i += 4
                    }
                    stack.removeAll()
                case 10, 29:         // callsubr, callgsubr
                    guard let n = stack.popLast() else { throw FontError.malformed("call without index") }
                    let list = op == 10 ? priv.subrs : font.globalSubrs
                    let i = Int(n) + CFFFont.bias(list.count)
                    guard i >= 0, i < list.count else { throw FontError.malformed("subroutine index") }
                    try run(list[i], depth: depth + 1)
                case 11:             // return
                    return
                case 14:             // endchar
                    width(true)
                    closeContour()
                    ended = true
                    stack.removeAll()
                case 1235:           // flex
                    curveTo(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
                    curveTo(arg(6), arg(7), arg(8), arg(9), arg(10), arg(11))
                    stack.removeAll()
                case 1234:           // hflex
                    let y0 = y
                    curveTo(arg(0), 0, arg(1), arg(2), arg(3), 0)
                    curveTo(arg(4), 0, arg(5), y0 - y, arg(6), 0)
                    stack.removeAll()
                case 1236:           // hflex1
                    let y0 = y
                    curveTo(arg(0), arg(1), arg(2), arg(3), arg(4), 0)
                    curveTo(arg(5), 0, arg(6), arg(7), arg(8), y0 - (y + arg(7)))
                    stack.removeAll()
                case 1237:           // flex1
                    let x0 = x, y0 = y
                    var dx = 0.0, dy = 0.0
                    for k in stride(from: 0, to: 10, by: 2) { dx += arg(k); dy += arg(k + 1) }
                    curveTo(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
                    if abs(dx) > abs(dy) {
                        curveTo(arg(6), arg(7), arg(8), arg(9), arg(10), y0 - (y + arg(7) + arg(9)))
                    } else {
                        curveTo(arg(6), arg(7), arg(8), arg(9), x0 - (x + arg(6) + arg(8)), arg(10))
                    }
                    stack.removeAll()
                default:
                    // Arithmetic and storage operators (deprecated in OpenType CFF): drop operands.
                    stack.removeAll()
                }
            }
        }
    }
}
