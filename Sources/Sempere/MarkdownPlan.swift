import Foundation

// MARK: - Rendered paragraphs (docs/format.md §8.5.4 "Rendered paragraphs")
//
// The font-independent half of drawing a Markdown box: every heading,
// paragraph, code block, display formula and thematic break becomes one
// rendered paragraph with its characters (styled as runs), its formula
// boxes, its column, gap, marker and fills. Line breaking and drawing, which
// need fonts, are SempereRender's (`MarkdownLayout`). Ported to
// `web/src/format/markdown.ts`.

/// A Markdown box turned into rendered paragraphs (format.md §8.5.4).
public struct MarkdownPlan: Sendable {
    /// A formula of the source, in the style it is drawn in.
    public struct Formula: Hashable, Sendable {
        public var latex: String
        public var display: Bool
        public var size: Double
        public var color: Color
    }

    /// One drawn element of a rendered paragraph.
    public struct Atom: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case char(Unicode.Scalar)
            /// A formula drawn as a box: its entry in `TextContent.math`.
            case box(TypesetFormula)
            case lineBreak
        }
        public var kind: Kind
        /// Source offset (Unicode scalar values) the stored breaks refer to.
        public var offset: Int
        /// The attributes of a character (its `t` is empty); a box's size and colour.
        public var run: TextRun
    }

    /// What is drawn left of a list item's first paragraph.
    public enum Marker: Hashable, Sendable {
        /// A disc, or a ring.
        case bullet(ring: Bool)
        case task(checked: Bool)
        /// An ordered item's number and delimiter (`3.`).
        case ordered(String)
    }

    public struct Paragraph: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case text, code, displayMath, rule }
        public var kind: Kind
        public var atoms: [Atom]
        /// The paragraph's own size: an empty line's.
        public var size: Double
        /// Bold throughout (headings).
        public var bold: Bool
        /// Left edge of the text column, from the frame's left edge.
        public var indent: Double
        /// Left edge of the column the containers leave (a code block's fill starts there).
        public var column: Double
        /// Space above the paragraph (blank source lines before it).
        public var gapBefore: Double
        /// Extra space above the first line and below the last (code blocks).
        public var pad: Double
        public var marker: Marker?
        public var align: TextContent.Alignment?
    }

    /// A block quote's bar: from the top of paragraph `first` to the bottom of `last`.
    public struct QuoteBar: Hashable, Sendable {
        /// Left edge, from the frame's left edge.
        public var x: Double
        public var first: Int
        public var last: Int
    }

    public let content: TextContent
    public let paragraphs: [Paragraph]
    public let quoteBars: [QuoteBar]
    /// Every formula of the source in the style it is drawn in, in order.
    public let formulas: [Formula]
    /// Link destinations (`MarkdownDocument.links`).
    public let links: [String]

    /// Sizes and lengths (format.md §8.5.4), as multiples of the box size.
    public enum Metrics {
        public static let headingScale: [Double] = [1.6, 1.4, 1.2, 1, 1, 1]
        public static let gap = 0.5
        public static let quoteIndent = 1.0
        public static let quoteBarX = 0.25
        public static let quoteBarWidth = 0.15
        public static let listIndent = 1.6
        public static let codeInset = 0.5
        public static let codePad = 0.25
    }

    public init(_ content: TextContent) {
        let doc = MarkdownDocument(content.string)
        var builder = Builder(content: content)
        builder.walk(doc.blocks, indent: 0, gap: 0, bulletDepth: 0)
        self.content = content
        paragraphs = builder.paragraphs
        quoteBars = builder.bars
        formulas = builder.formulas
        links = doc.links
    }

    private struct Builder {
        let content: TextContent
        var paragraphs: [Paragraph] = []
        var bars: [QuoteBar] = []
        var formulas: [Formula] = []
        /// The marker of the next paragraph made (a list item's first).
        var pendingMarker: Marker?

        init(content: TextContent) { self.content = content }

        var s: Double { content.size }

        func run(_ style: MarkdownStyle, size: Double, bold: Bool) -> TextRun {
            TextRun("", b: bold || style.contains(.bold), i: style.contains(.italic), u: style.contains(.link),
                    s: style.contains(.strike), color: style.contains(.link) ? MarkdownText.linkColor : nil,
                    size: size == content.size ? nil : size, font: style.contains(.code) ? .mono : nil)
        }

        /// Atoms of inline content at `size`: formulas with an entry are
        /// boxes, the others their source in `mono`.
        mutating func atoms(_ list: [MarkdownAtom], size: Double, bold: Bool) -> [Atom] {
            var out: [Atom] = []
            out.reserveCapacity(list.count)
            for a in list {
                let r = run(a.style, size: size, bold: bold)
                switch a.kind {
                case .char(let c): out.append(Atom(kind: .char(c), offset: a.offset, run: r))
                case .lineBreak: out.append(Atom(kind: .lineBreak, offset: a.offset, run: r))
                case .formula(let latex, let display):
                    let color = r.color ?? content.color
                    formulas.append(Formula(latex: latex, display: display, size: size, color: color))
                    if let f = MarkdownText.formula(in: content, latex: latex, display: display, size: size, color: color) {
                        out.append(Atom(kind: .box(f), offset: a.offset, run: r))
                    } else {
                        var mono = r
                        mono.font = .mono
                        for (k, c) in latex.unicodeScalars.enumerated() {
                            let off = k < a.latexOffsets.count ? a.latexOffsets[k] : a.offset
                            out.append(Atom(kind: c == "\n" ? .lineBreak : .char(c), offset: off, run: mono))
                        }
                    }
                }
            }
            return out
        }

        mutating func add(_ kind: Paragraph.Kind, _ atoms: [Atom], size: Double, bold: Bool = false, indent: Double,
                          column: Double, gap: Double, pad: Double = 0, align: TextContent.Alignment? = nil) {
            paragraphs.append(Paragraph(kind: kind, atoms: atoms, size: size, bold: bold, indent: indent, column: column,
                                        gapBefore: paragraphs.isEmpty ? 0 : gap, pad: pad, marker: pendingMarker,
                                        align: align ?? content.align))
            pendingMarker = nil
        }

        /// Paragraphs of `entries` in a column `indent` from the frame's
        /// left; `firstGap` is the gap above the first of them.
        mutating func walk(_ entries: [MarkdownEntry], indent: Double, gap firstGap: Double, bulletDepth: Int) {
            for (k, e) in entries.enumerated() {
                let gap = k == 0 ? firstGap : (e.blankBefore ? Metrics.gap * s : 0)
                switch e.block {
                case .paragraph(let list):
                    add(.text, atoms(list, size: s, bold: false), size: s, indent: indent, column: indent, gap: gap)
                case .heading(let level, let list):
                    let size = InkJSON.round3(s * Metrics.headingScale[max(0, min(5, level - 1))])
                    add(.text, atoms(list, size: size, bold: true), size: size, bold: true, indent: indent, column: indent,
                        gap: gap)
                case .code(let list):
                    var r = run(.code, size: s, bold: false)
                    r.font = .mono
                    let a = list.map { m -> Atom in
                        if case .char(let c) = m.kind { return Atom(kind: .char(c), offset: m.offset, run: r) }
                        return Atom(kind: .lineBreak, offset: m.offset, run: r)
                    }
                    add(.code, a, size: s, indent: indent + Metrics.codeInset * s, column: indent, gap: gap,
                        pad: Metrics.codePad * s, align: .start)
                case .math(let m):
                    let a = atoms([m], size: s, bold: false)
                    var boxed = false
                    if a.count == 1, case .box = a[0].kind { boxed = true }
                    add(boxed ? .displayMath : .text, a, size: s, indent: indent, column: indent, gap: gap, align: .center)
                case .rule:
                    add(.rule, [], size: s, indent: indent, column: indent, gap: gap)
                case .quote(let inner):
                    let first = paragraphs.count
                    walk(inner, indent: indent + Metrics.quoteIndent * s, gap: gap, bulletDepth: bulletDepth)
                    if paragraphs.count > first {
                        bars.append(QuoteBar(x: indent + Metrics.quoteBarX * s, first: first, last: paragraphs.count - 1))
                    }
                case .list(let list):
                    for (n, item) in list.items.enumerated() {
                        let itemGap = n == 0 ? gap : (item.blankBefore ? Metrics.gap * s : 0)
                        if let task = item.task {
                            pendingMarker = .task(checked: task)
                        } else if list.bullet != nil {
                            pendingMarker = .bullet(ring: bulletDepth % 2 == 1)
                        } else {
                            let number = list.start.addingReportingOverflow(n)
                            let value = number.overflow ? list.start : number.partialValue
                            pendingMarker = .ordered("\(value)\(list.delimiter.map { String($0) } ?? ".")")
                        }
                        let inner = indent + Metrics.listIndent * s
                        let before = paragraphs.count
                        walk(item.blocks, indent: inner, gap: itemGap, bulletDepth: bulletDepth + (list.bullet != nil ? 1 : 0))
                        if paragraphs.count == before {
                            // An empty item still shows its marker.
                            add(.text, [], size: s, indent: inner, column: inner, gap: itemGap)
                        }
                    }
                }
            }
        }
    }
}
