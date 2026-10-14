import Foundation

/// Copies pages of a `PDFFile` into another PDF as Form XObjects
/// (`docs/attachments.md` §10, "Copying a page as a form").
///
/// The page's content streams are decoded, joined with newlines and
/// re-compressed with Flate; its (inherited) `/Resources` and `/Group` are
/// deep-copied with every reachable indirect object renumbered by `allocate`.
/// Each source object is copied once per copier, however many pages use it,
/// so one copier per source PDF per export shares resources between pages.
/// Fonts, images and other streams keep their bytes and filters. References
/// to pages, page-tree nodes or the catalog become `null`, so a resource
/// cannot drag the rest of the document along. Annotations, structure,
/// metadata and thumbnails are page entries and are never copied.
///
/// Work and output are bounded by the source: at most one copy of each
/// source object, plus one decoded content stream per page.
public final class PDFFormCopier {
    /// An object to write into the output: its number and its body (what
    /// goes between `n 0 obj` and `endobj`).
    public struct OutputObject: Sendable {
        public var number: Int
        public var body: [UInt8]
    }

    let file: PDFFile
    let allocate: () -> Int
    private var map: [Int: Int] = [:]
    private var queue: [Int] = []
    private var forms: [Int: Int] = [:]
    private var pending: [OutputObject] = []

    /// - Parameters:
    ///   - file: the source PDF.
    ///   - allocate: returns a fresh object number of the output on each call.
    public init(file: PDFFile, allocate: @escaping () -> Int) {
        self.file = file
        self.allocate = allocate
    }

    /// The output object number of the form for page `index`, copying it
    /// (and whatever it needs that is not copied yet) on first use. Collect
    /// the objects to write with `takeObjects()`.
    ///
    /// - Throws: `PDFError` when the page is out of range or its contents
    ///   cannot be decoded (`unsupportedFilter` for a filter outside
    ///   `PDFFilters.decodable`, `limitExceeded`, …). Nothing is added to the
    ///   output for a page that fails.
    public func formObject(page index: Int) throws -> Int {
        if let f = forms[index] { return f }
        let info = try file.page(index)
        let node = try file.pageNode(index)
        let content = try PDFFilters.deflate(try file.pageContents(index))
        let saved = (map, queue, pending)
        do {
            var d = PDFDict()
            d["Type"] = .name("XObject")
            d["Subtype"] = .name("Form")
            d["FormType"] = .int(1)
            let v = info.visibleBox
            d["BBox"] = .array([.real(v.x0), .real(v.y0), .real(v.x1), .real(v.y1)])
            if let r = node.resources, let t = try translate(r), t != .null { d["Resources"] = t }
            else { d["Resources"] = .dict(PDFDict()) }
            if let g = node.group, let t = try translate(g), t != .null { d["Group"] = t }
            d["Filter"] = .name("FlateDecode")
            d["Length"] = .int(content.count)
            let number = allocate()
            pending.append(OutputObject(number: number, body: PDFSerializer.stream(dict: d, raw: content)))
            try drain()
            forms[index] = number
            return number
        } catch {
            (map, queue, pending) = saved
            throw error
        }
    }

    /// The objects copied since the last call, to write into the output.
    public func takeObjects() -> [OutputObject] {
        defer { pending = [] }
        return pending
    }

    private func drain() throws {
        while let src = queue.popLast() {
            guard let dst = map[src] else { continue }
            let o = (try? file.object(src)) ?? .null
            let body: [UInt8]
            if case .stream(var s) = o {
                s.dict["Length"] = nil
                guard case .dict(var d)? = try translate(.dict(s.dict)) else { continue }
                d["Length"] = .int(s.raw.count)
                body = PDFSerializer.stream(dict: d, raw: [UInt8](s.raw))
            } else {
                body = PDFSerializer.bytes(try translate(o) ?? .null)
            }
            pending.append(OutputObject(number: dst, body: body))
        }
    }

    /// `o` with every reference renumbered (and queued for copying).
    private func translate(_ o: PDFObject) throws -> PDFObject? {
        switch o {
        case .ref(let r): return try translateRef(r)
        case .array(let a): return .array(try a.map { try translate($0) ?? .null })
        case .dict(let d):
            var out = PDFDict()
            for (k, v) in d.entries {
                if let t = try translate(v), t != .null { out[k] = t }
            }
            return .dict(out)
        case .stream:
            return .null   // a direct stream cannot occur inside another object
        default:
            return o
        }
    }

    private func translateRef(_ r: PDFRef) throws -> PDFObject {
        if let m = map[r.num] { return .ref(PDFRef(m)) }
        let target: PDFObject
        do { target = try file.resolve(.ref(r)) } catch let e as PDFError {
            if case .limitExceeded = e { throw e }
            return .null   // a broken resource is left out, as viewers do
        }
        if target == .null { return .null }
        if let t = target.dictValue?["Type"]?.nameValue, t == "Page" || t == "Pages" || t == "Catalog" { return .null }
        let n = allocate()
        map[r.num] = n
        queue.append(r.num)
        return .ref(PDFRef(n))
    }
}

/// Writes PDF objects as bytes.
public enum PDFSerializer {
    /// The object's bytes (a direct stream is written as `null`).
    public static func bytes(_ o: PDFObject) -> [UInt8] {
        var out: [UInt8] = []
        write(o, into: &out)
        return out
    }

    /// A stream object's body: dictionary, `stream`, the data, `endstream`.
    public static func stream(dict: PDFDict, raw: [UInt8]) -> [UInt8] {
        var out = bytes(.dict(dict))
        out += Array("\nstream\n".utf8)
        out += raw
        out += Array("\nendstream".utf8)
        return out
    }

    static func write(_ o: PDFObject, into out: inout [UInt8]) {
        switch o {
        case .null, .stream: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let i): out += Array(String(i).utf8)
        case .real(let r): out += Array(real(r).utf8)
        case .string(let s):
            out.append(0x3C)
            let hex = Array("0123456789ABCDEF".utf8)
            for c in s { out.append(hex[Int(c >> 4)]); out.append(hex[Int(c & 15)]) }
            out.append(0x3E)
        case .name(let n): name(n, into: &out)
        case .array(let a):
            out.append(0x5B)
            for (i, x) in a.enumerated() {
                if i > 0 { out.append(0x20) }
                write(x, into: &out)
            }
            out.append(0x5D)
        case .dict(let d):
            out += [0x3C, 0x3C]
            for k in d.entries.keys.sorted() {
                guard let v = d.entries[k] else { continue }
                out.append(0x20)
                name(k, into: &out)
                out.append(0x20)
                write(v, into: &out)
            }
            out += [0x20, 0x3E, 0x3E]
        case .ref(let r): out += Array("\(r.num) \(r.gen) R".utf8)
        }
    }

    static func name(_ n: PDFName, into out: inout [UInt8]) {
        out.append(0x2F)
        let hex = Array("0123456789ABCDEF".utf8)
        for c in n.bytes {
            if c < 0x21 || c > 0x7E || c == 0x23 || PDFLexer.isDelimiter(c) {
                out.append(0x23); out.append(hex[Int(c >> 4)]); out.append(hex[Int(c & 15)])
            } else {
                out.append(c)
            }
        }
    }

    /// A real without exponent, at most 6 decimals.
    static func real(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}
