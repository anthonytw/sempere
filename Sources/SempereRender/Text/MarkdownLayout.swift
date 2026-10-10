import Foundation
import Sempere

// The font-dependent half of drawing a Markdown box (format.md §8.5.4
// "Lines", "Drawing"): the rendered paragraphs of `MarkdownPlan` cut into
// lines (the writer's `layout` when usable, else greedily with a renderer's
// widths), stacked with the format's metrics, and turned into what every
// writer already draws: text items with fixed lines (never broken again),
// formula boxes drawn like math renders, and shapes (markers, quote bars,
// rules, code fills). Ported to `web/src/render/markdown.ts`.

/// The width of `runs` drawn on one line in `box`'s style (points).
public typealias MarkdownMeasure = @Sendable (_ runs: [TextRun], _ box: TextContent) -> Double

/// A Markdown box laid out in a frame (format.md §8.5.4).
public struct MarkdownLayout: Sendable {
    /// A text item to draw: its content (with `breaks`, so never broken
    /// again) and frame, page coordinates, before the box's rotation.
    public struct TextPiece: Sendable {
        public var content: TextContent
        public var frame: Rect
    }

    /// A formula box: drawn like a math item's render onto `frame`.
    public struct Box: Sendable {
        public var formula: TypesetFormula
        public var frame: Rect
    }

    /// One rendered line, font independent: what the shared fixtures pin.
    public struct Line: Hashable, Sendable {
        /// Index of its rendered paragraph.
        public var paragraph: Int
        /// Source offset of its first drawn item (nil for an empty line).
        public var start: Int?
        /// Its drawn characters, trailing white space dropped, a box as U+FFFC.
        public var text: String
        public var baseline: Double
    }

    public var lines: [Line] = []
    public var texts: [TextPiece] = []
    public var boxes: [Box] = []
    /// Markers, quote bars, rules and code fills, in page coordinates
    /// (before rotation), drawn under the text.
    public var shapes: [DrawCommand] = []
    /// Where soft-wrapped lines start: source offsets (format.md §8.2.4
    /// `layout.breaks`).
    public var breaks: [Int] = []
    /// From the frame's top to the last line's bottom.
    public var height: Double = 0
    /// The stored `layout` decided the lines.
    public var usedStoredBreaks = false

    /// A measure from a shaper: the width of the single line it lays the
    /// runs out on. Widths are cached per run sequence.
    public static func measure(with shaper: any TextShaper) -> MarkdownMeasure {
        let cache = MeasureCache()
        return { runs, box in
            let key = MeasureCache.Key(runs: runs, font: box.font, lang: box.lang, size: box.size)
            if let w = cache.get(key) { return w }
            let content = TextContent(font: box.font, size: box.size, color: box.color, lang: box.lang, runs: runs, breaks: [])
            let w = (try? shaper.shape(content, frame: Rect(x: 0, y: 0, w: 1e7, h: 1)))?.lines.map(\.width).max() ?? 0
            cache.set(key, w)
            return w
        }
    }

    final class MeasureCache: @unchecked Sendable {
        struct Key: Hashable {
            var runs: [TextRun]
            var font: TextContent.Font
            var lang: String?
            var size: Double
        }
        private var values: [Key: Double] = [:]
        private let lock = NSLock()
        func get(_ k: Key) -> Double? { lock.lock(); defer { lock.unlock() }; return values[k] }
        func set(_ k: Key, _ v: Double) { lock.lock(); defer { lock.unlock() }; if values.count < 100_000 { values[k] = v } }
    }

    /// Lays out the Markdown box `content` in `frame`.
    public init(_ content: TextContent, frame: Rect, measure: MarkdownMeasure) {
        self.init(plan: MarkdownPlan(content), frame: frame, measure: measure)
    }

    public init(plan: MarkdownPlan, frame: Rect, measure: MarkdownMeasure) {
        let content = plan.content
        let s = content.size
        let stored = Self.storedBreaks(plan)
        usedStoredBreaks = stored != nil
        var y = frame.y
        var tops: [Double] = []
        var fills: [DrawCommand] = []
        var bottoms: [Double] = []
        for (pi, p) in plan.paragraphs.enumerated() {
            y += p.gapBefore
            let top = y
            y += p.pad
            let x0 = frame.x + p.indent
            let width = max(frame.w - p.indent, 1)
            if p.kind == .rule {
                let thick = s / 12
                shapes.append(Self.rect(x: x0, y: y + 0.6 * s - thick / 2, w: width, h: thick,
                                        paint: Paint(content.color, opacity: 0.4)))
                y += 1.2 * s
            } else {
                let lines = Self.lines(p, stored: stored, width: width, box: content, measure: measure)
                for l in lines where l.softStart { breaks.append(p.atoms[l.range.lowerBound].offset) }
                let hasBox = p.atoms.contains { if case .box = $0.kind { return true } else { return false } }
                var firstBaseline: Double?
                var firstSize = p.size
                if !hasBox {
                    // One text item for the whole paragraph: its own layout puts the lines where §8.5.3 does.
                    let piece = Self.paragraphText(p, lines: lines, box: content, frame: Rect(x: x0, y: y, w: width, h: 1))
                    var lineTop = y
                    for l in lines {
                        let size = Self.lineSize(p, l.range)
                        if firstBaseline == nil { firstBaseline = lineTop + 0.95 * size; firstSize = size }
                        self.lines.append(Self.line(p, pi, l.range, baseline: lineTop + 0.95 * size))
                        lineTop += 1.2 * size
                    }
                    var f = piece.frame
                    f.h = max(lineTop - y, 1)
                    texts.append(TextPiece(content: piece.content, frame: f))
                    y = lineTop
                } else {
                    for l in lines {
                        let size = Self.lineSize(p, l.range)
                        var ascent = 0.95 * size, descent = 0.25 * size
                        for i in l.range {
                            if case .box(let f) = p.atoms[i].kind, let r = f.math.renderSize {
                                ascent = max(ascent, r.h - f.depth)
                                descent = max(descent, f.depth)
                            }
                        }
                        let baseline = y + ascent
                        if firstBaseline == nil { firstBaseline = baseline; firstSize = size }
                        self.lines.append(Self.line(p, pi, l.range, baseline: baseline))
                        place(p, l.range, baseline: baseline, x0: x0, width: width, box: content, measure: measure,
                              lineTop: y, size: size)
                        y = baseline + descent
                    }
                }
                if let m = p.marker, let b = firstBaseline {
                    marker(m, baseline: b, size: firstSize, column: x0, box: content)
                }
            }
            y += p.pad
            if p.kind == .code {
                fills.append(Self.rect(x: frame.x + p.column, y: top, w: max(frame.w - p.column, 0), h: y - top,
                                        paint: Paint(content.color, opacity: 0.08)))
            }
            tops.append(top)
            bottoms.append(y)
        }
        for bar in plan.quoteBars where bar.first < tops.count && bar.last < bottoms.count {
            shapes.append(Self.rect(x: frame.x + bar.x, y: tops[bar.first], w: MarkdownPlan.Metrics.quoteBarWidth * s,
                                    h: bottoms[bar.last] - tops[bar.first], paint: Paint(content.color, opacity: 0.4)))
        }
        // Fills first, so text and markers are drawn over them.
        shapes = fills + shapes
        height = y - frame.y
    }

    // MARK: Lines

    struct LineRange {
        var range: Range<Int>
        /// Starts a soft-wrapped line (not a paragraph's or a hard break's first).
        var softStart: Bool
    }

    /// The stored breaks as a set, when the `layout` is usable for the whole box.
    static func storedBreaks(_ plan: MarkdownPlan) -> Set<Int>? {
        let content = plan.content
        guard let layout = content.layout, layout.of == MarkdownText.hash(content.string) else { return nil }
        var wanted = Set(layout.breaks)
        guard wanted.count == layout.breaks.count else { return nil }
        if wanted.isEmpty { return wanted }
        for p in plan.paragraphs {
            for g in groups(p) where g.count > 1 {
                let scalars = g.map { i -> UInt32 in
                    if case .char(let c) = p.atoms[i].kind { return c.value }
                    return 0xFFFC
                }
                let clusters = Set(GraphemeClusters.boundaries(scalars))
                for (k, i) in g.enumerated().dropFirst() where wanted.contains(p.atoms[i].offset) {
                    guard clusters.contains(k) else { return nil }
                    wanted.remove(p.atoms[i].offset)
                }
            }
        }
        return wanted.isEmpty ? Set(layout.breaks) : nil
    }

    /// The atom indices of each hard line of a paragraph (between line breaks).
    static func groups(_ p: MarkdownPlan.Paragraph) -> [[Int]] {
        var out: [[Int]] = [[]]
        for (i, a) in p.atoms.enumerated() {
            if case .lineBreak = a.kind { out.append([]) } else { out[out.count - 1].append(i) }
        }
        return out
    }

    static func isWide(_ c: UInt32) -> Bool {
        if (0x3000...0x303F).contains(c) || (0xFF01...0xFF60).contains(c) || (0xFFE0...0xFFE6).contains(c) { return true }
        let script = UnicodeProperties.script[c]
        return script == "Han" || script == "Hiragana" || script == "Katakana" || script == "Hangul"
    }

    static func isWhite(_ c: UInt32) -> Bool { Unicode.Scalar(c)?.properties.isWhitespace ?? false }

    /// A paragraph's lines: at its hard breaks, then at `stored`, else greedily.
    static func lines(_ p: MarkdownPlan.Paragraph, stored: Set<Int>?, width: Double, box: TextContent,
                      measure: MarkdownMeasure) -> [LineRange] {
        var out: [LineRange] = []
        for g in groups(p) {
            guard let first = g.first, let last = g.last else {
                // An empty line: it sits between break atoms; a range of no atoms.
                let at = out.last?.range.upperBound ?? 0
                out.append(LineRange(range: at..<at, softStart: false))
                continue
            }
            let range = first..<(last + 1)
            if let stored {
                var s = first
                for i in g.dropFirst() where stored.contains(p.atoms[i].offset) {
                    out.append(LineRange(range: s..<i, softStart: s != first))
                    s = i
                }
                out.append(LineRange(range: s..<range.upperBound, softStart: s != first))
            } else {
                for (k, r) in greedy(p, range, width: width, box: box, measure: measure).enumerated() {
                    out.append(LineRange(range: r, softStart: k > 0))
                }
            }
        }
        // Empty lines' ranges: right after the break atom before them.
        for k in out.indices where out[k].range.isEmpty && k > 0 {
            let at = out[k - 1].range.upperBound + 1
            out[k].range = at..<at
        }
        return out
    }

    static func scalar(_ a: MarkdownPlan.Atom) -> UInt32? {
        if case .char(let c) = a.kind { return c.value }
        return nil
    }

    /// Greedy lines of one hard line (format.md §8.5.3 minimum rules, plus
    /// opportunities around formula boxes).
    static func greedy(_ p: MarkdownPlan.Paragraph, _ range: Range<Int>, width: Double, box: TextContent,
                       measure: MarkdownMeasure) -> [Range<Int>] {
        let atoms = p.atoms
        var opportunities: [Int] = []
        for i in (range.lowerBound + 1)..<range.upperBound {
            guard let a = scalar(atoms[i - 1]), let b = scalar(atoms[i]) else { opportunities.append(i); continue }
            let space = isWhite(a) && a != 0xA0 && a != 0x2007 && a != 0x202F && !isWhite(b)
            if space || a == 0x2D || (isWide(a) && isWide(b)) { opportunities.append(i) }
        }
        opportunities.append(range.upperBound)
        // Segments between opportunities, measured whole and without trailing white space.
        var segStart = range.lowerBound
        var segments: [(range: Range<Int>, full: Double, trimmed: Double)] = []
        for o in opportunities {
            let r = segStart..<o
            var e = o
            while e > r.lowerBound, let c = scalar(atoms[e - 1]), isWhite(c) { e -= 1 }
            let full = Self.width(of: atoms, r, box: box, measure: measure)
            let trimmed = e == o ? full : Self.width(of: atoms, r.lowerBound..<e, box: box, measure: measure)
            segments.append((r, full, trimmed))
            segStart = o
        }
        var out: [Range<Int>] = []
        var lineStart = range.lowerBound
        var used = 0.0
        var k = 0
        while k < segments.count {
            let seg = segments[k]
            if used + seg.trimmed <= width + 1e-9 || seg.range.lowerBound == lineStart && seg.trimmed <= width + 1e-9 {
                used += seg.full
                k += 1
                continue
            }
            if seg.range.lowerBound > lineStart {
                out.append(lineStart..<seg.range.lowerBound)
                lineStart = seg.range.lowerBound
                used = 0
                continue
            }
            // A segment wider than the line: cut it between grapheme clusters.
            let pieces = cut(atoms, seg.range, width: width, box: box, measure: measure)
            for r in pieces.dropLast() { out.append(r) }
            let rest = pieces.last ?? seg.range
            lineStart = rest.lowerBound
            used = Self.width(of: atoms, rest, box: box, measure: measure)
            k += 1
        }
        out.append(lineStart..<range.upperBound)
        return out
    }

    /// `range` (one segment, wider than `width`) cut between grapheme
    /// clusters into lines that fit (at least one cluster each).
    static func cut(_ atoms: [MarkdownPlan.Atom], _ range: Range<Int>, width: Double, box: TextContent,
                    measure: MarkdownMeasure) -> [Range<Int>] {
        let scalars = atoms[range].map { scalar($0) ?? 0xFFFC }
        let bounds = GraphemeClusters.boundaries(scalars).map { range.lowerBound + $0 }.filter { $0 > range.lowerBound }
        var out: [Range<Int>] = []
        var start = range.lowerBound
        var used = 0.0
        var previous = range.lowerBound
        for b in bounds {
            let w = Self.width(of: atoms, previous..<b, box: box, measure: measure)
            if used + w > width + 1e-9, previous > start {
                out.append(start..<previous)
                start = previous
                used = 0
            }
            used += w
            previous = b
        }
        out.append(start..<range.upperBound)
        return out
    }

    /// The runs of the characters in `range` (boxes and breaks left out).
    static func runs(_ atoms: [MarkdownPlan.Atom], _ range: Range<Int>) -> [TextRun] {
        var out: [TextRun] = []
        for i in range {
            guard case .char(let c) = atoms[i].kind else { continue }
            if let last = out.last, last.hasSameAttributes(as: atoms[i].run) {
                out[out.count - 1].t.unicodeScalars.append(c)
            } else {
                var r = atoms[i].run
                r.t = String(c)
                out.append(r)
            }
        }
        return out
    }

    /// Width of `range`: its text pieces measured, its boxes' widths.
    static func width(of atoms: [MarkdownPlan.Atom], _ range: Range<Int>, box: TextContent, measure: MarkdownMeasure) -> Double {
        var w = 0.0
        var s = range.lowerBound
        for i in range {
            if case .box(let f) = atoms[i].kind {
                if i > s { w += measure(runs(atoms, s..<i), box) }
                w += f.math.renderSize?.w ?? 0
                s = i + 1
            }
        }
        if range.upperBound > s { w += measure(runs(atoms, s..<range.upperBound), box) }
        return w
    }

    static func line(_ p: MarkdownPlan.Paragraph, _ index: Int, _ range: Range<Int>, baseline: Double) -> Line {
        var text = String.UnicodeScalarView()
        for i in range where i < p.atoms.count {
            switch p.atoms[i].kind {
            case .char(let c): text.append(c)
            case .box: text.append("\u{FFFC}")
            case .lineBreak: break
            }
        }
        while let last = text.last, last.properties.isWhitespace { text.removeLast() }
        let start = range.isEmpty || range.lowerBound >= p.atoms.count ? nil : p.atoms[range.lowerBound].offset
        return Line(paragraph: index, start: start, text: String(text), baseline: InkJSON.round3(baseline))
    }

    /// The line size `S`: the largest size on the line, the paragraph's for an empty one.
    static func lineSize(_ p: MarkdownPlan.Paragraph, _ range: Range<Int>) -> Double {
        var size = 0.0
        for i in range where i < p.atoms.count {
            if case .lineBreak = p.atoms[i].kind { continue }
            size = max(size, p.atoms[i].run.size ?? p.size)
        }
        return size > 0 ? size : p.size
    }

    // MARK: Drawing

    /// A paragraph without boxes as one text item, lines cut at `lines`.
    static func paragraphText(_ p: MarkdownPlan.Paragraph, lines: [LineRange], box: TextContent,
                              frame: Rect) -> TextPiece {
        var runs: [TextRun] = []
        var starts: [Int] = []   // scalar offsets of soft line starts in the piece's text
        var position = 0
        var softAt = Set<Int>()
        for l in lines where l.softStart { softAt.insert(l.range.lowerBound) }
        for (i, a) in p.atoms.enumerated() {
            if softAt.contains(i) { starts.append(position) }
            var scalar: Unicode.Scalar
            switch a.kind {
            case .char(let c): scalar = c
            case .lineBreak: scalar = "\n"
            case .box: continue
            }
            var r = a.run
            r.size = r.size ?? box.size
            if r.size == p.size { r.size = nil }
            if let last = runs.last, last.hasSameAttributes(as: r) {
                runs[runs.count - 1].t.unicodeScalars.append(scalar)
            } else {
                r.t = String(scalar)
                runs.append(r)
            }
            position += 1
        }
        let content = TextContent(font: box.font, size: p.size, color: box.color, align: p.align, dir: box.dir,
                                  lang: box.lang, runs: runs, breaks: starts)
        return TextPiece(content: content, frame: frame)
    }

    /// One line holding boxes, placed piece by piece (format.md §8.5.4
    /// "Drawing"): left to right in logical order, right to left in a
    /// right-to-left paragraph.
    mutating func place(_ p: MarkdownPlan.Paragraph, _ range: Range<Int>, baseline: Double, x0: Double, width: Double,
                        box: TextContent, measure: MarkdownMeasure, lineTop: Double, size: Double) {
        // Trailing white space is not drawn.
        var end = range.upperBound
        while end > range.lowerBound, let c = Self.scalar(p.atoms[end - 1]), Self.isWhite(c) { end -= 1 }
        enum Piece { case text(Range<Int>), box(TypesetFormula) }
        var pieces: [(Piece, Double)] = []
        var s = range.lowerBound
        for i in range.lowerBound..<end {
            if case .box(let f) = p.atoms[i].kind {
                if i > s { pieces.append((.text(s..<i), Self.width(of: p.atoms, s..<i, box: box, measure: measure))) }
                pieces.append((.box(f), f.math.renderSize?.w ?? 0))
                s = i + 1
            }
        }
        if end > s { pieces.append((.text(s..<end), Self.width(of: p.atoms, s..<end, box: box, measure: measure))) }
        let total = pieces.reduce(0) { $0 + $1.1 }
        let scalars = p.atoms.compactMap(Self.scalar)
        let rtl: Bool
        switch box.dir?.effective ?? .auto {
        case .rtl: rtl = true
        case .ltr: rtl = false
        default: rtl = BidiParagraph(scalars, direction: nil).level == 1
        }
        var x: Double
        switch p.kind == .displayMath ? .center : (p.align?.effective ?? .start) {
        case .left: x = x0
        case .right: x = x0 + width - total
        case .center: x = x0 + (width - total) / 2
        case .end: x = rtl ? x0 : x0 + width - total
        default: x = rtl ? x0 + width - total : x0
        }
        if p.kind == .displayMath, total > width { x = x0 }
        let ordered = rtl ? Array(pieces.reversed()) : pieces
        for (piece, w) in ordered {
            switch piece {
            case .box(let f):
                let h = f.math.renderSize?.h ?? 0
                boxes.append(Box(formula: f, frame: Rect(x: x, y: baseline - (h - f.depth), w: max(w, 0.001), h: max(h, 0.001))))
            case .text(let r):
                let runs = Self.runs(p.atoms, r)
                let pieceSize = runs.map { $0.size ?? box.size }.max() ?? size
                let content = TextContent(font: box.font, size: pieceSize, color: box.color, align: .left, dir: box.dir,
                                          lang: box.lang, runs: runs.map { r in
                                              var r = r
                                              r.size = r.size ?? box.size
                                              if r.size == pieceSize { r.size = nil }
                                              return r
                                          }, breaks: [])
                texts.append(TextPiece(content: content, frame: Rect(x: x, y: baseline - 0.95 * pieceSize,
                                                                     w: max(w, 0.001) + pieceSize, h: 1.2 * pieceSize)))
            }
            x += w
        }
        _ = lineTop
    }

    /// A list item's marker on its first line.
    mutating func marker(_ m: MarkdownPlan.Marker, baseline b: Double, size S: Double, column x0: Double, box: TextContent) {
        let s = box.size
        let paint = Paint(box.color)
        switch m {
        case .bullet(let ring):
            let r = 0.18 * S
            let c = Point(x: x0 - 0.8 * s, y: b - 0.32 * S)
            let points = (0..<24).map { k -> Point in
                let t = Double(k) / 24 * 2 * Double.pi
                return Point(x: c.x + r * cos(t), y: c.y + r * sin(t))
            }
            if ring {
                let w = S / 16
                let inner = points.map { Point(x: c.x + ($0.x - c.x) * (r - w / 2) / r, y: c.y + ($0.y - c.y) * (r - w / 2) / r) }
                shapes.append(DrawCommand(.path([Subpath(points: inner, closed: true)]), stroke: paint, lineWidth: w))
            } else {
                shapes.append(DrawCommand(.path([Subpath(points: points, closed: true)]), fill: paint))
            }
        case .task(let checked):
            let a = 0.66 * S
            let left = x0 - 0.35 * s - a, top = b - a
            let w = S / 14
            let sq = [Point(x: left + w / 2, y: top + w / 2), Point(x: left + a - w / 2, y: top + w / 2),
                      Point(x: left + a - w / 2, y: top + a - w / 2), Point(x: left + w / 2, y: top + a - w / 2)]
            shapes.append(DrawCommand(.path([Subpath(points: sq, closed: true)]), stroke: paint, lineWidth: w))
            if checked {
                let tick = [(0.18, 0.52), (0.42, 0.76), (0.82, 0.24)].map { Point(x: left + $0.0 * a, y: top + $0.1 * a) }
                shapes.append(DrawCommand(.path([Subpath(points: tick, closed: false)]), stroke: paint, lineWidth: S / 9))
            }
        case .ordered(let label):
            let w = (MarkdownPlan.Metrics.listIndent - 0.35) * s
            let content = TextContent(font: box.font, size: s, color: box.color, align: .right, dir: .ltr, lang: box.lang,
                                      runs: [TextRun(label)], breaks: [])
            texts.append(TextPiece(content: content, frame: Rect(x: x0 - 0.35 * s - w, y: b - 0.95 * s, w: w, h: 1.2 * s)))
        }
    }

    static func rect(x: Double, y: Double, w: Double, h: Double, paint: Paint) -> DrawCommand {
        DrawCommand(.path([Subpath(points: [Point(x: x, y: y), Point(x: x + w, y: y), Point(x: x + w, y: y + h),
                                            Point(x: x, y: y + h)], closed: true)]), fill: paint)
    }
}

extension MarkdownLayout {
    /// `content` (a Markdown box) laid out afresh at `frame`'s width, as a
    /// writer stores it (format.md §8.2.4): its `layout` (breaks where
    /// `measure` broke the lines, for this text) and the frame with the
    /// height of those lines (at least one line of the box size).
    public static func relayout(_ content: TextContent, frame: Rect, measure: MarkdownMeasure)
        -> (content: TextContent, frame: Rect) {
        var free = content
        free.layout = nil
        free.breaks = nil
        let laid = MarkdownLayout(free, frame: frame, measure: measure)
        var out = content
        out.breaks = nil
        out.layout = RenderedLayout(of: MarkdownText.hash(content.string), breaks: laid.breaks)
        let h = InkJSON.round3(max(laid.height, 1.2 * content.size))
        return (out, Rect(x: frame.x, y: frame.y, w: frame.w, h: h))
    }
}
