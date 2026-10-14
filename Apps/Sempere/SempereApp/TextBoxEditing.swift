import Foundation
import Sempere
import SempereRender
import UIKit

/// A text box as the editor's text view holds it, and back (format.md
/// §8.2.4, task E2): runs ↔ attributed string. Bold and italic are the
/// font's traits (so the system's ⌘B / ⌘I and the edit menu work), sizes the
/// font's point size, colour, underline and strikethrough their attributes;
/// a run's language and unknown fields ride along in attributes of their
/// own, so editing a box never drops what it does not show. Pure, tested.
enum TextBoxEditing {
    /// A run's `lang` override.
    static let langKey = NSAttributedString.Key("io.github.anthonytw.sempere.lang")
    /// A run's unknown fields (`RunExtra`).
    static let extraKey = NSAttributedString.Key("io.github.anthonytw.sempere.extra")
    /// Bold or italic asked for on a family without that face (drawn synthetically).
    static let boldKey = NSAttributedString.Key("io.github.anthonytw.sempere.bold")
    static let italicKey = NSAttributedString.Key("io.github.anthonytw.sempere.italic")

    /// Unknown run fields, boxed for an attribute.
    final class RunExtra: NSObject {
        let extra: [String: JSONValue]
        init(_ extra: [String: JSONValue]) { self.extra = extra }
        override func isEqual(_ object: Any?) -> Bool { (object as? RunExtra)?.extra == extra }
        override var hash: Int { extra.hashValue }
    }

    /// The box-level style the editor keeps beside the text (format.md §8.2.4).
    struct BoxStyle: Equatable {
        var font: TextContent.Font
        var size: Double
        var color: Sempere.Color
        var align: TextContent.Alignment?
        var dir: TextContent.Direction?

        init(_ content: TextContent) {
            font = content.font; size = content.size; color = content.color; align = content.align; dir = content.dir
        }
    }

    /// The paragraph style shown for `align` and `dir` (the editor's
    /// approximation; the committed layout applies the format's rules).
    static func paragraphStyle(align: TextContent.Alignment?, dir: TextContent.Direction?, lineHeight: Double) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let rtl = dir?.effective == .rtl
        switch align?.effective ?? .start {
        case .center: p.alignment = .center
        case .left: p.alignment = .left
        case .right: p.alignment = .right
        case .end: p.alignment = rtl ? .left : .right
        default: p.alignment = .natural
        }
        if dir?.effective == .rtl { p.baseWritingDirection = .rightToLeft } else if dir?.effective == .ltr {
            p.baseWritingDirection = .leftToRight
        } else {
            p.baseWritingDirection = .natural
        }
        p.lineBreakMode = .byWordWrapping
        p.lineBreakStrategy = []
        p.hyphenationFactor = 0
        // Lines 1.2 × the size apart, as the committed text (format.md §8.5.3).
        p.minimumLineHeight = CGFloat(1.2 * lineHeight)
        p.maximumLineHeight = CGFloat(1.2 * lineHeight)
        return p
    }

    /// The attributes of a run.
    static func attributes(_ run: TextRun, style: BoxStyle) -> [NSAttributedString.Key: Any] {
        let size = run.size ?? style.size
        let f = TextBoxFonts.font(style.font, size: size, bold: run.b, italic: run.i)
        var a: [NSAttributedString.Key: Any] = [
            .font: f.font, .foregroundColor: (run.color ?? style.color).uiColor,
            .paragraphStyle: paragraphStyle(align: style.align, dir: style.dir, lineHeight: size),
        ]
        if run.u { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.s { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let lang = run.lang { a[langKey] = lang }
        if !run.extra.isEmpty { a[extraKey] = RunExtra(run.extra) }
        if f.syntheticBold { a[boldKey] = true }
        if f.syntheticItalic { a[italicKey] = true }
        return a
    }

    /// The text view's text for `content` (real tabs and line feeds).
    static func attributed(_ content: TextContent) -> NSAttributedString {
        let style = BoxStyle(content)
        let out = NSMutableAttributedString()
        for run in content.runs where !run.t.isEmpty {
            out.append(NSAttributedString(string: run.t, attributes: attributes(run, style: style)))
        }
        return out
    }

    /// What typing into an empty box (or at a caret without neighbours) gets.
    static func typingAttributes(_ style: BoxStyle) -> [NSAttributedString.Key: Any] {
        attributes(TextRun(""), style: style)
    }

    /// The runs of an edited text, against the box's style: overrides only
    /// where a run differs from the box (sizes at the stored precision),
    /// normalised as writers store them (`NoteOps.normalizedRuns`).
    static func runs(from text: NSAttributedString, style: BoxStyle) -> [TextRun] {
        var out: [TextRun] = []
        let ns = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { a, range, _ in
            let t = ns.substring(with: range)
            let font = a[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            var run = TextRun(t)
            run.b = traits.contains(.traitBold) || (a[boldKey] as? Bool ?? false)
            run.i = traits.contains(.traitItalic) || (a[italicKey] as? Bool ?? false)
            run.u = (a[.underlineStyle] as? Int ?? 0) != 0
            run.s = (a[.strikethroughStyle] as? Int ?? 0) != 0
            if let font {
                let size = InkJSON.round3(Double(font.pointSize))
                if size != InkJSON.round3(style.size), size > 0, size <= TextContent.Limits.size { run.size = size }
            }
            if let color = a[.foregroundColor] as? UIColor {
                let c = Sempere.Color(color)
                if c != style.color { run.color = c }
            }
            run.lang = a[langKey] as? String
            run.extra = (a[extraKey] as? RunExtra)?.extra ?? [:]
            out.append(run)
        }
        return NoteOps.normalizedRuns(out)
    }

    /// The box as it is written after editing: the runs of `text`, the box
    /// style, the language (`lang` if the box had none: the keyboard's), the
    /// concrete family, `breaks` from TextKit at `frame`'s width, and the
    /// frame with the height of its lines. Fields the editor does not show
    /// (`extra`) are kept from `original`.
    static func content(from text: NSAttributedString, style: BoxStyle, original: TextContent?, keyboardLanguage: String?,
                        frame: Rect) -> (content: TextContent, frame: Rect) {
        var content = original ?? TextContent(size: style.size, color: style.color, runs: [])
        content.font = style.font
        content.size = style.size
        content.color = style.color
        content.align = style.align
        content.dir = style.dir
        content.family = TextBoxFonts.family(style.font)
        if content.lang == nil, let lang = keyboardLanguage, !lang.isEmpty, lang != "emoji", lang != "dictation" { content.lang = lang }
        content.runs = runs(from: text, style: style)
        return TextKitBreaks.relayout(content, frame: frame)
    }

    // MARK: Style changes (selection or typing attributes)

    /// A change the style bar makes to selected text or to what is typed next.
    enum Change {
        case bold, italic, underline, strikethrough
        case size(Double)
        case color(Sempere.Color)
    }

    /// `attributes` with `change` applied (`on`: whether a toggle turns on).
    static func apply(_ change: Change, on: Bool, to attributes: [NSAttributedString.Key: Any],
                      style: BoxStyle) -> [NSAttributedString.Key: Any] {
        var a = attributes
        let font = a[.font] as? UIFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        var bold = traits.contains(.traitBold) || (a[boldKey] as? Bool ?? false)
        var italic = traits.contains(.traitItalic) || (a[italicKey] as? Bool ?? false)
        var size = font.map { Double($0.pointSize) } ?? style.size
        switch change {
        case .bold: bold = on
        case .italic: italic = on
        case .underline:
            if on { a[.underlineStyle] = NSUnderlineStyle.single.rawValue } else { a.removeValue(forKey: .underlineStyle) }
        case .strikethrough:
            if on { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue } else { a.removeValue(forKey: .strikethroughStyle) }
        case .size(let s): size = s
        case .color(let c): a[.foregroundColor] = c.uiColor
        }
        let f = TextBoxFonts.font(style.font, size: size, bold: bold, italic: italic)
        a[.font] = f.font
        if f.syntheticBold { a[boldKey] = true } else { a.removeValue(forKey: boldKey) }
        if f.syntheticItalic { a[italicKey] = true } else { a.removeValue(forKey: italicKey) }
        a[.paragraphStyle] = paragraphStyle(align: style.align, dir: style.dir, lineHeight: size)
        return a
    }

    /// Whether a toggle is on for every character of `range` (an empty
    /// range: in `typing`).
    static func isOn(_ change: Change, in text: NSAttributedString, range: NSRange,
                     typing: [NSAttributedString.Key: Any]) -> Bool {
        func has(_ a: [NSAttributedString.Key: Any]) -> Bool {
            let traits = (a[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            switch change {
            case .bold: return traits.contains(.traitBold) || (a[boldKey] as? Bool ?? false)
            case .italic: return traits.contains(.traitItalic) || (a[italicKey] as? Bool ?? false)
            case .underline: return (a[.underlineStyle] as? Int ?? 0) != 0
            case .strikethrough: return (a[.strikethroughStyle] as? Int ?? 0) != 0
            case .size, .color: return false
            }
        }
        guard range.length > 0, NSMaxRange(range) <= text.length else { return has(typing) }
        var all = true
        text.enumerateAttributes(in: range) { a, _, stop in
            if !has(a) { all = false; stop.pointee = true }
        }
        return all
    }

    /// `text` with `change` applied to `range` (a toggle turns on unless it
    /// is on everywhere in the range).
    static func applying(_ change: Change, to text: NSAttributedString, range: NSRange, style: BoxStyle) -> NSAttributedString {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return text }
        let on = !isOn(change, in: text, range: range, typing: [:])
        let out = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: range) { a, r, _ in
            out.setAttributes(apply(change, on: on, to: a, style: style), range: r)
        }
        return out
    }

    /// `text` restyled for a new box style (family, size, colour, alignment,
    /// direction): runs keep their own overrides.
    static func restyled(_ text: NSAttributedString, from old: BoxStyle, to new: BoxStyle) -> NSAttributedString {
        attributed(TextContent(font: new.font, size: new.size, color: new.color, align: new.align, dir: new.dir,
                               runs: runs(from: text, style: old).map { run in
                                   var r = run
                                   // An override equal to the new box value is no override.
                                   if r.size == new.size { r.size = nil }
                                   if r.color == new.color { r.color = nil }
                                   return r
                               }))
    }

    // MARK: Markdown boxes (format.md §8.2.4 "Markdown text")

    /// How a Markdown box's source is shown while it is edited: plain text in
    /// the box's body family (sans or serif), size and colour.
    static func markdownAttributes(_ style: BoxStyle) -> [NSAttributedString.Key: Any] {
        let f = TextBoxFonts.font(style.font == .serif ? .serif : .sans, size: style.size, bold: false, italic: false)
        return [.font: f.font, .foregroundColor: style.color.uiColor,
                .paragraphStyle: paragraphStyle(align: style.align, dir: style.dir, lineHeight: style.size)]
    }

    /// The text view's text for a Markdown source.
    static func markdownSource(_ source: String, style: BoxStyle) -> NSAttributedString {
        NSAttributedString(string: source, attributes: markdownAttributes(style))
    }

    /// The Markdown box written after editing `source` (before its formulas
    /// are typeset and it is laid out): the source as one run, the box
    /// style, the keyboard's language if the box had none; fields the editor
    /// does not show (`extra`, typeset formulas still used) kept from
    /// `original`. Nil when the source breaks the format's limits.
    static func markdownContent(_ source: String, style: BoxStyle, original: TextContent?,
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
        content.family = TextBoxFonts.family(content.font)
        content.size = style.size
        content.color = style.color
        content.align = style.align
        content.dir = style.dir
        if content.lang == nil, let lang = keyboardLanguage, !lang.isEmpty, lang != "emoji", lang != "dictation" { content.lang = lang }
        let used = MarkdownText.usedFormulas(content)
        content.math = used.isEmpty ? nil : used
        return content
    }

    /// The smallest change (UTF-16) that turns `old` into `new`: the range of
    /// `old` to replace and its replacement (common prefix and suffix kept).
    static func changedRange(from old: String, to new: String) -> (range: NSRange, replacement: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        // Never split a surrogate pair: keep a lead surrogate with its trail.
        if p > 0, UTF16.isLeadSurrogate(a[p - 1]) { p -= 1 }
        if s > 0, a.count - s - 1 >= p, UTF16.isLeadSurrogate(a[a.count - s - 1]) { s -= 1 }
        let replacement = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        return (NSRange(location: p, length: a.count - s - p), replacement)
    }
}
