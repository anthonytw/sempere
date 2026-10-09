import Foundation
import SempereImport
import Sempere

/// Reader for Notability's newer `.ntb` files (`docs/import-notability.md`,
/// ".ntb format"): a zip of `version`, `manifest.json`, `thumbnail.png` and
/// `noteBundle`, a FlatBuffers buffer holding the note as a list of records.
/// The schema is not published; everything here was decoded without it and
/// checked against the `.note` copies of the same notes. Only ink (strokes
/// and straight lines), the page geometry, the paper pattern, the title and
/// the creation date are read; there is no handwriting recognition in the
/// bundle, and PDFs and images live outside it.
public enum NotabilityBundle {
    /// Record types (`record.type`).
    enum RecordType: UInt8 {
        case document = 1
        case pdf = 2
        case stroke = 15
        case shape = 18
        case media = 22
        case erase = 25
    }

    /// Parses an `.ntb` package (already opened as a zip or directory).
    ///
    /// - Throws: `ImportError.package` when there is no `noteBundle` or it
    ///   is not a bundle this reader understands.
    public static func parse(package pkg: NotePackage) throws -> NotabilityNote {
        guard let path = pkg.paths.first(where: { $0 == "noteBundle" })
                ?? pkg.paths.first(where: { $0.hasSuffix("/noteBundle") && $0.split(separator: "/").count == 2 }) else {
            throw ImportError.package("no noteBundle in .ntb package")
        }
        var note = try parse(bundle: pkg.read(path))
        note.bundleFiles = attachmentFiles(pkg)
        let index = pkg.paths.first(where: { $0 == "ios/HandwritingIndex.fb" })
            ?? pkg.paths.first(where: { $0.hasSuffix("/ios/HandwritingIndex.fb") && $0.split(separator: "/").count == 3 })
        // Recognition is auxiliary: a malformed index loses the text, never the ink.
        if let index, let data = try? pkg.read(index),
           let pages = try? parseHandwritingIndex(data, inset: note.paper.insetX) {
            note.recognition = pages
        }
        return note
    }

    /// Notability's handwriting recognition in an `.ntb` (`ios/HandwritingIndex.fb`,
    /// FlatBuffers; `docs/import-notability.md`): root field 2 is a table whose
    /// field 0 lists one table per recognised page. A page table holds field 0,
    /// three words whose third is the 0-based page index (as in stroke
    /// records), field 1 the text, field 2 one 8-byte box per UTF-16 unit (four
    /// IEEE half floats, the `.note` `characterRects` encoding) and field 3 a
    /// 32-byte hash. Boxes are page coordinates; the origin `(-inset, 0)` maps
    /// them through `NotabilityImporter.recognition` exactly as the bundle's
    /// strokes are placed.
    ///
    /// - Throws: `ImportError.package` for a malformed buffer.
    static func parseHandwritingIndex(_ data: Data, inset: Double) throws -> [Int: NotabilityNote.RecognizedPage] {
        let fb = FlatBuffer(data)
        let root = try fb.root()
        guard let listField = try fb.field(root, 2) else { return [:] }
        let list = try fb.table(atRef: listField)
        guard let pagesField = try fb.field(list, 0) else { return [:] }
        var out: [Int: NotabilityNote.RecognizedPage] = [:]
        // Page tables can all reference one text and one box list: charge their bytes.
        var budget = Budget(limit: decodeBudgetFactor * data.count + 65_536)
        for page in try fb.tables(atVectorRef: pagesField) {
            guard let header = try fb.field(page, 0), let textField = try fb.field(page, 1) else { continue }
            let index = Int(try fb.u32(header + 8))
            let number = index + 1
            guard (1...NotabilityNote.maxRecognizedPage).contains(number), out[number] == nil else { continue }
            try budget.spend(try fb.vector(atRef: textField, elementSize: 1).count)
            let text = try fb.string(atRef: textField)
            var boxes: [Recognition.Box?] = []
            if let boxField = try fb.field(page, 2) {
                let (start, count) = try fb.vector(atRef: boxField, elementSize: 8)
                try budget.spend(8 * count)
                guard count <= text.utf16.count else {
                    throw ImportError.package(".ntb: more character boxes than characters on page \(number)")
                }
                boxes = NotabilityNote.halfRects(Data(fb.bytes[start..<(start + 8 * count)]))
                    .map { $0.flatMap { b in
                        [b.x, b.y, b.w, b.h].allSatisfy { abs($0) <= NotabilityNote.maxCoordinate } ? b : nil } }
            }
            out[number] = NotabilityNote.RecognizedPage(text: text, origin: NotabilityNote.Point(x: -inset, y: 0),
                                                        characterBoxes: boxes)
        }
        return out
    }

    /// How many bytes of geometry and erase lists one parse may decode, per
    /// byte of bundle. FlatBuffers references can point many records at one
    /// payload, so without a limit a small buffer could decode into
    /// gigabytes of points. A real bundle decodes each payload once (at most
    /// its own size); the factor leaves room for a writer that shares some.
    static let decodeBudgetFactor = 4

    /// Parses the bytes of a `noteBundle`.
    ///
    /// - Throws: `ImportError.package` when the bundle is malformed or
    ///   references its payloads so often that decoding would exceed
    ///   `decodeBudgetFactor` times its size.
    public static func parse(bundle data: Data) throws -> NotabilityNote {
        let fb = FlatBuffer(data)
        var budget = Budget(limit: decodeBudgetFactor * data.count + 65_536)
        let root = try fb.root()
        guard let recordsField = try fb.field(root, 6) else {
            throw ImportError.package(".ntb: no record list")
        }
        let records = try fb.tables(atVectorRef: recordsField)
        let createdMs = try fb.field(root, 4).map { try fb.i64($0) }

        var title: String?
        var page: (w: Double, h: Double)?
        var paperPattern: Int?
        var paperSpacing: Double?
        var lastEdit: Int64?
        var curves: [NotabilityNote.Curve] = []
        var lines: [NotabilityNote.Curve] = []
        var placed: [(curve: Int, page: Int)] = []   // stroke and line indices with their page
        var originX: [Float] = []   // per stroke, as stored
        var pdfs = 0, media = 0, unsupportedStrokes = 0, unsupportedShapes = 0, dashed = Set<Int>()
        var unsupportedKinds: [String: Int] = [:]
        var attachments: [NotabilityNote.BundleAttachment] = []

        // Erase records list the ids of the stroke and shape records they
        // remove (bundles written as a log, without a `.note` next to them;
        // bundles next to a `.note` are compacted and hold none).
        var erased = Set<UInt64>()
        for record in records {
            guard let tf = try fb.field(record, 4), try fb.u8(tf) == RecordType.erase.rawValue,
                  let pf = try fb.field(record, 5) else { continue }
            let payload = try fb.table(atRef: pf)
            guard let list = try fb.field(payload, 0) else { continue }
            let (start, count) = try fb.vector(atRef: list, elementSize: 8)
            try budget.spend(8 * count)
            for i in 0..<count { erased.insert(try fb.recordID(start + 8 * i)) }
        }
        var erasedCount = 0

        for record in records {
            if !erased.isEmpty, let idField = try fb.field(record, 0), erased.contains(try fb.recordID(idField)) {
                erasedCount += 1
                continue
            }
            if let t = try fb.field(record, 1) {
                let ms = try fb.i64(t)
                lastEdit = max(lastEdit ?? ms, ms)
            }
            guard let typeField = try fb.field(record, 4), let type = RecordType(rawValue: try fb.u8(typeField)) else {
                continue
            }
            guard let payloadField = try fb.field(record, 5) else { continue }
            let payload = try fb.table(atRef: payloadField)
            switch type {
            case .document:
                // Every record may point at one shared title: charge its bytes.
                try budget.spend(64)
                if let f = try fb.field(payload, 0), let s = try fb.field(fb.table(atRef: f), 0) {
                    try budget.spend(try fb.vector(atRef: s, elementSize: 1).count)
                    title = try fb.string(atRef: s)
                }
                if let f = try fb.field(payload, 1), let l = try fb.field(fb.table(atRef: f), 0) {
                    let layout = try fb.table(atRef: l)
                    if let size = try fb.field(layout, 3) {
                        page = (Double(try fb.f32(size)), Double(try fb.f32(size + 4)))
                    }
                    if let p = try fb.field(layout, 0) {
                        let paper = try fb.table(atRef: p)
                        paperPattern = try fb.field(paper, 0).map { Int(try fb.u8($0)) }
                        paperSpacing = try fb.field(paper, 1).map { Double(try fb.f32($0)) }
                    }
                }
            case .pdf:
                pdfs += 1
                try budget.spend(256)
                attachments.append(try attachment(fb, payload, kind: .pdf, index: attachments.count, budget: &budget))
            case .media:
                media += 1
                try budget.spend(256)
                attachments.append(try attachment(fb, payload, kind: .image, index: attachments.count, budget: &budget))
            case .erase:
                break
            case .stroke:
                guard let pieces = try stroke(fb, payload, budget: &budget) else {
                    unsupportedStrokes += 1
                    unsupportedKinds[try unsupportedStrokeKind(fb, payload), default: 0] += 1
                    continue
                }
                let isDashed = try fb.field(payload, 5).map { try fb.u8($0) != 0 } ?? false
                let pg = try pageIndex(fb, payload)
                let ox = try fb.field(payload, 1).map { try fb.f32($0) } ?? 0
                for curve in pieces {
                    if isDashed { dashed.insert(curves.count) }
                    placed.append((curves.count, pg))
                    originX.append(ox)
                    curves.append(curve)
                }
            case .shape:
                try budget.spend(64)
                guard let curve = try line(fb, payload) else {
                    unsupportedShapes += 1
                    unsupportedKinds[try unsupportedShapeKind(fb, payload), default: 0] += 1
                    continue
                }
                placed.append((-(lines.count + 1), try pageIndex(fb, payload)))
                lines.append(curve)
            }
        }

        let width = page.map(\.w).flatMap(NotabilityNote.plausibleWidth) ?? NotabilityNote.defaultWidth
        let pageHeight = page.flatMap { NotabilityNote.plausibleAspect($0.h / width).map { $0 * width } }
            ?? width * NotabilityNote.defaultPageAspect
        // Bundle coordinates are page coordinates (x from the page edge, y
        // from the page's top); `.note` coordinates are continuous with x = 0
        // at `insetX`. Not the bundle's recorded margin: newer letter-size
        // notes record 36 there while their points are still page coordinates.
        let inset = width * NotabilityNote.horizontalInsetFraction
        func place(_ c: inout NotabilityNote.Curve, page: Int) {
            let dy = Double(page) * pageHeight
            c.points = c.points.map { NotabilityNote.Point(x: $0.x - inset, y: $0.y + dy) }
        }
        var curvePages = [Int](repeating: 0, count: curves.count), linePages = [Int](repeating: 0, count: lines.count)
        for (index, pg) in placed {
            if index >= 0 { place(&curves[index], page: pg); curvePages[index] = pg } else {
                place(&lines[-index - 1], page: pg); linePages[-index - 1] = pg
            }
        }
        for i in dashed { curves[i].dashed = true }
        // A stroke that starts beyond the right page edge is stored with its
        // origin clamped to the edge (seen on notes whose ink overhangs the
        // page): its shape is right, its position is not recoverable.
        if let w = page?.w {
            for i in curves.indices where originX[i] == Float(w) { curves[i].originClamped = true }
        }
        let all = curves + lines
        guard all.allSatisfy({ $0.points.allSatisfy { abs($0.x) <= NotabilityNote.maxCoordinate
                && abs($0.y) <= NotabilityNote.maxCoordinate } }) else {
            throw ImportError.package(".ntb: coordinates beyond ±\(Int(NotabilityNote.maxCoordinate))")
        }

        let kind: PaperKind
        switch paperPattern {
        case 0?: kind = .ruled
        case 1?: kind = .dot
        case 2?: kind = .grid
        default: kind = .blank
        }
        let spacing = kind == .blank ? nil : paperSpacing.flatMap { $0.isFinite && $0 > 0 && $0 < width ? $0 : nil }
        // Dates the vault cannot store (beyond years 0001...9999) are dropped,
        // as for a `.note` (`NotabilityNote.writable`): the import would
        // otherwise trap turning them back into milliseconds.
        func date(_ ms: Int64?) -> Date? {
            ms.flatMap { NotabilityNote.writable(Date(timeIntervalSince1970: Double($0) / 1000)) }
        }
        let created = date(createdMs)
        var note = NotabilityNote(
            metadata: .init(name: title.map { $0.isEmpty ? "Untitled" : $0 } ?? "Untitled", created: created),
            paper: .init(width: width, pageHeight: pageHeight, kind: kind, spacing: spacing),
            curves: all, pdfCount: pdfs, mediaCount: media)
        note.sourceFormat = .ntb
        note.bundleModified = date(lastEdit)
        note.shapeCount = lines.count
        note.unsupportedShapes = unsupportedShapes
        note.unsupportedStrokes = unsupportedStrokes
        note.unsupportedKinds = unsupportedKinds
        note.clampedStrokes = curves.filter(\.originClamped).count
        note.erasedRecords = erasedCount
        note.bundleAttachments = attachments
        note.bundleCurvePages = curvePages + linePages
        return note
    }

    /// A PDF (2) or media (22) record, read without a schema
    /// (docs/import-notability.md ".ntb attachments"): the file it names is
    /// any string or byte vector reachable from its payload (three tables
    /// deep) that holds a 64-hex-digit name, or 32 bytes read as a SHA-256;
    /// its page is the third word of a 12-byte field 0 (as on strokes); its
    /// geometry the inline float structs: a 16-byte one is a rectangle
    /// `(x, y, w, h)`, 8-byte ones are points or sizes in field order.
    static func attachment(_ fb: FlatBuffer, _ payload: Int, kind: NotabilityNote.BundleAttachment.Kind,
                           index: Int, budget: inout Budget) throws -> NotabilityNote.BundleAttachment {
        var a = NotabilityNote.BundleAttachment(kind: kind, index: index)
        let fields = (try? fb.inlineFields(payload)) ?? []
        a.layout = fields.map { "\($0.index):\($0.size)" }.joined(separator: ",")
        // Records can share one payload: the walk's reads are charged to the parse's budget,
        // not only the flat 256 bytes per record.
        var visited = 0
        func names(in t: Int, depth: Int) throws {
            guard depth <= 3, visited < 64, let fs = try? fb.inlineFields(t) else { return }
            visited += 1
            try budget.spend(16 * fs.count)
            for f in fs where f.size == 4 {
                guard let target = try? fb.ref(f.position) else { continue }
                if let (start, count) = try? fb.vector(atRef: f.position, elementSize: 1), count > 0, count <= 1024 {
                    try budget.spend(count)
                    let bytes = Array(fb.bytes[start..<(start + count)])
                    if let name = BundleFileName.name(in: bytes), !a.fileNames.contains(name) { a.fileNames.append(name) }
                }
                if depth < 3, (try? fb.table(target)) != nil { try names(in: target, depth: depth + 1) }
            }
        }
        try names(in: payload, depth: 0)
        // Notability 16 stores the file's hash inline: field 0 starts with the 64 raw
        // bytes of the file's SHA-512 (files `assets/<128 hex>.<ext>`); its measured
        // size includes trailing padding (68 bytes).
        for f in fields {
            for n in BundleFileName.hashByteCounts where f.size >= n && f.size < n + 8 {
                try fb.check(f.position, n)
                try budget.spend(n)   // records can share a payload, as for the name walk above
                let raw = Array(fb.bytes[f.position..<(f.position + n)])
                if let name = BundleFileName.name(in: raw), !a.fileNames.contains(name) { a.fileNames.append(name) }
            }
        }
        for f in fields {
            switch f.size {
            case 12 where f.index == 0:
                let page = Int(try fb.u32(f.position + 8))
                if page < 100_000 { a.page = page }
            case 16:
                let v = try (0..<4).map { Double(try fb.f32(f.position + 4 * $0)) }
                if a.rect == nil, v.allSatisfy({ $0.isFinite && abs($0) <= NotabilityNote.maxCoordinate }) {
                    a.rect = (v[0], v[1], v[2], v[3])
                }
            case 8:
                let x = Double(try fb.f32(f.position)), y = Double(try fb.f32(f.position + 4))
                if x.isFinite, y.isFinite, abs(x) <= NotabilityNote.maxCoordinate, abs(y) <= NotabilityNote.maxCoordinate {
                    a.pairs.append((f.index, x, y))
                }
            default: break
            }
        }
        return a
    }

    /// The 0-based page of a stroke or shape record (third word of its field 0).
    static func pageIndex(_ fb: FlatBuffer, _ payload: Int) throws -> Int {
        guard let f = try fb.field(payload, 0) else { return 0 }
        let page = Int(try fb.u32(f + 8))
        guard page < 100_000 else { throw ImportError.package(".ntb: page index \(page)") }
        return page
    }

    /// A stroke record: origin (field 1), tool (4; 2 is the highlighter),
    /// colour RGBA (7), width (8) and the geometry bytes (9). One curve per
    /// piece (an erased gap splits a stroke into pieces, where a `.note` has
    /// separate curves). Nil for a geometry this reader does not decode.
    static func stroke(_ fb: FlatBuffer, _ p: Int, budget: inout Budget) throws -> [NotabilityNote.Curve]? {
        guard let o = try fb.field(p, 1), let g = try fb.field(p, 9) else { return nil }
        let x0 = Double(try fb.f32(o)), y0 = Double(try fb.f32(o + 4))
        try budget.spend(try fb.vector(atRef: g, elementSize: 1).count)
        let blob = try fb.bytes(atVectorRef: g)
        guard let pieces = geometry(blob, x0: x0, y0: y0) else { return nil }
        let color = try fb.field(p, 7).map { f in
            Color(r: try fb.u8(f), g: try fb.u8(f + 1), b: try fb.u8(f + 2), a: try fb.u8(f + 3))
        } ?? Color(r: 0, g: 0, b: 0, a: 255)
        let width = try fb.field(p, 8).map { Double(try fb.f32($0)) } ?? NotabilityNote.defaultCurveWidth
        let tool = try fb.field(p, 4).map { try fb.u8($0) } ?? 0
        guard width.isFinite, width > 0, width <= NotabilityNote.maxCoordinate else { return nil }
        return pieces.map { geo in
            NotabilityNote.Curve(points: geo.points, fractionalWidths: geo.fw, forces: geo.forces,
                                 altitudes: geo.altitudes, azimuths: geo.azimuths, width: width, color: color,
                                 style: tool == 2 ? NotabilityNote.highlighterStyle : NotabilityNote.penStyle)
        }
    }

    /// Decoded geometry of one piece of a stroke.
    struct Geometry {
        var points: [NotabilityNote.Point]
        var fw: [Double], forces: [Double], altitudes: [Double], azimuths: [Double]
    }

    /// The geometry bytes of a stroke: an 8-byte header (precision, node
    /// count as little-endian u16, kind 3, four zero bytes), for float32
    /// precision four more bytes, then the first node and one segment per
    /// further node. A node is the width multiplier and force (half floats)
    /// plus altitude and azimuth bytes. A segment is a flags byte, the two
    /// control points and the end point as (x, y) offsets from the stroke's
    /// origin (half floats, or float32 when the precision byte is 1), then its
    /// end node. Flags 3 (both control points omitted) is a jump: the end
    /// point starts a new piece, nothing is drawn in between (verified against
    /// the `.note` copies, which hold the pieces as separate curves). Other
    /// flags were never seen and are rejected.
    static func geometry(_ b: Data, x0: Double, y0: Double) -> [Geometry]? {
        let bytes = [UInt8](b)
        guard bytes.count >= 14, bytes[3] == 3, bytes[0] <= 1 else { return nil }
        let wide = bytes[0] == 1
        let n = Int(bytes[1]) | Int(bytes[2]) << 8
        guard n >= 1 else { return nil }
        var pos = wide ? 12 : 8
        func half(_ i: Int) -> Double {
            NotabilityNote.half(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
        }
        func float(_ i: Int) -> Double {
            Double(Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16
                         | UInt32(bytes[i + 3]) << 24))
        }
        var pieces: [Geometry] = []
        var g = Geometry(points: [NotabilityNote.Point(x: x0, y: y0)], fw: [], forces: [], altitudes: [], azimuths: [])
        func node() -> Bool {
            guard pos + 6 <= bytes.count else { return false }
            g.fw.append(half(pos)); g.forces.append(half(pos + 2))
            g.altitudes.append(Double(bytes[pos + 4]) / 255 * .pi / 2)
            g.azimuths.append(Double(bytes[pos + 5]) / 255 * 2 * .pi)
            pos += 6
            return true
        }
        func offset() -> NotabilityNote.Point? {
            let size = wide ? 8 : 4
            guard pos + size <= bytes.count else { return nil }
            let dx = wide ? float(pos) : half(pos), dy = wide ? float(pos + 4) : half(pos + 2)
            pos += size
            return NotabilityNote.Point(x: x0 + dx, y: y0 + dy)
        }
        guard node() else { return nil }
        for _ in 1..<max(n, 1) {
            guard pos < bytes.count else { return nil }
            let flags = bytes[pos]
            pos += 1
            switch flags {
            case 0:
                guard let c1 = offset(), let c2 = offset(), let end = offset() else { return nil }
                g.points += [c1, c2, end]
                guard node() else { return nil }
            case 3:
                guard let start = offset() else { return nil }
                pieces.append(g)
                g = Geometry(points: [start], fw: [], forces: [], altitudes: [], azimuths: [])
                guard node() else { return nil }
            default:
                return nil
            }
        }
        pieces.append(g)
        guard pos == bytes.count,
              pieces.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } && $0.fw.allSatisfy(\.isFinite) })
        else { return nil }
        return pieces
    }

    /// What kind of stroke record `stroke` could not decode, for the report (GA-27): the geometry
    /// header's kind byte, or why there is none. Names only, never content.
    static func unsupportedStrokeKind(_ fb: FlatBuffer, _ p: Int) throws -> String {
        guard let g = try fb.field(p, 9) else { return "stroke without geometry" }
        let blob = try fb.bytes(atVectorRef: g)
        guard blob.count >= 4 else { return "stroke with a short geometry" }
        let b = [UInt8](blob.prefix(4))
        return "stroke of geometry kind \(b[3])" + (b[3] == 3 ? " (undecodable: precision \(b[0]), flags or width)" : "")
    }

    /// The kind byte (record field 4) of a shape record `line` could not decode.
    static func unsupportedShapeKind(_ fb: FlatBuffer, _ p: Int) throws -> String {
        guard let k = try fb.field(p, 4) else { return "shape without a kind" }
        let kind = try fb.u8(k)
        return "shape of kind \(kind)" + (kind == 1 ? " (undecodable line)" : "")
    }

    /// A straight-line shape record: origin (field 1), kind 1 (field 4), the
    /// end point as an offset (field 5 → field 3), colour (9), width (10).
    static func line(_ fb: FlatBuffer, _ p: Int) throws -> NotabilityNote.Curve? {
        guard let k = try fb.field(p, 4), try fb.u8(k) == 1, let o = try fb.field(p, 1),
              let gf = try fb.field(p, 5) else { return nil }
        let geo = try fb.table(atRef: gf)
        guard let e = try fb.field(geo, 3) else { return nil }
        let a = NotabilityNote.Point(x: Double(try fb.f32(o)), y: Double(try fb.f32(o + 4)))
        let b = NotabilityNote.Point(x: a.x + Double(try fb.f32(e)), y: a.y + Double(try fb.f32(e + 4)))
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let color = try fb.field(p, 9).map { f in
            Color(r: try fb.u8(f), g: try fb.u8(f + 1), b: try fb.u8(f + 2), a: try fb.u8(f + 3))
        } ?? Color(r: 0, g: 0, b: 0, a: 255)
        let width = try fb.field(p, 10).map { Double(try fb.f32($0)) } ?? NotabilityNote.defaultCurveWidth
        guard width.isFinite, width > 0, width <= NotabilityNote.maxCoordinate else { return nil }
        return NotabilityNote.Curve(points: NotabilityShapes.line(a, b), fractionalWidths: [1, 1], width: width,
                                    color: color, style: NotabilityNote.penStyle)
    }
}

extension NotabilityBundle {
    /// Decoding work left for one parse (`decodeBudgetFactor`).
    struct Budget {
        var limit: Int
        var used = 0

        mutating func spend(_ n: Int) throws {
            used += n
            guard used <= limit else {
                throw ImportError.package(".ntb: decode budget exceeded (payloads referenced repeatedly)")
            }
        }
    }
}

/// Attachment file names in a `.ntb` bundle: `<64 hex digits>.<ext>`
/// (the file's SHA-256, then `pdf`, `jpeg`, `jpg`, `png`, `heic`, …).
enum BundleFileName {
    /// True for a bundle file name (no directory) that looks like an attachment:
    /// `<64 or 128 hex digits>.<ext>`.
    static func isAttachment(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, hashByteCounts.contains(parts[0].count / 2), parts[0].count % 2 == 0,
              parts[0].utf8.allSatisfy(isHex),
              (1...5).contains(parts[1].count), parts[1].utf8.allSatisfy({ isHex($0) || ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A })
        else { return false }
        return true
    }

    static func isHex(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66) }

    /// Hash lengths, in raw bytes, that name bundle files: 32 (SHA-256), and 64,
    /// what Notability 16 writes (files `assets/<128 hex digits>.<ext>`).
    static let hashByteCounts = [32, 64]

    /// A name found in a record's bytes: a whole `<hash>.<ext>` string, a
    /// string starting with 64 or 128 hex digits (the hash; the extension is
    /// matched against the bundle's files later), or 32 or 64 raw bytes
    /// (hex-encoded). Nil otherwise.
    static func name(in bytes: [UInt8]) -> String? {
        if hashByteCounts.contains(bytes.count), !bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return Hex.encode(bytes)
        }
        for digits in hashByteCounts.map({ $0 * 2 }).reversed()
        where bytes.count >= digits && bytes.prefix(digits).allSatisfy(isHex) {
            let text = String(decoding: bytes, as: UTF8.self)
            if isAttachment(text) { return text }
            return String(text.prefix(digits)).lowercased()
        }
        return nil
    }
}

/// A read-only, bounds-checked view of a FlatBuffers buffer, read without a
/// schema: tables by field index, references, vectors and strings.
struct FlatBuffer {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }

    func check(_ pos: Int, _ size: Int) throws {
        guard pos >= 0, size >= 0, pos <= bytes.count - size else {
            throw ImportError.package(".ntb: read of \(size) bytes at \(pos) beyond \(bytes.count)")
        }
    }

    func u8(_ p: Int) throws -> UInt8 { try check(p, 1); return bytes[p] }
    func u16(_ p: Int) throws -> Int { try check(p, 2); return Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
    func u32(_ p: Int) throws -> UInt32 {
        try check(p, 4)
        return UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
    }
    func i32(_ p: Int) throws -> Int { Int(Int32(bitPattern: try u32(p))) }
    func i64(_ p: Int) throws -> Int64 {
        Int64(bitPattern: UInt64(try u32(p)) | UInt64(try u32(p + 4)) << 32)
    }
    func f32(_ p: Int) throws -> Float { Float(bitPattern: try u32(p)) }
    /// A record id: the (u32, u32) struct at `p` as one 64-bit key.
    func recordID(_ p: Int) throws -> UInt64 { UInt64(try u32(p)) << 32 | UInt64(try u32(p + 4)) }

    /// The root table's position.
    func root() throws -> Int { try table(Int(try u32(0))) }

    /// Validates a table position (its vtable must lie inside the buffer).
    func table(_ t: Int) throws -> Int {
        let vt = t - (try i32(t))
        let size = try u16(vt)
        guard size >= 4, size % 2 == 0 else { throw ImportError.package(".ntb: bad vtable at \(vt)") }
        try check(vt, size)
        return t
    }

    /// The fields stored inline in the table at `t`, with their sizes inferred
    /// from the vtable: a field ends where the next one (by offset) starts,
    /// the last at the table's end. Without a schema this is all there is to
    /// tell a reference (4 bytes) from a struct (8, 12, 16 …).
    func inlineFields(_ t: Int) throws -> [(index: Int, position: Int, size: Int)] {
        let vt = t - (try i32(t))
        let vsize = try u16(vt)
        let tableSize = try u16(vt + 2)
        var offs: [(Int, Int)] = []
        var i = 0
        while 4 + 2 * i + 2 <= vsize, i < 64 {
            let off = try u16(vt + 4 + 2 * i)
            if off != 0, off < tableSize { offs.append((i, off)) }
            i += 1
        }
        offs.sort { $0.1 < $1.1 }
        var out: [(index: Int, position: Int, size: Int)] = []
        for (k, (index, off)) in offs.enumerated() {
            let end = k + 1 < offs.count ? offs[k + 1].1 : tableSize
            let size = end - off
            guard size > 0 else { continue }
            try check(t + off, size)
            out.append((index, t + off, size))
        }
        return out.sorted { $0.index < $1.index }
    }

    /// The absolute position of field `index` of the table at `t`, or nil when absent.
    func field(_ t: Int, _ index: Int) throws -> Int? {
        let vt = t - (try i32(t))
        let size = try u16(vt)
        let slot = 4 + 2 * index
        guard slot + 2 <= size else { return nil }
        let off = try u16(vt + slot)
        guard off != 0 else { return nil }
        let tableSize = try u16(vt + 2)
        guard off < tableSize else { throw ImportError.package(".ntb: field outside its table at \(t)") }
        return t + off
    }

    /// Follows the reference stored at `p` (an unsigned offset from `p`).
    func ref(_ p: Int) throws -> Int {
        let target = p + Int(try u32(p))
        try check(target, 4)
        return target
    }

    func table(atRef p: Int) throws -> Int { try table(ref(p)) }

    /// The element count and first-element position of the vector referenced at `p`.
    func vector(atRef p: Int, elementSize: Int) throws -> (start: Int, count: Int) {
        let v = try ref(p)
        let count = Int(try u32(v))
        guard count <= (bytes.count - v - 4) / max(elementSize, 1) else {
            throw ImportError.package(".ntb: vector of \(count) overruns the buffer")
        }
        return (v + 4, count)
    }

    func tables(atVectorRef p: Int) throws -> [Int] {
        let (start, count) = try vector(atRef: p, elementSize: 4)
        return try (0..<count).map { try table(atRef: start + 4 * $0) }
    }

    func bytes(atVectorRef p: Int) throws -> Data {
        let (start, count) = try vector(atRef: p, elementSize: 1)
        return Data(bytes[start..<(start + count)])
    }

    func string(atRef p: Int) throws -> String {
        let d = try bytes(atVectorRef: p)
        return String(decoding: d, as: UTF8.self)
    }
}
