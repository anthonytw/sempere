import Foundation

/// The recognised text of one page, as search sees it.
public struct PageText: Hashable, Sendable, Codable {
    /// A part of `text` that came from one source: the recognised handwriting, one text box, one PDF page or
    /// one equation (offsets in UTF-16 units, `start ..< end`, the newline between parts excluded).
    public struct Span: Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int
        /// The part is an equation's LaTeX source: searchable, but never quoted in a snippet.
        public var isMath: Bool

        public init(start: Int, end: Int, isMath: Bool = false) {
            self.start = start; self.end = end; self.isMath = isMath
        }
    }

    public var pageId: UUID
    /// 1-based position of the page in the note.
    public var number: Int
    public var text: String
    /// The parts `text` is made of, in order. Empty: one prose part (text built by hand).
    public var spans: [Span]

    public init(pageId: UUID, number: Int, text: String, spans: [Span] = []) {
        self.pageId = pageId; self.number = number; self.text = text; self.spans = spans
    }

    /// The pages of a note (in display order) that have searchable text: the
    /// recognised handwriting, then the text of each text box and the page
    /// text of each PDF page and the LaTeX source of each equation in drawing
    /// order (format.md §8.2.4, §8.2.6, §8.2.8),
    /// joined by newlines. `spans` says which part is which, so a snippet
    /// can stay inside one part and leave equations out.
    public static func texts(of pages: [Page]) -> [PageText] {
        pages.enumerated().compactMap { i, p in
            var parts: [(text: String, math: Bool)] = []
            if let text = p.recognition?.text, !text.isEmpty { parts.append((text, false)) }
            for item in p.items.sorted(by: Item.drawsBefore) {
                switch item.kind {
                case .text: if let text = item.text.map(MarkdownText.searchText), !text.isEmpty { parts.append((text, false)) }
                case .pdfPage: if let text = item.pageText?.text, !text.isEmpty { parts.append((text, false)) }
                case .math: if let latex = item.math?.latex, !latex.isEmpty { parts.append((latex, true)) }
                default: break
                }
            }
            guard !parts.isEmpty else { return nil }
            var spans: [Span] = []
            var offset = 0
            for part in parts {
                let length = part.text.utf16.count
                spans.append(Span(start: offset, end: offset + length, isMath: part.math))
                offset += length + 1   // the joining newline
            }
            return PageText(pageId: p.id, number: i + 1, text: parts.map(\.text).joined(separator: "\n"), spans: spans)
        }
    }
}

/// One note found by `NoteSearch`.
public struct NoteSearchHit: Hashable, Sendable, Identifiable {
    /// What a query word matched in a note.
    public enum Field: Int, Hashable, Sendable, Comparable, CaseIterable {
        case title, tag, notebook, text
        public static func < (a: Field, b: Field) -> Bool { a.rawValue < b.rawValue }
    }

    /// A piece of page text around the first match.
    public struct Snippet: Hashable, Sendable {
        public var text: String
        /// Where the query words are in `text`.
        public var matches: [Range<String.Index>]
        /// The match is inside an equation: `text` is the marker `NoteSearch.equationMarker` (an app shows
        /// its own localized one), never the LaTeX source.
        public var isEquation = false

        public init(text: String, matches: [Range<String.Index>], isEquation: Bool = false) {
            self.text = text; self.matches = matches; self.isEquation = isEquation
        }
    }

    public var id: UUID { note }
    public var note: UUID
    /// Where the query matched, in `Field` order.
    public var fields: [Field]
    /// The page the match is on: the one with most of the query's words
    /// (the first of them on a tie). Nil when only title, tags or notebook matched.
    public var page: PageText?
    public var snippet: Snippet?
    /// How many pages have at least one query word.
    public var matchedPages: Int
    public var score: Int
}

/// Search over note titles, notebooks, tags and recognised handwriting
/// (`NoteSummary.pageTexts`).
///
/// A query is words separated by whitespace; a note matches when every word
/// is found somewhere in it (case, accents and width ignored, substrings
/// count). A word starting with `#` only matches tags. Cost: O(Σ text length
/// × words). With a `NoteSearchIndex`, page text and words that are all ASCII
/// are compared as lowercased bytes (`ASCIIFold`, which gives Foundation's
/// answer for them); the rest goes through Foundation's insensitive compare.
public enum NoteSearch {
    /// Caps keep a pathological query or page from costing more than the text itself.
    public static let maxWords = 12
    public static let snippetBefore = 50
    public static let snippetAfter = 90

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    struct Word: Hashable {
        var text: String
        var tagOnly: Bool
    }

    static func words(_ query: String) -> [Word] {
        var seen = Set<Word>()
        var out: [Word] = []
        for raw in query.split(whereSeparator: \.isWhitespace) {
            var w = String(raw)
            let tagOnly = w.hasPrefix("#")
            if tagOnly { w.removeFirst() }
            guard !w.isEmpty else { continue }
            let word = Word(text: w, tagOnly: tagOnly)
            if seen.insert(word).inserted { out.append(word) }
            if out.count == maxWords { break }
        }
        return out
    }

    /// The notes of `notes` matching `query`, best first (score, then newest, then title).
    /// An empty query matches nothing.
    ///
    /// - Parameters:
    ///   - index: lowercased page text kept between searches (an app searching as the user types),
    ///     searched as bytes where page and word are ASCII; nil searches every page through Foundation.
    ///   - isCancelled: checked between notes; when it returns true the search stops and returns
    ///     no hits (the caller drops the result).
    public static func search(_ query: String, in notes: [NoteSummary], index: NoteSearchIndex? = nil,
                              isCancelled: () -> Bool = { false }) -> [NoteSearchHit] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        let needles = words.map { ASCIIFold.needle($0.text) }
        var hits: [NoteSearchHit] = []
        for (n, note) in notes.enumerated() {
            if n % 64 == 0, isCancelled() { return [] }
            // Without an index pages are not folded: folding a page costs a pass over all of it, while
            // Foundation stops at the first match, so it only pays off when the folds are kept.
            let folded = index?.foldedPages(of: note) ?? []
            if let h = hit(words, needles: needles, folded: folded, in: note) { hits.append(h) }
        }
        index?.trim(keeping: notes)
        return sorted(hits, notes: notes)
    }

    /// `hits` (of notes in `notes`) in `search`'s order: score, then newest, then title, then id.
    public static func sorted(_ hits: [NoteSearchHit], notes: [NoteSummary]) -> [NoteSearchHit] {
        // Not `uniqueKeysWithValues`: a list holding one id twice must not trap.
        let modified = Dictionary(notes.map { ($0.id, $0.modified ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        let titles = Dictionary(notes.map { ($0.id, $0.title.lowercased()) }, uniquingKeysWith: { a, _ in a })
        return hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let (a, b) = (modified[$0.id] ?? .distantPast, modified[$1.id] ?? .distantPast)
            if a != b { return a > b }
            return (titles[$0.id] ?? "", $0.id.uuidString) < (titles[$1.id] ?? "", $1.id.uuidString)
        }
    }

    /// The search's result after notes `changed` (by id) of the searched list changed: `previous` (the hits
    /// of `query` over the list before) without those notes, plus the hits of `query` among the changed notes
    /// still in `notes`, in `search`'s order. Equal to `search(query, in: notes)` when `previous` was that
    /// search's result over the earlier list and every note whose summary differs is in `changed`.
    public static func updated(_ previous: [NoteSearchHit], query: String, changed: Set<UUID>, in notes: [NoteSummary],
                               index: NoteSearchIndex? = nil) -> [NoteSearchHit] {
        let retested = notes.filter { changed.contains($0.id) }
        let fresh = search(query, in: retested, index: index)
        return sorted(previous.filter { !changed.contains($0.note) } + fresh, notes: notes)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: options) != nil
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: options) == .orderedSame
    }

    private static func hit(_ words: [Word], needles: [[UInt8]?], folded: [[UInt8]?],
                            in note: NoteSummary) -> NoteSearchHit? {
        var fields = Set<NoteSearchHit.Field>()
        var score = 0
        var pageWords: [Int: Set<Int>] = [:]   // page index → indices of words found there
        for (wi, word) in words.enumerated() {
            var best = 0
            if !word.tagOnly {
                if contains(note.title, word.text) {
                    fields.insert(.title)
                    best = max(best, equal(note.title, word.text) ? 150 : 100)
                }
                if let nb = NotebookPath.canonical(note.notebook), contains(nb, word.text) {
                    fields.insert(.notebook)
                    best = max(best, NotebookPath.components(nb).contains { equal($0, word.text) } ? 50 : 30)
                }
            }
            for tag in note.tags where contains(tag, word.text) {
                fields.insert(.tag)
                best = max(best, equal(tag, word.text) ? 80 : 40)
            }
            if !word.tagOnly {
                for (pi, page) in note.pageTexts.enumerated() {
                    // All-ASCII page and word: byte search, Foundation's answer for them (`ASCIIFold`).
                    if pi < folded.count, let hay = folded[pi], let needle = needles[wi] {
                        guard ASCIIFold.contains(hay, needle) else { continue }
                    } else {
                        guard contains(page.text, word.text) else { continue }
                    }
                    fields.insert(.text)
                    pageWords[pi, default: []].insert(wi)
                    best = max(best, 10)
                }
            }
            if best == 0 { return nil }   // every word must be found
            score += best
        }
        var page: PageText?
        var snippet: NoteSearchHit.Snippet?
        if let bestIndex = pageWords.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) })?.key {
            let best = note.pageTexts[bestIndex]
            page = best
            snippet = Self.snippet(best, words: words.map(\.text))
            score += 5 * (pageWords[bestIndex]?.count ?? 0) + min(pageWords.count, 5)
        }
        return NoteSearchHit(note: note.id, fields: fields.sorted(), page: page, snippet: snippet,
                             matchedPages: pageWords.count, score: score)
    }

    /// What a snippet says when the match is inside an equation.
    public static let equationMarker = "[equation]"

    /// An excerpt of `page` around the first match of any of `words` in its prose (handwriting, a text box, a PDF
    /// page), never crossing into the neighbouring part and starting and ending at word boundaries. When the
    /// words are only in equations the snippet is `equationMarker`: LaTeX source is searched but not quoted.
    /// Nil when no part matches.
    static func snippet(_ page: PageText, words: [String]) -> NoteSearchHit.Snippet? {
        let text = page.text
        let spans = page.spans.isEmpty ? [PageText.Span(start: 0, end: text.utf16.count)] : page.spans
        var inEquation = false
        for span in spans {
            guard let part = substring(of: text, span), !part.isEmpty else { continue }
            let hit = firstMatch(of: words, in: part)
            if span.isMath { if hit != nil { inEquation = true }; continue }
            if hit != nil { return excerpt(part, words: words) }
        }
        return inEquation ? NoteSearchHit.Snippet(text: equationMarker, matches: [], isEquation: true) : nil
    }

    /// `snippet(_:words:)` for plain text (one prose part).
    static func snippet(_ text: String, words: [String]) -> NoteSearchHit.Snippet? {
        snippet(PageText(pageId: UUID(), number: 1, text: text), words: words)
    }

    /// The part of `text` a span names. Through Unicode scalars, not characters: a part ending in
    /// `\r` forms one character (`\r\n`) with the joining newline, so its end is no character boundary.
    private static func substring(of text: String, _ span: PageText.Span) -> String? {
        let u = text.utf16, scalars = text.unicodeScalars
        guard span.start >= 0, span.end >= span.start, span.end <= u.count,
              let lo = u.index(u.startIndex, offsetBy: span.start, limitedBy: u.endIndex),
              let hi = u.index(u.startIndex, offsetBy: span.end, limitedBy: u.endIndex),
              let a = lo.samePosition(in: scalars), let b = hi.samePosition(in: scalars) else { return nil }
        return String(scalars[a..<b])
    }

    private static func firstMatch(of words: [String], in flat: String) -> Range<String.Index>? {
        var first: Range<String.Index>?
        for w in words {
            if let r = flat.range(of: w, options: options), first.map({ r.lowerBound < $0.lowerBound }) ?? true { first = r }
        }
        return first
    }

    /// A line-flattened excerpt of `part` around its first match of any of `words`, cut at word boundaries.
    private static func excerpt(_ part: String, words: [String]) -> NoteSearchHit.Snippet? {
        let flat = String(part.map { $0.isNewline ? " " : $0 })
        guard let first = firstMatch(of: words, in: flat) else { return nil }
        var lower = flat.index(first.lowerBound, offsetBy: -snippetBefore, limitedBy: flat.startIndex) ?? flat.startIndex
        var upper = flat.index(first.upperBound, offsetBy: snippetAfter, limitedBy: flat.endIndex) ?? flat.endIndex
        // A cut inside a word moves to the word's edge nearer the match (never past the match).
        if lower > flat.startIndex {
            while lower < first.lowerBound, !flat[lower].isWhitespace, !flat[flat.index(before: lower)].isWhitespace {
                lower = flat.index(after: lower)
            }
        }
        if upper < flat.endIndex {
            while upper > first.upperBound, !flat[flat.index(before: upper)].isWhitespace, !flat[upper].isWhitespace {
                upper = flat.index(before: upper)
            }
        }
        let cutBefore = lower > flat.startIndex, cutAfter = upper < flat.endIndex
        let body = String(flat[lower..<upper]).trimmingCharacters(in: .whitespaces)
        let shown = (cutBefore ? "…" : "") + body + (cutAfter ? "…" : "")
        var matches: [Range<String.Index>] = []
        for w in words {
            var from = shown.startIndex
            while from < shown.endIndex, let r = shown.range(of: w, options: options, range: from..<shown.endIndex) {
                matches.append(r)
                from = r.upperBound
            }
        }
        return .init(text: shown, matches: matches.sorted { $0.lowerBound < $1.lowerBound })
    }
}

/// ASCII text lowercased, for `NoteSearch`: for a haystack and a needle that
/// are both ASCII, Foundation's case-, diacritic- and width-insensitive
/// search finds the needle exactly when the lowercased bytes contain the
/// lowercased needle, as long as the needle holds no line break (ASCII has
/// no accents, width variants, ligatures or characters that fold to several,
/// and CR LF is its only multi-scalar character; `NoteSearchIndexTests`
/// checks it against Foundation). Anything else is left to Foundation.
enum ASCIIFold {
    /// `text`'s bytes with A-Z lowercased; nil when it is not all ASCII.
    static func folded(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for b in text.utf8 {
            guard b < 0x80 else { return nil }
            out.append(b >= 0x41 && b <= 0x5A ? b | 0x20 : b)
        }
        return out
    }

    /// A query word folded, or nil when it is not all ASCII or holds a line
    /// break or a NUL: CR LF is one character, which Foundation never matches
    /// in part (`NoteSearch` words never hold white space anyway), and
    /// swift-corelibs-foundation ends a search string at a NUL.
    static func needle(_ word: String) -> [UInt8]? {
        guard let bytes = folded(word), !bytes.contains(0x0A), !bytes.contains(0x0D), !bytes.contains(0) else { return nil }
        return bytes
    }

    /// Whether `needle` occurs in `haystack` (bytes).
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = haystack.count
        guard n > 0 else { return true }
        guard n <= h else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { nd in
                let first = nd[0]
                var i = 0
                let last = h - n
                while i <= last {
                    if hay[i] == first {
                        var k = 1
                        while k < n, hay[i + k] == nd[k] { k += 1 }
                        if k == n { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}

/// Lowercased page text (`ASCIIFold`) kept between searches, per note: built
/// the first time a note is searched and used again while the note's
/// `pageTexts` are the same (compared on each use, so a note whose
/// recognised text or text boxes changed is folded again). Memory: about one
/// byte per byte of ASCII page text. Thread-safe.
public final class NoteSearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: (pages: [PageText], folded: [[UInt8]?])] = [:]

    public init() {}

    /// The folded text of each of `note`'s pages (nil for a page that is not all ASCII).
    func foldedPages(of note: NoteSummary) -> [[UInt8]?] {
        lock.lock()
        let cached = entries[note.id]
        lock.unlock()
        // Equal strings that share storage compare in O(1); changed text compares unequal.
        if let cached, cached.pages == note.pageTexts { return cached.folded }
        let folded = note.pageTexts.map { ASCIIFold.folded($0.text) }
        lock.lock()
        entries[note.id] = (note.pageTexts, folded)
        lock.unlock()
        return folded
    }

    /// Drops the entries of notes not in `notes` once the index holds many more notes than were searched.
    func trim(keeping notes: [NoteSummary]) {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count > 2 * notes.count + 1_000 else { return }
        let ids = Set(notes.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
    }

    /// Forgets everything (the vault closed).
    public func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }

    /// Notes with folded text held.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

/// One word of recognised handwriting that a search matched, with its box
/// on the page (`format.md` §5.5): what the canvas highlights.
public struct SearchMatch: Hashable, Sendable, Codable {
    public var pageId: UUID
    /// 1-based position of the page in the note.
    public var page: Int
    /// The recognised word, or the matched text of a text box.
    public var text: String
    public var box: Recognition.Box
    /// The text box the match is in; nil for recognised handwriting.
    public var item: UUID?

    public init(pageId: UUID, page: Int, text: String, box: Recognition.Box, item: UUID? = nil) {
        self.pageId = pageId; self.page = page; self.text = text; self.box = box; self.item = item
    }
}

/// Where the words fall in a text box, in page points (needs text layout, so the caller supplies it:
/// `TextMatchBoxes` in SempereRender with the CLI's or the app's shaper). Only called for boxes whose text
/// contains one of the words.
public typealias TextBoxMatcher = @Sendable (_ words: [String], _ item: Item) -> [(text: String, box: Recognition.Box)]

/// Where a query's words are on a note's pages.
public enum SearchMatches {
    /// Caps the list: a page holds at most this many words in total, but a
    /// hostile note may claim more, and the UI steps through them one by one.
    public static let maxMatches = 10_000

    /// The recognised words of `pages` containing a word of `query` (case,
    /// accents and width ignored, substrings count, `#tag` words and boxes
    /// that cannot be drawn (`isDrawable`) skipped), in
    /// page order and, within a page, in the order the words are stored
    /// (reading order). Pages without word boxes give none, so a page
    /// found by text alone has no match here. Cost: O(Σ words × query words).
    public static func matches(_ query: String, in pages: [Page], textBoxes: TextBoxMatcher? = nil) -> [SearchMatch] {
        let words = NoteSearch.words(query).filter { !$0.tagOnly }.map(\.text)
        return matches(words: words, in: pages, textBoxes: textBoxes)
    }

    /// Largest coordinate or size of a box that is highlighted (points).
    public static let maxBoxCoordinate = 1e9

    /// Whether `box` can be drawn: every value finite and at most
    /// `maxBoxCoordinate` in size, `w` and `h` not negative. Boxes come from
    /// the vault (`format.md` §9): a box of `1e308` turns infinite once
    /// scaled for the screen, and a canvas layer at a NaN position traps.
    public static func isDrawable(_ box: Recognition.Box) -> Bool {
        [box.x, box.y, box.w, box.h].allSatisfy { $0.isFinite && abs($0) <= maxBoxCoordinate } && box.w >= 0 && box.h >= 0
    }

    /// `matches(_:in:)` for already split words (any of them matches). With `textBoxes`, the words found in
    /// the page's text boxes follow the page's recognised words (text boxes in drawing order, each in reading order).
    public static func matches(words: [String], in pages: [Page], textBoxes: TextBoxMatcher? = nil) -> [SearchMatch] {
        guard !words.isEmpty else { return [] }
        var out: [SearchMatch] = []
        for (index, page) in pages.enumerated() {
            for word in page.recognition?.words ?? [] where isDrawable(word.box) {
                guard words.contains(where: { word.text.range(of: $0, options: NoteSearch.options) != nil }) else { continue }
                out.append(SearchMatch(pageId: page.id, page: index + 1, text: word.text, box: word.box))
                if out.count >= maxMatches { return out }
            }
            guard let textBoxes else { continue }
            for item in page.items.sorted(by: Item.drawsBefore) where item.kind == .text {
                // Laying a text out is the costly part: only boxes that contain a word.
                guard let string = item.text.map(MarkdownText.searchText),
                      words.contains(where: { string.range(of: $0, options: NoteSearch.options) != nil }) else { continue }
                for found in textBoxes(words, item) where isDrawable(found.box) {
                    out.append(SearchMatch(pageId: page.id, page: index + 1, text: found.text, box: found.box, item: item.id))
                    if out.count >= maxMatches { return out }
                }
            }
        }
        return out
    }
}

/// Steps through the matches of a search in one note (across its pages): the
/// canvas highlights them and shows "3 of 12" with next and previous buttons.
public struct SearchMatchCursor: Sendable, Hashable {
    /// Page order, then reading order (`SearchMatches`).
    public private(set) var matches: [SearchMatch]
    /// Index of the current match in `matches`.
    public private(set) var index: Int
    /// The words being looked for, kept so the list can be rebuilt after the pages change.
    public let words: [String]
    /// How text boxes are searched (nil: only recognised handwriting); kept for `refreshed`.
    private let textBoxes: TextBoxMatcher?

    public static func == (a: SearchMatchCursor, b: SearchMatchCursor) -> Bool {
        a.matches == b.matches && a.index == b.index && a.words == b.words
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(matches); hasher.combine(index); hasher.combine(words)
    }

    /// The cursor for `query` over `pages`, on the first match of
    /// `preferredPage` when it has one (the page a search result named), else
    /// on the first match; nil when no word has a box.
    public init?(query: String, pages: [Page], preferredPage: UUID? = nil, textBoxes: TextBoxMatcher? = nil) {
        let words = NoteSearch.words(query).filter { !$0.tagOnly }.map(\.text)
        let found = SearchMatches.matches(words: words, in: pages, textBoxes: textBoxes)
        guard !found.isEmpty else { return nil }
        self.words = words
        self.textBoxes = textBoxes
        matches = found
        index = preferredPage.flatMap { p in found.firstIndex { $0.pageId == p } } ?? 0
    }

    public var count: Int { matches.count }
    public var current: SearchMatch { matches[index] }
    /// 1-based, as shown ("3 of 12").
    public var position: Int { index + 1 }

    /// Moves by `delta` matches, wrapping around the end of the note.
    public mutating func step(_ delta: Int) {
        let n = matches.count
        index = ((index + delta) % n + n) % n
    }

    /// The matches on page `id` with their index in `matches`.
    public func matches(onPage id: UUID) -> [(index: Int, match: SearchMatch)] {
        matches.enumerated().filter { $0.element.pageId == id }.map { ($0.offset, $0.element) }
    }

    /// Rebuilds the list for `pages` (their recognition changed), staying on the
    /// current match when it is still there, else the first one after it
    /// (by page and position); nil when nothing matches any more.
    public func refreshed(pages: [Page]) -> SearchMatchCursor? {
        let found = SearchMatches.matches(words: words, in: pages, textBoxes: textBoxes)
        guard !found.isEmpty else { return nil }
        var copy = self
        copy.matches = found
        let now = current
        if let same = found.firstIndex(of: now) {
            copy.index = same
        } else {
            let order = pages.map(\.id)
            let rank = { (m: SearchMatch) in order.firstIndex(of: m.pageId) ?? Int.max }
            copy.index = found.firstIndex { rank($0) > rank(now) || (rank($0) == rank(now) && $0.box.y >= now.box.y) } ?? 0
        }
        return copy
    }
}
