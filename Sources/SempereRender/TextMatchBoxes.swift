import Foundation
import Sempere

/// Where a search finds its words inside a text box (GA-07): the text is laid out by the
/// caller's shaper (the CLI's `DefaultTextShaper`, the app's CoreText one), each line's text is
/// searched, and the glyphs of a match give its box in page points — the same coordinates as the
/// boxes of recognised handwriting, so the canvas highlights both alike.
///
/// Boxes are approximate in height (`0.8 × size` above the baseline, `0.25 × size` below) and exact in
/// width for left-to-right lines whose glyphs map one to one onto the line's characters; any other line
/// (right to left, or glyph text that does not add up to the line) highlights the whole line's width.
/// A rotated box is the bounding box of the turned one.
public enum TextMatchBoxes {
    /// Matches searched at most per text box.
    public static let maxPerItem = 2_000

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The occurrences of `words` (any of them; case, accents and width ignored, substrings count) in
    /// `item`'s text, in reading order. Nothing for an item without text, or one the shaper cannot lay out.
    /// Cost: shaping the text once, then linear in the text for each word.
    public static func boxes(of words: [String], in item: Item, shaper: any TextShaper) -> [(text: String, box: Recognition.Box)] {
        guard let content = item.text, !words.isEmpty else { return [] }
        if content.isMarkdown {
            // A Markdown box is searched as it is drawn (format.md §8.5.4): in its text pieces, never in
            // the markup of its source; the pieces carry the box's rotation, so their boxes are the page's.
            guard let prepared = try? PreparedItem(item, pageNumber: 1),
                  let pieces = MarkdownItems.expand(prepared, shaper: shaper) else { return [] }
            var out: [(text: String, box: Recognition.Box)] = []
            for piece in pieces where piece.item.kind == .text {
                out += boxes(of: words, in: piece.item, shaper: shaper)
                if out.count >= maxPerItem { return Array(out.prefix(maxPerItem)) }
            }
            return out
        }
        guard let shaped = try? shaper.shape(content, frame: item.frame) else { return [] }
        var out: [(text: String, box: Recognition.Box)] = []
        for line in shaped.lines {
            let ranges = merged(ranges(of: words, in: line.text))
            guard !ranges.isEmpty else { continue }
            let spans = glyphSpans(of: line)
            for r in ranges {
                let matched = String(line.text[r])
                let lo = line.text.distance(from: line.text.startIndex, to: r.lowerBound)
                let hi = line.text.distance(from: line.text.startIndex, to: r.upperBound)
                var x0 = line.x, x1 = line.x + line.width
                if let spans, let a = spans.first(where: { $0.characters.contains(lo) }),
                   let b = spans.first(where: { $0.characters.contains(hi - 1) }) {
                    // Inside a cluster of several characters (a ligature) the whole cluster is taken.
                    x0 = a.x0; x1 = b.x1
                }
                let top = line.baseline - 0.8 * line.size, height = 1.05 * line.size
                if let box = rotated(Rect(x: x0, y: top, w: max(x1 - x0, 0), h: height), item: item) {
                    out.append((matched, box))
                    if out.count >= maxPerItem { return out }
                }
            }
        }
        return out
    }

    private static func ranges(of words: [String], in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: word, options: options, range: from..<text.endIndex) {
                out.append(r)
                from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
            }
        }
        return out
    }

    /// Overlapping or touching ranges joined, in text order.
    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { out.append(r) }
        }
        return out
    }

    /// The horizontal extent of every glyph cluster with the characters (offsets in the line's text) it stands
    /// for; nil when the line cannot be mapped (right to left, or the glyph text is not the line's text).
    private static func glyphSpans(of line: ShapedLine) -> [(characters: Range<Int>, x0: Double, x1: Double)]? {
        guard !line.rtl else { return nil }
        var spans: [(characters: Range<Int>, x0: Double, x1: Double)] = []
        var offset = 0
        var text = ""
        for run in line.runs {
            let glyphs = run.glyphs
            var i = 0
            while i < glyphs.count {
                let g = glyphs[i]
                // A cluster: its first glyph carries the text, the rest ("" text) follow it.
                var end = i + 1
                while end < glyphs.count, glyphs[end].text.isEmpty { end += 1 }
                let n = g.text.count
                let x1 = glyphs[i..<end].map { $0.x + $0.advance }.max() ?? g.x + g.advance
                if n > 0 {
                    spans.append((offset..<(offset + n), g.x, max(x1, g.x)))
                    offset += n
                    text += g.text
                }
                i = end
            }
        }
        // Trailing white space is dropped from the line's text, not from the glyphs.
        guard text.hasPrefix(line.text), offset >= line.text.count else { return nil }
        return spans
    }

    /// `rect` turned by the item's rotation about its frame's centre, as a bounding box (nil when not finite).
    private static func rotated(_ rect: Rect, item: Item) -> Recognition.Box? {
        var points = [(rect.x, rect.y), (rect.x + rect.w, rect.y), (rect.x + rect.w, rect.y + rect.h), (rect.x, rect.y + rect.h)]
        if let degrees = item.rotation, degrees != 0, degrees.isFinite {
            let t = degrees * .pi / 180, c = cos(t), s = sin(t)
            let cx = item.frame.x + item.frame.w / 2, cy = item.frame.y + item.frame.h / 2
            points = points.map { p in
                let dx = p.0 - cx, dy = p.1 - cy
                return (cx + dx * c - dy * s, cy + dx * s + dy * c)
            }
        }
        guard let minX = points.map(\.0).min(), let maxX = points.map(\.0).max(),
              let minY = points.map(\.1).min(), let maxY = points.map(\.1).max(),
              [minX, maxX, minY, maxY].allSatisfy(\.isFinite) else { return nil }
        return Recognition.Box(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }
}
