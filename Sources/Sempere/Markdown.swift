import Foundation

// MARK: - Markdown parser (docs/format.md §8.5.4 "Dialect")
//
// The Markdown dialect of text boxes: a line-based subset of CommonMark with
// GitHub's strikethrough and task lists and Pandoc's math. Every byte of a
// text box may be hostile (format.md §9): the parser is linear in the source
// times the nesting depth (at most `MarkdownDocument.maxDepth`), uses no
// recursion beyond that depth, and bounds every forward scan. Every drawn
// character keeps its offset in the source (Unicode scalar values), which is
// what the stored line breaks refer to. Ported to `web/src/format/markdown.ts`.

/// Inline style of a drawn character (format.md §8.5.4 "Styles").
public struct MarkdownStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = MarkdownStyle(rawValue: 1)
    public static let italic = MarkdownStyle(rawValue: 2)
    public static let strike = MarkdownStyle(rawValue: 4)
    public static let code = MarkdownStyle(rawValue: 8)
    public static let link = MarkdownStyle(rawValue: 16)
}

/// One drawn element of inline content.
public struct MarkdownAtom: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A character.
        case char(Unicode.Scalar)
        /// A formula: its LaTeX source and whether it is display style.
        case formula(latex: String, display: Bool)
        /// A hard line break.
        case lineBreak
    }
    public var kind: Kind
    /// Offset in Unicode scalar values of the source: the character itself,
    /// a formula's opening `$`, the line feed of a break.
    public var offset: Int
    public var style: MarkdownStyle
    /// Index of the link (`MarkdownDocument.links`) a link character belongs to.
    public var link: Int?
    /// A formula's source offset of each scalar of its `latex` (the line
    /// feed of a line break for a joined line), for drawing it as its source.
    public var latexOffsets: [Int]

    public init(_ kind: Kind, offset: Int, style: MarkdownStyle = [], link: Int? = nil, latexOffsets: [Int] = []) {
        self.kind = kind; self.offset = offset; self.style = style; self.link = link; self.latexOffsets = latexOffsets
    }
}

/// A block of a Markdown document.
public indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownAtom])
    case heading(level: Int, [MarkdownAtom])
    /// A fenced code block: its characters (style `code`) and line breaks.
    case code([MarkdownAtom])
    /// A display formula block: one formula atom.
    case math(MarkdownAtom)
    /// A thematic break, at the offset of its first character.
    case rule(offset: Int)
    case quote([MarkdownEntry])
    case list(MarkdownList)
}

/// A block and whether blank lines precede it in its container.
public struct MarkdownEntry: Hashable, Sendable {
    public var block: MarkdownBlock
    public var blankBefore: Bool
    public init(_ block: MarkdownBlock, blankBefore: Bool) { self.block = block; self.blankBefore = blankBefore }
}

/// A list: bullet or ordered, and its items.
public struct MarkdownList: Hashable, Sendable {
    /// The bullet character, or nil for an ordered list.
    public var bullet: Unicode.Scalar?
    /// An ordered list's delimiter (`.` or `)`).
    public var delimiter: Unicode.Scalar?
    /// An ordered list's first number.
    public var start: Int
    public var items: [MarkdownListItem]
}

public struct MarkdownListItem: Hashable, Sendable {
    /// nil: not a task; else whether it is checked.
    public var task: Bool?
    public var blocks: [MarkdownEntry]
    public var blankBefore: Bool
}

/// A Markdown source parsed (format.md §8.5.4).
public struct MarkdownDocument: Sendable {
    public let blocks: [MarkdownEntry]
    /// Link destinations, by `MarkdownAtom.link`.
    public let links: [String]

    /// Deepest container nesting (quotes and list items).
    public static let maxDepth = 16
    /// Longest link destination or title scanned, in scalars.
    static let maxLinkPart = 1_000

    public init(_ source: String) {
        let scalars = Array(source.unicodeScalars)
        var parser = BlockParser(src: scalars)
        var lines: [Line] = []
        var start = 0
        for (i, s) in scalars.enumerated() where s == "\n" {
            lines.append(Line(start: start, end: i))
            start = i + 1
        }
        lines.append(Line(start: start, end: scalars.count))
        blocks = parser.blocks(lines, depth: 0)
        links = parser.links
    }

    /// The plain text (format.md §8.5.4): every rendered paragraph's text,
    /// formulas as their source, joined with line feeds.
    public var plainText: String {
        var out = String.UnicodeScalarView()
        var first = true
        func atoms(_ list: [MarkdownAtom]) {
            if !first { out.append("\n") }
            first = false
            for a in list {
                switch a.kind {
                case .char(let c): out.append(c)
                case .formula(let latex, _): out.append(contentsOf: latex.unicodeScalars)
                case .lineBreak: out.append("\n")
                }
            }
        }
        func walk(_ entries: [MarkdownEntry]) {
            for e in entries {
                switch e.block {
                case .paragraph(let a), .heading(_, let a), .code(let a): atoms(a)
                case .math(let a): atoms([a])
                case .rule: break
                case .quote(let inner): walk(inner)
                case .list(let l): for item in l.items { walk(item.blocks) }
                }
            }
        }
        walk(blocks)
        return String(out)
    }
}

/// A line of the source as a container sees it: `[start, end)`, its
/// container prefixes already skipped.
struct Line: Hashable {
    var start: Int
    var end: Int
}

private extension Unicode.Scalar {
    var isSpaceOrTab: Bool { self == " " || self == "\t" }
    var isASCIIDigit: Bool { (0x30...0x39).contains(value) }
    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(value) || (0x3A...0x40).contains(value) || (0x5B...0x60).contains(value)
            || (0x7B...0x7E).contains(value)
    }
}

// MARK: - Blocks

private struct BlockParser {
    let src: [Unicode.Scalar]
    var links: [String] = []

    init(src: [Unicode.Scalar]) { self.src = src }

    func isBlank(_ l: Line) -> Bool { (l.start..<l.end).allSatisfy { src[$0].isSpaceOrTab } }

    /// Columns of leading white space (a tab is 4) and the scalars they take.
    func indent(_ l: Line) -> (columns: Int, count: Int) {
        var cols = 0, n = 0
        while l.start + n < l.end, src[l.start + n].isSpaceOrTab {
            cols += src[l.start + n] == "\t" ? 4 : 1
            n += 1
        }
        return (cols, n)
    }

    /// `l` without up to `columns` columns of leading white space.
    func dropIndent(_ l: Line, _ columns: Int) -> Line {
        var out = l
        var cols = 0
        while cols < columns, out.start < out.end, src[out.start].isSpaceOrTab {
            cols += src[out.start] == "\t" ? 4 : 1
            out.start += 1
        }
        return out
    }

    /// The line with its ignored indent (≤ 3 columns) skipped, or nil when
    /// it is indented more (it then starts no block).
    func opening(_ l: Line) -> Line? {
        let (cols, n) = indent(l)
        guard cols <= 3 else { return nil }
        return Line(start: l.start + n, end: l.end)
    }

    func run(of c: Unicode.Scalar, from i: Int, to end: Int) -> Int {
        var j = i
        while j < end, src[j] == c { j += 1 }
        return j - i
    }

    /// A fence: its character and length.
    func fence(_ t: Line) -> (Unicode.Scalar, Int)? {
        guard t.start < t.end else { return nil }
        let c = src[t.start]
        guard c == "`" || c == "~" else { return nil }
        let n = run(of: c, from: t.start, to: t.end)
        guard n >= 3 else { return nil }
        // A backtick fence's info string has no backtick (CommonMark).
        if c == "`", (t.start + n..<t.end).contains(where: { src[$0] == "`" }) { return nil }
        return (c, n)
    }

    /// `$$` opening a display-math block: no other `$$` on the line but at its end.
    func startsMath(_ t: Line) -> Bool {
        guard t.end - t.start >= 2, src[t.start] == "$", src[t.start + 1] == "$" else { return false }
        var e = t.end
        while e > t.start + 2, src[e - 1].isSpaceOrTab { e -= 1 }
        var k = t.start + 2
        while k + 1 < e {
            if src[k] == "$", src[k + 1] == "$" { return k + 2 == e }
            k += 1
        }
        return true
    }

    func heading(_ t: Line) -> Int? {
        let n = run(of: "#", from: t.start, to: t.end)
        guard (1...6).contains(n) else { return nil }
        guard t.start + n == t.end || src[t.start + n].isSpaceOrTab else { return nil }
        return n
    }

    func isRule(_ t: Line) -> Bool {
        guard t.start < t.end else { return false }
        let c = src[t.start]
        guard c == "-" || c == "*" || c == "_" else { return false }
        var count = 0
        for i in t.start..<t.end {
            if src[i] == c { count += 1 } else if !src[i].isSpaceOrTab { return false }
        }
        return count >= 3
    }

    /// A list marker: bullet char or ordered (number, delimiter), its
    /// length, and the content column relative to the line's start.
    struct Marker {
        var bullet: Unicode.Scalar?
        var number: Int
        var delimiter: Unicode.Scalar?
        /// Where the item's content starts in the source.
        var contentStart: Int
        /// Content column, counted from the container's left edge.
        var column: Int
    }

    func listMarker(_ l: Line) -> Marker? {
        let (cols, n) = indent(l)
        guard cols <= 3 else { return nil }
        let p = l.start + n
        guard p < l.end else { return nil }
        var bullet: Unicode.Scalar?
        var number = 0
        var delimiter: Unicode.Scalar?
        var m: Int
        let c = src[p]
        if c == "-" || c == "+" || c == "*" {
            bullet = c
            m = 1
        } else {
            var d = 0
            while p + d < l.end, d < 10, src[p + d].isASCIIDigit { d += 1 }
            guard (1...9).contains(d), p + d < l.end, src[p + d] == "." || src[p + d] == ")" else { return nil }
            for k in 0..<d { number = number * 10 + Int(src[p + k].value - 0x30) }
            delimiter = src[p + d]
            m = d + 1
        }
        let after = p + m
        guard after == l.end || src[after].isSpaceOrTab else { return nil }
        // Spaces after the marker (1–4; more, or none, count as 1).
        var k = 0, kcols = 0
        while after + k < l.end, src[after + k].isSpaceOrTab, kcols < 5 {
            kcols += src[after + k] == "\t" ? 4 : 1
            k += 1
        }
        let restBlank = (after + k..<l.end).allSatisfy { src[$0].isSpaceOrTab }
        var contentStart = after + k
        if kcols == 0 || kcols > 4 || restBlank {
            kcols = 1
            contentStart = min(after + 1, l.end)
            if restBlank { contentStart = l.end }
        }
        return Marker(bullet: bullet, number: number, delimiter: delimiter, contentStart: contentStart,
                      column: cols + m + kcols)
    }

    /// True when `l` starts a block other than a paragraph (rules 1–6).
    func startsBlock(_ l: Line, depth: Int) -> Bool {
        guard let t = opening(l) else { return false }
        if fence(t) != nil || startsMath(t) || heading(t) != nil || isRule(t) { return true }
        guard depth < MarkdownDocument.maxDepth else { return false }
        if t.start < t.end, src[t.start] == ">" { return true }
        return listMarker(l) != nil
    }

    mutating func blocks(_ lines: [Line], depth: Int) -> [MarkdownEntry] {
        var out: [MarkdownEntry] = []
        var blank = false
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if isBlank(l) { blank = true; i += 1; continue }
            let blankBefore = blank && !out.isEmpty
            blank = false
            guard let t = opening(l) else {
                let (b, next) = paragraph(lines, from: i, depth: depth)
                out.append(MarkdownEntry(b, blankBefore: blankBefore))
                i = next
                continue
            }
            if let (c, n) = fence(t) {
                let indent = self.indent(l).columns
                var atoms: [MarkdownAtom] = []
                var j = i + 1
                var firstLine = true
                while j < lines.count {
                    if let u = opening(lines[j]), u.start < u.end, src[u.start] == c, run(of: c, from: u.start, to: u.end) >= n,
                       (u.start + run(of: c, from: u.start, to: u.end)..<u.end).allSatisfy({ src[$0].isSpaceOrTab }) {
                        j += 1
                        break
                    }
                    let content = dropIndent(lines[j], indent)
                    if !firstLine { atoms.append(MarkdownAtom(.lineBreak, offset: lines[j].start - 1, style: .code)) }
                    firstLine = false
                    for k in content.start..<content.end { atoms.append(MarkdownAtom(.char(src[k]), offset: k, style: .code)) }
                    j += 1
                }
                out.append(MarkdownEntry(.code(atoms), blankBefore: blankBefore))
                i = j
                continue
            }
            if startsMath(t), let (atom, next) = displayMath(lines, from: i, opening: t) {
                out.append(MarkdownEntry(.math(atom), blankBefore: blankBefore))
                i = next
                continue
            }
            if let level = heading(t) {
                var s = t.start + level, e = t.end
                while s < e, src[s].isSpaceOrTab { s += 1 }
                while e > s, src[e - 1].isSpaceOrTab { e -= 1 }
                // Closing sequence: trailing #s preceded by white space, or the whole rest.
                var h = e
                while h > s, src[h - 1] == "#" { h -= 1 }
                if h < e, h == s || src[h - 1].isSpaceOrTab {
                    e = h
                    while e > s, src[e - 1].isSpaceOrTab { e -= 1 }
                }
                var inline = InlineParser(src: src, chars: (s..<e).map { ($0, src[$0]) }, linkBase: links.count)
                let atoms = inline.parse()
                links += inline.links
                out.append(MarkdownEntry(.heading(level: level, atoms), blankBefore: blankBefore))
                i += 1
                continue
            }
            if isRule(t) {
                out.append(MarkdownEntry(.rule(offset: t.start), blankBefore: blankBefore))
                i += 1
                continue
            }
            if depth < MarkdownDocument.maxDepth, t.start < t.end, src[t.start] == ">" {
                var inner: [Line] = []
                var j = i
                while j < lines.count, let u = opening(lines[j]), u.start < u.end, src[u.start] == ">" {
                    var s = u.start + 1
                    if s < u.end, src[s].isSpaceOrTab { s += 1 }
                    inner.append(Line(start: s, end: u.end))
                    j += 1
                }
                out.append(MarkdownEntry(.quote(blocks(inner, depth: depth + 1)), blankBefore: blankBefore))
                i = j
                continue
            }
            if depth < MarkdownDocument.maxDepth, let first = listMarker(l) {
                var list = MarkdownList(bullet: first.bullet, delimiter: first.delimiter, start: first.number, items: [])
                var j = i
                var itemBlank = false
                while j < lines.count {
                    if isBlank(lines[j]) {
                        // Blank lines inside the list: go on only if another item follows.
                        var k = j
                        while k < lines.count, isBlank(lines[k]) { k += 1 }
                        guard k < lines.count, let m = listMarker(lines[k]), m.bullet == first.bullet,
                              m.delimiter == first.delimiter else { break }
                        itemBlank = true
                        j = k
                        continue
                    }
                    guard let m = listMarker(lines[j]), m.bullet == first.bullet, m.delimiter == first.delimiter else { break }
                    var content: [Line] = [Line(start: m.contentStart, end: lines[j].end)]
                    var k = j + 1
                    while k < lines.count {
                        if isBlank(lines[k]) {
                            var q = k
                            while q < lines.count, isBlank(lines[q]) { q += 1 }
                            guard q < lines.count, indent(lines[q]).columns >= m.column else { break }
                            for b in k..<q { content.append(dropIndent(lines[b], m.column)) }
                            k = q
                            continue
                        }
                        guard indent(lines[k]).columns >= m.column else { break }
                        content.append(dropIndent(lines[k], m.column))
                        k += 1
                    }
                    // A task: "[ ]", "[x]" or "[X]" then white space or the end.
                    var task: Bool?
                    let c0 = content[0]
                    if c0.end - c0.start >= 3, src[c0.start] == "[", src[c0.start + 2] == "]",
                       [" ", "x", "X"].contains(src[c0.start + 1]),
                       c0.start + 3 == c0.end || src[c0.start + 3].isSpaceOrTab {
                        task = src[c0.start + 1] != " "
                        content[0].start = min(c0.start + 4, c0.end)
                    }
                    list.items.append(MarkdownListItem(task: task, blocks: blocks(content, depth: depth + 1),
                                                       blankBefore: itemBlank))
                    itemBlank = false
                    j = k
                }
                out.append(MarkdownEntry(.list(list), blankBefore: blankBefore))
                i = j
                continue
            }
            let (b, next) = paragraph(lines, from: i, depth: depth)
            out.append(MarkdownEntry(b, blankBefore: blankBefore))
            i = next
        }
        return out
    }

    /// A display-math block opened on `lines[i]` (`t`: after its indent),
    /// and the index after it; nil when its formula is empty.
    func displayMath(_ lines: [Line], from i: Int, opening t: Line) -> (MarkdownAtom, Int)? {
        let open = t.start
        var s = t.start + 2
        var e = t.end
        while e > s, src[e - 1].isSpaceOrTab { e -= 1 }
        var chars: [(Int, Unicode.Scalar)] = []
        var next = i + 1
        func add(_ a: Int, _ b: Int) { for k in a..<max(a, b) { chars.append((k, src[k])) } }
        if e - s >= 2, src[e - 1] == "$", src[e - 2] == "$" {
            add(s, e - 2)
        } else {
            add(s, e)
            var j = i + 1
            while j < lines.count {
                chars.append((lines[j].start - 1, "\n"))
                s = lines[j].start
                e = lines[j].end
                while e > s, src[e - 1].isSpaceOrTab { e -= 1 }
                if e - s >= 2, src[e - 1] == "$", src[e - 2] == "$" {
                    add(s, e - 2)
                    j += 1
                    break
                }
                add(s, e)
                j += 1
            }
            next = j
        }
        let trim: Set<Unicode.Scalar> = [" ", "\t", "\n"]
        // One cut, not removeFirst per character (quadratic on a long blank run).
        let first = chars.firstIndex { !trim.contains($0.1) } ?? chars.count
        chars.removeFirst(first)
        while let l = chars.last, trim.contains(l.1) { chars.removeLast() }
        guard !chars.isEmpty else { return nil }
        let latex = String(String.UnicodeScalarView(chars.map(\.1)))
        return (MarkdownAtom(.formula(latex: latex, display: true), offset: open, latexOffsets: chars.map(\.0)), next)
    }

    /// A paragraph starting at `lines[i]`, and the index after it.
    mutating func paragraph(_ lines: [Line], from i: Int, depth: Int) -> (MarkdownBlock, Int) {
        var chars: [(Int, Unicode.Scalar)] = []
        var j = i
        while j < lines.count {
            let l = lines[j]
            if j > i && (isBlank(l) || startsBlock(l, depth: depth)) { break }
            var s = l.start, e = l.end
            while s < e, src[s].isSpaceOrTab { s += 1 }
            while e > s, src[e - 1].isSpaceOrTab { e -= 1 }
            // A trailing backslash marks a hard break in CommonMark; every line break is one here.
            if e > s, src[e - 1] == "\\", !(e - 2 >= s && src[e - 2] == "\\") { e -= 1 }
            if j > i { chars.append((lines[j - 1].end, "\n")) }
            for k in s..<e { chars.append((k, src[k])) }
            j += 1
        }
        var inline = InlineParser(src: src, chars: chars, linkBase: links.count)
        let atoms = inline.parse()
        links += inline.links
        return (.paragraph(atoms), j)
    }
}

// MARK: - Inline content

/// Inline content of one paragraph or heading: characters with their
/// source offsets (`\n` between a paragraph's lines), scanned once.
private struct InlineParser {
    let src: [Unicode.Scalar]
    /// (source offset, character).
    let chars: [(Int, Unicode.Scalar)]
    let linkBase: Int
    var links: [String] = []

    init(src: [Unicode.Scalar], chars: [(Int, Unicode.Scalar)], linkBase: Int) {
        self.src = src; self.chars = chars; self.linkBase = linkBase
    }

    enum TokKind {
        case char(Unicode.Scalar)
        case formula(String, Bool)
        case lineBreak
        /// A delimiter run: character, offsets `[lo, hi)` of its unused characters.
        case delim(Unicode.Scalar)
    }

    struct Tok {
        var kind: TokKind
        var offset: Int
        var style: MarkdownStyle = []
        var link: Int?
        var deleted = false
        var latexOffsets: [Int] = []
        // Delimiter runs.
        var lo = 0, hi = 0
        var canOpen = false, canClose = false
    }

    var toks: [Tok] = []
    /// Emphasis matches: the tokens `[lo, hi)` between an opener and its
    /// closer take `style`. Applied once when flattening, so nested emphasis
    /// stays linear (styling the range at each match was quadratic).
    var emphasis: [(lo: Int, hi: Int, style: MarkdownStyle)] = []

    func c(_ i: Int) -> Unicode.Scalar? { i >= 0 && i < chars.count ? chars[i].1 : nil }

    static func isWhite(_ s: Unicode.Scalar?) -> Bool { s.map { $0.properties.isWhitespace } ?? true }
    static func isPunct(_ s: Unicode.Scalar?) -> Bool {
        guard let s else { return false }
        if s.isASCIIPunctuation { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    mutating func parse() -> [MarkdownAtom] {
        let n = chars.count
        // Precomputed for linear scans (format.md §9).
        // Next valid `$` closer at or after each index.
        var nextDollar = [Int](repeating: n, count: n + 1)
        var i = n - 1
        while i >= 0 {
            nextDollar[i] = nextDollar[i + 1]
            if chars[i].1 == "$", i > 0, !Self.isWhite(chars[i - 1].1), chars[i - 1].1 != "\\",
               !(c(i + 1)?.isASCIIDigit ?? false) {
                nextDollar[i] = i
            }
            i -= 1
        }
        // Next `$$` at or after each index.
        var nextDouble = [Int](repeating: n, count: n + 1)
        i = n - 1
        while i >= 0 {
            nextDouble[i] = (chars[i].1 == "$" && c(i + 1) == "$") ? i : nextDouble[i + 1]
            i -= 1
        }
        // Backtick runs by length, in order, with a cursor each.
        var runs: [Int: [Int]] = [:]
        i = 0
        while i < n {
            if chars[i].1 == "`" {
                var j = i
                while j < n, chars[j].1 == "`" { j += 1 }
                runs[j - i, default: []].append(i)
                i = j
            } else {
                i += 1
            }
        }
        var runCursor: [Int: Int] = [:]

        var delimStack: [Int] = []          // indices into toks of potential openers
        var bottom: [Unicode.Scalar: Int] = [:]
        var brackets: [(tok: Int, image: Bool, stack: Int, active: Bool)] = []
        i = 0
        while i < n {
            let (off, ch) = chars[i]
            switch ch {
            case "\\":
                if let next = c(i + 1), next.isASCIIPunctuation {
                    toks.append(Tok(kind: .char(next), offset: chars[i + 1].0))
                    i += 2
                } else {
                    toks.append(Tok(kind: .char(ch), offset: off))
                    i += 1
                }
            case "\n":
                toks.append(Tok(kind: .lineBreak, offset: off))
                i += 1
            case "`":
                var j = i
                while j < n, chars[j].1 == "`" { j += 1 }
                let len = j - i
                let list = runs[len] ?? []
                var k = runCursor[len] ?? 0
                while k < list.count, list[k] <= i { k += 1 }
                runCursor[len] = k
                if k < list.count {
                    let close = list[k]
                    var content = Array(chars[j..<close])
                    for q in content.indices where content[q].1 == "\n" { content[q].1 = " " }
                    if content.count >= 2, content.first?.1 == " ", content.last?.1 == " ",
                       !content.allSatisfy({ $0.1 == " " }) {
                        content.removeFirst(); content.removeLast()
                    }
                    for (o, s) in content { toks.append(Tok(kind: .char(s), offset: o, style: .code)) }
                    i = close + len
                } else {
                    for q in i..<j { toks.append(Tok(kind: .char("`"), offset: chars[q].0)) }
                    i = j
                }
            case "$":
                if c(i + 1) == "$" {
                    let close = nextDouble[min(i + 2, n)]
                    if close < n, close > i + 2 {
                        let latex = String(String.UnicodeScalarView(chars[(i + 2)..<close].map(\.1)))
                        var tok = Tok(kind: .formula(latex, true), offset: off)
                        tok.latexOffsets = chars[(i + 2)..<close].map(\.0)
                        toks.append(tok)
                        i = close + 2
                    } else {
                        toks.append(Tok(kind: .char("$"), offset: off))
                        toks.append(Tok(kind: .char("$"), offset: chars[i + 1].0))
                        i += 2
                    }
                } else if let next = c(i + 1), !Self.isWhite(next) {
                    let close = nextDollar[min(i + 2, n)]
                    if close < n {
                        let latex = String(String.UnicodeScalarView(chars[(i + 1)..<close].map(\.1)))
                        var tok = Tok(kind: .formula(latex, false), offset: off)
                        tok.latexOffsets = chars[(i + 1)..<close].map(\.0)
                        toks.append(tok)
                        i = close + 1
                    } else {
                        toks.append(Tok(kind: .char("$"), offset: off))
                        i += 1
                    }
                } else {
                    toks.append(Tok(kind: .char("$"), offset: off))
                    i += 1
                }
            case "*", "_", "~":
                var j = i
                while j < n, chars[j].1 == ch { j += 1 }
                let count = j - i
                if ch == "~" && count != 2 {
                    for q in i..<j { toks.append(Tok(kind: .char("~"), offset: chars[q].0)) }
                    i = j
                    continue
                }
                let before = c(i - 1), after = c(j)
                let left = !Self.isWhite(after) && (!Self.isPunct(after) || Self.isWhite(before) || Self.isPunct(before))
                let right = !Self.isWhite(before) && (!Self.isPunct(before) || Self.isWhite(after) || Self.isPunct(after))
                var tok = Tok(kind: .delim(ch), offset: off)
                tok.lo = i; tok.hi = j
                if ch == "_" {
                    tok.canOpen = left && (!right || Self.isPunct(before))
                    tok.canClose = right && (!left || Self.isPunct(after))
                } else {
                    tok.canOpen = left
                    tok.canClose = right
                }
                toks.append(tok)
                let index = toks.count - 1
                if tok.canClose { matchCloser(index, stack: &delimStack, bottom: &bottom) }
                if toks[index].canOpen, toks[index].hi > toks[index].lo { delimStack.append(index) }
                i = j
            case "!" where c(i + 1) == "[":
                toks.append(Tok(kind: .char("!"), offset: off))
                toks.append(Tok(kind: .char("["), offset: chars[i + 1].0))
                brackets.append((toks.count - 1, true, delimStack.count, true))
                i += 2
            case "[":
                toks.append(Tok(kind: .char("["), offset: off))
                brackets.append((toks.count - 1, false, delimStack.count, true))
                i += 1
            case "]":
                guard let b = brackets.last else {
                    toks.append(Tok(kind: .char("]"), offset: off))
                    i += 1
                    continue
                }
                brackets.removeLast()
                if b.active, let (dest, end) = linkTail(after: i) {
                    toks[b.tok].deleted = true
                    if b.image {
                        toks[b.tok - 1].deleted = true
                    } else {
                        let index = linkBase + links.count
                        links.append(dest)
                        for q in (b.tok + 1)..<toks.count where toks[q].link == nil {
                            toks[q].style.insert(.link)
                            toks[q].link = index
                        }
                        // Links do not nest: earlier openers become text.
                        for q in brackets.indices where !brackets[q].image { brackets[q].active = false }
                    }
                    // Emphasis does not cross the link text's end.
                    if delimStack.count > b.stack { delimStack.removeLast(delimStack.count - b.stack) }
                    for (k, v) in bottom where v > delimStack.count { bottom[k] = delimStack.count }
                    i = end
                } else {
                    toks.append(Tok(kind: .char("]"), offset: off))
                    i += 1
                }
            case "<":
                if let (url, end) = autolink(at: i) {
                    let index = linkBase + links.count
                    links.append(url)
                    for q in (i + 1)..<(end - 1) {
                        toks.append(Tok(kind: .char(chars[q].1), offset: chars[q].0, style: .link, link: index))
                    }
                    i = end
                } else {
                    toks.append(Tok(kind: .char("<"), offset: off))
                    i += 1
                }
            default:
                toks.append(Tok(kind: .char(ch), offset: off))
                i += 1
            }
        }
        // Emphasis styles, from per-style coverage counts (a difference array each).
        for style in [MarkdownStyle.bold, .italic, .strike] {
            var delta = [Int](repeating: 0, count: toks.count + 1)
            var any = false
            for e in emphasis where e.style == style && e.lo < e.hi {
                delta[e.lo] += 1
                delta[e.hi] -= 1
                any = true
            }
            guard any else { continue }
            var depth = 0
            for q in toks.indices {
                depth += delta[q]
                if depth > 0 { toks[q].style.insert(style) }
            }
        }
        // Flatten: unused delimiter characters are text.
        var out: [MarkdownAtom] = []
        out.reserveCapacity(toks.count)
        for t in toks where !t.deleted {
            switch t.kind {
            case .char(let s): out.append(MarkdownAtom(.char(s), offset: t.offset, style: t.style, link: t.link))
            case .formula(let latex, let display):
                out.append(MarkdownAtom(.formula(latex: latex, display: display), offset: t.offset, style: t.style, link: t.link,
                                        latexOffsets: t.latexOffsets))
            case .lineBreak: out.append(MarkdownAtom(.lineBreak, offset: t.offset, style: t.style))
            case .delim:
                for q in t.lo..<t.hi {
                    out.append(MarkdownAtom(.char(chars[q].1), offset: chars[q].0, style: t.style, link: t.link))
                }
            }
        }
        return out
    }

    /// Matches the closer `k` against openers on the stack (CommonMark
    /// §6.2 without the multiple-of-3 rule), as often as it can.
    mutating func matchCloser(_ k: Int, stack: inout [Int], bottom: inout [Unicode.Scalar: Int]) {
        guard case .delim(let ch) = toks[k].kind else { return }
        while toks[k].hi > toks[k].lo {
            let floor = min(bottom[ch] ?? 0, stack.count)
            var found: Int?
            var p = stack.count - 1
            while p >= floor {
                let o = stack[p]
                if case .delim(let oc) = toks[o].kind, oc == ch, toks[o].hi > toks[o].lo { found = p; break }
                p -= 1
            }
            guard let at = found else {
                bottom[ch] = stack.count
                return
            }
            let o = stack[at]
            let use: Int
            let style: MarkdownStyle
            if ch == "~" {
                use = 2; style = .strike
            } else if toks[o].hi - toks[o].lo >= 2 && toks[k].hi - toks[k].lo >= 2 {
                use = 2; style = .bold
            } else {
                use = 1; style = .italic
            }
            toks[o].hi -= use
            toks[k].lo += use
            emphasis.append((o + 1, k, style))
            // Delimiters between them are text from now on.
            stack.removeLast(stack.count - at - 1)
            if toks[o].hi == toks[o].lo { stack.removeLast() }
            for (key, v) in bottom where v > stack.count { bottom[key] = stack.count }
        }
    }

    /// `(destination …)` right after the `]` at `i`: the destination and the
    /// index after the `)`.
    func linkTail(after i: Int) -> (String, Int)? {
        var j = i + 1
        guard c(j) == "(" else { return nil }
        j += 1
        let limit = min(chars.count, j + 2 * MarkdownDocument.maxLinkPart + 8)
        func skipSpaces() { while j < limit, let s = c(j), s.isSpaceOrTab || s == "\n" { j += 1 } }
        skipSpaces()
        var dest = String.UnicodeScalarView()
        if c(j) == "<" {
            j += 1
            while j < limit, let s = c(j), s != ">" {
                if s == "\n" || s == "<" { return nil }
                if s == "\\", let e = c(j + 1), e.isASCIIPunctuation { dest.append(e); j += 2; continue }
                dest.append(s)
                j += 1
            }
            guard c(j) == ">" else { return nil }
            j += 1
        } else {
            var depth = 0
            let start = j
            while j < limit, let s = c(j), !s.isSpaceOrTab, s != "\n", !(s.properties.generalCategory == .control) {
                if j - start > MarkdownDocument.maxLinkPart { return nil }
                if s == "\\", let e = c(j + 1), e.isASCIIPunctuation { dest.append(e); j += 2; continue }
                if s == "(" { depth += 1; if depth > 32 { return nil } }
                if s == ")" { if depth == 0 { break }; depth -= 1 }
                dest.append(s)
                j += 1
            }
            guard depth == 0 else { return nil }
        }
        let beforeTitle = j
        skipSpaces()
        if j > beforeTitle, let q = c(j), q == "\"" || q == "'" || q == "(" {
            let close: Unicode.Scalar = q == "(" ? ")" : q
            j += 1
            let start = j
            while j < limit, let s = c(j), s != close {
                if j - start > MarkdownDocument.maxLinkPart { return nil }
                if s == "\\" { j += 1 }
                j += 1
            }
            guard c(j) == close else { return nil }
            j += 1
            skipSpaces()
        }
        guard c(j) == ")" else { return nil }
        return (String(dest), j + 1)
    }

    /// `<scheme:rest>` at `i`: the URL and the index after the `>`.
    func autolink(at i: Int) -> (String, Int)? {
        var j = i + 1
        guard let first = c(j), first.isASCII, first.properties.isAlphabetic else { return nil }
        var schemeLength = 0
        while let s = c(j), s.isASCII, s.properties.isAlphabetic || s.isASCIIDigit || s == "+" || s == "." || s == "-" {
            schemeLength += 1
            j += 1
            if schemeLength > 32 { return nil }
        }
        guard schemeLength >= 2, c(j) == ":" else { return nil }
        j += 1
        let limit = min(chars.count, j + 2048)
        while j < limit, let s = c(j), s != ">" {
            if s == "<" || s.properties.isWhitespace || s.value < 0x20 { return nil }
            j += 1
        }
        guard c(j) == ">" else { return nil }
        return (String(String.UnicodeScalarView(chars[(i + 1)..<j].map(\.1))), j + 1)
    }
}
