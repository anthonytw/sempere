import Foundation

/// A rectangle in PDF user space, normalised so that `x0 < x1`, `y0 < y1`.
public struct PDFRect: Hashable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double

    /// Creates a rectangle from two corners in any order.
    public init(_ a: Double, _ b: Double, _ c: Double, _ d: Double) {
        x0 = min(a, c); y0 = min(b, d); x1 = max(a, c); y1 = max(b, d)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }

    /// The intersection, or nil when it is empty.
    public func intersection(_ o: PDFRect) -> PDFRect? {
        let r = PDFRect(max(x0, o.x0), max(y0, o.y0), min(x1, o.x1), min(y1, o.y1))
        return max(x0, o.x0) < min(x1, o.x1) && max(y0, o.y0) < min(y1, o.y1) ? r : nil
    }
}

/// One page's geometry (format.md §8.2.6, §8.5.1).
public struct PDFPageInfo: Hashable, Sendable {
    /// 0-based index in page-tree order.
    public var index: Int
    /// `/MediaBox` (inherited; US Letter when missing or invalid).
    public var mediaBox: PDFRect
    /// `/CropBox` (inherited; the MediaBox when missing or invalid).
    public var cropBox: PDFRect
    /// CropBox ∩ MediaBox: the part of the page that is shown.
    public var visibleBox: PDFRect
    /// `/Rotate` (inherited), normalised to 0, 90, 180 or 270 (clockwise).
    public var rotation: Int

    /// The effective page: the visible box turned by `rotation`, `W' × H'` points.
    public var effectiveWidth: Double { rotation % 180 == 0 ? visibleBox.width : visibleBox.height }
    /// See `effectiveWidth`.
    public var effectiveHeight: Double { rotation % 180 == 0 ? visibleBox.height : visibleBox.width }

    /// Creates page geometry (for callers without a parsed PDF).
    public init(index: Int, mediaBox: PDFRect, cropBox: PDFRect, visibleBox: PDFRect, rotation: Int) {
        self.index = index; self.mediaBox = mediaBox; self.cropBox = cropBox
        self.visibleBox = visibleBox; self.rotation = rotation
    }
}

/// A read-only, minimal PDF reader for untrusted files (`docs/attachments.md`
/// §10): classic cross-reference tables and cross-reference streams, hybrid
/// files, incremental updates (newest wins), object streams, and a rebuild of
/// the cross-reference data by scanning when it is missing or broken. It
/// reads page geometry and copies pages out as Form XObjects
/// (`PDFFormCopier`); it does not render.
///
/// Encrypted files are refused. Every limit of `PDFLimits` ends in a
/// `PDFError`; nothing the bytes say makes the reader trap, recurse without
/// bound or allocate beyond the limits.
///
/// Not thread-safe: objects are parsed lazily and cached. Use one instance
/// from one task.
public final class PDFFile {
    enum XrefEntry: Equatable {
        case free
        case offset(Int)
        case compressed(stream: Int, index: Int)
    }

    struct ObjectStream {
        var data: [UInt8]
        var first: Int
        var entries: [(num: Int, offset: Int)]
        /// Object number → offset of its first entry: a lookup whose
        /// `index` is wrong costs one hash, not a scan of `entries` (a
        /// hostile stream may list millions, and every resolve may miss).
        var byNumber: [Int: Int] = [:]

        init(data: [UInt8], first: Int, entries: [(num: Int, offset: Int)]) {
            self.data = data; self.first = first; self.entries = entries
            for e in entries where byNumber[e.num] == nil { byNumber[e.num] = e.offset }
        }
    }

    struct PageNode {
        var dict: PDFDict
        var resources: PDFObject?
        var mediaBox: PDFObject?
        var cropBox: PDFObject?
        var rotate: PDFObject?
        var group: PDFObject?
    }

    /// The limits in force.
    public let limits: PDFLimits
    let bytes: [UInt8]
    private(set) var xref: [Int: XrefEntry] = [:]
    /// The (merged) trailer dictionary.
    public private(set) var trailer = PDFDict()
    /// True when the cross-reference data was rebuilt by scanning the file.
    public private(set) var repaired = false
    /// The version from the `%PDF-x.y` header, when there is one.
    public private(set) var headerVersion: String?

    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: ObjectStream] = [:]
    private var resolving = Set<Int>()
    private var decodedTotal = 0
    /// Bytes the object parser looked at so far (`chargeParse`).
    private var parsedTotal = 0
    private var endstreams: [Int]?
    private var pages: [PageNode]?

    /// Opens a PDF held in memory.
    public convenience init(data: Data, limits: PDFLimits = .standard) throws {
        guard data.count <= limits.maxFileBytes else {
            throw PDFError.limitExceeded("file larger than \(limits.maxFileBytes) bytes")
        }
        try self.init(bytes: [UInt8](data), limits: limits)
    }

    /// Opens a PDF held in memory.
    ///
    /// - Throws: `PDFError.encrypted` when the trailer has `/Encrypt`;
    ///   `.notAPDF` when no catalog and page tree can be found even after a
    ///   rebuild; `.limitExceeded`, `.cycle`, `.badPageTree` and the like for
    ///   hostile structure.
    public init(bytes: [UInt8], limits: PDFLimits = .standard) throws {
        guard bytes.count <= limits.maxFileBytes else {
            throw PDFError.limitExceeded("file larger than \(limits.maxFileBytes) bytes")
        }
        self.limits = limits
        self.bytes = bytes
        headerVersion = Self.headerVersion(bytes)
        do {
            try loadXref()
            if trailer["Encrypt"] != nil { throw PDFError.encrypted }
            _ = try pageNodes()
        } catch let e as PDFError {
            // A broken table may claim anything (even sizes beyond the limits): rebuild it once.
            guard e != .encrypted, !repaired else { throw e }
            try repair()
            if trailer["Encrypt"] != nil { throw PDFError.encrypted }
            _ = try pageNodes()
        }
    }

    // MARK: - Header, startxref

    static func headerVersion(_ b: [UInt8]) -> String? {
        let marker = Array("%PDF-".utf8)
        let window = min(b.count, 1024)
        guard window >= marker.count else { return nil }
        for i in 0...(window - marker.count) where b[i] == 0x25 && Array(b[i..<(i + 5)]) == marker {
            var j = i + 5
            var v = ""
            while j < b.count, j < i + 9, b[j] == 0x2E || PDFLexer.isDigit(b[j]) {
                v.append(Character(Unicode.Scalar(b[j])))
                j += 1
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Offset named by the last `startxref` in the final 1 KiB (a little more
    /// is searched, for trailing garbage).
    func startxref() -> Int? {
        let key = Array("startxref".utf8)
        let from = max(0, bytes.count - 4096)
        var i = bytes.count - key.count
        while i >= from {
            if bytes[i] == 0x73, Array(bytes[i..<(i + key.count)]) == key {
                var lx = PDFLexer(bytes, at: i + key.count, maxDepth: limits.maxDepth)
                return lx.unsignedInt()
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Work budget

    /// Charges `n` bytes looked at by the object parser against the file's
    /// budget (`PDFLimits.parseBytesPerByte`), so no structure, however
    /// hostile, makes the reader's work more than linear in its input.
    ///
    /// - Throws: `limitExceeded` once the budget is spent.
    func chargeParse(_ n: Int) throws {
        parsedTotal = parsedTotal.addingReportingOverflow(max(n, 0)).overflow ? Int.max : parsedTotal + max(n, 0)
        let input = bytes.count.addingReportingOverflow(decodedTotal)
        let scaled = input.partialValue.multipliedReportingOverflow(by: max(limits.parseBytesPerByte, 0))
        let sum = scaled.partialValue.addingReportingOverflow(max(limits.parseBytesBase, 0))
        let budget = input.overflow || scaled.overflow || sum.overflow ? Int.max : sum.partialValue
        guard parsedTotal <= budget else {
            throw PDFError.limitExceeded("more than \(budget) bytes parsed (\(limits.parseBytesPerByte) per byte of input)")
        }
    }

    /// `lx.parseObject()`, charging what the lexer looked at (also when it throws).
    private func parseCharged(_ lx: inout PDFLexer) throws -> PDFObject {
        let before = lx.scanned
        do {
            let o = try lx.parseObject()
            try chargeParse(lx.scanned - before)
            return o
        } catch {
            try chargeParse(lx.scanned - before)
            throw error
        }
    }

    // MARK: - Cross-reference data

    private func loadXref() throws {
        guard let start = startxref(), start < bytes.count else { throw PDFError.notAPDF }
        var next: Int? = start
        var visited = Set<Int>()
        var first = true
        while let offset = next {
            guard visited.insert(offset).inserted else { break }   // a /Prev loop: the chain ends
            guard visited.count <= limits.maxXrefSections else {
                throw PDFError.limitExceeded("more than \(limits.maxXrefSections) cross-reference sections")
            }
            let (entries, dict) = try readSection(at: offset)
            merge(entries)
            if let stm = dict["XRefStm"]?.intValue, stm >= 0, stm < bytes.count, visited.insert(stm).inserted {
                if let (more, _) = try? readSection(at: stm) { merge(more) }   // hybrid file
            }
            if first {
                trailer = dict
                first = false
            } else {
                for (k, v) in dict.entries where trailer[k] == nil && k != "Prev" && k != "XRefStm" { trailer[k] = v }
            }
            if let prev = dict["Prev"]?.intValue, prev >= 0, prev < bytes.count { next = prev } else { next = nil }
        }
        guard trailer["Root"] != nil else { throw PDFError.notAPDF }
    }

    /// Newer sections are read first, so existing entries win.
    private func merge(_ entries: [(Int, XrefEntry)]) {
        for (num, e) in entries where xref[num] == nil { xref[num] = e }
    }

    private func readSection(at offset: Int) throws -> ([(Int, XrefEntry)], PDFDict) {
        var lx = PDFLexer(bytes, at: offset, maxDepth: limits.maxDepth)
        if lx.keyword("xref") {
            do {
                let r = try readTable(&lx)
                try chargeParse(lx.scanned)
                return r
            } catch {
                try chargeParse(lx.scanned)
                throw error
            }
        }
        try chargeParse(lx.scanned)
        guard case .stream(let s) = try parseIndirectObject(at: offset, expecting: nil),
              s.dict["Type"]?.nameValue == "XRef" else {
            throw PDFError.syntax("no cross-reference section", offset: offset)
        }
        return (try readXrefStream(s), s.dict)
    }

    private func readTable(_ lx: inout PDFLexer) throws -> ([(Int, XrefEntry)], PDFDict) {
        var entries: [(Int, XrefEntry)] = []
        while !lx.keyword("trailer") {
            guard let start = lx.unsignedInt(), let count = lx.unsignedInt() else { throw lx.error("bad xref subsection") }
            // An entry takes at least 6 bytes ("0 0 n "): a count beyond that is a lie.
            guard count <= (bytes.count - lx.pos) / 6 + 1 else { throw lx.error("xref count beyond the file") }
            guard start <= limits.maxObjects, count <= limits.maxObjects - start else {
                throw PDFError.limitExceeded("more than \(limits.maxObjects) objects")
            }
            for k in 0..<count {
                guard let off = lx.unsignedInt(), lx.unsignedInt() != nil else { throw lx.error("bad xref entry") }
                lx.skipWhitespace()
                let kind = lx.token()
                if kind.elementsEqual("n".utf8) {
                    entries.append((start + k, off == 0 ? .free : .offset(off)))
                } else if kind.elementsEqual("f".utf8) {
                    entries.append((start + k, .free))
                } else {
                    throw lx.error("bad xref entry type")
                }
            }
        }
        guard case .dict(let d) = try lx.parseObject() else { throw lx.error("trailer is not a dictionary") }
        return (entries, d)
    }

    private func readXrefStream(_ s: PDFStream) throws -> [(Int, XrefEntry)] {
        guard let w = s.dict["W"]?.arrayValue?.compactMap(\.intValue), w.count == 3,
              w.allSatisfy({ (0...8).contains($0) }), w.reduce(0, +) > 0 else {
            throw PDFError.syntax("bad /W in cross-reference stream", offset: 0)
        }
        let size = s.dict["Size"]?.intValue ?? 0
        guard size >= 0, size <= limits.maxObjects else {
            throw PDFError.limitExceeded("more than \(limits.maxObjects) objects")
        }
        var index: [Int] = [0, size]
        if let ix = s.dict["Index"]?.arrayValue {
            index = ix.compactMap(\.intValue)
            guard index.count % 2 == 0 else { throw PDFError.syntax("bad /Index", offset: 0) }
        }
        let data = try decodedData(of: s)
        let entrySize = w.reduce(0, +)
        var entries: [(Int, XrefEntry)] = []
        var p = 0
        func field(_ width: Int) -> Int? {
            var v: UInt64 = 0
            for _ in 0..<width { v = v << 8 | UInt64(data[p]); p += 1 }
            return v <= UInt64(Int.max) ? Int(v) : nil
        }
        var i = 0
        while i + 1 < index.count {
            let start = index[i], count = index[i + 1]
            i += 2
            guard start >= 0, count >= 0, start <= limits.maxObjects, count <= limits.maxObjects - start else {
                throw PDFError.limitExceeded("more than \(limits.maxObjects) objects")
            }
            for k in 0..<count {
                guard p + entrySize <= data.count else { return entries }
                let type = w[0] == 0 ? 1 : field(w[0])
                let f2 = field(w[1]) ?? -1
                let f3 = field(w[2]) ?? -1
                switch type {
                case 0: entries.append((start + k, .free))
                case 1: entries.append((start + k, f2 > 0 ? .offset(f2) : .free))
                case 2: if f2 >= 0, f3 >= 0 { entries.append((start + k, .compressed(stream: f2, index: f3))) }
                default: break   // reserved types are null references
                }
            }
        }
        return entries
    }

    // MARK: - Repair

    /// Rebuilds the cross-reference table by scanning for `n g obj` and
    /// `trailer`, and registers the members of every object stream found.
    func repair() throws {
        guard !repaired else { return }
        repaired = true
        cache = [:]
        objectStreams = [:]
        pages = nil
        var table: [Int: XrefEntry] = [:]
        var order: [Int] = []
        var trailers: [PDFDict] = []
        let b = bytes
        let obj = Array("obj".utf8), trl = Array("trailer".utf8)
        var i = 1
        while i + 3 <= b.count {
            if b[i] == 0x6F, b[i + 1] == 0x62, b[i + 2] == 0x6A, PDFLexer.isWhite(b[i - 1]),
               i + 3 == b.count || !PDFLexer.isRegular(b[i + 3]), let (num, start) = objectHeader(endingBefore: i) {
                guard num < limits.maxObjects else {
                    throw PDFError.limitExceeded("object number beyond \(limits.maxObjects)")
                }
                if table[num] == nil { order.append(num) }
                table[num] = .offset(start)
                i += obj.count
                continue
            }
            if b[i] == 0x74, i + trl.count <= b.count, Array(b[i..<(i + trl.count)]) == trl {
                var lx = PDFLexer(b, at: i + trl.count, maxDepth: limits.maxDepth)
                let parsed = try? lx.parseObject()
                try chargeParse(lx.scanned)
                if case .dict(let d)? = parsed { trailers.append(d) }
                // Resume where the parse stopped, whether it succeeded or not:
                // the bytes it read are never scanned for a trailer again.
                i = max(i + trl.count, lx.pos)
                continue
            }
            i += 1
        }
        xref = table
        // Objects stored in object streams, unless a plain copy exists.
        var compressed: [Int: XrefEntry] = [:]
        for num in order.sorted() {
            guard case .stream(let s)? = try? object(num), s.dict["Type"]?.nameValue == "ObjStm",
                  let os = try? objectStream(num) else { continue }
            for (k, e) in os.entries.enumerated() where e.num < limits.maxObjects && table[e.num] == nil {
                compressed[e.num] = .compressed(stream: num, index: k)
            }
        }
        for (num, e) in compressed { xref[num] = e }
        guard xref.count <= limits.maxObjects else { throw PDFError.limitExceeded("more than \(limits.maxObjects) objects") }

        // Trailers: cross-reference stream dictionaries, then `trailer` keywords, later ones winning.
        var merged = PDFDict()
        for num in order {
            if case .stream(let s)? = try? object(num), s.dict["Type"]?.nameValue == "XRef" {
                for (k, v) in s.dict.entries { merged[k] = v }
            }
        }
        for t in trailers { for (k, v) in t.entries { merged[k] = v } }
        for k: PDFName in ["Prev", "XRefStm", "Type", "W", "Index", "Size", "Length", "Filter", "DecodeParms"] {
            merged[k] = nil
        }
        if let root = merged["Root"], case .dict? = try? resolve(root) {
            trailer = merged
            return
        }
        // No usable trailer (or one naming a missing catalog): find the catalog itself.
        for num in order.reversed() {
            if let d = (try? object(num))?.dictValue, d["Type"]?.nameValue == "Catalog" {
                merged["Root"] = .ref(PDFRef(num))
                trailer = merged
                return
            }
        }
        throw PDFError.notAPDF
    }

    /// For `obj` at `objAt`: the object number and the offset of the header
    /// `num gen obj` when the bytes before it are one.
    private func objectHeader(endingBefore objAt: Int) -> (Int, Int)? {
        let b = bytes
        var j = objAt - 1
        while j >= 0, PDFLexer.isWhite(b[j]) { j -= 1 }
        var genDigits = 0
        while j >= 0, PDFLexer.isDigit(b[j]) { j -= 1; genDigits += 1 }
        guard (1...5).contains(genDigits), j >= 0, PDFLexer.isWhite(b[j]) else { return nil }
        while j >= 0, PDFLexer.isWhite(b[j]) { j -= 1 }
        var numDigits = 0
        while j >= 0, PDFLexer.isDigit(b[j]) { j -= 1; numDigits += 1 }
        guard (1...10).contains(numDigits), j < 0 || !PDFLexer.isRegular(b[j]) else { return nil }
        var num = 0
        for k in (j + 1)...(j + numDigits) { num = num * 10 + Int(b[k] - 0x30) }
        return (num, j + 1)
    }

    // MARK: - Objects

    /// The object `num` (`.null` when it does not exist). Indirect values are
    /// returned as stored; use `resolve` to follow references.
    public func object(_ num: Int) throws -> PDFObject {
        if let c = cache[num] { return c }
        guard let entry = xref[num] else { return .null }
        guard resolving.insert(num).inserted else { throw PDFError.cycle("object \(num) refers to itself") }
        var result: PDFObject
        do {
            defer { resolving.remove(num) }
            switch entry {
            case .free:
                result = .null
            case .offset(let off):
                result = try parseIndirectObject(at: off, expecting: num)
            case .compressed(let stm, let index):
                result = try objectFromStream(stm, index: index, num: num)
            }
        } catch let e as PDFError {
            switch e {
            case .limitExceeded, .cycle, .encrypted: throw e
            default:
                // The table points at something else: rebuild once and retry.
                guard !repaired, resolving.isEmpty else { throw e }
                try repair()
                return try object(num)
            }
        }
        cache[num] = result
        return result
    }

    /// Follows references (at most `limits.maxReferenceChain` hops).
    public func resolve(_ o: PDFObject) throws -> PDFObject {
        var cur = o
        var hops = 0
        while case .ref(let r) = cur {
            hops += 1
            guard hops <= limits.maxReferenceChain else { throw PDFError.cycle("reference chain at \(r)") }
            cur = try object(r.num)
        }
        return cur
    }

    /// `resolve` of a dictionary entry, nil when absent or null.
    func value(_ d: PDFDict, _ key: PDFName) throws -> PDFObject? {
        guard let v = d[key] else { return nil }
        let r = try resolve(v)
        return r == .null ? nil : r
    }

    func parseIndirectObject(at offset: Int, expecting num: Int?) throws -> PDFObject {
        guard offset >= 0, offset < bytes.count else { throw PDFError.syntax("offset beyond the file", offset: offset) }
        var lx = PDFLexer(bytes, at: offset, maxDepth: limits.maxDepth)
        guard let n = lx.unsignedInt(), lx.unsignedInt() != nil, lx.keyword("obj") else {
            try chargeParse(lx.scanned)
            throw PDFError.syntax("no object header", offset: offset)
        }
        if let num, n != num {
            try chargeParse(lx.scanned)
            throw PDFError.syntax("object \(n) where \(num) was expected", offset: offset)
        }
        try chargeParse(lx.scanned)
        let o = try parseCharged(&lx)
        guard case .dict(let d) = o else { return o }
        let save = lx.pos, seen = lx.scanned
        let found = lx.keyword("stream")
        try chargeParse(lx.scanned - seen)
        guard found else { lx.rewind(to: save); return o }
        var start = lx.pos
        if start < bytes.count, bytes[start] == 13 { start += 1 }
        if start < bytes.count, bytes[start] == 10 { start += 1 }
        var length: Int?
        if let l = d["Length"] {
            if case .int(let v) = l { length = v } else if case .ref = l { length = (try? resolve(l))?.intValue }
        }
        if let len = length, len >= 0, len <= bytes.count - start {
            var after = PDFLexer(bytes, at: start + len, maxDepth: limits.maxDepth)
            let found = after.keyword("endstream")
            try chargeParse(after.scanned)
            if found {
                return .stream(PDFStream(dict: d, raw: Data(bytes[start..<(start + len)])))
            }
        }
        // /Length missing or wrong: the data ends at the next `endstream`.
        guard var end = nextEndstream(from: start) else { throw PDFError.syntax("missing endstream", offset: start) }
        if end > start, bytes[end - 1] == 10 { end -= 1 }
        if end > start, bytes[end - 1] == 13 { end -= 1 }
        return .stream(PDFStream(dict: d, raw: Data(bytes[start..<end])))
    }

    /// The first `endstream` at or after `pos` (positions are found once, in
    /// one pass, so many streams with bad lengths cost O(n log n), not O(n²)).
    private func nextEndstream(from pos: Int) -> Int? {
        if endstreams == nil {
            let key = Array("endstream".utf8)
            var found: [Int] = []
            var i = 0
            while i + key.count <= bytes.count {
                if bytes[i] == 0x65, bytes[i + 1] == 0x6E, Array(bytes[i..<(i + key.count)]) == key {
                    found.append(i)
                    i += key.count
                } else {
                    i += 1
                }
            }
            endstreams = found
        }
        guard let list = endstreams else { return nil }
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid] < pos { lo = mid + 1 } else { hi = mid }
        }
        return lo < list.count ? list[lo] : nil
    }

    func objectStream(_ num: Int) throws -> ObjectStream {
        if let s = objectStreams[num] { return s }
        guard case .offset? = xref[num] else { throw PDFError.syntax("object stream \(num) is not a plain object", offset: 0) }
        guard case .stream(let s) = try object(num) else { throw PDFError.syntax("object stream \(num) is not a stream", offset: 0) }
        guard let n = s.dict["N"]?.intValue, let first = s.dict["First"]?.intValue, n >= 0, first >= 0 else {
            throw PDFError.syntax("bad object stream \(num)", offset: 0)
        }
        let data = try decodedData(of: s)
        var lx = PDFLexer(data, at: 0, maxDepth: limits.maxDepth)
        var entries: [(num: Int, offset: Int)] = []
        for _ in 0..<min(n, data.count / 2 + 1) {
            guard let on = lx.unsignedInt(), let off = lx.unsignedInt() else { break }
            entries.append((on, off))
        }
        try chargeParse(lx.scanned)
        let os = ObjectStream(data: data, first: first, entries: entries)
        objectStreams[num] = os
        return os
    }

    private func objectFromStream(_ stm: Int, index: Int, num: Int) throws -> PDFObject {
        let os = try objectStream(stm)
        var entry: (num: Int, offset: Int)?
        if index < os.entries.count, os.entries[index].num == num { entry = os.entries[index] }
        if entry == nil, let offset = os.byNumber[num] { entry = (num, offset) }
        guard let e = entry else { return .null }
        let (p, overflow) = os.first.addingReportingOverflow(e.offset)
        guard !overflow, p < os.data.count else { throw PDFError.syntax("object \(num) beyond its object stream", offset: 0) }
        var lx = PDFLexer(os.data, at: p, maxDepth: limits.maxDepth)
        return try parseCharged(&lx)
    }

    // MARK: - Streams

    /// The stream's filters and their parameters.
    func filters(of s: PDFStream) throws -> [(name: PDFName, parms: PDFDict?)] {
        var names: [PDFName] = []
        switch try value(s.dict, "Filter") {
        case .name(let n)?: names = [n]
        case .array(let a)?:
            guard a.count <= limits.maxFilters else { throw PDFError.limitExceeded("more than \(limits.maxFilters) filters") }
            for f in a {
                guard case .name(let n) = try resolve(f) else { throw PDFError.syntax("bad /Filter", offset: 0) }
                names.append(n)
            }
        case nil: return []
        default: throw PDFError.syntax("bad /Filter", offset: 0)
        }
        var parms: [PDFDict?] = []
        switch try value(s.dict, "DecodeParms") {
        case .dict(let d)?: parms = [d]
        case .array(let a)?: parms = try a.prefix(names.count).map { try resolve($0).dictValue }
        default: break
        }
        return names.enumerated().map { ($1, $0 < parms.count ? parms[$0] : nil) }
    }

    /// The stream's decoded bytes.
    ///
    /// - Parameter allowed: when given, a filter outside it throws
    ///   `unsupportedFilter` instead of being decoded.
    /// - Throws: `limitExceeded` beyond `maxDecodedStreamBytes`, or when this
    ///   file has decoded `maxTotalDecodedBytes` in all.
    public func decodedData(of s: PDFStream, allowed: Set<PDFName>? = nil) throws -> [UInt8] {
        let fs = try filters(of: s)
        if let allowed {
            for f in fs where !allowed.contains(PDFFilters.abbreviations[f.name] ?? f.name) {
                throw PDFError.unsupportedFilter(String(decoding: f.name.bytes, as: UTF8.self))
            }
        }
        let budget = limits.maxTotalDecodedBytes - decodedTotal
        guard budget > 0 else { throw PDFError.limitExceeded("more than \(limits.maxTotalDecodedBytes) bytes decoded") }
        let out = try PDFFilters.decode([UInt8](s.raw), filters: fs, maxOutput: min(limits.maxDecodedStreamBytes, budget))
        decodedTotal += out.count
        return out
    }

    // MARK: - Pages

    /// The pages in page-tree order (format.md §8.2.6 `pageIndex`).
    func pageNodes() throws -> [PageNode] {
        if let pages { return pages }
        guard let rootRef = trailer["Root"], let root = try resolve(rootRef).dictValue else { throw PDFError.notAPDF }
        guard let top = root["Pages"] else { throw PDFError.badPageTree("no /Pages") }
        var result: [PageNode] = []
        var visited = Set<Int>()
        var stack: [(PDFObject, PageNode, Int)] = [(top, PageNode(dict: PDFDict()), 0)]
        while let (o, inherited, depth) = stack.popLast() {
            guard depth <= limits.maxDepth else { throw PDFError.limitExceeded("page tree deeper than \(limits.maxDepth)") }
            if case .ref(let r) = o {
                guard visited.insert(r.num).inserted else { throw PDFError.cycle("page tree node \(r)") }
            }
            guard let d = try resolve(o).dictValue else { continue }
            var node = inherited
            node.dict = d
            if let v = d["Resources"] { node.resources = v }
            if let v = d["MediaBox"] { node.mediaBox = v }
            if let v = d["CropBox"] { node.cropBox = v }
            if let v = d["Rotate"] { node.rotate = v }
            node.group = d["Group"]
            let type = d["Type"]?.nameValue
            if type != "Page", case .array(let kids)? = try value(d, "Kids") {
                guard result.count + stack.count + kids.count <= limits.maxObjects else {
                    throw PDFError.limitExceeded("more than \(limits.maxObjects) pages")
                }
                for k in kids.reversed() { stack.append((k, node, depth + 1)) }
            } else if type == "Page" || (type == nil && d["Kids"] == nil) {
                result.append(node)
            }
        }
        pages = result
        return result
    }

    /// Number of pages.
    public var pageCount: Int { (try? pageNodes().count) ?? 0 }

    /// The geometry of page `index`.
    public func page(_ index: Int) throws -> PDFPageInfo {
        let node = try pageNode(index)
        let media = try box(node.mediaBox) ?? PDFRect(0, 0, 612, 792)
        let crop = try box(node.cropBox) ?? media
        guard let visible = crop.intersection(media) else { throw PDFError.invalidPageBox }
        var rotation = 0
        if let r = node.rotate, let v = try resolve(r).number, v.isFinite, abs(v) < 1e9 {
            let n = ((Int(v) % 360) + 360) % 360
            rotation = n % 90 == 0 ? n : 0
        }
        return PDFPageInfo(index: index, mediaBox: media, cropBox: crop, visibleBox: visible, rotation: rotation)
    }

    func pageNode(_ index: Int) throws -> PageNode {
        let nodes = try pageNodes()
        guard index >= 0, index < nodes.count else {
            throw PDFError.badPageTree("page \(index + 1) of \(nodes.count)")
        }
        return nodes[index]
    }

    /// A box array `[x0 y0 x1 y1]`; nil when absent or invalid.
    private func box(_ o: PDFObject?) throws -> PDFRect? {
        guard let o, case .array(let a) = try resolve(o), a.count == 4 else { return nil }
        var v: [Double] = []
        for x in a {
            guard let n = try resolve(x).number, n.isFinite, abs(n) <= 1e7 else { return nil }
            v.append(n)
        }
        let r = PDFRect(v[0], v[1], v[2], v[3])
        return r.width > 0 && r.height > 0 ? r : nil
    }

    /// The page's content streams, decoded and joined with newlines.
    ///
    /// - Throws: `unsupportedFilter` for a content stream in a filter other
    ///   than `PDFFilters.decodable`; `limitExceeded` beyond
    ///   `maxDecodedStreamBytes` in all.
    public func pageContents(_ index: Int) throws -> [UInt8] {
        let node = try pageNode(index)
        var streams: [PDFStream] = []
        switch try value(node.dict, "Contents") {
        case .stream(let s)?: streams = [s]
        case .array(let a)?:
            for x in a {
                switch try resolve(x) {
                case .stream(let s): streams.append(s)
                case .null: continue
                default: throw PDFError.badPageTree("page contents are not streams")
                }
            }
        case nil: break
        default: throw PDFError.badPageTree("page contents are not streams")
        }
        var out: [UInt8] = []
        for (i, s) in streams.enumerated() {
            if i > 0 { out.append(10) }
            out += try decodedData(of: s, allowed: PDFFilters.decodable)
            guard out.count <= limits.maxDecodedStreamBytes else {
                throw PDFError.limitExceeded("page contents larger than \(limits.maxDecodedStreamBytes) bytes")
            }
        }
        return out
    }
}
