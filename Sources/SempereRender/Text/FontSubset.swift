import Foundation

/// A font subset (docs/attachments.md §10 "Text, fonts and the PDF writer"):
/// exactly the glyphs an export draws plus `.notdef`, renumbered in order of
/// first use (glyph 0 stays `.notdef`). TrueType subsets keep `glyf` outlines
/// without hinting instructions; CFF subsets become a CID-keyed CFF with the
/// subroutines inlined (no unused subroutine travels with the subset).
struct FontSubset {
    let font: OpenTypeFont
    /// Original glyph ids in new order; `glyphs[0] == 0`.
    private(set) var glyphs: [Int] = [0]
    private var newIDs: [Int: Int] = [0: 0]

    init(_ font: OpenTypeFont) { self.font = font }

    /// The subset's id for original glyph `g`, adding it on first use.
    mutating func id(_ g: Int) -> Int {
        if let n = newIDs[g] { return n }
        let n = glyphs.count
        glyphs.append(g)
        newIDs[g] = n
        return n
    }

    /// A second id for `.notdef` (a cmap entry that maps to glyph 0 means
    /// "missing" to viewers, so SVG addresses the missing-glyph box through
    /// a copy), added once.
    mutating func notdefCopy() -> Int {
        if let n = notdefCopyID { return n }
        glyphs.append(0)
        notdefCopyID = glyphs.count - 1
        return glyphs.count - 1
    }
    private var notdefCopyID: Int?

    /// `ABCDEF+PostScriptName`: a tag from a hash of the glyph set, as PDF
    /// requires for subsets (ISO 32000 §9.6.4).
    var subsetName: String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for g in glyphs { h = (h ^ UInt64(g)) &* 0x100_0000_01B3 }
        var tag = ""
        for _ in 0..<6 { tag.append(Character(Unicode.Scalar(UInt8(65 + h % 26)))); h /= 26 }
        let ps = font.postScriptName.unicodeScalars.filter { $0.value > 32 && $0.value < 127 && !"[](){}<>/%".unicodeScalars.contains($0) }
        return tag + "+" + (ps.isEmpty ? "Font" : String(String.UnicodeScalarView(ps)))
    }

    /// Advance of new glyph `i` in font units.
    func advance(_ i: Int) -> Int { font.advance(glyphs[i]) }

    // MARK: - TrueType

    /// Adds every glyph composite glyphs refer to (their components).
    private mutating func closeComposites() throws {
        var i = 0
        while i < glyphs.count {
            let r = try font.glyfRange(glyphs[i])
            if r.count >= 10, try font.bytes.i16(r.lowerBound) < 0 {
                var p = r.lowerBound + 10
                var guardCount = 0
                while true {
                    let flags = try font.bytes.u16(p), comp = try font.bytes.u16(p + 2)
                    guard comp < font.numGlyphs else { throw FontError.malformed("component glyph id") }
                    _ = id(comp)
                    p += 4 + (flags & 1 != 0 ? 4 : 2) + (flags & 8 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0)
                    guardCount += 1
                    guard flags & 0x20 != 0, guardCount < 256 else { break }
                }
            }
            i += 1
        }
    }

    /// The glyph's `glyf` data without instructions, components renumbered.
    private func strippedGlyph(_ g: Int) throws -> [UInt8] {
        let b = font.bytes
        let r = try font.glyfRange(g)
        guard r.count >= 10 else { return [] }
        var out = Array(try b.slice(r))
        let contours = try b.i16(r.lowerBound)
        if contours >= 0 {
            let instrAt = 10 + 2 * contours
            guard instrAt + 2 <= out.count else { throw FontError.malformed("glyph header") }
            let n = Int(out[instrAt]) << 8 | Int(out[instrAt + 1])
            guard instrAt + 2 + n <= out.count else { throw FontError.malformed("instructions") }
            // Exact length: flags and coordinates (the source may carry padding).
            let points = contours == 0 ? 0 : (Int(out[instrAt - 2]) << 8 | Int(out[instrAt - 1])) + 1
            var p = instrAt + 2 + n, i = 0, xBytes = 0, yBytes = 0
            while i < points {
                guard p < out.count else { throw FontError.malformed("glyph flags") }
                let f = out[p]; p += 1
                var repeatCount = 1
                if f & 8 != 0 { guard p < out.count else { throw FontError.malformed("glyph flags") }; repeatCount += Int(out[p]); p += 1 }
                let xs = f & 2 != 0 ? 1 : f & 16 != 0 ? 0 : 2, ys = f & 4 != 0 ? 1 : f & 32 != 0 ? 0 : 2
                xBytes += xs * repeatCount; yBytes += ys * repeatCount
                i += repeatCount
            }
            let end = min(p + xBytes + yBytes, out.count)
            out = Array(out[..<end])
            out.replaceSubrange(instrAt..<(instrAt + 2 + n), with: [0, 0])
            return out
        }
        var p = 10
        while true {
            guard p + 4 <= out.count else { throw FontError.malformed("composite") }
            var flags = Int(out[p]) << 8 | Int(out[p + 1])
            let comp = Int(out[p + 2]) << 8 | Int(out[p + 3])
            let n = newIDs[comp] ?? 0
            out[p + 2] = UInt8(n >> 8); out[p + 3] = UInt8(n & 0xFF)
            let more = flags & 0x20 != 0
            if !more && flags & 0x100 != 0 {
                flags &= ~0x100
                out[p] = UInt8(flags >> 8); out[p + 1] = UInt8(flags & 0xFF)
            }
            p += 4 + (flags & 1 != 0 ? 4 : 2) + (flags & 8 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0)
            if !more { break }
        }
        return Array(out.prefix(p))
    }

    /// A TrueType font file holding the subset. `cmap` maps code points to
    /// subset glyph ids (SVG needs it; PDF ignores it).
    mutating func trueTypeFile(cmap: [UInt32: Int] = [:]) throws -> [UInt8] {
        try closeComposites()
        let n = glyphs.count
        var glyf: [UInt8] = [], loca: [UInt8] = []
        for g in glyphs {
            loca += be32(glyf.count)
            glyf += try strippedGlyph(g)
            while glyf.count % 4 != 0 { glyf.append(0) }
        }
        loca += be32(glyf.count)
        var hmtx: [UInt8] = []
        for g in glyphs {
            hmtx += be16(font.advance(g))
            let hmtxAt = font.tables["hmtx"]?.lowerBound ?? 0
            let lsbAt = g < font.numberOfHMetrics ? hmtxAt + 4 * g + 2 : hmtxAt + 4 * font.numberOfHMetrics + 2 * (g - font.numberOfHMetrics)
            let lsb = (try? font.bytes.u16(lsbAt)) ?? 0
            hmtx += be16(lsb)
        }
        var tables: [String: [UInt8]] = ["glyf": glyf, "loca": loca, "hmtx": hmtx]
        tables["head"] = try patched("head", 54) { t in
            t.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            t.replaceSubrange(50..<52, with: [0, 1])
        }
        tables["hhea"] = try patched("hhea", 36) { t in t.replaceSubrange(34..<36, with: be16(n)) }
        tables["maxp"] = try patched("maxp", 6) { t in t.replaceSubrange(4..<6, with: be16(n)) }
        try addCommonTables(&tables, cmap: cmap)
        return Self.sfnt(tables, version: 0x0001_0000)
    }

    /// Copies table `tag` (at least `min` bytes) and lets `edit` patch it.
    private func patched(_ tag: String, _ min: Int, _ edit: (inout [UInt8]) -> Void) throws -> [UInt8] {
        guard let t = font.table(tag), t.count >= min else { throw FontError.malformed("short \(tag)") }
        var a = Array(t)
        edit(&a)
        return a
    }

    /// `cmap`, `name`, `post`, `OS/2` for a subset font file.
    private func addCommonTables(_ tables: inout [String: [UInt8]], cmap: [UInt32: Int]) throws {
        tables["cmap"] = Self.cmapTable(cmap)
        let name = subsetName
        tables["name"] = Self.nameTable(family: name, subfamily: "Regular", postScript: name)
        var post = [UInt8](repeating: 0, count: 32)
        post[1] = 3
        if let p = font.table("post"), p.count >= 16 { post.replaceSubrange(4..<16, with: Array(p)[4..<16]) }
        tables["post"] = post
        if let os2 = font.table("OS/2") { tables["OS/2"] = Array(os2) }
    }

    // MARK: - CFF

    /// A CID-keyed CFF table holding the subset (PDF `FontFile3` /
    /// `CIDFontType0C`): charstrings with subroutines inlined, one Font DICT
    /// per Private DICT the subset uses.
    func cffTable() throws -> [UInt8] {
        let cff = try font.cff()
        // Font DICTs in use, renumbered.
        var fdMap: [Int: Int] = [:]
        var fds: [Int] = []
        var select: [Int] = []
        var charStrings: [[UInt8]] = []
        for g in glyphs {
            guard g < cff.charStrings.count else { throw FontError.malformed("glyph id") }
            let fd = Int(cff.fdSelect[g])
            if fdMap[fd] == nil { fdMap[fd] = fds.count; fds.append(fd) }
            select.append(fdMap[fd] ?? 0)
            var flattener = Desubroutinizer(cff: cff, priv: cff.privates[fd])
            charStrings.append(try flattener.flatten(cff.charStrings[g]))
        }
        let name = Array(subsetName.utf8)
        let strings: [[UInt8]] = [Array("Adobe".utf8), Array("Identity".utf8)]
        // Font and Private DICTs (without Subrs; FontName dropped: its SID belongs to the old String INDEX).
        func copied(_ entries: [CFFFont.DictEntry], dropping: Set<Int>) -> [UInt8] {
            var out: [UInt8] = []
            for e in entries where !dropping.contains(e.op) { out += Self.dictEntry(e.op, e.operands) }
            return out
        }
        let privates = fds.map { copied(cff.privates[$0].entries, dropping: [19]) }
        let fontDictBase: [[UInt8]] = fds.map { fd in
            copied(cff.fontDicts?[fd] ?? cff.topDict.filter { [1207, 5].contains($0.op) }, dropping: [18, 1238, 1230, 1236, 1237, 17, 15, 19])
        }
        func topDict(charset: Int, fdSelect: Int, charStringsAt: Int, fdArray: Int) -> [UInt8] {
            var t = Self.dictEntry(1230, [391, 392, 0])                    // ROS Adobe-Identity-0
            for e in cff.topDict where [5, 1207].contains(e.op) { t += Self.dictEntry(e.op, e.operands) }   // FontBBox, FontMatrix
            t += Self.dictEntry(1234, [Double(glyphs.count)])                // CIDCount
            t += Self.dictInt(15, charset) + Self.dictInt(17, charStringsAt)
            t += Self.dictInt(1236, fdArray) + Self.dictInt(1237, fdSelect)
            return t
        }
        // Layout: header, Name, Top DICT, String, Global Subrs (empty), charset, FDSelect, CharStrings, FDArray, Privates.
        let header: [UInt8] = [1, 0, 4, 4]
        let nameIndex = Self.index([name])
        let stringIndex = Self.index(strings)
        let gsubrs = Self.index([])
        var charset: [UInt8] = []
        if glyphs.count > 1 { charset = [2] + be16(1) + be16(glyphs.count - 2) } else { charset = [0] }
        var fdSelect: [UInt8] = [3] + be16(0)
        var ranges: [(Int, Int)] = []
        for (g, fd) in select.enumerated() where ranges.last?.1 != fd { ranges.append((g, fd)) }
        fdSelect = [3] + be16(ranges.count)
        for r in ranges { fdSelect += be16(r.0) + [UInt8(r.1)] }
        fdSelect += be16(glyphs.count)
        let charStringIndex = Self.index(charStrings)
        // The Top DICT's size does not depend on the offsets (fixed 5-byte integers).
        let topSize = Self.index([topDict(charset: 0, fdSelect: 0, charStringsAt: 0, fdArray: 0)]).count
        let charsetAt = header.count + nameIndex.count + topSize + stringIndex.count + gsubrs.count
        let fdSelectAt = charsetAt + charset.count
        let charStringsAt = fdSelectAt + fdSelect.count
        let fdArrayAt = charStringsAt + charStringIndex.count
        // Font DICTs point at their Privates, which follow the FDArray.
        let fdDictSize = fontDictBase.map { $0.count + Self.dictInt(18, 0, 0).count }
        let fdArraySize = Self.index(fdDictSize.map { [UInt8](repeating: 0, count: $0) }).count
        var privateAt = fdArrayAt + fdArraySize
        var fontDicts: [[UInt8]] = []
        for (i, base) in fontDictBase.enumerated() {
            fontDicts.append(base + Self.dictInt(18, privates[i].count, privateAt))
            privateAt += privates[i].count
        }
        var out = header + nameIndex
        out += Self.index([topDict(charset: charsetAt, fdSelect: fdSelectAt, charStringsAt: charStringsAt, fdArray: fdArrayAt)])
        out += stringIndex + gsubrs + charset + fdSelect + charStringIndex + Self.index(fontDicts)
        for p in privates { out += p }
        return out
    }

    /// An OpenType (`OTTO`) file around `cffTable()` for SVG `@font-face`.
    func openTypeCFFFile(cmap: [UInt32: Int]) throws -> [UInt8] {
        let n = glyphs.count
        var tables: [String: [UInt8]] = ["CFF ": try cffTable()]
        var hmtx: [UInt8] = []
        for g in glyphs { hmtx += be16(font.advance(g)) + be16(0) }
        tables["hmtx"] = hmtx
        tables["head"] = try patched("head", 54) { t in t.replaceSubrange(8..<12, with: [0, 0, 0, 0]) }
        tables["hhea"] = try patched("hhea", 36) { t in t.replaceSubrange(34..<36, with: be16(n)) }
        tables["maxp"] = [0, 0, 0x50, 0] + be16(n)   // version 0.5
        try addCommonTables(&tables, cmap: cmap)
        return Self.sfnt(tables, version: 0x4F54_544F)
    }

    // MARK: - Serialization helpers

    static func index(_ items: [[UInt8]]) -> [UInt8] {
        guard !items.isEmpty else { return [0, 0] }
        var out = be16(items.count) + [4]
        var off = 1
        out += be32(off)
        for i in items { off += i.count; out += be32(off) }
        for i in items { out += i }
        return out
    }

    /// A DICT entry with operands in the shortest integer forms or as reals.
    static func dictEntry(_ op: Int, _ operands: [Double]) -> [UInt8] {
        var out: [UInt8] = []
        for v in operands {
            if v == v.rounded(), abs(v) < 2_000_000_000 {
                let i = Int(v)
                if (-107...107).contains(i) { out.append(UInt8(i + 139)) }
                else if (108...1131).contains(i) { let w = i - 108; out += [UInt8(w / 256 + 247), UInt8(w % 256)] }
                else if (-1131 ... -108).contains(i) { let w = -i - 108; out += [UInt8(w / 256 + 251), UInt8(w % 256)] }
                else if (-32768...32767).contains(i) { out += [28] + be16(i & 0xFFFF) }
                else { out += [29] + be32(i) }
            } else {
                out += real(v)
            }
        }
        out += op >= 1200 ? [12, UInt8(op - 1200)] : [UInt8(op)]
        return out
    }

    /// An entry whose integer operands are always 5 bytes (offsets fixed in size).
    static func dictInt(_ op: Int, _ values: Int...) -> [UInt8] {
        var out: [UInt8] = []
        for v in values { out += [29] + be32(v) }
        out += op >= 1200 ? [12, UInt8(op - 1200)] : [UInt8(op)]
        return out
    }

    static func real(_ v: Double) -> [UInt8] {
        var s = String(format: "%.8g", v).uppercased()
        if s.contains("E-") { s = s.replacingOccurrences(of: "E-", with: "c") }
        var nibbles: [UInt8] = []
        for ch in s {
            switch ch {
            case "0"..."9": nibbles.append(UInt8(String(ch))!)
            case ".": nibbles.append(0xA)
            case "E": nibbles.append(0xB)
            case "c": nibbles.append(0xC)
            case "-": nibbles.append(0xE)
            default: break
            }
        }
        nibbles.append(0xF)
        if nibbles.count % 2 == 1 { nibbles.append(0xF) }
        var out: [UInt8] = [30]
        for i in stride(from: 0, to: nibbles.count, by: 2) { out.append(nibbles[i] << 4 | nibbles[i + 1]) }
        return out
    }

    static func cmapTable(_ map: [UInt32: Int]) -> [UInt8] {
        let pairs = map.sorted { $0.key < $1.key }
        // Format 12 groups (consecutive code points with consecutive glyphs).
        var groups: [(UInt32, UInt32, Int)] = []
        for (c, g) in pairs {
            if let last = groups.last, last.1 + 1 == c, last.2 + Int(c - last.0) == g { groups[groups.count - 1].1 = c }
            else { groups.append((c, c, g)) }
        }
        var f12 = be16(12) + be16(0) + be32(16 + 12 * groups.count) + be32(0) + be32(groups.count)
        for g in groups { f12 += be32(Int(g.0)) + be32(Int(g.1)) + be32(g.2) }
        // Format 4 for the BMP, one segment per group plus the final 0xFFFF.
        let bmp = groups.filter { $0.1 <= 0xFFFE }
        let segs = bmp.count + 1
        var ends: [UInt8] = [], starts: [UInt8] = [], deltas: [UInt8] = [], offsets: [UInt8] = []
        for g in bmp {
            ends += be16(Int(g.1)); starts += be16(Int(g.0))
            deltas += be16((g.2 - Int(g.0)) & 0xFFFF); offsets += be16(0)
        }
        ends += be16(0xFFFF); starts += be16(0xFFFF); deltas += be16(1); offsets += be16(0)
        var p2 = 1, e = 0
        while p2 * 2 <= segs { p2 *= 2; e += 1 }
        let body = ends + [0, 0] + starts + deltas + offsets
        let f4 = be16(4) + be16(14 + body.count) + be16(0) + be16(2 * segs) + be16(2 * p2) + be16(e)
            + be16(2 * segs - 2 * p2) + body
        var out = be16(0) + be16(2)
        out += be16(3) + be16(1) + be32(4 + 16)
        out += be16(3) + be16(10) + be32(4 + 16 + f4.count)
        return out + f4 + f12
    }

    static func nameTable(family: String, subfamily: String, postScript: String) -> [UInt8] {
        let records: [(Int, String)] = [(1, family), (2, subfamily), (3, postScript), (4, family), (6, postScript)]
        var strings: [UInt8] = []
        var out = be16(0) + be16(records.count) + be16(6 + 12 * records.count)
        for (id, s) in records {
            let utf16 = s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            out += be16(3) + be16(1) + be16(0x409) + be16(id) + be16(utf16.count) + be16(strings.count)
            strings += utf16
        }
        return out + strings
    }

    /// An sfnt file from tables (directory sorted by tag, checksums, `head` adjustment).
    static func sfnt(_ tables: [String: [UInt8]], version: Int) -> [UInt8] {
        let tags = tables.keys.sorted()
        let n = tags.count
        var p2 = 1, e = 0
        while p2 * 2 <= n { p2 *= 2; e += 1 }
        var out = be32(version) + be16(n) + be16(16 * p2) + be16(e) + be16(16 * n - 16 * p2)
        var offset = 12 + 16 * n
        var body: [UInt8] = []
        var headAt: Int?
        for tag in tags {
            var t = tables[tag]!
            let length = t.count
            while t.count % 4 != 0 { t.append(0) }
            out += Array(tag.utf8) + be32(Int(checksum(t))) + be32(offset) + be32(length)
            if tag == "head" { headAt = offset }
            body += t
            offset += t.count
        }
        out += body
        if let h = headAt {
            let adj = Int((0xB1B0_AFBA &- checksum(out)) & 0xFFFF_FFFF)
            out.replaceSubrange((h + 8)..<(h + 12), with: be32(adj))
        }
        return out
    }

    static func checksum(_ b: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < b.count {
            var w: UInt32 = 0
            for k in 0..<4 { w = w << 8 | UInt32(i + k < b.count ? b[i + k] : 0) }
            sum &+= w
            i += 4
        }
        return sum
    }
}

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
/// The big-endian 32-bit value at `d[i..<i + 4]`.
func readBE32(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }

/// Rewrites a Type 2 charstring with every `callsubr`/`callgsubr` replaced by
/// the subroutine's body (and `return` dropped), keeping operand bytes as they
/// were. Hint masks are copied with the stem count tracked across calls.
struct Desubroutinizer {
    let cff: CFFFont
    let priv: CFFFont.PrivateDict
    private var out: [UInt8] = []
    /// Byte ranges in `out` of operands not yet consumed by an operator.
    private var operands: [(start: Int, value: Double)] = []
    private var stems = 0
    private var ended = false
    private var budget = 1 << 16

    init(cff: CFFFont, priv: CFFFont.PrivateDict) { self.cff = cff; self.priv = priv }

    mutating func flatten(_ r: Range<Int>) throws -> [UInt8] {
        try walk(r, depth: 0)
        if !ended { out.append(14) }
        return out
    }

    private mutating func walk(_ r: Range<Int>, depth: Int) throws {
        guard depth <= 10 else { throw FontError.malformed("subroutine nesting") }
        let d = cff.data
        var p = r.lowerBound
        while p < r.upperBound && !ended {
            budget -= 1
            guard budget >= 0 else { throw FontError.malformed("charstring too long") }
            let v = Int(d[p])
            if v >= 32 || v == 28 {
                let len = v == 28 ? 3 : v <= 246 ? 1 : v <= 254 ? 2 : 5
                guard p + len <= r.upperBound else { throw FontError.malformed("charstring operand") }
                var value: Double
                switch v {
                case 28: value = Double(Int16(bitPattern: UInt16(d[p + 1]) << 8 | UInt16(d[p + 2])))
                case 32...246: value = Double(v - 139)
                case 247...250: value = Double((v - 247) * 256 + Int(d[p + 1]) + 108)
                case 251...254: value = Double(-(v - 251) * 256 - Int(d[p + 1]) - 108)
                default: value = 0
                }
                operands.append((out.count, value))
                out += d[p..<(p + len)]
                p += len
                continue
            }
            var opLen = 1
            if v == 12 { opLen = 2 }
            guard p + opLen <= r.upperBound else { throw FontError.malformed("charstring operator") }
            switch v {
            case 10, 29:
                guard let last = operands.popLast() else { throw FontError.malformed("call without index") }
                out.removeSubrange(last.start...)
                let list = v == 10 ? priv.subrs : cff.globalSubrs
                let i = Int(last.value) + CFFFont.bias(list.count)
                guard i >= 0, i < list.count else { throw FontError.malformed("subroutine index") }
                p += 1
                try walk(list[i], depth: depth + 1)
                continue
            case 11:
                return
            case 1, 3, 18, 23:
                stems += operands.count / 2
            case 19, 20:
                stems += operands.count / 2
                let maskBytes = (stems + 7) / 8
                guard p + 1 + maskBytes <= r.upperBound else { throw FontError.malformed("hint mask") }
                out += d[p..<(p + 1 + maskBytes)]
                operands.removeAll()
                p += 1 + maskBytes
                continue
            case 14:
                ended = true
            default:
                break
            }
            out += d[p..<(p + opLen)]
            operands.removeAll()
            p += opLen
        }
    }
}
