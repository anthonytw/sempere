import Foundation
import Sempere
import PencilKit
import Testing
@testable import SempereApp

/// Page gestures and the paged/pageless switch in the editor (format.md
/// §5.4.3): each is one delta, and the vault then reads what the editor shows.
@MainActor
struct PageEditorTests {
    static let lecture = AppModelTests.lecture

    /// The editor's pages are what a reader reconstructs.
    private func expectSaved(_ editor: NoteEditor, _ vault: Vault, note: UUID = lecture) throws {
        let state = try vault.reconstruct(noteId: note)
        #expect(state.pages.map(\.id) == editor.pages.map(\.id))
        #expect(state.strokeCounts == editor.pages.map { editor.liveStrokes(of: $0.id).count })
        #expect(state.meta.pageSize == editor.pageSize)
    }

    private func draw(_ editor: NoteEditor, y: Double = 300) throws {
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: y)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
    }

    @Test func addPageAfterCurrentGoesBetween() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        #expect(editor.pages.count == 2)
        let first = editor.pages[0].id, second = editor.pages[1].id
        editor.addPageAfterCurrent()
        #expect(editor.pageIndex == 1)
        #expect(editor.pages.count == 3)
        #expect(editor.pages[0].id == first && editor.pages[2].id == second)
        await editor.flush()
        try expectSaved(editor, vault)
    }

    @Test func moveIsOneDeltaWithOneSetPageOrder() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let ids = editor.pages.map(\.id)
        editor.movePage(from: 1, to: 0)
        #expect(editor.pages.map(\.id) == ids.reversed())
        #expect(editor.currentPage?.id == ids[0], "the page on the canvas stays on the canvas")
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        #expect(deltas.first?.count == 1)
        if case .setPageOrder(let id, _)? = deltas.first?.first { #expect(id == ids[1]) } else { Issue.record("\(deltas)") }
        try expectSaved(editor, vault)
        editor.movePage(from: 0, to: 0)   // no move, no delta
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 1)
    }

    @Test func deleteThenUndoRecreatesThePageWithItsUnsavedInk() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        editor.selectPage(1)
        await editor.flush()
        let page = try #require(editor.currentPage)
        try draw(editor)   // not saved yet
        let strokes = editor.liveStrokes(of: page.id).count
        editor.deletePage(page.id)
        #expect(editor.pages.count == 1)
        #expect(editor.deletedPages.count == 1)
        #expect(!editor.canDeletePage, "the last page stays")
        editor.deletePage(editor.pages[0].id)
        #expect(editor.pages.count == 1)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock).last?.contains(.removePage(pageId: page.id)) == true)
        try expectSaved(editor, vault)

        editor.undoDeletePage()
        #expect(editor.deletedPages.isEmpty)
        #expect(editor.pages.count == 2)
        #expect(editor.pageIndex == 1)
        let restored = try #require(editor.currentPage)
        #expect(restored.id != page.id)
        #expect(restored.parent == page.id)
        #expect(editor.liveStrokes(of: restored.id).count == strokes)
        await editor.flush()
        let last = try #require(try NoteEditorTests.myDeltas(vault, clock).last)
        if case .addPage(let p)? = last.first { #expect(p.parent == page.id) } else { Issue.record("\(last)") }
        try expectSaved(editor, vault)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages[1].parent == page.id)
    }

    @Test func duplicateCopiesInkAfterThePage() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let source = try #require(editor.currentPage)
        try draw(editor)
        let ink = editor.liveStrokes(of: source.id)
        editor.duplicatePage(source.id)
        #expect(editor.pages.count == 3)
        #expect(editor.pageIndex == 1)
        let copy = try #require(editor.currentPage)
        let copied = editor.liveStrokes(of: copy.id)
        #expect(copied.map(\.points) == ink.map(\.points))
        #expect(Set(copied.map(\.id)).isDisjoint(with: ink.map(\.id)))
        await editor.flush()
        try expectSaved(editor, vault)
    }

    @Test func switchingToPagelessAndBackKeepsEveryStroke() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        #expect(!editor.isPageless)
        try draw(editor, y: 500)   // unsaved: saved in its own delta before the switch
        let counts = editor.pages.map { editor.liveStrokes(of: $0.id).count }
        let size = editor.pageSize

        await editor.setLayout(pageless: true)
        #expect(editor.isPageless)
        #expect(editor.pages.count == 1)
        #expect(editor.pageSize.breakHeight == size.height)
        #expect(editor.liveStrokes(of: editor.pages[0].id).count == counts.reduce(0, +))
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 2)
        #expect(deltas[0].allSatisfy { if case .addStroke = $0 { true } else { false } })
        #expect(deltas[1].last == .setMeta(.pageSize(editor.pageSize)))
        try expectSaved(editor, vault)

        await editor.setLayout(pageless: true)   // already pageless: nothing
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 2)

        await editor.setLayout(pageless: false)
        #expect(!editor.isPageless)
        #expect(editor.pageSize == size)
        #expect(editor.pages.map { editor.liveStrokes(of: $0.id).count } == counts)
        #expect(try NoteEditorTests.myDeltas(vault, clock).count == 3)
        try expectSaved(editor, vault)
    }

    /// A switch keeps page 1's id, so the canvas would keep its old drawing
    /// (and diff it against the new page: a join's moved ink removed by the next
    /// stroke). `canvasGeneration` changes so the canvas reloads; a stroke drawn
    /// on the reloaded drawing adds exactly that stroke.
    @Test func aSwitchReloadsTheCanvasAndTheNextStrokeAddsOnlyItself() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let shown = try #require(editor.currentPage?.id)
        _ = editor.drawing(for: shown)   // on the canvas
        let generation = editor.canvasGeneration
        let total = editor.pages.map { editor.liveStrokes(of: $0.id).count }.reduce(0, +)

        await editor.setLayout(pageless: true)
        #expect(editor.currentPage?.id == shown, "page 1 keeps its id")
        #expect(editor.canvasGeneration != generation, "so the canvas must be told to reload")
        // The drawing shown before the switch is not handed back for the page,
        // even once something has built its new ledger (the canvas reload asks first).
        #expect(editor.liveStrokes(of: shown).count == total)
        if let ready = editor.readyDrawing(for: shown) { #expect(ready.strokes.count == total) }
        let before = try NoteEditorTests.myDeltas(vault, clock).count
        var drawing = editor.drawing(for: shown)   // what the reloaded canvas shows
        #expect(drawing.strokes.count == total)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 900)))
        let change = editor.drawingDidChange(pageID: shown, drawing: drawing, tool: nil)
        #expect(change.added.count == 1)
        #expect(change.removed.isEmpty)
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == before + 1)
        let last = try #require(deltas.last)
        #expect(last.allSatisfy { if case .addStroke = $0 { true } else { false } })
        try expectSaved(editor, vault)

        let split = editor.canvasGeneration
        await editor.setLayout(pageless: false)
        #expect(editor.canvasGeneration != split)
        try expectSaved(editor, vault)
    }

    @Test func pendingChangesAreReportedUntilSaved() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        #expect(!editor.hasPendingChanges)
        try draw(editor)
        #expect(editor.hasPendingChanges)
        await editor.flush()
        #expect(!editor.hasPendingChanges)
        editor.addPageAfterCurrent()
        #expect(editor.hasPendingChanges)
        await editor.flush()
        #expect(!editor.hasPendingChanges)
    }

    /// Thumbnail cache keys outlive an editor; ink revisions restart at 0 in each.
    @Test func everyEditorHasItsOwnSessionID() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (a, _) = try await NoteEditorTests.open(vault)
        let (b, _) = try await NoteEditorTests.open(vault)
        #expect(a.sessionID != b.sessionID)
    }

    @Test func readOnlyNotesTakeNoPageGestures() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, note: AppModelTests.deleted)
        let page = try #require(editor.currentPage)
        let before = editor.pages
        editor.addPageAfterCurrent()
        editor.duplicatePage(page.id)
        editor.deletePage(page.id)
        editor.movePage(from: 0, to: 1)
        await editor.setLayout(pageless: !editor.isPageless)
        #expect(editor.pages == before)
        await editor.flush()
        #expect(try NoteEditorTests.myDeltas(vault, clock, note: AppModelTests.deleted).isEmpty)
    }

    /// A closed editor (a window or view may still show it) takes no page
    /// gestures: they would change what it shows without ever being written.
    @Test func aClosedEditorTakesNoPageGestures() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault)
        await editor.close()
        let page = try #require(editor.currentPage)
        let before = editor.pages
        let layout = editor.isPageless
        editor.addPageAfterCurrent()
        editor.duplicatePage(page.id)
        editor.deletePage(page.id)
        editor.movePage(from: 0, to: 1)
        await editor.setLayout(pageless: !editor.isPageless)
        #expect(editor.pages == before)
        #expect(editor.isPageless == layout)
        #expect(!editor.canDeletePage)
        #expect(try NoteEditorTests.myDeltas(vault, clock).isEmpty)
    }

    @Test func newNoteLayouts() async throws {
        #expect(NewNoteLayout.letter.pageSize == .letter)
        #expect(NewNoteLayout.a4.pageSize == .a4)
        #expect(NewNoteLayout.pagelessA4.pageSize == PageSize(width: 595, height: 842, infinite: true, breakHeight: 842))
        let defaults = try #require(UserDefaults(suiteName: "PageEditorTests-\(UUID())"))
        #expect(NewNoteLayout.load(from: defaults) == .letter)
        NewNoteLayout.save(.pagelessLetter, to: defaults)
        #expect(NewNoteLayout.load(from: defaults) == .pagelessLetter)

        let model = try await BrowserTests.unlockedFixtureModel()
        let id = try await model.createNote(title: "Scroll", paper: .ruled, notebook: nil,
                                            pageSize: NewNoteLayout.pagelessLetter.pageSize)
        let state = try #require(model.vault).reconstruct(noteId: id)
        #expect(state.meta.pageSize.isPageless)
        #expect(state.pages.count == 1)
    }

    @Test func stripMoveIndexAndThumbnailSize() {
        #expect(PageStrip.targetIndex(from: 0, toOffset: 2) == 1)   // down past one row
        #expect(PageStrip.targetIndex(from: 2, toOffset: 0) == 0)
        #expect(PageStrip.targetIndex(from: 1, toOffset: 3) == 2)
        #expect(PageStrip.thumbnailHeight(width: 85, pageSize: .letter) == 110)
        #expect(PageStrip.thumbnailHeight(width: 100, pageSize: PageSize(width: .nan, height: 1)) == 100 * 11 / 8.5)
        let image = PageThumbnail.image(strokes: [TS.stroke()], paper: .ruled, pageSize: .letter,
                                        size: CGSize(width: 60, height: 78), scale: 2)
        #expect(image.size == CGSize(width: 60, height: 78))
    }
}

extension NoteState {
    var strokeCounts: [Int] { pages.map(\.strokes.count) }
}
