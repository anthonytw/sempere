import Foundation
import Sempere

// The font-independent part of text layout (format.md §8.5.3), shared by
// every layout engine: the CLI's `DefaultTextShaper` and the app's CoreText
// layout. Line ranges, `breaks`, vertical metrics, paragraph direction and
// alignment are computed here once, so two engines with the same breaks put
// the same characters on the same lines at the same heights; only glyph
// widths (and so horizontal positions within a line) are the engine's.

/// Turning laid-out lines into `breaks` and back (format.md §8.2.4, §8.5.3).
public enum TextLineBreaks {
    /// The stored `breaks` a renderer may cut lines at: `validBreaks` (strictly
    /// increasing, inside paragraphs, never right after a `\n`) whose every
    /// offset is also a grapheme cluster boundary; nil otherwise (the renderer
    /// then breaks the lines itself).
    public static func usable(_ content: TextContent) -> [Int]? {
        usable(content, scalars: content.runs.flatMap { $0.t.unicodeScalars.map(\.value) })
    }

    static func usable(_ content: TextContent, scalars: [UInt32]) -> [Int]? {
        guard let valid = content.validBreaks else { return nil }
        guard !valid.isEmpty else { return valid }
        let clusters = Set(GraphemeClusters.boundaries(scalars))
        return valid.allSatisfy({ clusters.contains($0) }) ? valid : nil
    }

    /// `breaks` for lines starting at `starts` (scalar offsets into the item's
    /// text, any order): every start that is not 0 and does not follow a `\n`
    /// (those are paragraph starts, not soft breaks), inside the text, once.
    public static func breaks(lineStarts starts: [Int], in content: TextContent) -> [Int] {
        let scalars = Array(content.string.unicodeScalars)
        var out = Set<Int>()
        for s in starts where s > 0 && s < scalars.count && scalars[s - 1] != "\n" && scalars[s] != "\n" {
            out.insert(s)
        }
        return out.sorted()
    }

    /// The `breaks` of laid-out text: where each of its lines starts.
    public static func breaks(of shaped: ShapedText, content: TextContent) -> [Int] {
        breaks(lineStarts: shaped.lines.map(\.range.lowerBound), in: content)
    }
}

/// A text box's text prepared for a layout engine (format.md §8.5.3): the
/// characters with their runs, the string handed to a platform engine (tabs
/// as four spaces, so a tab advances like four spaces everywhere), offsets
/// between the two, and the font-independent line geometry.
public struct LayoutText: Sendable {
    public let content: TextContent
    /// The item's text, one entry per Unicode scalar value.
    public let scalars: [Unicode.Scalar]
    /// The index in `content.runs` of each scalar's run.
    public let runOfScalar: [Int]
    /// The text a platform engine lays out: the item's text with every tab
    /// replaced by four spaces.
    public let layoutString: String
    /// The UTF-16 offset in `layoutString` where each scalar starts, plus the
    /// end (`scalars.count + 1` entries).
    public let utf16Offsets: [Int]

    /// Spaces a tab stands for (format.md §8.5.3).
    public static let tabSpaces = 4

    public init(_ content: TextContent) {
        self.content = content
        var scalars: [Unicode.Scalar] = []
        var runs: [Int] = []
        for (r, run) in content.runs.enumerated() {
            for s in run.t.unicodeScalars { scalars.append(s); runs.append(r) }
        }
        self.scalars = scalars
        runOfScalar = runs
        var layout = String.UnicodeScalarView()
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count + 1)
        var u = 0
        for s in scalars {
            offsets.append(u)
            if s == "\t" {
                for _ in 0..<Self.tabSpaces { layout.append(" ") }
                u += Self.tabSpaces
            } else {
                layout.append(s)
                u += s.utf16.count
            }
        }
        offsets.append(u)
        utf16Offsets = offsets
        layoutString = String(layout)
    }

    /// The scalar offset of UTF-16 offset `u` in `layoutString`; an offset
    /// inside a scalar (a tab's spaces, a surrogate pair) rounds up to the
    /// next scalar.
    public func scalarOffset(utf16 u: Int) -> Int {
        var lo = 0, hi = utf16Offsets.count - 1
        guard u > 0 else { return 0 }
        guard u < utf16Offsets[hi] else { return scalars.count }
        // The first scalar starting at or after u.
        while lo < hi {
            let mid = (lo + hi) / 2
            if utf16Offsets[mid] < u { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// `breaks` from the UTF-16 offsets (in `layoutString`) where a platform
    /// engine started its lines (TextKit line fragments, CoreText lines).
    public func breaks(lineStartsUTF16 starts: [Int]) -> [Int] {
        TextLineBreaks.breaks(lineStarts: starts.map(scalarOffset(utf16:)), in: content)
    }

    /// The UTF-16 range in `layoutString` of a scalar range.
    public func utf16Range(_ r: Range<Int>) -> Range<Int> {
        utf16Offsets[r.lowerBound]..<utf16Offsets[r.upperBound]
    }

    /// The paragraphs (scalar ranges without their `\n`), at least one.
    public var paragraphs: [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for (i, s) in scalars.enumerated() where s == "\n" {
            out.append(start..<i)
            start = i + 1
        }
        out.append(start..<scalars.count)
        return out
    }

    /// The size of run `r` (its own, else the box's).
    public func size(ofRun r: Int) -> Double { content.runs[r].size ?? content.size }

    /// Whether paragraph `p` is right to left: `dir`, or for `auto` its first
    /// strong character (UAX #9 P2–P3), left to right without one.
    public func isRightToLeft(_ p: Range<Int>) -> Bool {
        switch content.dir?.effective ?? .auto {
        case .rtl: return true
        case .ltr: return false
        default: return BidiParagraph(scalars[p].map(\.value), direction: nil).level == 1
        }
    }

    static func isWhiteSpace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }

    /// One line of the layout, font-independent.
    public struct Line: Hashable, Sendable {
        /// The line's characters (scalar offsets), trailing white space included.
        public var range: Range<Int>
        /// The characters drawn: `range` without trailing white space.
        public var drawn: Range<Int>
        /// The line size `S`: the largest run size on it (an empty line: the
        /// size of the run of its line feed, else the box's).
        public var size: Double
        /// Top and baseline (`top + 0.95 S`), page coordinates.
        public var top: Double
        public var baseline: Double
        /// Its paragraph is right to left.
        public var rtl: Bool
        /// Index of its paragraph.
        public var paragraph: Int

        /// Bottom of the line (`top + 1.2 S`).
        public var bottom: Double { top + 1.2 * size }
    }

    /// The line ranges for `breaks` (already checked, `TextLineBreaks.usable`):
    /// each paragraph cut exactly there; an empty paragraph is one empty line.
    public func lineRanges(breaks: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var k = 0
        let sorted = breaks.sorted()
        for p in paragraphs {
            var s = p.lowerBound
            while k < sorted.count, sorted[k] <= p.lowerBound { k += 1 }
            while k < sorted.count, sorted[k] < p.upperBound {
                out.append(s..<sorted[k])
                s = sorted[k]
                k += 1
            }
            out.append(s..<p.upperBound)
        }
        return out
    }

    /// The lines for `ranges` (every line of the text, in order, as from
    /// `lineRanges`), stacked from `top` with the format's fixed vertical
    /// metrics: each line `1.2 S` high, its baseline `0.95 S` below its top.
    public func lines(_ ranges: [Range<Int>], top: Double) -> [Line] {
        let paras = paragraphs
        let rtl = paras.map(isRightToLeft)
        var out: [Line] = []
        var y = top
        var p = 0
        for r in ranges {
            while p + 1 < paras.count, r.lowerBound > paras[p].upperBound { p += 1 }
            let size: Double
            if r.isEmpty {
                size = r.lowerBound < scalars.count ? self.size(ofRun: runOfScalar[r.lowerBound]) : content.size
            } else {
                size = r.map { self.size(ofRun: runOfScalar[$0]) }.max() ?? content.size
            }
            var end = r.upperBound
            while end > r.lowerBound, Self.isWhiteSpace(scalars[end - 1]) { end -= 1 }
            out.append(Line(range: r, drawn: r.lowerBound..<end, size: size, top: y, baseline: y + 0.95 * size,
                            rtl: rtl[min(p, rtl.count - 1)], paragraph: p))
            y += 1.2 * size
        }
        return out
    }

    /// The height of `lines` (from the first top to the last bottom); the
    /// box's line height for none.
    public static func height(of lines: [Line]) -> Double {
        guard let first = lines.first, let last = lines.last else { return 0 }
        return last.bottom - first.top
    }

    /// The left edge of a line `width` wide in `frame` (format.md §8.5.3):
    /// `start` is the left for a left-to-right paragraph and the right for a
    /// right-to-left one, `end` the opposite.
    public func lineX(width: Double, frame: Rect, rtl: Bool) -> Double {
        switch content.align?.effective ?? .start {
        case .left: return frame.x
        case .right: return frame.x + frame.w - width
        case .center: return frame.x + (frame.w - width) / 2
        case .end: return rtl ? frame.x : frame.x + frame.w - width
        default: return rtl ? frame.x + frame.w - width : frame.x
        }
    }

    /// The Unicode script of a scalar (`Latin`, `Han`, `Arabic`, …), for reports.
    public static func script(of scalar: Unicode.Scalar) -> String { UnicodeProperties.script[scalar.value] }
}

extension TextLineBreaks {
    /// `content` laid out afresh at `frame`'s width by `shaper`, as a writer
    /// stores it (format.md §8.2.4): its `breaks` where `shaper` broke the
    /// lines, and `frame` with the height those lines take (at least one line
    /// of the box's size).
    public static func relayout(_ content: TextContent, frame: Rect, shaper: any TextShaper) throws
        -> (content: TextContent, frame: Rect) {
        var free = content
        free.breaks = nil
        let shaped = try shaper.shape(free, frame: frame)
        var out = content
        out.breaks = breaks(of: shaped, content: content)
        let layout = LayoutText(content)
        let height = LayoutText.height(of: layout.lines(layout.lineRanges(breaks: out.breaks ?? []), top: 0))
        let h = InkJSON.round3(max(height, 1.2 * content.size))
        return (out, Rect(x: frame.x, y: frame.y, w: frame.w, h: h))
    }
}
