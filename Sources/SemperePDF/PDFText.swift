import Foundation

/// Plain-text extraction from a PDF page (format.md §8.2.6 `pageText`):
/// the strings the page's content stream shows (`Tj`, `TJ`, `'`, `"`), in
/// content order, decoded through each font's `/ToUnicode` CMap or, for
/// simple fonts, its encoding (`WinAnsiEncoding`, `MacRomanEncoding`,
/// `StandardEncoding`, `/Differences` with Adobe glyph names). Text moved to
/// a new line (`Td`, `TD`, `T*`, `Tm`, `'`, `"`) starts a new line; a large
/// gap inside `TJ` or a horizontal `Td` becomes a space. Form XObjects
/// (`Do`) are read in place, four levels deep at most.
///
/// It is not a layout engine: columns come out in content order, and glyphs a
/// font cannot map (a Type 0 font without `/ToUnicode`) are left out. Every
/// byte is untrusted (format.md §9): the work is linear in the content and
/// CMap bytes read, and the output is capped at `maxOutputBytes`.
public enum PDFText {
    /// The engine name written with the text (`PDFPageText.engine`).
    public static let engine = "semperepdf-1"
    /// Most UTF-8 bytes produced per page (the stored limit is 65 536; a
    /// little more lets the writer cut at a character boundary).
    public static let maxOutputBytes = 70_000
    /// Most operators interpreted per page, over every form it draws.
    public static let maxOperators = 2_000_000
    /// Deepest nesting of form XObjects followed.
    public static let maxFormDepth = 4
    /// Most content bytes lexed per page beyond the page's own content
    /// stream: what form XObjects drawn by `Do` add. A form is decoded once
    /// but lexed on every `Do`, so without this bound 2·10⁶ `Do`s of a
    /// 256 KiB form would lex 5·10¹¹ bytes (security review S8). Past it the
    /// page keeps the text found so far.
    public static let maxFormLexBytesPerPage = 16 << 20
    /// Most form bytes lexed (as `maxFormLexBytesPerPage`) over all the pages
    /// of one file sharing an `ExtractionCache`.
    public static let maxFormLexBytesPerFile = 128 << 20

    /// The text of page `index` (0-based).
    ///
    /// - Throws: `PDFError` when the page or its content cannot be read.
    public static func pageText(_ file: PDFFile, page index: Int) throws -> String {
        try pageText(file, page: index, cache: ExtractionCache())
    }

    /// `pageText`, reusing the fonts and forms `cache` holds from other pages of `file`.
    static func pageText(_ file: PDFFile, page index: Int, cache: ExtractionCache) throws -> String {
        let node = try file.pageNode(index)
        var state = Extraction(file: file, cache: cache)
        let resources = try node.resources.flatMap { try file.resolve($0).dictValue }
        let contents = try file.pageContents(index)
        let extra = min(cache.formLexPerPage, cache.formLexLeft)
        state.lexBudget = contents.count + extra
        defer { cache.formLexLeft -= min(max(state.lexed - contents.count, 0), extra) }
        try state.run(contents, resources: resources, depth: 0)
        return state.finish()
    }

    /// The text of every page, by 0-based index; a page whose content cannot
    /// be read is missing from the result (the others are still read).
    public static func pageTexts(_ data: Data, pages: [Int]? = nil) throws -> [Int: String] {
        let file = try PDFFile(data: data)
        // Fonts (their ToUnicode CMaps) and forms shared by pages are decoded once per file.
        let cache = ExtractionCache()
        var out: [Int: String] = [:]
        for i in pages ?? Array(0..<file.pageCount) {
            if let t = try? pageText(file, page: i, cache: cache) { out[i] = t }
        }
        return out
    }
}

// MARK: - Interpreter

/// What the pages of one `PDFFile` share: font decoders of indirect fonts
/// and decoded form XObjects, by object number (objects of a parsed file
/// never change). Forms are kept up to `maxFormBytes` in all.
final class ExtractionCache {
    static let maxFormBytes = 64 << 20
    var fonts: [Int: FontDecoder] = [:]
    var forms: [Int: [UInt8]] = [:]
    var formBytes = 0
    /// Form bytes a page may lex beyond its own content, and what is left
    /// of the file's allowance (`PDFText.maxFormLexBytesPerPage`, `…PerFile`).
    let formLexPerPage: Int
    var formLexLeft: Int

    init(formLexPerPage: Int = PDFText.maxFormLexBytesPerPage, formLexPerFile: Int = PDFText.maxFormLexBytesPerFile) {
        self.formLexPerPage = formLexPerPage
        formLexLeft = formLexPerFile
    }
}

struct Extraction {
    let file: PDFFile
    let cache: ExtractionCache
    var out = ""
    var outBytes = 0
    var operators = 0
    /// Content bytes lexed on this page, forms included, and the most allowed.
    var lexed = 0
    var lexBudget = Int.max
    var fonts: [String: FontDecoder] = [:]   // direct fonts, by name in a resource dict (this page only)
    var forms: [Int: [UInt8]] = [:]          // decoded form XObjects, by object number (this page, uncapped)
    /// Line state: y of the current line in text space, and whether text was shown on it.
    var lineY: Double?
    var pendingSpace = false

    init(file: PDFFile, cache: ExtractionCache = ExtractionCache()) {
        self.file = file
        self.cache = cache
    }

    mutating func emit(_ s: String) {
        guard outBytes < PDFText.maxOutputBytes, !s.isEmpty else { return }
        if pendingSpace, let last = out.last, !last.isWhitespace { out.append(" "); outBytes += 1 }
        pendingSpace = false
        out += s
        outBytes += s.utf8.count
    }

    mutating func newLine() {
        pendingSpace = false
        guard !out.isEmpty, out.last != "\n" else { return }
        out.append("\n")
        outBytes += 1
    }

    mutating func space() { if !out.isEmpty, out.last != "\n" { pendingSpace = true } }

    func finish() -> String {
        out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Moves the text line to `y` (text space); a different line starts a new output line.
    mutating func moveTo(y: Double, size: Double) {
        if let ly = lineY, abs(ly - y) > max(abs(size) * 0.3, 0.5) { newLine() }
        lineY = y
    }

    mutating func run(_ content: [UInt8], resources: PDFDict?, depth: Int) throws {
        var lx = PDFLexer(content, maxDepth: file.limits.maxDepth)
        var operands: [PDFObject] = []
        var font: FontDecoder?
        var fontSize = 12.0
        var leading = 0.0
        var ty = 0.0   // y of the line matrix's origin
        var tm = (a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0)

        func num(_ i: Int) -> Double? {
            guard i < operands.count else { return nil }
            return operands[operands.count - 1 - i].number.flatMap { $0.isFinite ? $0 : nil }
        }

        var seen = 0
        while true {
            lexed += lx.scanned - seen
            seen = lx.scanned
            guard lexed <= lexBudget else { return }
            lx.skipWhitespace()
            guard !lx.atEnd else { break }
            let c = lx.b[lx.pos]
            if PDFLexer.isRegular(c), !(c == 0x2B || c == 0x2D || c == 0x2E || PDFLexer.isDigit(c)) {
                let tok = Array(lx.token())
                guard !tok.isEmpty else { lx.pos += 1; continue }
                operators += 1
                guard operators <= PDFText.maxOperators else { return }
                let op = String(decoding: tok, as: UTF8.self)
                switch op {
                case "true", "false", "null":
                    operands.append(op == "null" ? .null : .bool(op == "true"))
                    continue
                case "BT":
                    tm = (1, 0, 0, 1, 0, 0); ty = 0
                case "ET":
                    break
                case "Tf":
                    if operands.count >= 2, case .name(let n) = operands[operands.count - 2] {
                        font = try decoder(named: n, resources: resources)
                        fontSize = num(0) ?? fontSize
                    }
                case "TL":
                    leading = num(0) ?? leading
                case "Td", "TD":
                    if let tx = num(1), let dy = num(0) {
                        if op == "TD" { leading = -dy }
                        ty += dy
                        let y = ty * tm.d
                        if abs(dy) < 1e-9 { if tx > 0 { space() } } else { moveTo(y: y, size: fontSize * tm.d) }
                        if abs(dy) < 1e-9 { lineY = y }
                    }
                case "Tm":
                    if operands.count >= 6, let f = num(0), let e = num(1), let d = num(2), let cc = num(3),
                       let b = num(4), let a = num(5) {
                        tm = (a, b, cc, d, e, f); ty = 0
                        moveTo(y: f, size: fontSize * d)
                    }
                case "T*":
                    ty -= leading
                    moveTo(y: tm.f + ty * tm.d, size: fontSize * tm.d)
                    if leading == 0 { newLine() }
                case "Tj", "'", "\"":
                    if op != "Tj" {
                        ty -= leading
                        newLine()
                        lineY = tm.f + ty * tm.d
                    }
                    if case .string(let s)? = operands.last, let font { emit(font.decode(s, maxBytes: PDFText.maxOutputBytes - outBytes)) }
                case "TJ":
                    if case .array(let parts)? = operands.last, let font {
                        for p in parts {
                            switch p {
                            case .string(let s): emit(font.decode(s, maxBytes: PDFText.maxOutputBytes - outBytes))
                            default:
                                if let n = p.number, n.isFinite, n < -180 { space() }
                            }
                        }
                    }
                case "Do":
                    if depth < PDFText.maxFormDepth, case .name(let n)? = operands.last {
                        try form(named: n, resources: resources, depth: depth)
                    }
                case "BI":
                    skipInlineImage(&lx)
                default:
                    break
                }
                operands.removeAll(keepingCapacity: true)
            } else {
                do {
                    operands.append(try lx.parseObject())
                } catch let e as PDFError {
                    if case .limitExceeded = e { throw e }
                    // An unparseable operand: skip a byte and go on (content
                    // streams in the wild are often slightly broken).
                    lx.pos += 1
                    operands.removeAll(keepingCapacity: true)
                }
                if operands.count > 64 { operands.removeFirst(operands.count - 64) }
            }
        }
    }

    /// Skips an inline image (`BI … ID <data> EI`): the data ends at `EI`
    /// between white space.
    func skipInlineImage(_ lx: inout PDFLexer) {
        let b = lx.b
        // Find "ID" as a token.
        while !lx.atEnd {
            lx.skipWhitespace()
            guard !lx.atEnd else { return }
            if PDFLexer.isRegular(b[lx.pos]) {
                let t = lx.token()
                if t.elementsEqual("ID".utf8) { break }
                if t.isEmpty { lx.pos += 1 }
            } else if (try? lx.parseObject()) == nil {
                lx.pos += 1
            }
        }
        lx.pos += 1
        var i = lx.pos
        while i + 1 < b.count {
            if b[i] == 0x45, b[i + 1] == 0x49, i > 0, PDFLexer.isWhite(b[i - 1]),
               i + 2 >= b.count || PDFLexer.isWhite(b[i + 2]) || PDFLexer.isDelimiter(b[i + 2]) {
                lx.pos = i + 2
                return
            }
            i += 1
        }
        lx.pos = b.count
    }

    mutating func form(named n: PDFName, resources: PDFDict?, depth: Int) throws {
        guard let res = resources, let xobjects = try file.value(res, "XObject")?.dictValue,
              let entry = xobjects[n], case .stream(let s) = try file.resolve(entry),
              s.dict["Subtype"]?.nameValue == "Form" else { return }
        // A form drawn many times is decoded once.
        let data: [UInt8]
        if case .ref(let r) = entry, let hit = forms[r.num] ?? cache.forms[r.num] { data = hit } else {
            data = try file.decodedData(of: s, allowed: PDFFilters.decodable)
            if case .ref(let r) = entry {
                forms[r.num] = data
                if cache.formBytes + data.count <= ExtractionCache.maxFormBytes {
                    cache.forms[r.num] = data
                    cache.formBytes += data.count
                }
            }
        }
        let own = try file.value(s.dict, "Resources")?.dictValue ?? resources
        try run(data, resources: own, depth: depth + 1)
    }

    mutating func decoder(named n: PDFName, resources: PDFDict?) throws -> FontDecoder? {
        guard let res = resources, let fontsDict = try file.value(res, "Font")?.dictValue, let entry = fontsDict[n] else {
            return nil
        }
        if case .ref(let r) = entry {
            if let hit = cache.fonts[r.num] { return hit }
            guard let dict = try file.resolve(entry).dictValue else { return nil }
            let d = FontDecoder(dict: dict, file: file)
            cache.fonts[r.num] = d
            return d
        }
        let key = String(decoding: n.bytes, as: UTF8.self)
        if let hit = fonts[key] { return hit }
        guard let dict = try file.resolve(entry).dictValue else { return nil }
        let d = FontDecoder(dict: dict, file: file)
        fonts[key] = d
        return d
    }
}

// MARK: - Fonts

/// Maps the bytes of a shown string to text for one font.
struct FontDecoder {
    var cmap: ToUnicodeCMap?
    /// Byte length of a code (1 for simple fonts, 2 for Type 0 unless the CMap says otherwise).
    var codeLengths: [Int] = [1]
    var simple: [UInt16: String] = [:]   // single-byte code → text (simple fonts)
    var isType0 = false

    init(dict: PDFDict, file: PDFFile) {
        isType0 = dict["Subtype"]?.nameValue == "Type0"
        if let tu = try? file.value(dict, "ToUnicode"), case .stream(let s) = tu,
           let bytes = try? file.decodedData(of: s, allowed: PDFFilters.decodable) {
            cmap = ToUnicodeCMap(bytes)
        }
        if isType0 {
            if let lengths = cmap?.codeLengths, !lengths.isEmpty { codeLengths = lengths } else { codeLengths = [2] }
            return
        }
        codeLengths = [1]
        var table = StandardEncodings.winAnsi
        var differences: [Int: String] = [:]
        switch try? file.value(dict, "Encoding") {
        case .name(let n)?:
            table = StandardEncodings.table(named: n) ?? table
        case .dict(let e)?:
            if let base = e["BaseEncoding"]?.nameValue { table = StandardEncodings.table(named: base) ?? table }
            if case .array(let diffs)? = try? file.value(e, "Differences") {
                var code = 0
                for d in diffs.prefix(4096) {
                    if let i = d.intValue { code = i; continue }
                    if case .name(let g) = d, (0...255).contains(code) {
                        if let t = GlyphNames.text(for: String(decoding: g.bytes, as: UTF8.self)) { differences[code] = t }
                        code += 1
                    }
                }
            }
        default: break
        }
        for code in 0...255 {
            if let t = differences[code] ?? table[code] { simple[UInt16(code)] = t }
        }
    }

    /// The text of `bytes`, cut once it holds more than `maxBytes` UTF-8
    /// bytes: one code can map to a long string, so a string of repeated codes
    /// would otherwise build gigabytes before the page's output cap applies.
    func decode(_ bytes: [UInt8], maxBytes: Int = .max) -> String {
        var out = ""
        var outBytes = 0
        var i = 0
        while i < bytes.count, outBytes <= maxBytes {
            // The longest code length that the CMap knows at this position, else the shortest.
            var len = codeLengths.min() ?? 1
            if let cmap, codeLengths.count > 1 {
                for l in codeLengths.sorted(by: >) where i + l <= bytes.count {
                    if cmap.lookup(code(bytes, i, l), length: l) != nil { len = l; break }
                }
            }
            len = min(max(len, 1), 4)
            guard i + len <= bytes.count else { break }
            let c = code(bytes, i, len)
            if let cmap, let t = cmap.lookup(c, length: len) {
                out += t; outBytes += t.utf8.count
            } else if !isType0, let t = simple[UInt16(truncatingIfNeeded: c)] {
                out += t; outBytes += t.utf8.count
            }
            i += len
        }
        return out
    }

    func code(_ b: [UInt8], _ i: Int, _ len: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<len { v = v << 8 | UInt32(b[i + k]) }
        return v
    }
}

/// A `/ToUnicode` CMap: `bfchar` and `bfrange` mappings and the codespace's
/// code lengths. Ranges are kept as ranges (never expanded), so a hostile
/// `<0000> <FFFFFFFF>` costs nothing.
struct ToUnicodeCMap {
    struct Range { var lo: UInt32; var hi: UInt32; var length: Int; var start: [UInt16]?; var list: [String]? }
    var chars: [UInt64: String] = [:]   // length << 32 | code
    var ranges: [Range] = []
    var codeLengths: [Int] = []

    static let maxEntries = 100_000

    init(_ bytes: [UInt8]) {
        var lx = PDFLexer(bytes)
        var operands: [PDFObject] = []
        var mode = ""
        var lengths = Set<Int>()
        var entries = 0
        while !lx.atEnd, entries < Self.maxEntries {
            lx.skipWhitespace()
            guard !lx.atEnd else { break }
            let c = lx.b[lx.pos]
            if PDFLexer.isRegular(c), !(c == 0x2B || c == 0x2D || c == 0x2E || PDFLexer.isDigit(c)) {
                let t = String(decoding: lx.token(), as: UTF8.self)
                if t.isEmpty { lx.pos += 1; continue }
                switch t {
                case "begincodespacerange", "beginbfchar", "beginbfrange": mode = t; operands = []
                case "endcodespacerange":
                    var k = 0
                    while k + 1 < operands.count {
                        if case .string(let a) = operands[k], (1...4).contains(a.count) { lengths.insert(a.count) }
                        k += 2
                    }
                    mode = ""; operands = []
                case "endbfchar":
                    var k = 0
                    while k + 1 < operands.count {
                        if case .string(let src) = operands[k], (1...4).contains(src.count),
                           case .string(let dst) = operands[k + 1] {
                            chars[UInt64(src.count) << 32 | UInt64(Self.value(src))] = Self.utf16(dst)
                            entries += 1
                        }
                        k += 2
                    }
                    mode = ""; operands = []
                case "endbfrange":
                    var k = 0
                    while k + 2 < operands.count {
                        if case .string(let lo) = operands[k], case .string(let hi) = operands[k + 1],
                           (1...4).contains(lo.count), lo.count == hi.count, Self.value(lo) <= Self.value(hi) {
                            var r = Range(lo: Self.value(lo), hi: Self.value(hi), length: lo.count, start: nil, list: nil)
                            switch operands[k + 2] {
                            case .string(let dst): r.start = Self.units(dst)
                            case .array(let a):
                                r.list = a.prefix(Self.maxEntries).map { if case .string(let s) = $0 { return Self.utf16(s) }; return "" }
                            default: break
                            }
                            ranges.append(r)
                            entries += 1
                        }
                        k += 3
                    }
                    mode = ""; operands = []
                default: if mode.isEmpty { operands = [] }
                }
            } else {
                if let o = try? lx.parseObject() { if !mode.isEmpty { operands.append(o) } } else { lx.pos += 1 }
                if operands.count > 3 * Self.maxEntries { operands.removeAll() }
            }
        }
        codeLengths = lengths.sorted()
        if codeLengths.isEmpty {
            codeLengths = Array(Set(chars.keys.map { Int($0 >> 32) } + ranges.map(\.length))).sorted()
        }
        // Sorted by (length, lo), so a lookup is a binary search, not a scan of every range.
        ranges.sort { ($0.length, $0.lo) < ($1.length, $1.lo) }
    }

    /// Ranges overlapping one code are checked at most this many deep (real
    /// CMaps do not overlap; a hostile one cannot make a lookup scan them all).
    static let maxOverlap = 8

    func lookup(_ code: UInt32, length: Int) -> String? {
        if let s = chars[UInt64(length) << 32 | UInt64(code)] { return s }
        // The last range starting at or before `code`, then a few before it.
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if (r.length, r.lo) <= (length, code) { lo = mid + 1 } else { hi = mid }
        }
        for r in ranges[max(0, lo - Self.maxOverlap)..<lo].reversed() where r.length == length && code >= r.lo && code <= r.hi {
            let off = Int(code - r.lo)
            if let list = r.list { return off < list.count ? list[off] : nil }
            if var units = r.start, !units.isEmpty {
                let (v, o) = units[units.count - 1].addingReportingOverflow(UInt16(truncatingIfNeeded: off))
                guard !o, off <= 0xFFFF else { return nil }
                units[units.count - 1] = v
                return String(decoding: units, as: UTF16.self)
            }
        }
        return nil
    }

    static func value(_ b: [UInt8]) -> UInt32 { b.reduce(0) { $0 << 8 | UInt32($1) } }
    static func units(_ b: [UInt8]) -> [UInt16] {
        stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
    }
    static func utf16(_ b: [UInt8]) -> String {
        if b.count == 1 { return String(Unicode.Scalar(b[0])) }
        return String(decoding: units(b), as: UTF16.self)
    }
}

// MARK: - Encodings and glyph names

enum StandardEncodings {
    static func table(named n: PDFName) -> [Int: String]? {
        switch n {
        case "WinAnsiEncoding": return winAnsi
        case "MacRomanEncoding": return macRoman
        case "StandardEncoding", "PDFDocEncoding": return winAnsi
        default: return nil
        }
    }

    /// Windows-1252 (ISO 32000-1 Annex D): ASCII, Latin-1, and 0x80–0x9F as cp1252.
    static let winAnsi: [Int: String] = {
        var t: [Int: String] = [:]
        for c in 0x20...0x7E { t[c] = String(Unicode.Scalar(UInt8(c))) }
        for c in 0xA0...0xFF { t[c] = String(Unicode.Scalar(UInt8(c))) }
        let high: [Int: UInt32] = [0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020,
                                   0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
                                   0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
                                   0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
                                   0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178]
        for (k, v) in high { t[k] = Unicode.Scalar(v).map { String($0) } }
        t[0xAD] = "-"
        return t
    }()

    /// Mac OS Roman, 0x80–0xFF.
    static let macRoman: [Int: String] = {
        var t: [Int: String] = [:]
        for c in 0x20...0x7E { t[c] = String(Unicode.Scalar(UInt8(c))) }
        let high = "ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü†°¢£§•¶ß®©™´¨≠ÆØ∞±≤≥¥µ∂∑∏π∫ªºΩæø¿¡¬√ƒ≈∆«»… ÀÃÕŒœ–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔ\u{F8FF}ÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ"
        for (i, ch) in high.enumerated() { t[0x80 + i] = String(ch) }
        return t
    }()
}

/// Adobe glyph names to text: `uniXXXX`, `uXXXX[XX]`, single letters and
/// digits' names, the Latin-1 accented letters and common punctuation, and
/// ligatures. Unknown names map to nothing.
enum GlyphNames {
    static func text(for name: String) -> String? {
        let base = name.split(separator: ".").first.map(String.init) ?? name
        if let t = table[base] { return t }
        if base.count == 1, let c = base.unicodeScalars.first, c.isASCII, c.properties.isAlphabetic { return base }
        if base.hasPrefix("uni"), base.count >= 7, base.count % 4 == 3 {
            var units: [UInt16] = []
            var s = base.dropFirst(3)
            while !s.isEmpty { guard let v = UInt16(s.prefix(4), radix: 16) else { return nil }; units.append(v); s = s.dropFirst(4) }
            return String(decoding: units, as: UTF16.self)
        }
        if base.hasPrefix("u"), (5...7).contains(base.count), let v = UInt32(base.dropFirst(), radix: 16),
           let sc = Unicode.Scalar(v) {
            return String(sc)
        }
        return nil
    }

    static let table: [String: String] = {
        var t: [String: String] = [
            "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
            "ampersand": "&", "quotesingle": "'", "quoteright": "\u{2019}", "quoteleft": "\u{2018}", "parenleft": "(",
            "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "minus": "\u{2212}",
            "period": ".", "slash": "/", "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">",
            "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]",
            "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{", "bar": "|", "braceright": "}",
            "asciitilde": "~", "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}",
            "ellipsis": "\u{2026}", "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}",
            "quotesinglbase": "\u{201A}", "quotedblbase": "\u{201E}", "dagger": "\u{2020}", "daggerdbl": "\u{2021}",
            "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi", "ffl": "ffl", "Euro": "\u{20AC}",
            "trademark": "\u{2122}", "copyright": "\u{00A9}", "registered": "\u{00AE}", "degree": "\u{00B0}",
            "section": "\u{00A7}", "paragraph": "\u{00B6}", "dotlessi": "\u{0131}", "germandbls": "\u{00DF}",
            "AE": "\u{00C6}", "ae": "\u{00E6}", "OE": "\u{0152}", "oe": "\u{0153}", "Oslash": "\u{00D8}",
            "oslash": "\u{00F8}", "exclamdown": "\u{00A1}", "questiondown": "\u{00BF}", "guillemotleft": "\u{00AB}",
            "guillemotright": "\u{00BB}", "multiply": "\u{00D7}", "divide": "\u{00F7}", "periodcentered": "\u{00B7}",
            "nbspace": "\u{00A0}", "sterling": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
        ]
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (i, d) in digits.enumerated() { t[d] = String(i) }
        // Accented letters: <letter><accent>, as in the Adobe Glyph List.
        let accents: [(String, UInt32)] = [("grave", 0x300), ("acute", 0x301), ("circumflex", 0x302), ("tilde", 0x303),
                                           ("dieresis", 0x308), ("ring", 0x30A), ("cedilla", 0x327), ("caron", 0x30C)]
        for letter in "AEIOUYCNSZaeiouycnsz" {
            for (name, mark) in accents {
                guard let scalar = Unicode.Scalar(mark) else { continue }
                let composed = (String(letter) + String(scalar)).precomposedStringWithCanonicalMapping
                if composed.unicodeScalars.count == 1 { t[String(letter) + name] = composed }
            }
        }
        return t
    }()
}
