import Foundation
import Sempere

/// One glyph placed by text layout, in page coordinates (points, y down).
public struct PlacedGlyph: Sendable {
    /// Glyph id in the run's font.
    public var glyph: Int
    /// Origin of the glyph on the baseline.
    public var x: Double
    public var y: Double
    /// Advance in points (0 for an attached mark).
    public var advance: Double
    /// The characters this glyph stands for, on the first glyph of its
    /// cluster ("" on the others): what copying the text yields.
    public var text: String

    public init(glyph: Int, x: Double, y: Double, advance: Double, text: String) {
        self.glyph = glyph; self.x = x; self.y = y; self.advance = advance; self.text = text
    }
}

/// Consecutive glyphs of one font, size, colour and style on one line.
public struct GlyphRun: Sendable {
    public var face: FontFace
    /// Font size in points.
    public var size: Double
    public var color: Color
    /// The face lacks bold: draw with an outline stroke of `size / 30`.
    public var syntheticBold: Bool
    /// The face lacks italic: slant by 12°.
    public var syntheticItalic: Bool
    public var glyphs: [PlacedGlyph]

    public init(face: FontFace, size: Double, color: Color, syntheticBold: Bool, syntheticItalic: Bool, glyphs: [PlacedGlyph]) {
        self.face = face; self.size = size; self.color = color
        self.syntheticBold = syntheticBold; self.syntheticItalic = syntheticItalic; self.glyphs = glyphs
    }
}

/// An underline or strikethrough: a filled rectangle (page coordinates).
public struct TextDecoration: Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var color: Color

    public init(x: Double, y: Double, width: Double, height: Double, color: Color) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
    }
}

/// One laid-out line.
public struct ShapedLine: Sendable {
    /// Baseline, page coordinates.
    public var baseline: Double
    /// Line size `S` (format.md §8.5.3): the largest run size on the line.
    public var size: Double
    /// Glyph runs in visual order, left to right.
    public var runs: [GlyphRun]
    /// The line's characters in logical order (trailing white space dropped).
    public var text: String
    /// The paragraph is right to left.
    public var rtl: Bool
    /// Left edge and width of the drawn line.
    public var x: Double
    public var width: Double
    /// The line's characters as offsets in Unicode scalar values into the
    /// item's text (`TextContent.string`), trailing white space included:
    /// what `TextLineBreaks` turns into `breaks`.
    public var range: Range<Int> = 0..<0

    public init(baseline: Double, size: Double, runs: [GlyphRun], text: String, rtl: Bool, x: Double, width: Double,
                range: Range<Int> = 0..<0) {
        self.baseline = baseline; self.size = size; self.runs = runs; self.text = text; self.rtl = rtl
        self.x = x; self.width = width; self.range = range
    }
}

/// Text laid out in a frame (format.md §8.5.3), ready for any writer.
public struct ShapedText: Sendable {
    public var lines: [ShapedLine] = []
    public var decorations: [TextDecoration] = []
    /// Scripts with characters no available font covers (drawn as the
    /// missing-glyph box), with an example character each.
    public var missingScripts: [String: UInt32] = [:]
    /// Scripts the shaper draws approximately (they need a full shaping engine).
    public var approximateScripts: Set<String> = []
    /// Scripts of characters whose glyphs have no outlines the exporters can
    /// draw (colour or bitmap glyphs, e.g. Apple Color Emoji in the app), with
    /// an example character each: left out of the export and reported.
    public var bitmapScripts: [String: UInt32] = [:]
    /// Bottom of the last line.
    public var bottom: Double = 0

    public init() {}
}

/// Lays text out and shapes it (docs/attachments.md §10): the CLI uses
/// `DefaultTextShaper`; the app implements this with CoreText.
public protocol TextShaper: Sendable {
    func shape(_ text: TextContent, frame: Rect) throws -> ShapedText
}

/// The CLI's shaper: bundled and font-pack fonts (`FontLibrary`), UAX #9,
/// #14 and #29, `cmap`/`hmtx`, GSUB single and ligature substitution for
/// the Arabic joining forms and `rlig`, GPOS mark attachment.
public struct DefaultTextShaper: TextShaper {
    public let library: FontLibrary

    public init(library: FontLibrary) { self.library = library }

    /// Scripts that need reordering or conjunct formation this shaper does not do.
    static let complexScripts: Set<String> = [
        "Devanagari", "Bengali", "Gurmukhi", "Gujarati", "Oriya", "Tamil", "Telugu", "Kannada", "Malayalam",
        "Sinhala", "Khmer", "Myanmar", "Tibetan", "Balinese", "Javanese", "Lao", "Thai", "Tai_Tham", "Chakma",
        "Grantha", "Newa", "Tirhuta", "Sharada", "Takri", "Kaithi", "Brahmi", "Tai_Viet", "Cham", "Lepcha",
    ]
    /// Scripts with cursive joining (Arabic shaping, ArabicShaping.txt).
    static let joiningScripts: Set<String> = ["Arabic", "Syriac", "Nko", "Mandaic", "Manichaean", "Psalter_Pahlavi",
                                              "Adlam", "Hanifi_Rohingya", "Sogdian", "Old_Uyghur", "Mongolian", "Phags_Pa"]
    static let scriptTags: [String: String] = [
        "Arabic": "arab", "Hebrew": "hebr", "Latin": "latn", "Greek": "grek", "Cyrillic": "cyrl", "Han": "hani",
        "Hiragana": "kana", "Katakana": "kana", "Hangul": "hang", "Syriac": "syrc", "Thaana": "thaa", "Nko": "nko ",
        "Armenian": "armn", "Georgian": "geor", "Ethiopic": "ethi", "Mongolian": "mong", "Adlam": "adlm",
    ]

    // MARK: - Characters

    /// One character of the text with its run's attributes.
    struct Char {
        var scalar: UInt32
        var run: Int
    }

    static func isIgnorable(_ c: UInt32) -> Bool {
        switch c {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E,
             0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0x1BCA0...0x1BCA3, 0xE0000...0xE0FFF:
            return true
        default:
            return false
        }
    }

    static func isVariationSelector(_ c: UInt32) -> Bool { (0xFE00...0xFE0F).contains(c) || (0xE0100...0xE01EF).contains(c) }

    static func isWhiteSpace(_ c: UInt32) -> Bool { Unicode.Scalar(c)?.properties.isWhitespace ?? false }

    // MARK: - Shape

    public func shape(_ content: TextContent, frame: Rect) throws -> ShapedText {
        var chars: [Char] = []
        for (r, run) in content.runs.enumerated() {
            for s in run.t.unicodeScalars { chars.append(Char(scalar: s.value, run: r)) }
        }
        var out = ShapedText()
        // format.md §8.5.3: stored breaks are used only if valid, including grapheme boundaries.
        let breaks = TextLineBreaks.usable(content, scalars: chars.map(\.scalar)).map(Set.init)
        let sizes = content.runs.map { $0.size ?? content.size }
        var y = frame.y
        var start = 0
        while start <= chars.count {
            var end = start
            while end < chars.count, chars[end].scalar != 0x0A { end += 1 }
            try layoutParagraph(chars, start..<end, content: content, frame: frame, breaks: breaks, sizes: sizes,
                                y: &y, into: &out)
            start = end + 1
        }
        out.bottom = y
        return out
    }

    /// A shaped glyph before placement.
    struct ShapedGlyph {
        var glyph: Int
        /// Index of the character it starts from (absolute).
        var cluster: Int
        var advance: Double            // points
        var offset = Point(x: 0, y: 0)  // points, y up (font convention)
        /// Index (in the segment) of the glyph it is attached to.
        var attachedTo: Int?
        /// The characters of the glyph (several for a ligature).
        var text: String
    }

    /// A stretch of one font, run and bidi level.
    struct Segment {
        var range: Range<Int>
        var face: FontFace
        var run: Int
        var level: UInt8
        var script: String
        var syntheticBold: Bool
        var syntheticItalic: Bool
        var glyphs: [ShapedGlyph] = []
    }

    private func layoutParagraph(_ chars: [Char], _ para: Range<Int>, content: TextContent, frame: Rect,
                                 breaks: Set<Int>?, sizes: [Double], y: inout Double, into out: inout ShapedText) throws {
        guard !para.isEmpty else {
            // An empty line: the box size, or the size of the run holding its line feed.
            let s = para.lowerBound < chars.count ? sizes[chars[para.lowerBound].run] : content.size
            y += 1.2 * s
            return
        }
        let scalars = chars[para].map(\.scalar)
        let dir = content.dir?.effective ?? .auto
        let bidi = BidiParagraph(scalars, direction: dir == .rtl ? 1 : dir == .ltr ? 0 : nil)
        let rtl = bidi.level == 1
        var segments = try itemize(chars, para, content: content, levels: bidi.levels, out: &out)
        for i in segments.indices { try shapeSegment(&segments[i], chars, content: content, sizes: sizes) }
        // Width attributed to each character (its glyphs' advances), as prefix sums,
        // and the end of each prefix without trailing white space: widths in O(1).
        var advance = [Double](repeating: 0, count: chars.count)
        var segmentOf = [Int](repeating: 0, count: chars.count)
        var glyphsOf: [Int: [(segment: Int, glyph: Int)]] = [:]
        for (si, seg) in segments.enumerated() {
            for i in seg.range { segmentOf[i] = si }
            for (gi, g) in seg.glyphs.enumerated() {
                advance[g.cluster] += g.advance
                glyphsOf[g.cluster, default: []].append((si, gi))
            }
        }
        var prefix = [Double](repeating: 0, count: chars.count + 1)
        var lastInk = [Int](repeating: 0, count: chars.count + 1)   // lastInk[e]: end of [.., e) without trailing white space
        for i in para {
            prefix[i + 1] = prefix[i] + advance[i]
            lastInk[i + 1] = Self.isWhiteSpace(chars[i].scalar) ? lastInk[i] : i + 1
        }
        lastInk[para.lowerBound] = para.lowerBound
        func width(_ r: Range<Int>) -> Double {
            let e = max(lastInk[r.upperBound], r.lowerBound)
            return prefix[e] - prefix[r.lowerBound]
        }
        // Lines (absolute ranges).
        var lines: [Range<Int>] = []
        if let breaks {
            var s = para.lowerBound
            for b in breaks.sorted() where b > para.lowerBound && b < para.upperBound {
                lines.append(s..<b); s = b
            }
            lines.append(s..<para.upperBound)
        } else {
            let opportunities = LineBreaker.opportunities(scalars).map { (para.lowerBound + $0.index, $0.mandatory) }
            let clusters = GraphemeClusters.boundaries(scalars).map { para.lowerBound + $0 }
            var s = para.lowerBound
            var lastFit: Int?
            var k = 0
            while k < opportunities.count {
                let (b, mandatory) = opportunities[k]
                if width(s..<b) <= frame.w + 1e-9 {
                    if mandatory { lines.append(s..<b); s = b; lastFit = nil } else { lastFit = b }
                    k += 1
                } else if let f = lastFit {
                    lines.append(s..<f); s = f; lastFit = nil
                } else {
                    // A word wider than the frame: break it between grapheme clusters.
                    var cut = s
                    // The first cluster boundary after `s` (binary search), then forward.
                    var lo = 0, hi = clusters.count
                    while lo < hi { let mid = (lo + hi) / 2; if clusters[mid] <= s { lo = mid + 1 } else { hi = mid } }
                    var ci = lo
                    while ci < clusters.count, clusters[ci] < b {
                        let c = clusters[ci]
                        if width(s..<c) <= frame.w + 1e-9 || cut == s { cut = c } else { break }
                        ci += 1
                    }
                    if cut == s || cut >= b {
                        if mandatory { lines.append(s..<b); s = b } else { lastFit = b }
                        k += 1
                    } else {
                        lines.append(s..<cut); s = cut
                    }
                }
            }
            if s < para.upperBound { lines.append(s..<para.upperBound) }
        }
        // Each line: vertical metrics, visual order, placement.
        let align = content.align?.effective ?? .start
        for line in lines {
            let lineSize = line.map { sizes[chars[$0].run] }.max() ?? content.size
            let baseline = y + 0.95 * lineSize
            let drawn = line.lowerBound..<max(lastInk[line.upperBound], line.lowerBound)
            // Clusters (a base and the marks after it), in visual order.
            let order = drawn.isEmpty ? [] : bidi.visualOrder((drawn.lowerBound - para.lowerBound)..<(drawn.upperBound - para.lowerBound))
                .map { $0 + para.lowerBound }
            var clusterOf: [Int: Int] = [:]
            var base = drawn.lowerBound
            for i in drawn {
                let c = chars[i].scalar
                if i == drawn.lowerBound || !(UnicodeProperties.isMark(c) || Self.isIgnorable(c)) || segmentOf[i] != segmentOf[base] {
                    base = i
                }
                clusterOf[i] = base
            }
            var emitted = Set<Int>()
            var sequence: [(segment: Int, glyph: Int)] = []
            for i in order {
                guard let b = clusterOf[i], emitted.insert(b).inserted else { continue }
                var j = b
                while j < drawn.upperBound, clusterOf[j] == b {
                    sequence += glyphsOf[j] ?? []
                    j += 1
                }
            }
            let lineWidth = sequence.reduce(0) { $0 + (segments[$1.segment].glyphs[$1.glyph].attachedTo == nil ? segments[$1.segment].glyphs[$1.glyph].advance : 0) }
            var x: Double
            switch align {
            case .left: x = frame.x
            case .right: x = frame.x + frame.w - lineWidth
            case .center: x = frame.x + (frame.w - lineWidth) / 2
            case .end: x = rtl ? frame.x : frame.x + frame.w - lineWidth
            default: x = rtl ? frame.x + frame.w - lineWidth : frame.x
            }
            let x0 = x
            var placed: [Int: [Int: Double]] = [:]   // segment → glyph → x
            var runs: [GlyphRun] = []
            for (si, gi) in sequence {
                let seg = segments[si]
                let g = seg.glyphs[gi]
                let gx: Double
                if let a = g.attachedTo, let bx = placed[si]?[a] { gx = bx + g.offset.x } else { gx = x + g.offset.x }
                placed[si, default: [:]][gi] = g.attachedTo == nil ? x : gx - g.offset.x
                let pg = PlacedGlyph(glyph: g.glyph, x: gx, y: baseline - g.offset.y, advance: g.attachedTo == nil ? g.advance : 0,
                                     text: g.text)
                if g.attachedTo == nil { x += g.advance }
                let run = content.runs[seg.run]
                let color = run.color ?? content.color
                let size = sizes[seg.run]
                if let last = runs.last, last.face.key == seg.face.key, last.size == size, last.color == color,
                   last.syntheticBold == seg.syntheticBold, last.syntheticItalic == seg.syntheticItalic {
                    runs[runs.count - 1].glyphs.append(pg)   // in place: a copy would make long lines quadratic
                } else {
                    runs.append(GlyphRun(face: seg.face, size: size, color: color, syntheticBold: seg.syntheticBold,
                                         syntheticItalic: seg.syntheticItalic, glyphs: [pg]))
                }
                // Decorations (format.md §8.5.3): S/18 thick; underline 0.12 × run size below the baseline,
                // strikethrough 0.3 × run size above it.
                if g.attachedTo == nil && g.advance > 0 {
                    let t = lineSize / 18
                    if run.u { out.decorations.append(TextDecoration(x: pg.x - g.offset.x, y: baseline + 0.12 * size - t / 2, width: g.advance, height: t, color: color)) }
                    if run.s { out.decorations.append(TextDecoration(x: pg.x - g.offset.x, y: baseline - 0.3 * size - t / 2, width: g.advance, height: t, color: color)) }
                }
            }
            let text = String(String.UnicodeScalarView(chars[drawn].compactMap { Unicode.Scalar($0.scalar) }))
            out.lines.append(ShapedLine(baseline: baseline, size: lineSize, runs: runs, text: text, rtl: rtl, x: x0, width: lineWidth,
                                        range: line))
            y += 1.2 * lineSize
        }
    }

    // MARK: - Itemize

    /// Splits a paragraph into segments of one run, font, script and level,
    /// choosing a font per character (the run's face, else a font pack).
    private func itemize(_ chars: [Char], _ para: Range<Int>, content: TextContent, levels: [UInt8],
                         out: inout ShapedText) throws -> [Segment] {
        // Scripts, with Common and Inherited taking their neighbour's.
        var scripts = chars[para].map { UnicodeProperties.script[$0.scalar] }
        var last = "Common"
        for i in scripts.indices {
            if scripts[i] == "Common" || scripts[i] == "Inherited" { scripts[i] = last } else { last = scripts[i] }
        }
        var next = last
        for i in scripts.indices.reversed() {
            if scripts[i] == "Common" { scripts[i] = next } else { next = scripts[i] }
        }
        var segments: [Segment] = []
        var prevFace: FontFace?
        for (k, i) in para.enumerated() {
            let ch = chars[i]
            let run = content.runs[ch.run]
            let lang = run.lang ?? content.lang
            let bold = run.b, italic = run.i
            let generic = run.effectiveFont(in: content.font)
            guard let primary = library.bundledFace(generic, bold: bold, italic: italic) ?? library.fallback(
                for: 0x41, lang: lang, generic: generic, bold: bold, italic: italic) else {
                throw FontError.unsupported("no fonts available (bundled fonts missing and no font packs)")
            }
            var face = primary
            let c = ch.scalar
            let neutral = Self.isIgnorable(c) || Self.isWhiteSpace(c) || UnicodeProperties.isMark(c) || c == 0x09
            if neutral, let p = prevFace, p.font.covers(c) || !UnicodeProperties.isMark(c) {
                face = p
            } else if !primary.font.covers(c) && !Self.isIgnorable(c) && c != 0x09 {
                if let f = library.fallback(for: c, lang: lang, generic: generic, bold: bold, italic: italic) {
                    face = f
                } else if !Self.isWhiteSpace(c) {
                    let script = UnicodeProperties.script[c]
                    if out.missingScripts[script] == nil { out.missingScripts[script] = c }
                }
            }
            if Self.complexScripts.contains(scripts[k]) { out.approximateScripts.insert(scripts[k]) }
            prevFace = face
            let fontBold = face.font.weight >= 600, fontItalic = face.font.italic
            if let lastSeg = segments.last, lastSeg.face.key == face.key, lastSeg.run == ch.run,
               lastSeg.level == levels[k], lastSeg.script == scripts[k] {
                segments[segments.count - 1].range = lastSeg.range.lowerBound..<(i + 1)
            } else {
                segments.append(Segment(range: i..<(i + 1), face: face, run: ch.run, level: levels[k], script: scripts[k],
                                        syntheticBold: bold && !fontBold, syntheticItalic: italic && !fontItalic))
            }
        }
        return segments
    }

    // MARK: - Shaping

    private func shapeSegment(_ seg: inout Segment, _ chars: [Char], content: TextContent, sizes: [Double]) throws {
        let font = seg.face.font
        let scale = sizes[seg.run] / Double(font.unitsPerEm)
        let rtl = seg.level % 2 == 1
        var glyphs: [ShapedGlyph] = []
        var i = seg.range.lowerBound
        let spaceGlyph = font.glyph(for: 0x20)
        while i < seg.range.upperBound {
            var c = chars[i].scalar
            let text = String(Unicode.Scalar(c) ?? "\u{FFFD}")
            if c == 0x09 {
                glyphs.append(ShapedGlyph(glyph: spaceGlyph, cluster: i, advance: 4 * Double(font.advance(spaceGlyph)) * scale,
                                          text: text))
                i += 1
                continue
            }
            if Self.isIgnorable(c) && !Self.isVariationSelector(c) { i += 1; continue }
            if Self.isVariationSelector(c) { i += 1; continue }
            var vs: UInt32?
            if i + 1 < seg.range.upperBound, Self.isVariationSelector(chars[i + 1].scalar) { vs = chars[i + 1].scalar }
            if rtl, let m = UnicodeProperties.mirror[c], font.covers(m) { c = m }
            let g = font.glyph(for: c, variation: vs)
            glyphs.append(ShapedGlyph(glyph: g, cluster: i, advance: Double(font.advance(g)) * scale, text: text))
            i += 1
        }
        let layout = OpenTypeLayout(font)
        let tag = Self.scriptTags[seg.script] ?? "DFLT"
        // GSUB in stages, as HarfBuzz orders them: composition, joining forms, required ligatures.
        if layout.gsub != nil {
            let joining = Self.joiningScripts.contains(seg.script)
            let forms = joining ? Self.joiningForms(chars, seg.range) : [:]
            var applier = GSUBApplier(layout: layout, buffer: glyphs.map { GSUBApplier.Entry(glyph: $0.glyph, cluster: $0.cluster) })
            let stages: [[String]] = joining ? [["ccmp", "locl"], ["isol", "fina", "medi", "init"], ["rlig"]]
                : [["ccmp", "locl"], ["rlig"]]
            for stage in stages {
                var done = Set<String>()
                for (l, feature) in layout.lookups(layout.gsub, script: tag, features: Set(stage))
                where done.insert("\(l)/\(feature)").inserted {
                    if ["isol", "fina", "medi", "init"].contains(feature) {
                        applier.apply(l) { forms[$0.cluster] == feature }
                    } else {
                        applier.apply(l)
                    }
                }
            }
            // Rebuild the glyphs; the first glyph of each cluster carries the
            // cluster's characters (all of a ligature's components).
            let starts = Set(applier.buffer.map(\.cluster)).sorted()
            var position: [Int: Int] = [:]
            for (k, c) in starts.enumerated() { position[c] = k }
            var rebuilt: [ShapedGlyph] = []
            var seen = Set<Int>()
            for e in applier.buffer {
                var text = ""
                if seen.insert(e.cluster).inserted {
                    let k = position[e.cluster] ?? starts.count
                    let next = k + 1 < starts.count ? starts[k + 1] : seg.range.upperBound
                    for j in e.cluster..<next where !Self.isIgnorable(chars[j].scalar) || Self.isVariationSelector(chars[j].scalar) == false {
                        if let u = Unicode.Scalar(chars[j].scalar), !Self.isVariationSelector(chars[j].scalar) { text.unicodeScalars.append(u) }
                    }
                }
                let advance = chars[e.cluster].scalar == 0x09 ? 4 * Double(font.advance(spaceGlyph)) * scale
                    : Double(font.advance(e.glyph)) * scale
                rebuilt.append(ShapedGlyph(glyph: e.glyph, cluster: e.cluster, advance: advance, text: text))
            }
            glyphs = rebuilt
        }
        // Mark attachment (GPOS mark, mkmk).
        let markLookups = layout.lookups(layout.gpos, script: tag, features: ["mark", "mkmk", "abvm", "blwm"])
        for k in glyphs.indices {
            let g = glyphs[k].glyph
            let isMark = layout.glyphClasses != nil ? layout.glyphClass(g) == 3 : UnicodeProperties.isMark(chars[glyphs[k].cluster].scalar)
            guard isMark, k > 0 else { continue }
            var attached = false
            for (l, feature) in markLookups where !attached {
                // mark: the closest base (or ligature) before; mkmk: the mark right before.
                var b = k - 1
                if feature != "mkmk" {
                    while b >= 0 && k - b <= 64 {
                        let bc = layout.glyphClasses != nil ? layout.glyphClass(glyphs[b].glyph)
                            : (UnicodeProperties.isMark(chars[glyphs[b].cluster].scalar) ? 3 : 1)
                        if bc != 3 { break }
                        b -= 1
                    }
                }
                guard b >= 0 else { continue }
                if let a = layout.attach(l, mark: g, base: glyphs[b].glyph, component: max(0, glyphs[k].cluster - glyphs[b].cluster)) {
                    if a.type == 6 && feature != "mkmk" { continue }
                    let baseOffset = glyphs[b].attachedTo != nil ? glyphs[b].offset : Point(x: 0, y: 0)
                    glyphs[k].attachedTo = glyphs[b].attachedTo ?? b
                    glyphs[k].offset = Point(x: baseOffset.x + a.offset.x * scale, y: baseOffset.y + a.offset.y * scale)
                    glyphs[k].advance = 0
                    attached = true
                }
            }
            if !attached && layout.glyphClasses != nil && layout.glyphClass(g) == 3 { glyphs[k].advance = 0 }
        }
        seg.glyphs = glyphs
    }

    /// The joining form (`isol`, `init`, `medi`, `fina`) of each joining
    /// character in `range` (ArabicShaping.txt; transparent characters skipped).
    static func joiningForms(_ chars: [Char], _ range: Range<Int>) -> [Int: String] {
        var out: [Int: String] = [:]
        // The paragraph around `range`, and the nearest non-transparent joining type on each side (two sweeps).
        var lo = range.lowerBound, hi = range.upperBound
        while lo > 0, chars[lo - 1].scalar != 0x0A { lo -= 1 }
        while hi < chars.count, chars[hi].scalar != 0x0A { hi += 1 }
        let types = chars[lo..<hi].map { UnicodeProperties.joiningType[$0.scalar] }
        var before = [JoiningType?](repeating: nil, count: types.count)
        var after = [JoiningType?](repeating: nil, count: types.count)
        var last: JoiningType?
        for k in types.indices { before[k] = last; if types[k] != .T { last = types[k] } }
        last = nil
        for k in types.indices.reversed() { after[k] = last; if types[k] != .T { last = types[k] } }
        for i in range {
            let k = i - lo
            let t = types[k]
            guard t == .D || t == .R || t == .L || t == .C else { continue }
            let prev = before[k], next = after[k]
            let joinsPrev = (t == .D || t == .R || t == .C) && (prev == .D || prev == .L || prev == .C)
            let joinsNext = (t == .D || t == .L || t == .C) && (next == .D || next == .R || next == .C)
            out[i] = joinsPrev ? (joinsNext ? "medi" : "fina") : (joinsNext ? "init" : "isol")
        }
        return out
    }
}
