import Foundation
import XCTest
@testable import Sempere

/// Page gestures and the paged/pageless switch (format.md §5.4.3): the ops,
/// and that the pages they predict are what a reader reconstructs.
final class PageEditTests: XCTestCase {
    private func ink(_ y: Double, x: Double = 10, transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
               points: [StrokePoint(x: x, y: y - 5, w: 2, h: 2), StrokePoint(x: x + 50, y: y + 5, w: 2, h: 2)],
               transform: transform)
    }

    /// A log that creates `pages` (in order, with their strokes) and `size`.
    private func base(_ log: inout LogBuilder, _ pages: [Page], size: PageSize = .letter) -> Revision {
        var ops: [Op] = [.setMeta(.pageSize(size))]
        for p in pages {
            ops.append(.addPage(Page(id: p.id, order: p.order)))
            ops += p.strokes.map { .addStroke(page: p.id, stroke: $0) }
            ops += p.items.map { .addItem(page: p.id, item: $0) }
            if let r = p.recognition { ops.append(.setPageRecognition(pageId: p.id, recognition: r)) }
            if let paper = p.paper { ops.append(.setPagePaper(pageId: p.id, paper: paper)) }
        }
        return log.delta(devA, 0, ops)
    }

    /// The reconstructed pages match the prediction: ids, order keys, stroke ids, recognition, paper.
    private func assertMatches(_ state: NoteState, _ pages: [Page], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.pages.map(\.id), pages.map(\.id), file: file, line: line)
        XCTAssertEqual(state.pages.map(\.order), pages.map(\.order), file: file, line: line)
        XCTAssertEqual(state.strokeIds, pages.map { $0.strokes.map(\.id) }, file: file, line: line)
        XCTAssertEqual(state.pages.map(\.recognition), pages.map(\.recognition), file: file, line: line)
        XCTAssertEqual(state.pages.map(\.paper), pages.map(\.paper), file: file, line: line)
        XCTAssertEqual(state.pages.map { $0.strokes.map(\.rec) }, pages.map { $0.strokes.map(\.rec) },
                       file: file, line: line)
    }

    private let recording = UUID()

    /// A stroke drawn while a recording ran (format.md §8.3.3).
    private func recorded(_ y: Double, at seconds: Double) -> Stroke {
        var s = ink(y)
        s.rec = RecordingLink(id: recording, at: seconds)
        return s
    }

    /// The items the ops add, by page, and the ids they remove. The reducer
    /// does not merge items yet (A1), so item moves are checked on the ops.
    private func itemOps(_ ops: [Op]) -> (added: [UUID: [Item]], removed: [UUID]) {
        var added: [UUID: [Item]] = [:], removed: [UUID] = []
        for op in ops {
            if case .addItem(let page, let item) = op { added[page, default: []].append(item) }
            if case .removeItem(_, let id) = op { removed.append(id) }
        }
        return (added, removed)
    }

    /// A text box (synthetic content) whose frame is centred at `y`.
    private func box(_ y: Double, z: String = "V") -> Item {
        .text(TextContent(size: 12, color: .black, runs: [TextRun("box")]),
              frame: Rect(x: 20, y: y - 10, w: 100, h: 20), z: z, rec: RecordingLink(id: recording, at: 2))
    }

    private func three() -> [Page] {
        [Page(order: "V", strokes: [ink(100)]), Page(order: "k", strokes: [ink(200)]), Page(order: "s")]
    }

    // MARK: Gestures

    func testAddPageAfterCurrentAndAtEnd() throws {
        var log = LogBuilder()
        let pages = three()
        let d0 = base(&log, pages)
        let after = NoteOps.addPage(at: 1, in: pages)
        XCTAssertEqual(after.ops.count, 1)
        guard case .addPage(let added) = after.ops[0] else { return XCTFail("\(after.ops)") }
        XCTAssertTrue(added.strokes.isEmpty)
        XCTAssertEqual(after.pages.map(\.id), [pages[0].id, added.id, pages[1].id, pages[2].id])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, after.ops)]), after.pages)

        let end = NoteOps.addPage(at: 99, in: after.pages)
        XCTAssertEqual(end.pages.last?.id, end.ops.first.flatMap { if case .addPage(let p) = $0 { p.id } else { nil } })
    }

    func testMovePageIsOneSetPageOrder() throws {
        var log = LogBuilder()
        let pages = three()
        let d0 = base(&log, pages)
        let edit = try XCTUnwrap(NoteOps.movePage(pages[2].id, to: 0, in: pages))
        XCTAssertEqual(edit.ops.count, 1)
        XCTAssertEqual(edit.pages.map(\.id), [pages[2].id, pages[0].id, pages[1].id])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, edit.ops)]), edit.pages)
        XCTAssertNil(NoteOps.movePage(pages[1].id, to: 1, in: pages), "not moving writes nothing")
        XCTAssertNil(NoteOps.movePage(UUID(), to: 0, in: pages))
    }

    /// Two devices inserted at the same place and got the same key: there is
    /// no key between them, so the writer re-keys the following page.
    func testMoveBetweenEqualKeysRekeys() throws {
        var log = LogBuilder()
        let a = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let pages = [Page(id: a, order: "V"), Page(id: b, order: "V"), Page(order: "k")]
        let d0 = base(&log, pages)
        let edit = try XCTUnwrap(NoteOps.movePage(pages[2].id, to: 1, in: pages))
        XCTAssertEqual(edit.pages.map(\.id), [a, pages[2].id, b])
        XCTAssertEqual(edit.ops.count, 2)
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, edit.ops)]), edit.pages)
    }

    func testDeleteAndUndoRecreatesThePage() throws {
        var log = LogBuilder()
        var pages = three()
        pages[1].recognition = Recognition(engine: "t", text: "hello", words: [])
        pages[1].paper = Paper(kind: .grid)
        let d0 = base(&log, pages)
        let del = try XCTUnwrap(NoteOps.deletePage(pages[1].id, in: pages))
        XCTAssertEqual(del.ops, [.removePage(pageId: pages[1].id)])
        let d1 = log.delta(devA, 10, del.ops)
        let after = try NoteReducer.reconstruct([d0, d1])
        assertMatches(after, del.pages)

        let undo = NoteOps.restorePage(pages[1], at: 1, in: del.pages)
        let restored = undo.pages[1]
        XCTAssertNotEqual(restored.id, pages[1].id)
        XCTAssertEqual(restored.parent, pages[1].id)
        XCTAssertEqual(restored.strokes.map(\.parent), pages[1].strokes.map(\.id))
        XCTAssertEqual(restored.strokes.map(\.points), pages[1].strokes.map(\.points))
        let state = try NoteReducer.reconstruct([d0, d1, log.delta(devA, 20, undo.ops)])
        assertMatches(state, undo.pages)
        XCTAssertEqual(state.pages[1].parent, pages[1].id)
    }

    func testDuplicateGoesRightAfterWithFreshIds() throws {
        var log = LogBuilder()
        var pages = three()
        pages[0].paper = Paper(kind: .dot)
        let d0 = base(&log, pages)
        let dup = try XCTUnwrap(NoteOps.duplicatePage(pages[0].id, in: pages))
        XCTAssertEqual(dup.pages.count, 4)
        XCTAssertEqual(dup.pages[0].id, pages[0].id)
        let copy = dup.pages[1]
        XCTAssertNil(copy.parent)
        XCTAssertEqual(copy.paper, Paper(kind: .dot))
        XCTAssertEqual(copy.strokes.map(\.points), pages[0].strokes.map(\.points))
        XCTAssertTrue(Set(copy.strokes.map(\.id)).isDisjoint(with: pages[0].strokes.map(\.id)))
        XCTAssertEqual(copy.strokes.map(\.parent), [nil])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, dup.ops)]), dup.pages)
    }

    /// Undo of a delete and duplicate carry the page's items and the strokes'
    /// recording links: format.md §5.7 restores items, §5.6 copies keep `rec`.
    func testRestoreAndDuplicateKeepItemsAndRecordingLinks() throws {
        var log = LogBuilder()
        var pages = three()
        pages[1].strokes = [recorded(200, at: 1.5)]
        pages[1].items = [box(300)]
        let d0 = base(&log, pages)
        let del = try XCTUnwrap(NoteOps.deletePage(pages[1].id, in: pages))
        let d1 = log.delta(devA, 10, del.ops)

        let undo = NoteOps.restorePage(pages[1], at: 1, in: del.pages)
        let restored = undo.pages[1]
        XCTAssertEqual(restored.strokes.map(\.rec), [RecordingLink(id: recording, at: 1.5)])
        XCTAssertEqual(restored.items.map(\.parent), pages[1].items.map(\.id))
        XCTAssertEqual(restored.items.map(\.frame), pages[1].items.map(\.frame))
        XCTAssertEqual(restored.items.map(\.rec), pages[1].items.map(\.rec))
        XCTAssertTrue(Set(restored.items.map(\.id)).isDisjoint(with: pages[1].items.map(\.id)))
        XCTAssertEqual(itemOps(undo.ops).added, [restored.id: restored.items])
        XCTAssertEqual(restored.items.map(\.text), pages[1].items.map(\.text))
        assertMatches(try NoteReducer.reconstruct([d0, d1, log.delta(devA, 20, undo.ops)]), undo.pages)

        let dup = try XCTUnwrap(NoteOps.duplicatePage(pages[1].id, in: pages))
        let copy = dup.pages[2]
        XCTAssertEqual(copy.items.count, 1)
        let copied = try XCTUnwrap(copy.items.first)
        XCTAssertNil(copied.parent)
        XCTAssertNotEqual(copied.id, pages[1].items[0].id)
        XCTAssertEqual(copy.strokes.map(\.rec), [RecordingLink(id: recording, at: 1.5)])
        XCTAssertEqual(itemOps(dup.ops).added, [copy.id: copy.items])
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, dup.ops)]), dup.pages)
    }

    // MARK: Paged and pageless

    /// A switch moves items like strokes and keeps every recording link: a
    /// join used to drop the later pages' items (with `removePage`) and a
    /// split left items below the first sheet stranded off the page.
    func testSwitchMovesItemsAndKeepsRecordingLinks() throws {
        var log = LogBuilder()
        let pages = [Page(order: "V", strokes: [recorded(100, at: 1)], items: [box(500)]),
                     Page(order: "k", strokes: [recorded(200, at: 2)], items: [box(300, z: "a"), box(600, z: "b")])]
        let d0 = base(&log, pages)

        let join = NoteOps.makePageless(pages: pages, pageSize: .letter)
        let joinedPage = try XCTUnwrap(join.pages.first)
        XCTAssertEqual(joinedPage.items.count, 3)
        XCTAssertEqual(Set(joinedPage.items.compactMap(\.parent)), Set(pages[1].items.map(\.id)))
        XCTAssertEqual(Set(joinedPage.items.map(\.frame.y)), [490, 792 + 290, 792 + 590])
        XCTAssertEqual(joinedPage.strokes.map(\.rec?.at), [1, 2])
        XCTAssertEqual(itemOps(join.ops).added[pages[0].id]?.count, 2, "the second page's items are re-added")
        XCTAssertTrue(joinedPage.items.allSatisfy { $0.rec == RecordingLink(id: recording, at: 2) })
        let d1 = log.delta(devA, 10, join.ops)
        let joined = try NoteReducer.reconstruct([d0, d1])
        assertMatches(joined, join.pages)

        // The split starts from the predicted joined page (with its items).
        let split = NoteOps.makePaged(pages: join.pages, pageSize: join.pageSize)
        XCTAssertEqual(split.pages.count, 2)
        XCTAssertEqual(split.pages.map { $0.items.map(\.frame.y) }, [[490], [290, 590]])
        XCTAssertEqual(split.pages.map { $0.items.map(\.z) }, [["V"], ["a", "b"]])
        XCTAssertEqual(split.pages[1].items.map(\.text), pages[1].items.map(\.text))
        let moved = itemOps(split.ops)
        XCTAssertEqual(moved.added, [split.pages[1].id: split.pages[1].items])
        XCTAssertEqual(Set(moved.removed), Set(joinedPage.items.filter { $0.frame.y > 792 }.map(\.id)))
        let state = try NoteReducer.reconstruct([d0, d1, log.delta(devA, 20, NoteOps.makePaged(
            pages: joined.pages, pageSize: joined.meta.pageSize).ops)])
        XCTAssertEqual(state.pages.map { $0.strokes.map(\.rec?.at) }, [[1], [2]])
    }

    /// An item alone below the first sheet makes the split add sheets down to it.
    func testSplitAddsSheetsForAnItem() throws {
        var log = LogBuilder()
        let size = PageSize(width: 612, height: 800, infinite: true, breakHeight: 792)
        let page = Page(order: "V", strokes: [ink(100)], items: [box(2 * 792 + 100)])
        let d0 = base(&log, [page], size: size)
        let split = NoteOps.makePaged(pages: [page], pageSize: size)
        XCTAssertEqual(split.pages.count, 3)
        XCTAssertEqual(split.pages.map { $0.items.count }, [0, 0, 1])
        XCTAssertEqual(split.pages[2].items.first?.frame.y, 90)
        XCTAssertEqual(itemOps(split.ops).removed, page.items.map(\.id))
        assertMatches(try NoteReducer.reconstruct([d0, log.delta(devA, 10, split.ops)]), split.pages)
    }

    func testSheetHeight() {
        XCTAssertEqual(PageSize.letter.sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 612, height: 5000, infinite: true).sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 595, height: 5000, infinite: true, breakHeight: 842).sheetHeight, 842)
        XCTAssertEqual(PageSize(width: 612, height: .nan).sheetHeight, 792)
        XCTAssertEqual(PageSize(width: 612, height: 10, infinite: true, breakHeight: 1).sheetHeight, 72)
        XCTAssertEqual(PageSize(width: 612, height: 10, infinite: true, breakHeight: 1e12).sheetHeight, 200_000)
    }

    /// The position of a stroke in the reading flow: its sheet's top plus its
    /// transformed y, which a switch must never change.
    private func flow(_ pages: [Page], sheet h: Double, pageless: Bool) -> [Double] {
        var out: [Double] = []
        for (i, p) in pages.enumerated() {
            for s in p.strokes {
                let t = s.transform ?? .identity
                let ys = s.points.map { t.b * $0.x + t.d * $0.y + t.ty }
                out.append((pageless ? 0 : Double(i) * h) + (ys.min()! + ys.max()!) / 2)
            }
        }
        return out.sorted()
    }

    func testJoinThenSplitPutsEveryStrokeBack() throws {
        var log = LogBuilder()
        let skew = Transform(a: 1, b: 0.1, c: 0, d: 1, tx: 3, ty: 4)
        let pages = [Page(order: "V", strokes: [ink(100), ink(700)]), Page(order: "k"),
                     Page(order: "s", strokes: [ink(50, transform: skew), ink(400)])]
        let d0 = base(&log, pages)
        let before = flow(pages, sheet: 792, pageless: false)

        let join = NoteOps.makePageless(pages: pages, pageSize: .letter)
        XCTAssertEqual(join.pageSize, PageSize(width: 612, height: 3 * 792, infinite: true, breakHeight: 792))
        XCTAssertEqual(join.pages.count, 1)
        XCTAssertEqual(join.ops.filter { if case .removePage = $0 { true } else { false } }.count, 2)
        let d1 = log.delta(devA, 10, join.ops)
        let joined = try NoteReducer.reconstruct([d0, d1])
        assertMatches(joined, join.pages)
        XCTAssertEqual(joined.meta.pageSize, join.pageSize)
        XCTAssertEqual(flow(joined.pages, sheet: 792, pageless: true), before)
        XCTAssertTrue(joined.pages[0].strokes.contains { $0.transform?.b == 0.1 }, "only ty changes")

        let split = NoteOps.makePaged(pages: joined.pages, pageSize: joined.meta.pageSize)
        XCTAssertEqual(split.pageSize, .letter)
        let d2 = log.delta(devA, 20, split.ops)
        let state = try NoteReducer.reconstruct([d0, d1, d2])
        assertMatches(state, split.pages)
        XCTAssertEqual(state.pages.count, 3, "the blank middle page comes back")
        XCTAssertEqual(state.pages.map { $0.strokes.count }, [2, 0, 2])
        let after = flow(state.pages, sheet: 792, pageless: false)
        for (a, b) in zip(after, before) { XCTAssertEqual(a, b, accuracy: 0.001) }
        XCTAssertTrue(NoteOps.makePaged(pages: state.pages, pageSize: state.meta.pageSize).ops.isEmpty)
    }

    /// Ink a concurrent edit left below a finite page (format.md §5.4.3) gets
    /// sheets of its own in a join: it used to land on top of the next page's
    /// ink, which moved to exactly one sheet down.
    func testJoinKeepsInkBelowAPageOffTheNextPage() throws {
        var log = LogBuilder()
        let pages = [Page(order: "V", strokes: [ink(100), ink(1000)]), Page(order: "k", strokes: [ink(200)])]
        let d0 = base(&log, pages)
        let join = NoteOps.makePageless(pages: pages, pageSize: .letter)
        XCTAssertEqual(join.pageSize, PageSize(width: 612, height: 3 * 792, infinite: true, breakHeight: 792))
        let state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, join.ops)])
        assertMatches(state, join.pages)
        let centres = flow(state.pages, sheet: 792, pageless: true)
        XCTAssertEqual(centres, [100, 1000, 2 * 792 + 200], "page 2 starts below page 1's stray ink")
        // Splitting back gives that ink its own page instead of stacking it.
        let split = NoteOps.makePaged(pages: join.pages, pageSize: join.pageSize)
        XCTAssertEqual(split.pages.map { $0.strokes.count }, [1, 1, 1])
    }

    /// A pageless note with several pages (a split overridden by a concurrent
    /// grow of `pageSize`, which stays infinite) can be joined back.
    func testJoinOfAPagelessNoteWithSeveralPages() throws {
        var log = LogBuilder()
        let size = PageSize(width: 612, height: 3000, infinite: true, breakHeight: 792)
        let pages = [Page(order: "V", strokes: [ink(100)]), Page(order: "k", strokes: [ink(200)])]
        let d0 = base(&log, pages, size: size)
        let join = NoteOps.makePageless(pages: pages, pageSize: size)
        XCTAssertEqual(join.pages.count, 1)
        XCTAssertEqual(join.pageSize, PageSize(width: 612, height: 2 * 792, infinite: true, breakHeight: 792))
        let state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, join.ops)])
        assertMatches(state, join.pages)
        XCTAssertEqual(flow(state.pages, sheet: 792, pageless: true), [100, 792 + 200])
        // One pageless page: nothing to do.
        XCTAssertTrue(NoteOps.makePageless(pages: state.pages, pageSize: state.meta.pageSize).ops.isEmpty)
    }

    func testSplitOfAnImportedPage() throws {
        var log = LogBuilder()
        let h = 800.0
        let words = [("Lecture", 20.0), ("three", 20.0), ("maps", 60.0), ("kernel", 850.0), ("image", 1700.0)]
        let rec = Recognition(engine: "notability-x", text: "Lecture three\nmaps\nkernel image",
                              words: words.map { Recognition.Word(text: $0.0, box: Recognition.Box(x: 0, y: $0.1, w: 10, h: 10)) })
        let page = Page(order: "V", strokes: [ink(100), ink(900), ink(1750), ink(h * 2 + 2)], recognition: rec)
        let size = PageSize(width: 612, height: 2000, infinite: true, breakHeight: h)
        let d0 = base(&log, [page], size: size)
        let split = NoteOps.makePaged(pages: [page], pageSize: size)
        let state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, split.ops)])
        assertMatches(state, split.pages)
        XCTAssertEqual(state.meta.pageSize, PageSize(width: 612, height: h))
        XCTAssertEqual(state.pages.map { $0.strokes.count }, [1, 1, 2])
        XCTAssertEqual(state.pages[0].id, page.id)
        XCTAssertEqual(state.pages.map { $0.recognition?.text }, ["Lecture three\nmaps", "kernel", "image"])
        XCTAssertEqual(state.pages[1].recognition?.words.first?.box.y, 50)
        XCTAssertEqual(state.pages[2].strokes.map(\.parent), page.strokes.suffix(2).map(\.id))
        XCTAssertEqual(state.pages[2].strokes[0].transform?.ty, -1600)
    }

    /// Recognition that moves keeps track of the ink it was read from
    /// (format.md §5.4.3, §5.5): current stays current on the new ids,
    /// an import stays unchecked, stale stays stale (read again).
    func testMovedRecognitionKeepsItsBasisState() throws {
        let h = 800.0
        func word(_ t: String, _ y: Double) -> Recognition.Word { .init(text: t, box: .init(x: 0, y: y, w: 10, h: 10)) }
        func read(_ page: Page, _ text: String, _ words: [Recognition.Word]) -> Recognition {
            Recognition(engine: "vision-26", text: text, words: words, basis: RecognitionBasis.digest(of: page))
        }
        // Current: a basis that matches (no basis would be "unchecked", which is not the same).
        func current(_ p: Page) -> Bool { p.recognition?.basis == RecognitionBasis.digest(of: p) }

        // Split of a current page: every sheet's share is current for its new strokes.
        var page = Page(order: "V", strokes: [ink(100), ink(900)])
        page.recognition = read(page, "alpha\nbeta", [word("alpha", 95), word("beta", 895)])
        let size = PageSize(width: 612, height: 1600, infinite: true, breakHeight: h)
        var log = LogBuilder()
        let d0 = base(&log, [page], size: size)
        let split = NoteOps.makePaged(pages: [page], pageSize: size)
        var state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, split.ops)])
        assertMatches(state, split.pages)
        XCTAssertEqual(state.pages.map { $0.recognition?.text }, ["alpha", "beta"])
        XCTAssertTrue(state.pages.allSatisfy(current), "read from this ink: not read again")

        // Join them back: still current.
        let join = NoteOps.makePageless(pages: state.pages, pageSize: state.meta.pageSize)
        state = try NoteReducer.reconstruct([d0, log.delta(devA, 10, split.ops), log.delta(devA, 20, join.ops)])
        assertMatches(state, join.pages)
        XCTAssertEqual(state.pages.first?.recognition?.text, "alpha\nbeta")
        XCTAssertTrue(current(try XCTUnwrap(state.pages.first)))

        // A join where one page's ink was never read: the joined text is stale.
        var p0 = Page(order: "V", strokes: [ink(100)])
        p0.recognition = read(p0, "alpha", [word("alpha", 95)])
        let p1 = Page(order: "k", strokes: [ink(100)])   // drawn, not read yet
        var p2 = Page(order: "s", strokes: [ink(100)])
        p2.recognition = read(p2, "gamma", [word("gamma", 95)])
        let stale = NoteOps.makePageless(pages: [p0, p1, p2], pageSize: .letter)
        XCTAssertNotNil(stale.pages[0].recognition?.basis)
        XCTAssertFalse(current(stale.pages[0]), "page 2's ink still needs reading")
        XCTAssertTrue(RecognitionPolicy.needsRecognition(stale.pages[0]))

        // An import (no basis) stays unchecked: kept, never replaced unasked.
        var imported = Page(order: "V", strokes: [ink(100), ink(900)])
        imported.recognition = Recognition(engine: "notability-x", text: "alpha beta",
                                           words: [word("alpha", 95), word("beta", 895)])
        let importedSplit = NoteOps.makePaged(pages: [imported], pageSize: size)
        XCTAssertEqual(importedSplit.pages.map { $0.recognition?.basis }, [nil, nil])

        // Text without words cannot be split: it stays on the first sheet, stale once ink left it.
        var wordless = Page(order: "V", strokes: [ink(100), ink(900)])
        wordless.recognition = read(wordless, "alpha beta", [])
        let wordlessSplit = NoteOps.makePaged(pages: [wordless], pageSize: size)
        XCTAssertEqual(wordlessSplit.pages[0].recognition?.text, "alpha beta")
        XCTAssertTrue(RecognitionPolicy.needsRecognition(wordlessSplit.pages[0]))

        // Duplicate and undo of a delete copy the ink under new ids: the copy's text is current too.
        let dup = try XCTUnwrap(NoteOps.duplicatePage(page.id, in: [page]))
        XCTAssertTrue(dup.pages.allSatisfy(current))
        let restored = NoteOps.restorePage(page, at: 0, in: [])
        XCTAssertTrue(restored.pages.allSatisfy(current))
    }

    func testSplitKeepsBlankSheetsAndStoredHeight() throws {
        let page = Page(order: "V", strokes: [ink(100), ink(2500)])
        let edit = NoteOps.makePaged(pages: [page], pageSize: PageSize(width: 612, height: 5000, infinite: true))
        // Sheets of 792: ink on 0 and 3, stored height covers 6 whole sheets.
        XCTAssertEqual(edit.pages.map { $0.strokes.count }, [1, 0, 0, 1, 0, 0])
        // Nothing beyond the ink when there are several pages: the height is the note's.
        let two = NoteOps.makePaged(pages: [page, Page(order: "k")],
                                    pageSize: PageSize(width: 612, height: 5000, infinite: true))
        XCTAssertEqual(two.pages.map { $0.strokes.count }, [1, 0, 0, 1, 0])
    }

    func testSplitBoundsHostileInk() {
        let far = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                         points: [StrokePoint(x: 0, y: 1e300, w: 2, h: 2)])
        let nan = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                         points: [StrokePoint(x: 0, y: .nan, w: 2, h: 2)])
        let edit = NoteOps.makePaged(pages: [Page(order: "V", strokes: [far, nan])],
                                     pageSize: PageSize(width: 612, height: .infinity, infinite: true))
        XCTAssertEqual(edit.pages.count, NoteOps.maxSheetsPerPage)
        XCTAssertEqual(edit.pages[0].strokes.map(\.id), [nan.id])
    }

    /// format.md §5.4.3: a stroke another device adds below the first sheet
    /// while the split is written stays on the page (not lost).
    func testConcurrentInkBelowASplitStays() throws {
        var log = LogBuilder()
        let page = Page(order: "V", strokes: [ink(100), ink(900)])
        let size = PageSize(width: 612, height: 1600, infinite: true, breakHeight: 792)
        let d0 = base(&log, [page], size: size)
        let split = log.delta(devA, 10, NoteOps.makePaged(pages: [page], pageSize: size).ops)
        let late = ink(1000)
        let other = log.delta(devB, 5, [.addStroke(page: page.id, stroke: late)])
        let state = try NoteReducer.reconstruct([other, split, d0])
        XCTAssertTrue(state.pages[0].strokes.contains { $0.id == late.id })
        XCTAssertFalse(state.meta.pageSize.infinite)
    }
}
