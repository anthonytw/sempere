import Foundation

/// A TrueType font built from glyph outlines (docs/attachments.md §10, task
/// E2): how the app hands CoreText's glyphs to the export writers. The app
/// cannot embed its system fonts' own tables reliably: SF Pro and New York
/// are variable fonts whose `glyf` holds only the default instance (a bold
/// run would export regular outlines), and colour or bitmap fonts have no
/// outlines at all. CoreText gives every glyph's outline at the instance it
/// draws (`CTFontCreatePathForGlyph`), so the app builds one small font of
/// exactly the glyphs a text box uses, and the PDF, SVG and PNG writers
/// subset and draw it like any other font.
///
/// Glyph 0 is an empty `.notdef`; `glyphs[i]` becomes glyph `i + 1`. Cubic
/// segments (CFF outlines) are approximated by quadratic ones within
/// `cubicTolerance` font units; coordinates are rounded to whole units.
public enum OutlineFont {
    /// One glyph: its outline in font units (y up) and its advance.
    public struct Glyph: Hashable, Sendable {
        public var outline: [OutlineSegment]
        public var advance: Int

        public init(outline: [OutlineSegment], advance: Int) {
            self.outline = outline
            self.advance = advance
        }
    }

    /// Largest distance between a cubic segment and the quadratics replacing it, in font units.
    public static let cubicTolerance = 1.0
    /// Coordinates are clamped to this magnitude (so every delta fits in 16 bits).
    static let maxCoordinate = 16_383.0
    /// Points per glyph at most (a glyph beyond is left empty).
    static let maxPointsPerGlyph = 65_535

    /// The font, parsed back as an `OpenTypeFont`.
    public static func make(postScriptName: String, family: String, unitsPerEm: Int, ascender: Int, descender: Int,
                            weight: Int = 400, italic: Bool = false, glyphs: [Glyph]) throws -> OpenTypeFont {
        try OpenTypeFont(data: data(postScriptName: postScriptName, family: family, unitsPerEm: unitsPerEm,
                                    ascender: ascender, descender: descender, weight: weight, italic: italic, glyphs: glyphs))
    }

    /// The font file.
    public static func data(postScriptName: String, family: String, unitsPerEm: Int, ascender: Int, descender: Int,
                            weight: Int = 400, italic: Bool = false, glyphs: [Glyph]) throws -> [UInt8] {
        guard (16...16_384).contains(unitsPerEm) else { throw FontError.malformed("unitsPerEm") }
        guard glyphs.count < OpenTypeFont.maxGlyphs else { throw FontError.unsupported("more than 65 535 glyphs") }
        let all = [Glyph(outline: [], advance: 0)] + glyphs
        var glyf: [UInt8] = [], loca: [UInt8] = [], hmtx: [UInt8] = []
        var bbox: (Int, Int, Int, Int)?
        var maxPoints = 0, maxContours = 0, maxAdvance = 0
        for g in all {
            loca += be32(glyf.count)
            let contours = Self.contours(g.outline)
            let points = contours.reduce(0) { $0 + $1.count }
            var lsb = 0
            if !contours.isEmpty, points <= maxPointsPerGlyph {
                let encoded = encode(contours)
                glyf += encoded.bytes
                lsb = encoded.bbox.0
                bbox = bbox.map { (min($0.0, encoded.bbox.0), min($0.1, encoded.bbox.1), max($0.2, encoded.bbox.2), max($0.3, encoded.bbox.3)) }
                    ?? encoded.bbox
                maxPoints = max(maxPoints, points)
                maxContours = max(maxContours, contours.count)
                while glyf.count % 4 != 0 { glyf.append(0) }
            }
            let advance = min(max(g.advance, 0), 0xFFFF)
            maxAdvance = max(maxAdvance, advance)
            hmtx += be16(advance) + be16(lsb & 0xFFFF)
        }
        loca += be32(glyf.count)
        let (x0, y0, x1, y1) = bbox ?? (0, 0, 0, 0)
        let asc = clamp16(ascender), desc = clamp16(descender)
        let bold = weight >= 600
        var head = be32(0x0001_0000) + be32(0x0001_0000) + be32(0) + be32(0x5F0F_3CF5) + be16(3) + be16(unitsPerEm)
        head += [UInt8](repeating: 0, count: 16)
        head += be16(x0 & 0xFFFF) + be16(y0 & 0xFFFF) + be16(x1 & 0xFFFF) + be16(y1 & 0xFFFF)
        head += be16((bold ? 1 : 0) | (italic ? 2 : 0)) + be16(8) + be16(2) + be16(1) + be16(0)
        var hhea = be32(0x0001_0000) + be16(asc & 0xFFFF) + be16(desc & 0xFFFF) + be16(0) + be16(maxAdvance)
        hhea += be16(0) + be16(0) + be16(x1 & 0xFFFF) + be16(1) + be16(0) + be16(0)
        hhea += [UInt8](repeating: 0, count: 8) + be16(0) + be16(all.count)
        var maxp = be32(0x0001_0000) + be16(all.count) + be16(maxPoints) + be16(maxContours) + be16(0) + be16(0) + be16(2)
        maxp += [UInt8](repeating: 0, count: 16)
        var post = be32(0x0003_0000) + be32(italic ? (-12 << 16) & 0xFFFF_FFFF : 0)
        post += be16((-unitsPerEm / 10) & 0xFFFF) + be16(unitsPerEm / 20) + [UInt8](repeating: 0, count: 20)
        var os2 = be16(4) + be16(maxAdvance / 2) + be16(min(max(weight, 1), 1000)) + be16(5) + be16(0)
        os2 += [UInt8](repeating: 0, count: 16)   // sub- and superscript sizes and offsets
        os2 += be16(unitsPerEm / 20) + be16(unitsPerEm / 4) + be16(0) + [UInt8](repeating: 0, count: 10)
        os2 += [UInt8](repeating: 0, count: 16) + Array("NONE".utf8)
        os2 += be16((italic ? 1 : 0) | (bold ? 32 : 0) | (!italic && !bold ? 64 : 0)) + be16(0x20) + be16(0xFFFF)
        os2 += be16(asc & 0xFFFF) + be16(desc & 0xFFFF) + be16(0) + be16(max(asc, 0)) + be16(max(-desc, 0))
        os2 += [UInt8](repeating: 0, count: 8) + be16(0) + be16(0) + be16(0) + be16(0x20) + be16(1)
        let ps = sanitizedName(postScriptName)
        let tables: [String: [UInt8]] = [
            "head": head, "hhea": hhea, "maxp": maxp, "hmtx": hmtx, "loca": loca, "glyf": glyf, "post": post, "OS/2": os2,
            "cmap": FontSubset.cmapTable([:]),
            "name": FontSubset.nameTable(family: family.isEmpty ? ps : family, subfamily: bold ? (italic ? "Bold Italic" : "Bold")
                                         : (italic ? "Italic" : "Regular"), postScript: ps),
        ]
        return FontSubset.sfnt(tables, version: 0x0001_0000)
    }

    /// A PostScript name: printable ASCII without delimiters, at most 63 characters.
    static func sanitizedName(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0.value > 32 && $0.value < 127 && !"[](){}<>/%".unicodeScalars.contains($0) }
        let name = String(String.UnicodeScalarView(kept.prefix(63)))
        return name.isEmpty ? "Font" : name
    }

    static func clamp16(_ v: Int) -> Int { min(max(v, -32_768), 32_767) }

    /// A point of a contour, in whole font units.
    struct ContourPoint: Hashable {
        var x: Int, y: Int, on: Bool
    }

    static func round(_ p: Point) -> (Int, Int) {
        func r(_ v: Double) -> Int { Int((v.isFinite ? min(max(v, -maxCoordinate), maxCoordinate) : 0).rounded()) }
        return (r(p.x), r(p.y))
    }

    /// Closed TrueType contours (on- and off-curve points) of an outline.
    static func contours(_ outline: [OutlineSegment]) -> [[ContourPoint]] {
        var out: [[ContourPoint]] = []
        var current: [ContourPoint] = []
        var pen = Point(x: 0, y: 0)
        func on(_ p: Point) { let (x, y) = round(p); current.append(ContourPoint(x: x, y: y, on: true)) }
        func off(_ p: Point) { let (x, y) = round(p); current.append(ContourPoint(x: x, y: y, on: false)) }
        func finish() {
            // A closing point on the start is implied by TrueType's closed contours.
            if current.count > 1, let first = current.first, let last = current.last, last == first { current.removeLast() }
            if current.count >= 2 { out.append(current) }
            current = []
        }
        for seg in outline {
            switch seg {
            case .move(let p):
                finish()
                on(p); pen = p
            case .line(let p):
                if current.isEmpty { on(pen) }
                on(p); pen = p
            case .quad(let c, let p):
                if current.isEmpty { on(pen) }
                off(c); on(p); pen = p
            case .cubic(let a, let b, let p):
                if current.isEmpty { on(pen) }
                for (c, e) in quadratics(pen, a, b, p) { off(c); on(e) }
                pen = p
            case .close:
                finish()
            }
        }
        finish()
        return out
    }

    /// Quadratic segments (control, end) within `cubicTolerance` of the cubic
    /// `p0 p1 p2 p3`. One quadratic with control `(3(p1 + p2) − p0 − p3) / 4`
    /// is within `√3/36 · |p3 − 3p2 + 3p1 − p0|` of the cubic; halves are
    /// split until that bound is met (at most 2^8 pieces).
    static func quadratics(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point, depth: Int = 0) -> [(Point, Point)] {
        let dx = p3.x - 3 * p2.x + 3 * p1.x - p0.x, dy = p3.y - 3 * p2.y + 3 * p1.y - p0.y
        let error = 3.0.squareRoot() / 36 * (dx * dx + dy * dy).squareRoot()
        if error <= cubicTolerance || depth >= 8 || !error.isFinite {
            let c = Point(x: (3 * (p1.x + p2.x) - p0.x - p3.x) / 4, y: (3 * (p1.y + p2.y) - p0.y - p3.y) / 4)
            return [(c, p3)]
        }
        // de Casteljau at t = 1/2.
        func mid(_ a: Point, _ b: Point) -> Point { Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3)
        let d = mid(a, b), e = mid(b, c), m = mid(d, e)
        return quadratics(p0, a, d, m, depth: depth + 1) + quadratics(m, e, c, p3, depth: depth + 1)
    }

    /// A simple glyph's `glyf` data (no instructions; every coordinate a
    /// 16-bit delta) and its bounding box.
    static func encode(_ contours: [[ContourPoint]]) -> (bytes: [UInt8], bbox: (Int, Int, Int, Int)) {
        let pts = contours.flatMap { $0 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let bbox = (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
        var out = be16(contours.count) + be16(bbox.0 & 0xFFFF) + be16(bbox.1 & 0xFFFF) + be16(bbox.2 & 0xFFFF) + be16(bbox.3 & 0xFFFF)
        var end = -1
        for c in contours { end += c.count; out += be16(end) }
        out += be16(0)   // no instructions
        for p in pts { out.append(p.on ? 1 : 0) }
        var last = 0
        for p in pts { out += be16((p.x - last) & 0xFFFF); last = p.x }
        last = 0
        for p in pts { out += be16((p.y - last) & 0xFFFF); last = p.y }
        return (out, bbox)
    }
}
