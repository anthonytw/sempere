import Foundation
import Sempere
import SempereRender

/// The box-level style the editor keeps beside a text box's text (format.md §8.2.4).
public struct TextBoxStyle: Equatable, Sendable {
    public var font: TextContent.Font
    public var size: Double
    public var color: Sempere.Color
    public var align: TextContent.Alignment?
    public var dir: TextContent.Direction?

    public init(_ content: TextContent) {
        font = content.font; size = content.size; color = content.color; align = content.align; dir = content.dir
    }
}

/// The rules of editing and laying out a text box that need no TextKit or CoreText: the app's `TextBoxEditing.swift`
/// (the attributed string the text view holds) and `TextBoxLayout.swift` (TextKit breaks, CoreText runs and drawing)
/// call these. Pure, tested on Linux (`TextBoxRulesTests`).
public enum TextBoxRules {
    // MARK: Fonts and paragraphs

    /// The concrete family written to `family` (informational, format.md §8.2.4).
    public static func family(_ generic: TextContent.Font) -> String {
        switch generic.effective {
        case .serif: return "New York"
        case .mono: return "SF Mono"
        default: return "SF Pro"
        }
    }

    /// How the editor's paragraph is aligned and directed for a box's `align` and `dir` (an approximation of the
    /// format's rules; the committed layout applies them exactly).
    public struct ParagraphShape: Equatable, Sendable {
        public enum Alignment: Sendable { case center, left, right, natural }
        public enum Direction: Sendable { case rightToLeft, leftToRight, natural }
        public var alignment: Alignment
        public var direction: Direction
    }

    public static func paragraphShape(align: TextContent.Alignment?, dir: TextContent.Direction?) -> ParagraphShape {
        let rtl = dir?.effective == .rtl
        let alignment: ParagraphShape.Alignment
        switch align?.effective ?? .start {
        case .center: alignment = .center
        case .left: alignment = .left
        case .right: alignment = .right
        case .end: alignment = rtl ? .left : .right
        default: alignment = .natural
        }
        let direction: ParagraphShape.Direction = rtl ? .rightToLeft : (dir?.effective == .ltr ? .leftToRight : .natural)
        return ParagraphShape(alignment: alignment, direction: direction)
    }

    /// The line height the editor gives a paragraph of `size` (lines 1.2 × the size apart, as the committed text,
    /// format.md §8.5.3).
    public static func lineHeight(size: Double) -> Double { 1.2 * size }

    // MARK: What an edit writes

    /// The keyboard's language, when a box without one may take it: not empty, not the emoji or dictation pseudo-keyboards.
    public static func languageToTake(from keyboard: String?) -> String? {
        guard let lang = keyboard, !lang.isEmpty, lang != "emoji", lang != "dictation" else { return nil }
        return lang
    }

    /// The size override a run carries, from the point size of its font: none when it is the box's size (at the stored
    /// precision), not above zero or above the format's limit.
    public static func sizeOverride(pointSize: Double, style: TextBoxStyle) -> Double? {
        let size = InkJSON.round3(pointSize)
        return size != InkJSON.round3(style.size) && size > 0 && size <= TextContent.Limits.size ? size : nil
    }

    /// The color override a run carries: none when it is the box's color.
    public static func colorOverride(_ color: Sempere.Color, style: TextBoxStyle) -> Sempere.Color? {
        color != style.color ? color : nil
    }

    /// The box as it is written after editing, before TextKit's breaks and the frame's height are added: `runs`, the
    /// box style, the language (`lang` if the box had none: the keyboard's), the concrete family. Fields the editor
    /// does not show (`extra`) are kept from `original`.
    public static func content(runs: [TextRun], style: TextBoxStyle, original: TextContent?, keyboardLanguage: String?) -> TextContent {
        var content = original ?? TextContent(size: style.size, color: style.color, runs: [])
        content.font = style.font
        content.size = style.size
        content.color = style.color
        content.align = style.align
        content.dir = style.dir
        content.family = family(style.font)
        if content.lang == nil, let lang = languageToTake(from: keyboardLanguage) { content.lang = lang }
        content.runs = runs
        return content
    }

    /// `content` with the `breaks` its lines were cut at and `frame` with the height they take (at least one line of
    /// the box's size): what the app writes after an edit or a resize (the breaks come from TextKit).
    public static func relaid(_ content: TextContent, layout: LayoutText, breaks: [Int], frame: Rect) -> (content: TextContent, frame: Rect) {
        var out = content
        out.breaks = breaks
        let lines = layout.lines(layout.lineRanges(breaks: breaks), top: 0)
        let h = InkJSON.round3(max(LayoutText.height(of: lines), 1.2 * content.size))
        return (out, Rect(x: frame.x, y: frame.y, w: frame.w, h: h))
    }

    /// The runs of `runs` restyled for the box style `new`: an override equal to the new box value is no override.
    public static func restyled(_ runs: [TextRun], to new: TextBoxStyle) -> [TextRun] {
        runs.map { run in
            var r = run
            if r.size == new.size { r.size = nil }
            if r.color == new.color { r.color = nil }
            return r
        }
    }

    /// The Markdown box written after editing `source` (before its formulas are typeset and it is laid out): the
    /// source as one run, the box style, the keyboard's language if the box had none; fields the editor does not show
    /// (`extra`, typeset formulas still used) kept from `original`. Nil when the source breaks the format's limits.
    public static func markdownContent(_ source: String, style: TextBoxStyle, original: TextContent?,
                                       keyboardLanguage: String?) -> TextContent? {
        var content: TextContent
        do {
            if let original, original.isMarkdown {
                content = try MarkdownText.replacingSource(original, with: source)
            } else {
                content = try MarkdownText.content(source)
                if let original { content.lang = original.lang; content.extra = original.extra }
            }
        } catch {
            return nil
        }
        content.font = style.font == .serif ? .serif : .sans
        content.family = family(content.font)
        content.size = style.size
        content.color = style.color
        content.align = style.align
        content.dir = style.dir
        if content.lang == nil, let lang = languageToTake(from: keyboardLanguage) { content.lang = lang }
        let used = MarkdownText.usedFormulas(content)
        content.math = used.isEmpty ? nil : used
        return content
    }

    /// The smallest change (UTF-16) that turns `old` into `new`: the range of `old` to replace and its replacement
    /// (common prefix and suffix kept, never splitting a surrogate pair).
    public static func changedRange(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if p > 0, UTF16.isLeadSurrogate(a[p - 1]) { p -= 1 }
        if s > 0, a.count - s - 1 >= p, UTF16.isLeadSurrogate(a[a.count - s - 1]) { s -= 1 }
        let replacement = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        return (NSRange(location: p, length: a.count - s - p), replacement)
    }

    // MARK: Laid-out text

    /// The decorations of a run (format.md §8.5.3): `lineSize / 18` thick, the underline 0.12 × the run's size below
    /// the baseline, the strikethrough 0.3 × above it, over the run's `left ... right`.
    public static func decorations(underline: Bool, strikethrough: Bool, left: Double, right: Double, baseline: Double,
                                   lineSize: Double, runSize: Double, color: Sempere.Color) -> [TextDecoration] {
        let t = lineSize / 18
        var out: [TextDecoration] = []
        if underline {
            out.append(TextDecoration(x: left, y: baseline + 0.12 * runSize - t / 2, width: right - left, height: t, color: color))
        }
        if strikethrough {
            out.append(TextDecoration(x: left, y: baseline - 0.3 * runSize - t / 2, width: right - left, height: t, color: color))
        }
        return out
    }

    /// One laid-out line as `extent` reads it.
    public struct ExtentLine: Sendable {
        public var x: Double, width: Double, baseline: Double, size: Double
        public init(x: Double, width: Double, baseline: Double, size: Double) {
            self.x = x; self.width = width; self.baseline = baseline; self.size = size
        }
    }

    /// What the drawn text covers: the frame, and lines that overflow it (text is never clipped, format.md §8.2.4).
    /// `bottom` is the bottom of the last line (the frame's top without lines).
    public static func extent(frame: Rect, bottom: Double, lines: [ExtentLine]) -> Rect {
        var x0 = frame.x, x1 = frame.x + frame.w, y1 = max(frame.y + frame.h, bottom)
        for line in lines where line.width > 0 {
            x0 = min(x0, line.x)
            x1 = max(x1, line.x + line.width)
            y1 = max(y1, line.baseline + 0.5 * line.size)   // descenders, decorations
        }
        return Rect(x: x0, y: frame.y, w: x1 - x0, h: y1 - frame.y)
    }

    /// The characters each glyph of a run stands for, for search and copying in exports: they go on the first glyph
    /// of their cluster (the others get ""). `indices` are the glyphs' string indices (UTF-16 in the layout string),
    /// `runEnd` the end of the run's string range.
    public static func clusterTexts(indices: [Int], runEnd: Int, layout: LayoutText) -> [String] {
        let starts = Array(Set(indices)).sorted()
        var assigned = Set<Int>()
        var texts: [String] = []
        for i in indices {
            let s = layout.scalarOffset(utf16: i)
            guard assigned.insert(s).inserted else { texts.append(""); continue }
            let next = starts.first { $0 > i } ?? runEnd
            let e = max(s, layout.scalarOffset(utf16: next))
            texts.append(String(String.UnicodeScalarView(layout.scalars[s..<min(e, layout.scalars.count)])))
        }
        return texts
    }
}
