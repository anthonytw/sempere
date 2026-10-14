import Foundation

// MARK: - Sheets

extension PageSize {
    /// Largest sheet height `sheetHeight` returns, in points (the renderers' extent limit).
    public static let maxSheetHeight = 200_000.0

    /// Whether the note is pageless: one page that grows downward
    /// (format.md §5.4.3). Paged notes have fixed-size pages.
    public var isPageless: Bool { infinite }

    /// The height of one sheet (format.md §5.4.3): a paged note's page height;
    /// for a pageless note `breakHeight`, else `width × 11 / 8.5` (letter
    /// aspect). A non-finite or non-positive value gives 792; the result is
    /// clamped to 72 ... `maxSheetHeight`.
    public var sheetHeight: Double {
        let h = infinite ? (breakHeight ?? width * 11 / 8.5) : height
        return h.isFinite && h > 0 ? min(max(h, 72), Self.maxSheetHeight) : 792
    }
}

// MARK: - Page edits

/// The ops for one page gesture and the pages they leave.
public struct PageEdit: Hashable, Sendable {
    /// The ops, for one delta, in order.
    public var ops: [Op]
    /// The note's pages afterwards, in display order, with their strokes
    /// (a page the ops add carries the strokes they add to it).
    public var pages: [Page]

    public init(ops: [Op], pages: [Page]) {
        self.ops = ops; self.pages = pages
    }
}

/// A switch between paged and pageless (format.md §5.4.3): one delta's ops,
/// and the pages and page size it leaves.
public struct LayoutEdit: Hashable, Sendable {
    /// The ops, for one delta, in order; empty when the note already has the layout.
    public var ops: [Op]
    /// The note's pages afterwards, in display order, with their strokes.
    public var pages: [Page]
    /// The note's page size afterwards.
    public var pageSize: PageSize

    public init(ops: [Op], pages: [Page], pageSize: PageSize) {
        self.ops = ops; self.pages = pages; self.pageSize = pageSize
    }
}

extension NoteOps {
    /// Pages in reader order: byte-wise by `order`, then by lowercase id
    /// (format.md §5.5), as `NoteReducer` sorts them.
    public static func sortedPages(_ pages: [Page]) -> [Page] {
        pages.sorted(by: pagePrecedes)
    }

    static func pagePrecedes(_ l: Page, _ r: Page) -> Bool {
        if l.order != r.order { return l.order.utf8.lexicographicallyPrecedes(r.order.utf8) }
        return l.id.uuidString.lowercased() < r.id.uuidString.lowercased()
    }

    /// Adds a blank page at `index` (0 = first, `pages.count` = last; clamped)
    /// of `pages` (display order). One `addPage`, plus `setPageOrder` for
    /// neighbours only when no order key fits between them (`PageOrder.keys`).
    public static func addPage(at index: Int, in pages: [Page], id: UUID = UUID()) -> PageEdit {
        insert([Page(id: id, order: "")], at: index, in: pages, ops: { [.addPage(Page(id: $0[0].id, order: $0[0].order))] })
    }

    /// Moves page `id` so it ends up at `index` of the result (clamped): one
    /// `setPageOrder` (more only when neighbours must be re-keyed). Nil when
    /// the page is not in `pages` or would not move.
    public static func movePage(_ id: UUID, to index: Int, in pages: [Page]) -> PageEdit? {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return nil }
        let target = min(max(index, 0), pages.count - 1)
        guard target != from else { return nil }
        var rest = pages
        let page = rest.remove(at: from)
        return insert([page], at: target, in: rest, ops: { [.setPageOrder(pageId: $0[0].id, order: $0[0].order)] })
    }

    /// Deletes page `id`: one `removePage` (its strokes go with it). Nil when
    /// the page is not in `pages`. Undo with `restorePage`.
    public static func deletePage(_ id: UUID, in pages: [Page]) -> PageEdit? {
        guard pages.contains(where: { $0.id == id }) else { return nil }
        return PageEdit(ops: [.removePage(pageId: id)], pages: pages.filter { $0.id != id })
    }

    /// Re-creates a deleted `page` at `index` of `pages` (undo of
    /// `deletePage`, format.md §5.2: a removed id is never added again). The
    /// new page has a new id with `parent` naming the old one, copies of its
    /// strokes and items under new ids with `parent` set, and its recognition
    /// and own paper.
    public static func restorePage(_ page: Page, at index: Int, in pages: [Page], id: UUID = UUID(),
                                   newID: () -> UUID = UUID.init) -> PageEdit {
        copyPage(page, at: index, in: pages, id: id, parent: page.id, strokeParents: true, newID: newID)
    }

    /// Duplicates page `id` just after it: a new page with copies of its
    /// strokes and items (new ids, no `parent`: they are not re-creations),
    /// its recognition and its own paper. Nil when the page is not in `pages`.
    public static func duplicatePage(_ id: UUID, in pages: [Page], newPageID: UUID = UUID(),
                                     newID: () -> UUID = UUID.init) -> PageEdit? {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return nil }
        return copyPage(pages[i], at: i + 1, in: pages, id: newPageID, parent: nil, strokeParents: false, newID: newID)
    }

    private static func copyPage(_ page: Page, at index: Int, in pages: [Page], id: UUID, parent: UUID?,
                                 strokeParents: Bool, newID: () -> UUID) -> PageEdit {
        let strokes = page.strokes.map { moved($0, id: newID(), by: 0, parent: strokeParents ? $0.id : nil) }
        let items = page.items.map { moved($0, id: newID(), by: 0, parent: strokeParents ? $0.id : nil) }
        var copy = Page(id: id, order: "", strokes: strokes, parent: parent, paper: page.paper, items: items)
        copy.recognition = rebased(page.recognition, basisState(page), on: copy)
        return insert([copy], at: index, in: pages) { placed in
            let p = placed[0]
            var ops: [Op] = [.addPage(Page(id: p.id, order: p.order, parent: p.parent))]
            ops += p.strokes.map { .addStroke(page: p.id, stroke: $0) }
            ops += p.items.map { .addItem(page: p.id, item: $0) }
            if let r = p.recognition { ops.append(.setPageRecognition(pageId: p.id, recognition: r)) }
            if let paper = p.paper { ops.append(.setPagePaper(pageId: p.id, paper: paper)) }
            return ops
        }
    }

    /// Places `new` (their `order` is replaced) at `index` of `pages`; `ops`
    /// builds the ops for the placed pages, re-keys of neighbours follow them.
    private static func insert(_ new: [Page], at index: Int, in pages: [Page], ops: ([Page]) -> [Op]) -> PageEdit {
        let at = min(max(index, 0), pages.count)
        let placement = PageOrder.keys(count: new.count, at: at, among: pages.map(\.order))
        var placed = new
        for i in placed.indices { placed[i].order = placement.keys[i] }
        var result = pages
        var rekeyOps: [Op] = []
        for (offset, key) in placement.rekeyed {
            result[offset].order = key
            rekeyOps.append(.setPageOrder(pageId: result[offset].id, order: key))
        }
        result.insert(contentsOf: placed, at: at)
        return PageEdit(ops: ops(placed) + rekeyOps, pages: sortedPages(result))
    }
}

extension PageOrder {
    /// Order keys for `count` pages placed at `index` of a list whose keys
    /// are `orders` (display order), so that they sort right after
    /// `orders[index - 1]` and before `orders[index]`.
    ///
    /// When no keys fit strictly between those neighbours (equal keys from
    /// two devices inserting at the same place, or keys this library would
    /// not generate) the following pages are re-keyed too, one at a time,
    /// until they do: `rekeyed` lists their offsets in `orders` and new keys.
    /// Re-keying past the last page always succeeds.
    static func keys(count: Int, at index: Int, among orders: [String]) -> (keys: [String], rekeyed: [(Int, String)]) {
        let at = min(max(index, 0), orders.count)
        let lower: String? = at > 0 ? orders[at - 1] : nil
        var end = at
        while true {
            let upper: String? = end < orders.count ? orders[end] : nil
            if let run = increasingKeys(count + end - at, after: lower, before: upper) {
                return (Array(run.prefix(count)), Array(zip(at..<end, run.dropFirst(count))))
            }
            if end >= orders.count {
                // Unreachable for any `lower` (a key followed by "V" sorts after it);
                // kept as a defensive fallback that still returns `count` keys.
                var k = lower ?? ""
                let keys = (0..<count).map { _ in k += "V"; return k }
                return (keys, [])
            }
            end += 1
        }
    }

    /// `n` keys strictly increasing (byte-wise) between `lower` and `upper`, or nil.
    private static func increasingKeys(_ n: Int, after lower: String?, before upper: String?) -> [String]? {
        var out: [String] = []
        var prev = lower
        for _ in 0..<n {
            let k = between(prev, upper)
            if let prev, !prev.utf8.lexicographicallyPrecedes(k.utf8) { return nil }
            if let upper, !k.utf8.lexicographicallyPrecedes(upper.utf8) { return nil }
            out.append(k)
            prev = k
        }
        return out
    }
}

// MARK: - Paged and pageless

extension NoteOps {
    /// Most pages a pageless page is split into (format.md §5.4.3).
    public static let maxSheetsPerPage = 10_000

    /// Converts a paged note to pageless (format.md §5.4.3, "join"): the
    /// first page stays and every later page's strokes and items move onto
    /// it, each re-added under a new id (`parent` = old id) shifted down by
    /// the page's offset, in page order: the sheets the earlier pages reach
    /// (`sheetsReached`, one each unless a concurrent edit left ink below a
    /// page) × sheet height. Recognition is concatenated likewise; the later
    /// pages are removed. The page size becomes infinite with `breakHeight` =
    /// the old page height, so the sheets fall where the pages were. A
    /// pageless note with several pages (a concurrent split its own writes
    /// overrode) is joined the same way. Empty `ops` when the note is
    /// pageless with at most one page, or has no pages.
    public static func makePageless(pages: [Page], pageSize: PageSize, newID: () -> UUID = UUID.init) -> LayoutEdit {
        let pages = sortedPages(pages)
        guard let first = pages.first, !pageSize.infinite || pages.count > 1 else {
            return LayoutEdit(ops: [], pages: pages, pageSize: pageSize)
        }
        let h = pageSize.sheetHeight
        var joined = first
        var ops: [Op] = []
        var recognitions: [(Recognition, Double)] = first.recognition.map { [($0, 0)] } ?? []
        var sheets = sheetsReached(first, height: h)
        for page in pages.dropFirst() {
            let dy = Double(sheets) * h
            sheets += sheetsReached(page, height: h)
            for s in page.strokes {
                let copy = moved(s, id: newID(), by: dy, parent: s.id)
                ops.append(.addStroke(page: first.id, stroke: copy))
                joined.strokes.append(copy)
            }
            for item in page.items {
                let copy = moved(item, id: newID(), by: dy, parent: item.id)
                ops.append(.addItem(page: first.id, item: copy))
                joined.items.append(copy)
            }
            if let r = page.recognition { recognitions.append((r, dy)) }
            ops.append(.removePage(pageId: page.id))
        }
        if pages.dropFirst().contains(where: { $0.recognition != nil }) {
            let r = rebased(joinedRecognition(recognitions), combined(pages.map(basisState)), on: joined)
            joined.recognition = r
            ops.append(.setPageRecognition(pageId: first.id, recognition: r))
        }
        let size = PageSize(width: pageSize.width, height: (Double(sheets) * h).rounded(.up), infinite: true,
                            breakHeight: h)
        joined.items.sort(by: Item.drawsBefore)
        ops.append(.setMeta(.pageSize(size)))
        return LayoutEdit(ops: ops, pages: [joined], pageSize: size)
    }

    /// Converts a pageless note to paged (format.md §5.4.3, "split"): each
    /// page is cut into sheets of the note's sheet height `H`
    /// (`PageSize.sheetHeight`). A stroke belongs to the sheet holding the
    /// vertical centre of its transformed control points; strokes of the
    /// first sheet stay where they are, every other stroke is re-added under
    /// a new id (`parent` = old id) on a new page for its sheet, its transform
    /// shifted up by `k × H`, and removed from the old page; items likewise,
    /// by the vertical centre of their frame. A page becomes as many sheets
    /// as its ink, its items or its stored height reach (blank sheets
    /// between keep later ink in place), at most `maxSheetsPerPage`. Words
    /// of recognised text go to the sheet holding their box's centre. New
    /// pages copy the page's own paper. The page size becomes finite,
    /// `width × H`. Empty `ops` when the note is already paged.
    public static func makePaged(pages: [Page], pageSize: PageSize, newID: () -> UUID = UUID.init) -> LayoutEdit {
        guard pageSize.infinite else { return LayoutEdit(ops: [], pages: pages, pageSize: pageSize) }
        let h = pageSize.sheetHeight
        let size = PageSize(width: pageSize.width, height: h, infinite: false)
        var ops: [Op] = []
        var result: [Page] = []
        var sorted = sortedPages(pages)
        // The stored extent counts only for a single page: it is the note's, not a page's.
        let storedSheets = sorted.count == 1 ? sheetCount(height: pageSize.height, sheet: h) : 1
        for pi in sorted.indices {
            let page = sorted[pi]
            var bySheet: [Int: [Stroke]] = [:]
            var lastSheet = storedSheets - 1
            for s in page.strokes {
                let k = sheet(of: s, height: h)
                bySheet[k, default: []].append(s)
                lastSheet = max(lastSheet, k)
            }
            var itemsBySheet: [Int: [Item]] = [:]
            for item in page.items {
                let k = sheetIndex(item.frame.y + item.frame.h / 2, height: h)
                itemsBySheet[k, default: []].append(item)
                lastSheet = max(lastSheet, k)
            }
            let words = sheetWords(page.recognition, height: h, lastSheet: lastSheet)
            var first = page
            first.strokes = bySheet[0] ?? []
            first.items = itemsBySheet[0] ?? []
            // Text without words stays on sheet 0 but describes ink that moved away: stale.
            let wordless = page.recognition?.words.isEmpty ?? false
            let source = basisState(page)
            let state = wordless && lastSheet > 0 && source == .current ? .stale : source
            if page.recognition != nil, lastSheet > 0 {
                first.recognition = rebased(sheetRecognition(page.recognition, words[0] ?? [], dy: 0), state, on: first)
                if first.recognition != page.recognition {
                    ops.append(.setPageRecognition(pageId: page.id, recognition: first.recognition))
                }
            }
            result.append(first)
            guard lastSheet > 0 else { continue }
            // Keys between this page and the next one, in sheet order; later
            // pages are re-keyed only when none fit (equal keys).
            let placement = PageOrder.keys(count: lastSheet, at: pi + 1, among: sorted.map(\.order))
            for (offset, key) in placement.rekeyed {
                sorted[offset].order = key
                ops.append(.setPageOrder(pageId: sorted[offset].id, order: key))
            }
            for k in 1...lastSheet {
                let dy = -Double(k) * h
                var sheet = Page(id: newID(), order: placement.keys[k - 1], paper: page.paper)
                ops.append(.addPage(Page(id: sheet.id, order: sheet.order)))
                for s in bySheet[k] ?? [] {
                    let copy = moved(s, id: newID(), by: dy, parent: s.id)
                    ops.append(.removeStroke(page: page.id, strokeId: s.id))
                    ops.append(.addStroke(page: sheet.id, stroke: copy))
                    sheet.strokes.append(copy)
                }
                for item in itemsBySheet[k] ?? [] {
                    let copy = moved(item, id: newID(), by: dy, parent: item.id)
                    ops.append(.removeItem(page: page.id, itemId: item.id))
                    ops.append(.addItem(page: sheet.id, item: copy))
                    sheet.items.append(copy)
                }
                if let r = rebased(sheetRecognition(page.recognition, words[k] ?? [], dy: dy), state, on: sheet) {
                    sheet.recognition = r
                    ops.append(.setPageRecognition(pageId: sheet.id, recognition: r))
                }
                if let paper = page.paper { ops.append(.setPagePaper(pageId: sheet.id, paper: paper)) }
                sheet.items.sort(by: Item.drawsBefore)
                result.append(sheet)
            }
        }
        ops.append(.setMeta(.pageSize(size)))
        return LayoutEdit(ops: ops, pages: sortedPages(result), pageSize: size)
    }

    /// A copy of `s` under `id` with `parent`, shifted down by `dy`. It keeps
    /// the ink, points and recording link (format.md §5.6: copies keep `rec`);
    /// the snapshot-only `origin` is dropped.
    static func moved(_ s: Stroke, id: UUID, by dy: Double, parent: UUID?) -> Stroke {
        Stroke(id: id, ink: s.ink, points: s.points, transform: dy == 0 ? s.transform : shifted(s.transform, by: dy),
               parent: parent, rec: s.rec)
    }

    /// A copy of `item` under `id` with `parent`, its frame shifted down by
    /// `dy`. Every other field is kept (`rec`, the blob, unknown fields);
    /// the snapshot-only `origin` and `clocks` are dropped.
    static func moved(_ item: Item, id: UUID, by dy: Double, parent: UUID?) -> Item {
        var copy = item
        copy.id = id
        copy.parent = parent
        copy.frame.y += dy
        copy.origin = nil
        copy.clocks = nil
        return copy
    }

    /// The sheets of height `height` a page's ink reaches (format.md §5.4.3):
    /// 1 + the largest sheet of its strokes (`sheet(of:)`) and items (their
    /// frame's vertical centre), at least 1. A page's stored height does not count.
    static func sheetsReached(_ page: Page, height: Double) -> Int {
        var last = 0
        for s in page.strokes { last = max(last, sheet(of: s, height: height)) }
        for item in page.items { last = max(last, sheetIndex(item.frame.y + item.frame.h / 2, height: height)) }
        return last + 1
    }

    /// `t` translated by `dy` after it: `[a b c d tx ty + dy]`; nil (identity) when that is the identity.
    static func shifted(_ t: Transform?, by dy: Double) -> Transform? {
        var m = t ?? .identity
        m.ty += dy
        return m.isIdentity ? nil : m
    }

    /// Whole sheets of height `sheet` in `height` (a pageless page's stored
    /// extent), at least 1, at most `maxSheetsPerPage`. A height within 1 pt
    /// over a multiple counts as that multiple.
    static func sheetCount(height: Double, sheet: Double) -> Int {
        guard height.isFinite, height > 0 else { return 1 }
        let n = ((height + 1) / sheet).rounded(.down)
        return Int(min(max(n, 1), Double(maxSheetsPerPage)))
    }

    /// The sheet holding `y`: `⌊y / height⌋`, 0 for negative or non-finite `y`,
    /// at most `maxSheetsPerPage - 1`.
    static func sheetIndex(_ y: Double, height: Double) -> Int {
        guard y.isFinite, y > 0 else { return 0 }
        return Int(min((y / height).rounded(.down), Double(maxSheetsPerPage - 1)))
    }

    /// The sheet of a stroke: the one holding the vertical centre of its
    /// control points under its transform.
    static func sheet(of stroke: Stroke, height: Double) -> Int {
        let t = stroke.transform ?? .identity
        var lo = Double.infinity, hi = -Double.infinity
        for p in stroke.points {
            let y = t.b * p.x + t.d * p.y + t.ty
            guard y.isFinite else { continue }
            lo = min(lo, y); hi = max(hi, y)
        }
        guard lo <= hi else { return 0 }
        return sheetIndex(lo / 2 + hi / 2, height: height)
    }

    /// Indices of `recognition.words` by sheet (their box's vertical centre;
    /// words beyond `lastSheet` go to it).
    static func sheetWords(_ recognition: Recognition?, height: Double, lastSheet: Int) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for (i, w) in (recognition?.words ?? []).enumerated() {
            out[min(sheetIndex(w.box.y + w.box.h / 2, height: height), lastSheet), default: []].append(i)
        }
        return out
    }

    /// The recognition of one sheet: the words at `indices` with boxes moved
    /// by `dy`, and their text: the words in order, separated by a newline
    /// where the original text has one between them, else a space. When the
    /// words cannot be found in order in the text, they are joined by spaces.
    /// Without words, the whole recognition stays on sheet 0 (`dy == 0`).
    /// Nil when the sheet has no words (and is not sheet 0 of a word-less one).
    static func sheetRecognition(_ r: Recognition?, _ indices: [Int], dy: Double) -> Recognition? {
        guard let r else { return nil }
        if r.words.isEmpty { return dy == 0 ? r : nil }
        guard !indices.isEmpty else { return nil }
        let breaks = lineBreaks(r)
        var text = ""
        var words: [Recognition.Word] = []
        for (n, i) in indices.enumerated() {
            let w = r.words[i]
            if n > 0 {
                let prev = indices[n - 1]
                let newline = breaks.map { b in (prev + 1...i).contains { b[$0] } } ?? false
                text += newline ? "\n" : " "
            }
            text += w.text
            var box = w.box
            box.y += dy
            words.append(Recognition.Word(text: w.text, box: box))
        }
        return Recognition(engine: r.engine, text: text, words: words)
    }

    /// For each word index i > 0: whether the text has a newline between word
    /// i − 1 and word i. Nil when the words are not found in order in `text`.
    static func lineBreaks(_ r: Recognition) -> [Bool]? {
        var out: [Bool] = []
        var rest = r.text[...]
        for w in r.words {
            guard !w.text.isEmpty, let range = rest.range(of: w.text) else { return nil }
            out.append(rest[rest.startIndex..<range.lowerBound].contains("\n"))
            rest = rest[range.upperBound...]
        }
        return out
    }

    /// How current a page's recognition is before its ink moves (format.md
    /// §5.4.3, §5.5): current (its `basis` matches, or the page is blank
    /// without any), unchecked (no `basis`: an import) or stale (another
    /// basis, or ink never read).
    enum MovedBasis: Comparable { case current, unchecked, stale }

    static func basisState(_ page: Page) -> MovedBasis {
        guard let r = page.recognition else { return page.strokes.isEmpty ? .current : .stale }
        guard let basis = r.basis else { return .unchecked }
        return basis == RecognitionBasis.digest(of: page) ? .current : .stale
    }

    /// The state of recognition merged from several pages: the worst of theirs.
    static func combined(_ states: [MovedBasis]) -> MovedBasis { states.max() ?? .current }

    /// `r` on `page` (its final strokes) with the `basis` a moved recognition
    /// gets (format.md §5.4.3): the page's digest when every source was
    /// current, none when one was unchecked, and one that matches no strokes
    /// (the digest of a fresh id) when one was stale, so it is read again.
    static func rebased(_ r: Recognition?, _ state: MovedBasis, on page: Page) -> Recognition? {
        guard var r else { return nil }
        switch state {
        case .current: r.basis = RecognitionBasis.digest(of: page)
        case .unchecked: r.basis = nil
        case .stale: r.basis = RecognitionBasis.digest(of: [UUID()])
        }
        return r
    }

    /// Recognitions of consecutive pages joined onto one: texts separated by
    /// newlines, boxes moved down by each page's offset; the first engine.
    static func joinedRecognition(_ parts: [(Recognition, Double)]) -> Recognition? {
        guard let engine = parts.first?.0.engine else { return nil }
        var words: [Recognition.Word] = []
        for (r, dy) in parts {
            for w in r.words {
                var box = w.box
                box.y += dy
                words.append(Recognition.Word(text: w.text, box: box))
            }
        }
        return Recognition(engine: engine, text: parts.map(\.0.text).joined(separator: "\n"), words: words)
    }
}
