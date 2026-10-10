import Foundation

// MARK: - Markdown text boxes (docs/format.md §8.2.4 "Markdown text", §8.5.4)
//
// A text box whose `markup` is `markdown` holds Markdown source as its text
// (one run), so readers that predate Markdown boxes draw and search the
// source as it is. The rendering is derived from the source by the shared
// parser (`MarkdownDocument`), plus the writer's line breaks of the rendered
// text (`layout`) and typeset formulas (`math`) that renderers without a
// typesetter draw.

/// How a text box's text is marked up (format.md §8.2.4). An open set: an
/// unknown value is kept and the runs are drawn as styled text.
public struct TextMarkup: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Markdown source with LaTeX math (format.md §8.5.4).
    public static let markdown = TextMarkup(rawValue: "markdown")
}

/// A Markdown box's line breaks of its rendered text (format.md §8.2.4
/// `layout`): source offsets where soft-wrapped lines start, for the text
/// whose hash is `of`.
public struct RenderedLayout: Hashable, Sendable, Codable {
    /// `MarkdownText.hash` of the text the breaks were computed for.
    public var of: String
    /// Strictly increasing offsets in Unicode scalar values of the source.
    public var breaks: [Int]
    /// Unknown fields, re-emitted unchanged.
    public var extra: [String: JSONValue]

    public init(of: String, breaks: [Int], extra: [String: JSONValue] = [:]) {
        self.of = of; self.breaks = breaks; self.extra = extra
    }

    /// Why the value breaks format.md §8.2.4, or nil.
    var violation: String? {
        guard of.utf8.count == 8, of.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return "layout hash is not 8 lowercase hexadecimal digits"
        }
        var last = -1
        for b in breaks {
            guard b > last else { return "layout breaks are not strictly increasing" }
            last = b
        }
        return nil
    }

    static let knownKeys: Set<String> = ["of", "breaks"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        of = try c.decode(String.self, "of")
        var u = try c.nestedUnkeyedContainer(forKey: AnyKey("breaks"))
        if let n = u.count, n > TextContent.Limits.breaks {
            throw DecodingError.dataCorruptedError(in: u, debugDescription: "more than \(TextContent.Limits.breaks) layout breaks")
        }
        var out: [Int] = []
        while !u.isAtEnd { out.append(try u.decode(Int.self)) }
        breaks = out
        extra = try c.extra(excluding: Self.knownKeys)
        if let why = violation { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why)) }
    }

    public func encode(to encoder: Encoder) throws {
        if let why = violation { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why)) }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(of, "of")
        try c.encode(breaks, "breaks")
        try c.encodeExtra(extra, excluding: Self.knownKeys)
    }
}

/// One typeset formula of a Markdown box (format.md §8.2.4 `math`): a math
/// value (§8.2.8) with its render, and the depth of its baseline.
public struct TypesetFormula: Hashable, Sendable, Codable {
    /// The formula as typeset; `render` and `renderSize` are present.
    public var math: MathContent
    /// Points from the bottom of the render's page up to the baseline.
    public var depth: Double

    public init(math: MathContent, depth: Double) { self.math = math; self.depth = depth }

    /// Why the entry breaks format.md §8.2.4, or nil.
    var violation: String? {
        if let why = math.validationError { return why }
        guard math.render != nil, let size = math.renderSize else { return "typeset formula without a render" }
        guard depth.isFinite, InkJSON.round3(depth) >= 0, InkJSON.round3(depth) <= InkJSON.round3(size.h) else {
            return "formula depth out of range"
        }
        return nil
    }

    /// True when this entry draws the formula `latex` in that style, size and colour.
    public func draws(latex: String, display: Bool, size: Double, color: Color) -> Bool {
        math.latex == latex && math.display == display && InkJSON.round3(math.size) == InkJSON.round3(size)
            && math.color == color
    }

    public init(from decoder: Decoder) throws {
        var m = try MathContent(from: decoder)
        guard case .number(let d)? = m.extra.removeValue(forKey: "depth") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "typeset formula without a depth"))
        }
        math = m
        depth = d
        if let why = violation { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: why)) }
    }

    public func encode(to encoder: Encoder) throws {
        if let why = violation { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: why)) }
        var m = math
        m.extra["depth"] = .number(InkJSON.round3(depth))
        try m.encode(to: encoder)
    }
}

/// Markdown boxes as a whole: the hash that ties `layout` to its text, the
/// plain text, building a box.
public enum MarkdownText {
    /// FNV-1a 32-bit of the UTF-8 bytes of `text`, as 8 lowercase hex
    /// digits (format.md §8.2.4 `layout.of`).
    public static func hash(_ text: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in text.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The colour of link text (format.md §8.5.4).
    public static let linkColor = Color(r: 0x1F, g: 0x6F, b: 0xEB)

    /// The text of `content` as search and reports see it: a Markdown box's
    /// plain text (format.md §8.5.4), any other box's text.
    public static func searchText(_ content: TextContent) -> String {
        content.isMarkdown ? MarkdownDocument(content.string).plainText : content.string
    }

    /// A Markdown box for `source` in the box style `style` (format.md
    /// §8.2.4): NFC, `\r\n` and `\r` as `\n`, one run without overrides, no
    /// `breaks`; the body family is `sans` or `serif` (a `mono` style is
    /// `sans`). Bold and italic of `style` do not apply (Markdown says it).
    public static func content(_ source: String, style: TextStyle = TextStyle()) throws -> TextContent {
        let normalized = NoteOps.withoutControls(source.replacingOccurrences(of: "\r\n", with: "\n"))
            .precomposedStringWithCanonicalMapping
        let content = TextContent(font: style.font == .serif ? .serif : .sans, size: style.size, color: style.color,
                                  align: style.align, lang: style.lang, runs: normalized.isEmpty ? [] : [TextRun(normalized)],
                                  markup: .markdown)
        if let why = content.limitViolation { throw AttachmentOpsError.invalidText(why) }
        return content
    }

    /// `content` with its source replaced by `source` (normalised like
    /// `content(_:style:)`), its layout dropped (it belonged to the old
    /// text) and its formulas kept (they match by formula, so the ones still
    /// in the source still draw).
    public static func replacingSource(_ content: TextContent, with source: String) throws -> TextContent {
        let normalized = NoteOps.withoutControls(source.replacingOccurrences(of: "\r\n", with: "\n"))
            .precomposedStringWithCanonicalMapping
        var out = content
        out.runs = normalized.isEmpty ? [] : [TextRun(normalized)]
        out.breaks = nil
        out.markup = .markdown
        out.layout = nil
        if let why = out.limitViolation { throw AttachmentOpsError.invalidText(why) }
        return out
    }

    /// The typeset formula drawing `latex` in that style, size and colour, if any.
    public static func formula(in content: TextContent, latex: String, display: Bool, size: Double,
                               color: Color) -> TypesetFormula? {
        content.math?.first { $0.draws(latex: latex, display: display, size: size, color: color) }
    }

    /// `content`'s formulas that its current source still draws, in order,
    /// each once (what a writer keeps).
    public static func usedFormulas(_ content: TextContent) -> [TypesetFormula] {
        guard let math = content.math, !math.isEmpty else { return [] }
        let plan = MarkdownPlan(content)
        var used: [TypesetFormula] = []
        for f in plan.formulas {
            if let t = formula(in: content, latex: f.latex, display: f.display, size: f.size, color: f.color),
               !used.contains(t) {
                used.append(t)
            }
        }
        return used
    }
}
