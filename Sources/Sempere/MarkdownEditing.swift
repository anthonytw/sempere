import Foundation

/// The Markdown helpers of the app's text box editor (format.md §8.5.4): each
/// inserts or removes syntax in the source around the selection, as typing
/// it would. Offsets are UTF-16 (`NSRange`, as `UITextView` reports them).
/// Pure, so it is tested on Linux.
public enum MarkdownEditing {
    public enum Action: Hashable, Sendable, CaseIterable {
        case bold, italic, strikethrough, code, link, math, displayMath
        case heading, bulletList, numberedList, taskList, quote
    }

    /// The source and selection after `action`.
    public static func apply(_ action: Action, to text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let sel = NSRange(location: min(max(selection.location, 0), ns.length),
                          length: max(0, min(selection.length, ns.length - min(max(selection.location, 0), ns.length))))
        switch action {
        case .bold: return wrap(ns, sel, "**")
        case .italic: return wrap(ns, sel, "*")
        case .strikethrough: return wrap(ns, sel, "~~")
        case .code: return wrap(ns, sel, "`")
        case .math: return wrap(ns, sel, "$")
        case .link:
            let label = ns.substring(with: sel)
            let url = "https://"
            let inserted = "[\(label)](\(url))"
            let out = ns.replacingCharacters(in: sel, with: inserted)
            // An empty label gets the caret; otherwise the destination is selected to type over.
            let caret = label.isEmpty ? NSRange(location: sel.location + 1, length: 0)
                : NSRange(location: sel.location + (label as NSString).length + 3, length: (url as NSString).length)
            return (out, caret)
        case .displayMath:
            let inner = ns.substring(with: sel)
            let before = sel.location > 0 && ns.character(at: sel.location - 1) != 0x0A ? "\n" : ""
            let end = sel.location + sel.length
            let after = end < ns.length && ns.character(at: end) != 0x0A ? "\n" : ""
            let inserted = "\(before)$$\n\(inner)\n$$\(after)"
            let out = ns.replacingCharacters(in: sel, with: inserted)
            let start = sel.location + (before as NSString).length + 3
            return (out, NSRange(location: start, length: (inner as NSString).length))
        case .heading: return cycleHeading(ns, sel)
        case .bulletList: return prefix(ns, sel, "- ")
        case .numberedList: return prefix(ns, sel, nil)
        case .taskList: return prefix(ns, sel, "- [ ] ")
        case .quote: return prefix(ns, sel, "> ")
        }
    }

    /// Wraps the selection in `marker` (an empty one: the caret between two
    /// markers), or unwraps it when it already is wrapped.
    static func wrap(_ ns: NSString, _ sel: NSRange, _ marker: String) -> (text: String, selection: NSRange) {
        let m = (marker as NSString).length
        let start = sel.location, end = sel.location + sel.length
        if start >= m, end + m <= ns.length,
           ns.substring(with: NSRange(location: start - m, length: m)) == marker,
           ns.substring(with: NSRange(location: end, length: m)) == marker {
            var out = ns.replacingCharacters(in: NSRange(location: end, length: m), with: "") as NSString
            out = out.replacingCharacters(in: NSRange(location: start - m, length: m), with: "") as NSString
            return (out as String, NSRange(location: start - m, length: sel.length))
        }
        let inner = ns.substring(with: sel)
        let out = ns.replacingCharacters(in: sel, with: marker + inner + marker)
        return (out, NSRange(location: start + m, length: sel.length))
    }

    /// The ranges (UTF-16) of the lines the selection touches, without their line feeds.
    static func lines(_ ns: NSString, _ sel: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var start = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let end = sel.location + sel.length
        repeat {
            let r = ns.lineRange(for: NSRange(location: start, length: 0))
            var len = r.length
            if len > 0, ns.character(at: r.location + len - 1) == 0x0A { len -= 1 }
            out.append(NSRange(location: r.location, length: len))
            start = r.location + r.length
        } while start < end && start < ns.length
        return out
    }

    /// The length of a list or quote marker at the start of `line`, if any
    /// (`- `, `* `, `+ `, `1. `, `- [ ] `, `- [x] `, `> `).
    static func markerLength(_ line: String) -> Int {
        let u = Array(line.utf16)
        var i = 0
        if i < u.count, u[i] == 0x3E { return i + 1 < u.count && u[i + 1] == 0x20 ? 2 : 1 }
        if i < u.count, [0x2D, 0x2A, 0x2B].contains(u[i]), i + 1 < u.count, u[i + 1] == 0x20 {
            i = 2
            if i + 3 < u.count, u[i] == 0x5B, [0x20, 0x78, 0x58].contains(u[i + 1]), u[i + 2] == 0x5D, u[i + 3] == 0x20 { return i + 4 }
            return i
        }
        var d = 0
        while d < u.count, d < 9, (0x30...0x39).contains(u[d]) { d += 1 }
        if d > 0, d + 1 < u.count, u[d] == 0x2E || u[d] == 0x29, u[d + 1] == 0x20 { return d + 2 }
        return 0
    }

    /// Puts `marker` (nil: numbers `1.`, `2.`, …) at the start of every line
    /// the selection touches, replacing another list or quote marker; takes
    /// it off when every line has it already.
    static func prefix(_ ns: NSString, _ sel: NSRange, _ marker: String?) -> (text: String, selection: NSRange) {
        let ranges = lines(ns, sel)
        let texts = ranges.map { ns.substring(with: $0) }
        func wanted(_ k: Int) -> String { marker ?? "\(k + 1). " }
        let all = texts.enumerated().allSatisfy { k, t in
            let n = markerLength(t)
            guard n > 0 else { return false }
            let existing = String(decoding: Array(t.utf16.prefix(n)), as: UTF16.self)
            return marker == nil ? existing.last == " " && existing.first?.isNumber == true : existing == marker
        }
        var out = ns as String
        var edits: [(location: Int, old: Int, new: Int)] = []
        for (k, r) in ranges.enumerated().reversed() {
            let n = markerLength(texts[k])
            let replacement = all ? "" : wanted(k)
            out = (out as NSString).replacingCharacters(in: NSRange(location: r.location, length: n), with: replacement)
            edits.append((r.location, n, (replacement as NSString).length))
        }
        // Each end of the selection (original offsets) follows the edits before it; inside a
        // replaced marker it stays within the new one.
        func map(_ p: Int) -> Int {
            var shift = 0
            for e in edits.sorted(by: { $0.location < $1.location }) {
                if p >= e.location + e.old {
                    shift += e.new - e.old
                } else if p > e.location {
                    return e.location + shift + min(p - e.location, e.new)
                } else {
                    break
                }
            }
            return p + shift
        }
        let start = map(sel.location), end = map(sel.location + sel.length)
        return (out, NSRange(location: start, length: max(0, end - start)))
    }

    /// The first selected line's heading level goes up by one (`#` to
    /// `###`), then back to none.
    static func cycleHeading(_ ns: NSString, _ sel: NSRange) -> (text: String, selection: NSRange) {
        let line = lines(ns, sel)[0]
        let t = ns.substring(with: line)
        var level = 0
        for c in t.utf16 { if c == 0x23 { level += 1 } else { break } }
        let hasSpace = level > 0 && level < (t as NSString).length && (t as NSString).character(at: level) == 0x20
        let old = level > 0 && (hasSpace || level == (t as NSString).length) ? level + (hasSpace ? 1 : 0) : 0
        let current = old > 0 ? level : 0
        let next = current >= 3 ? 0 : current + 1
        let replacement = next == 0 ? "" : String(repeating: "#", count: next) + " "
        let out = ns.replacingCharacters(in: NSRange(location: line.location, length: old), with: replacement)
        let new = (replacement as NSString).length
        // Each end of the selection follows the edit; inside the old marker it stays within the new one.
        func map(_ p: Int) -> Int {
            if p >= line.location + old { return p + new - old }
            if p > line.location { return line.location + min(p - line.location, new) }
            return p
        }
        let start = map(sel.location), end = map(sel.location + sel.length)
        return (out, NSRange(location: start, length: max(0, end - start)))
    }
}
