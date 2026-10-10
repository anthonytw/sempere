import Foundation
import Sempere

/// Synthetic italic slant (format.md §8.5.3): 12°.
let italicSlant = tan(12 * Double.pi / 180)

extension ShapedText {
    /// Underlines and strikethroughs as filled polygons, after `transform`.
    func decorationCommands(_ transform: Affine) -> [DrawCommand] {
        decorations.map { d in
            let pts = [Point(x: d.x, y: d.y), Point(x: d.x + d.width, y: d.y), Point(x: d.x + d.width, y: d.y + d.height),
                       Point(x: d.x, y: d.y + d.height)].map(transform.apply)
            return DrawCommand(.path([Subpath(points: pts, closed: true)]), fill: Paint(d.color))
        }
    }
}

// MARK: - PDF

/// The fonts of one PDF (docs/attachments.md §10): one Type0 font per face
/// used, Identity-H, with a CIDFontType2 (TrueType outlines) or
/// CIDFontType0C (CFF) subset of exactly the glyphs drawn and a `ToUnicode`
/// CMap so the text can be searched and copied.
struct PDFFontSet {
    struct Entry {
        var subset: FontSubset
        /// Subset glyph → the text it stands for (first assignment wins).
        var toUnicode: [Int: String] = [:]
    }
    private(set) var entries: [Entry] = []
    private var byKey: [String: Int] = [:]

    /// The resource index of a face, adding it on first use.
    mutating func index(_ face: FontFace) -> Int {
        if let i = byKey[face.key] { return i }
        entries.append(Entry(subset: FontSubset(face.font)))
        byKey[face.key] = entries.count - 1
        return entries.count - 1
    }

    /// The subset glyph for `glyph` of font `i`, recording its text.
    mutating func glyph(_ i: Int, _ glyph: Int, text: String) -> Int {
        let g = entries[i].subset.id(glyph)
        // Missing characters all share .notdef: no single text belongs to it.
        if g != 0 && !text.isEmpty && entries[i].toUnicode[g] == nil { entries[i].toUnicode[g] = text }
        return g
    }

    /// Five objects per font, numbered from `base`: Type0, CIDFont,
    /// FontDescriptor, font file, ToUnicode.
    func objects(base: Int, compress: Bool) throws -> [Data] {
        var out: [Data] = []
        for (i, e) in entries.enumerated() {
            let n = base + 5 * i
            var subset = e.subset
            let font = subset.font
            let name = "/" + subset.subsetName
            let file: [UInt8] = font.isCFF ? try subset.cffTable() : try subset.trueTypeFile()
            let k = 1000 / Double(font.unitsPerEm)
            out.append(Data("<< /Type /Font /Subtype /Type0 /BaseFont \(name) /Encoding /Identity-H /DescendantFonts [\(n + 1) 0 R] /ToUnicode \(n + 4) 0 R >>".utf8))
            let widths = subset.glyphs.indices.map { fmt(Double(subset.advance($0)) * k) }.joined(separator: " ")
            var cid = "<< /Type /Font /Subtype /\(font.isCFF ? "CIDFontType0" : "CIDFontType2") /BaseFont \(name) "
            cid += "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor \(n + 2) 0 R "
            cid += "/DW 0 /W [0 [\(widths)]]"
            if !font.isCFF { cid += " /CIDToGIDMap /Identity" }
            out.append(Data((cid + " >>").utf8))
            var bbox = "0 0 1000 1000"
            if let head = font.table("head"), head.count >= 44 {
                let h = Array(head)
                func i16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(h[o]) << 8 | UInt16(h[o + 1]))) * k }
                bbox = [36, 38, 40, 42].map { fmt(i16($0)) }.joined(separator: " ")
            }
            let asc = fmt(Double(font.ascender) * k), desc = fmt(Double(font.descender) * k)
            out.append(Data(("<< /Type /FontDescriptor /FontName \(name) /Flags 4 /FontBBox [\(bbox)] /ItalicAngle 0 "
                + "/Ascent \(asc) /Descent \(desc) /CapHeight \(asc) /StemV 80 /\(font.isCFF ? "FontFile3" : "FontFile2") \(n + 3) 0 R >>").utf8))
            let fileData = try Zlib.compress(Data(file))
            let fileDict = font.isCFF ? "/Subtype /CIDFontType0C /Filter /FlateDecode /Length \(fileData.count)"
                : "/Length1 \(file.count) /Filter /FlateDecode /Length \(fileData.count)"
            out.append(PDFWriter.streamObject(dict: fileDict, fileData))
            var cmap = Data(Self.toUnicode(e.toUnicode).utf8)
            var dict = "/Length \(cmap.count)"
            if compress { cmap = try Zlib.compress(cmap); dict = "/Filter /FlateDecode /Length \(cmap.count)" }
            out.append(PDFWriter.streamObject(dict: dict, cmap))
        }
        return out
    }

    static func toUnicode(_ map: [Int: String]) -> String {
        var s = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange

            """
        let pairs = map.sorted { $0.key < $1.key }
        var i = 0
        while i < pairs.count {
            let chunk = pairs[i..<min(i + 100, pairs.count)]
            s += "\(chunk.count) beginbfchar\n"
            for (g, t) in chunk {
                let hex = t.utf16.prefix(256).map { String(format: "%04X", $0) }.joined()
                s += String(format: "<%04X> <", g) + hex + ">\n"
            }
            s += "endbfchar\n"
            i += 100
        }
        s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return s
    }
}

extension ContentStream {
    /// Draws laid-out text: `transform` maps layout coordinates to the page
    /// (rotation, chunk offset). Glyphs are shown one by one with a text
    /// matrix that flips them upright in the y-down page space.
    mutating func text(_ shaped: ShapedText, transform m: Affine, fonts: inout PDFFontSet) {
        for c in shaped.decorationCommands(m) { emit(c) }
        for line in shaped.lines {
            for run in line.runs where !run.glyphs.isEmpty {
                let f = fonts.index(run.face)
                usedFonts.insert(f)
                text += "q\n\(coef(m.a)) \(coef(m.b)) \(coef(m.c)) \(coef(m.d)) \(fmt(m.tx)) \(fmt(m.ty)) cm\n"
                let paint = Paint(run.color)
                let alpha = Int((paint.alpha * 1000).rounded())
                if alpha < 1000 { alphas.insert(alpha); text += "/GS\(alpha) gs\n" }
                let rgb = "\(fmt(Double(paint.r) / 255)) \(fmt(Double(paint.g) / 255)) \(fmt(Double(paint.b) / 255))"
                text += "BT\n/T\(f) \(fmt(run.size)) Tf\n\(rgb) rg\n"
                if run.syntheticBold { text += "\(rgb) RG\n\(fmt(run.size / 30)) w\n2 Tr\n" }
                let slant = run.syntheticItalic ? coef(italicSlant) : "0"
                for g in run.glyphs {
                    let id = fonts.glyph(f, g.glyph, text: g.text)
                    text += "1 0 \(slant) -1 \(fmt(g.x)) \(fmt(g.y)) Tm <\(String(format: "%04X", id))> Tj\n"
                }
                text += "ET\nQ\n"
            }
        }
    }
}

// MARK: - SVG

/// The fonts of one SVG page: an `@font-face` subset per face. Glyphs are
/// addressed through private-use code points (U+E000 + subset id, plane 15
/// beyond), so viewers draw exactly the shaped glyphs (no reshaping); an
/// invisible `<text>` per line over them carries the real characters for
/// selection, search and copying.
struct SVGFontSet {
    /// Goes in front of the font family names (`SVGWriter` id prefix).
    var prefix = ""
    private(set) var subsets: [FontSubset] = []
    private var byKey: [String: Int] = [:]

    // Explicit: the private properties make the memberwise initializer private before Swift 6.4.
    init(prefix: String = "") { self.prefix = prefix }

    mutating func index(_ face: FontFace) -> Int {
        if let i = byKey[face.key] { return i }
        subsets.append(FontSubset(face.font))
        byKey[face.key] = subsets.count - 1
        return subsets.count - 1
    }

    static func codePoint(_ id: Int) -> UInt32 { id < 0x1900 ? 0xE000 + UInt32(id) : 0xF0000 + UInt32(id) }

    mutating func glyph(_ i: Int, _ glyph: Int) -> UInt32 {
        Self.codePoint(glyph == 0 ? subsets[i].notdefCopy() : subsets[i].id(glyph))
    }

    /// The `<style>` with every face as a data URI.
    func style() throws -> String {
        var css = ""
        for (i, sub) in subsets.enumerated() {
            var s = sub
            var cmap: [UInt32: Int] = [:]
            for id in s.glyphs.indices.dropFirst() { cmap[Self.codePoint(id)] = id }
            let file = s.font.isCFF ? try s.openTypeCFFFile(cmap: cmap) : try s.trueTypeFile(cmap: cmap)
            css += "@font-face{font-family:\"\(prefix)sempere-f\(i)\";src:url(data:font/\(s.font.isCFF ? "otf" : "ttf");base64,"
                + Data(file).base64EncodedString() + ")}\n"
        }
        return css
    }

    /// SVG elements for laid-out text; `transform` is the item's rotation.
    mutating func elements(_ shaped: ShapedText, transform m: Affine) -> String {
        var out = ""
        let rotated = m != .identity
        if rotated { out += "<g transform=\"matrix(\(coef(m.a)) \(coef(m.b)) \(coef(m.c)) \(coef(m.d)) \(fmt(m.tx)) \(fmt(m.ty)))\">\n" }
        for c in shaped.decorationCommands(.identity) { out += SVGWriter.element(c) + "\n" }
        for line in shaped.lines {
            for run in line.runs where !run.glyphs.isEmpty {
                let f = index(run.face)
                let paint = Paint(run.color)
                var chars = ""
                for g in run.glyphs { chars += String(format: "&#x%X;", glyph(f, g.glyph)) }
                let xs = run.glyphs.map { fmt($0.x) }.joined(separator: " ")
                let ys = run.glyphs.map { fmt($0.y) }.joined(separator: " ")
                var attrs = "font-family=\"\(prefix)sempere-f\(f)\" font-size=\"\(fmt(run.size))\" fill=\"\(paint.hex)\""
                if paint.alpha < 0.9995 { attrs += " fill-opacity=\"\(fmt(paint.alpha))\"" }
                if run.syntheticBold { attrs += " stroke=\"\(paint.hex)\" stroke-width=\"\(fmt(run.size / 30))\"" }
                if run.syntheticItalic {
                    attrs += " transform=\"matrix(1 0 \(coef(-italicSlant)) 1 \(coef(italicSlant * line.baseline)) 0)\""
                }
                out += "<text \(attrs) x=\"\(xs)\" y=\"\(ys)\" aria-hidden=\"true\" style=\"user-select:none\">\(chars)</text>\n"
            }
            // The real characters, invisible, stretched over the drawn line.
            guard !line.text.isEmpty, line.width > 0 else { continue }
            let x = line.rtl ? line.x + line.width : line.x
            out += "<text x=\"\(fmt(x))\" y=\"\(fmt(line.baseline))\" font-size=\"\(fmt(line.size))\" fill-opacity=\"0\" "
            out += "textLength=\"\(fmt(line.width))\" lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\""
            if line.rtl { out += " direction=\"rtl\"" }
            out += ">\(SVGWriter.escape(line.text))</text>\n"
        }
        if rotated { out += "</g>\n" }
        return out
    }
}

// MARK: - Raster

/// Glyph outlines of laid-out text as polygons for the PNG rasterizer.
struct GlyphRasterizer {
    private var cache: [String: [OutlineSegment]] = [:]

    /// Polygons (device coordinates) of a run's glyphs after `m` (layout →
    /// device), and for synthetic bold the outline stroke, to fill
    /// separately (glyph contours wind either way; stroke polygons are all
    /// positive, so one non-zero fill of both could cancel).
    mutating func polygons(_ run: GlyphRun, transform m: Affine) -> (fill: [[Point]], stroke: [[Point]]) {
        let font = run.face.font
        let s = run.size / Double(font.unitsPerEm)
        var out: [[Point]] = []
        var stroke: [[Point]] = []
        for g in run.glyphs {
            let key = run.face.key + "/\(g.glyph)"
            if cache[key] == nil { cache[key] = (try? font.outline(g.glyph)) ?? [] }
            guard let segs = cache[key], !segs.isEmpty else { continue }
            // Font units (y up) → layout: scale, flip, slant, place at the glyph origin.
            let slant = run.syntheticItalic ? italicSlant : 0
            let full = m.after(Affine(a: s, b: 0, c: slant * s, d: -s, tx: g.x, ty: g.y))
            let scale = sqrt(abs(full.determinant))
            var contour: [Point] = []
            var current = Point(x: 0, y: 0)
            func steps(_ length: Double) -> Int { min(max(Int(length * scale / 2) + 1, 1), 64) }
            for seg in segs {
                switch seg {
                case .move(let p):
                    if contour.count > 2 { out.append(contour) }
                    contour = [full.apply(p)]; current = p
                case .line(let p):
                    contour.append(full.apply(p)); current = p
                case .quad(let c, let p):
                    let n = steps(current.distance(to: c) + c.distance(to: p))
                    for k in 1...n {
                        let t = Double(k) / Double(n), u = 1 - t
                        contour.append(full.apply(Point(x: u * u * current.x + 2 * u * t * c.x + t * t * p.x,
                                                        y: u * u * current.y + 2 * u * t * c.y + t * t * p.y)))
                    }
                    current = p
                case .cubic(let a, let b, let p):
                    let n = steps(current.distance(to: a) + a.distance(to: b) + b.distance(to: p))
                    for k in 1...n {
                        let t = Double(k) / Double(n), u = 1 - t
                        let x = u * u * u * current.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * p.x
                        let y = u * u * u * current.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * p.y
                        contour.append(full.apply(Point(x: x, y: y)))
                    }
                    current = p
                case .close:
                    if contour.count > 2 { out.append(contour) }
                    contour = []
                }
            }
            if contour.count > 2 { out.append(contour) }
        }
        if run.syntheticBold {
            let w = run.size / 30 * sqrt(abs(m.determinant))
            for c in out { stroke += PNGWriter.strokePolygons(Subpath(points: c, closed: true), width: w) }
        }
        return (out, stroke)
    }
}
