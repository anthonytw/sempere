import Foundation
import Observation
import Sempere
@testable import SempereAppCore
import Testing

extension NoteEditorSuites {
    /// Autosave: drawing changes → one delta per pause, readable by the package (moved from the app's
    /// `NoteEditorTests`, on the test canvas).
    @MainActor
    struct NoteEditorModelTests {
        typealias F = EditorFixture

        @Test func autosaveWritesOneDeltaPerPause() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault)
            #expect(!editor.isReadOnly)
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            #expect(drawing.strokes.count == 2)
            for i in 0..<3 {
                drawing.strokes.append(F.stroke(x: 50 + 60 * Double(i), y: 400))
                editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
                await Task.yield()   // one burst, well inside the debounce
            }
            #expect(editor.deltasWritten == 0)
            #expect(await F.waitUntil { editor.deltasWritten == 1 })
            await editor.flush()   // nothing pending: no second delta follows
            #expect(editor.deltasWritten == 1)
            var deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == 1)
            #expect(deltas.first?.count == 3)
            #expect(deltas.first?.allSatisfy { if case .addStroke(let p, _) = $0 { return p == page.id } else { return false } } == true)

            // A second pause: erase one stored stroke.
            let erased = try #require(editor.liveStrokes(of: page.id).first)
            drawing.strokes.removeFirst()
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            #expect(await F.waitUntil { editor.deltasWritten == 2 })
            deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == 2)
            #expect(deltas.last == [.removeStroke(page: page.id, strokeId: erased.id)])

            let state = try await EditorFixture.state(vault, F.lecture)
            let saved = try #require(state.pages.first { $0.id == page.id })
            #expect(saved.strokes.count == 4)
            #expect(Set(saved.strokes.map(\.id)) == Set(editor.liveStrokes(of: page.id).map(\.id)))
        }

        /// The toolbar's Undo and Redo follow `undoAvailability`, written by the app's canvas glue: disabled at
        /// first, observable (the bar redraws), and the editor itself holds no undo stack.
        @Test func undoAvailabilityStartsDisabledAndIsObservable() async throws {
            #expect(UndoAvailability() == UndoAvailability(canUndo: false, canRedo: false, undoName: "", redoName: ""))
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            #expect(editor.undoAvailability == UndoAvailability())
            final class Count: @unchecked Sendable { var n = 0 }
            let changes = Count()
            withObservationTracking { _ = editor.undoAvailability } onChange: { changes.n += 1 }
            editor.undoAvailability = UndoAvailability(canUndo: true, undoName: "Move")
            #expect(changes.n == 1)
            #expect(editor.undoAvailability.canUndo && !editor.undoAvailability.canRedo)
            #expect(editor.undoAvailability.undoName == "Move")
        }

        @Test func closeFlushesImmediately() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(F.stroke())
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            await editor.close()
            #expect(editor.deltasWritten == 1)
            #expect(try await F.myDeltas(vault, clock).count == 1)
            #expect(editor.glue.closes == 1, "the app's close hook ran (a recording is saved before the last save)")
            await editor.flush()   // nothing pending: no empty delta
            #expect(try await F.myDeltas(vault, clock).count == 1)
        }

        @Test func undoOfASavedEraseWritesANewIdWithParent() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage)
            let full = editor.drawing(for: page.id)
            let victim = try #require(editor.liveStrokes(of: page.id).first)
            var erased = full
            erased.strokes.removeFirst()
            editor.drawingDidChange(pageID: page.id, drawing: erased, tool: nil)
            await editor.flush()
            editor.drawingDidChange(pageID: page.id, drawing: full, tool: nil)   // undo
            await editor.flush()

            let state = try await EditorFixture.state(vault, F.lecture)
            let strokes = try #require(state.pages.first { $0.id == page.id }).strokes
            #expect(!strokes.contains { $0.id == victim.id })
            let restored = try #require(strokes.first { $0.parent == victim.id })
            #expect(restored.points == victim.points)
            #expect(strokes.count == 2)
        }

        @Test func infinitePageGrowsAndSavesItsHeight() async throws {
            let vault = try await F.vault()
            let note = UUID()
            let clock = try DeviceClock(url: F.deviceStateURL(), app: "sempere-test/1")
            let size = PageSize(width: 612, height: 800, infinite: true)
            try await NoteWriter(vault: vault, noteID: note, clock: clock, nextSeq: 1)
                .write([.addPage(Page(order: PageOrder.between(nil, nil))), .setMeta(.pageSize(size))])
            let editor = try await TestEditor.open(vault: vault, noteID: note, clock: clock, debounce: .seconds(60))
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(F.stroke(y: 100))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            #expect(editor.pageSize == size)   // far from the bottom
            drawing.strokes.append(F.stroke(y: 700))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            #expect(editor.pageSize.height > 1000)
            #expect(editor.takeMeasuredInk(of: page.id).map { $0.maxY >= 700 } == true, "the ledger measured the ink")
            #expect(editor.takeMeasuredInk(of: page.id) == nil, "once")
            await editor.flush()
            let state = try await EditorFixture.state(vault, note)
            #expect(state.meta.pageSize == editor.pageSize)
            #expect(state.pages.first?.strokes.count == 2)
        }

        @Test func finitePagesNeverGrow() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault)
            let before = editor.pageSize
            #expect(!before.infinite)
            editor.growPage(toFit: before.height + 500)
            #expect(editor.pageSize == before)
            await editor.flush()
            #expect(try await F.myDeltas(vault, clock).isEmpty)
        }

        @Test func addPageIsSavedBeforeItsStrokes() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault)
            editor.addPage()
            let page = try #require(editor.currentPage)
            #expect(editor.pageIndex == 2)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(F.stroke())
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            await editor.flush()
            let ops = try #require(try await F.myDeltas(vault, clock).first)
            #expect(ops.count == 2)
            if case .addPage(let p) = ops[0] { #expect(p.id == page.id) } else { Issue.record("first op \(ops[0])") }
            let state = try await EditorFixture.state(vault, F.lecture)
            #expect(state.pages.count == 3)
            #expect(state.pages.last?.strokes.count == 1)
        }

        @Test func deletedNotesOpenReadOnly() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, note: F.deleted)
            #expect(editor.isReadOnly)
            #expect(editor.readOnly == .deleted)
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(F.stroke())
            #expect(editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil).isEmpty)
            await editor.flush()
            #expect(try await F.myDeltas(vault, clock, note: F.deleted).isEmpty)
        }

        /// An editor made without a writer says why in a value the app words (`NoteReadOnly`).
        @Test func readOnlyReasonsAreValues() async throws {
            let state = try await F.state(try await F.vault())
            #expect(TestEditor(noteID: UUID(), state: state, writer: nil, readOnly: nil).readOnly == .noWriter)
            #expect(TestEditor(noteID: UUID(), state: state, writer: nil, readOnly: .preview).readOnly == .preview)
        }

        /// Ink taken off a page (a conversion) is one `removeStroke` per stroke in the next save, and every canvas
        /// showing the page reloads in the same turn; putting it back revives the strokes under new ids with
        /// `parent` once the removal was saved. `keepUndo` is visible to the canvases while they reload.
        @Test func takenInkIsSavedLikeAnEraseAndComesBackWithParents() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            let page = try #require(editor.currentPage).id
            let view = TestInkView(page: page)
            editor.attachInkView(view)
            _ = editor.drawing(for: page)
            let victim = try #require(editor.liveStrokes(of: page).first)
            let taken = try #require(editor.takeInk([victim.id], from: page))
            #expect(taken.strokes.map(\.id) == [victim.id])
            #expect(view.reloads == 1)
            #expect(view.shown?.strokes.count == 1)
            await editor.flush()
            #expect(try await F.myDeltas(vault, clock).last == [.removeStroke(page: page, strokeId: victim.id)])
            let back = try #require(editor.putInkBack(taken, keepUndo: true))
            #expect(view.reloads == 2)
            #expect(!editor.reloadKeepsUndo, "only while the canvases reload")
            await editor.flush()
            let state = try await EditorFixture.state(vault, F.lecture)
            let revived = try #require(state.pages.first { $0.id == page }?.strokes.first { back.contains($0.id) })
            #expect(revived.parent == victim.id)
            #expect(editor.takeInk([UUID()], from: page) == nil, "nothing taken")
        }
    }

    /// Page gestures and the paged/pageless switch in the editor (format.md §5.4.3): each is one delta, and the
    /// vault then reads what the editor shows (moved from the app's `PageEditorTests`).
    @MainActor
    struct PageEditorModelTests {
        typealias F = EditorFixture

        /// The editor's pages are what a reader reconstructs.
        private func expectSaved(_ editor: TestEditor, _ vault: Vault, note: UUID = F.lecture) async throws {
            let state = try await EditorFixture.state(vault, note)
            #expect(state.pages.map(\.id) == editor.pages.map(\.id))
            #expect(state.pages.map(\.strokes.count) == editor.pages.map { editor.liveStrokes(of: $0.id).count })
            #expect(state.meta.pageSize == editor.pageSize)
        }

        private func draw(_ editor: TestEditor, y: Double = 300) throws {
            let page = try #require(editor.currentPage)
            var drawing = editor.drawing(for: page.id)
            drawing.strokes.append(F.stroke(y: y))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        }

        @Test func addPageAfterCurrentGoesBetween() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            #expect(editor.pages.count == 2)
            let first = editor.pages[0].id, second = editor.pages[1].id
            editor.addPageAfterCurrent()
            #expect(editor.pageIndex == 1)
            #expect(editor.pages.count == 3)
            #expect(editor.pages[0].id == first && editor.pages[2].id == second)
            await editor.flush()
            try await expectSaved(editor, vault)
        }

        @Test func moveIsOneDeltaWithOneSetPageOrder() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            let ids = editor.pages.map(\.id)
            editor.movePage(from: 1, to: 0)
            #expect(editor.pages.map(\.id) == ids.reversed())
            #expect(editor.currentPage?.id == ids[0], "the page on the canvas stays on the canvas")
            await editor.flush()
            let deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == 1)
            #expect(deltas.first?.count == 1)
            if case .setPageOrder(let id, _)? = deltas.first?.first { #expect(id == ids[1]) } else { Issue.record("\(deltas)") }
            try await expectSaved(editor, vault)
            editor.movePage(from: 0, to: 0)   // no move, no delta
            await editor.flush()
            #expect(try await F.myDeltas(vault, clock).count == 1)
        }

        @Test func deleteThenUndoRecreatesThePageWithItsUnsavedInk() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
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
            #expect(try await F.myDeltas(vault, clock).last?.contains(.removePage(pageId: page.id)) == true)
            try await expectSaved(editor, vault)

            editor.undoDeletePage()
            #expect(editor.deletedPages.isEmpty)
            #expect(editor.pages.count == 2)
            #expect(editor.pageIndex == 1)
            let restored = try #require(editor.currentPage)
            #expect(restored.id != page.id)
            #expect(restored.parent == page.id)
            #expect(editor.liveStrokes(of: restored.id).count == strokes)
            await editor.flush()
            let last = try #require(try await F.myDeltas(vault, clock).last)
            if case .addPage(let p)? = last.first { #expect(p.parent == page.id) } else { Issue.record("\(last)") }
            try await expectSaved(editor, vault)
            let state = try await EditorFixture.state(vault, F.lecture)
            #expect(state.pages[1].parent == page.id)
        }

        @Test func duplicateCopiesInkAfterThePage() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
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
            try await expectSaved(editor, vault)
        }

        @Test func switchingToPagelessAndBackKeepsEveryStroke() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            #expect(!editor.isPageless)
            try draw(editor, y: 500)   // unsaved: saved in its own delta before the switch
            let counts = editor.pages.map { editor.liveStrokes(of: $0.id).count }
            let size = editor.pageSize

            await editor.setLayout(pageless: true)
            #expect(editor.isPageless)
            #expect(editor.pages.count == 1)
            #expect(editor.pageSize.breakHeight == size.height)
            #expect(editor.liveStrokes(of: editor.pages[0].id).count == counts.reduce(0, +))
            let deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == 2)
            #expect(deltas[0].allSatisfy { if case .addStroke = $0 { true } else { false } })
            #expect(deltas[1].last == .setMeta(.pageSize(editor.pageSize)))
            try await expectSaved(editor, vault)

            await editor.setLayout(pageless: true)   // already pageless: nothing
            #expect(try await F.myDeltas(vault, clock).count == 2)

            await editor.setLayout(pageless: false)
            #expect(!editor.isPageless)
            #expect(editor.pageSize == size)
            #expect(editor.pages.map { editor.liveStrokes(of: $0.id).count } == counts)
            #expect(try await F.myDeltas(vault, clock).count == 3)
            try await expectSaved(editor, vault)
        }

        /// A switch keeps page 1's id, so the canvas would keep its old drawing (and diff it against the new page: a
        /// join's moved ink removed by the next stroke). `canvasGeneration` changes so the canvas reloads; a stroke
        /// drawn on the reloaded drawing adds exactly that stroke.
        @Test func aSwitchReloadsTheCanvasAndTheNextStrokeAddsOnlyItself() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            let shown = try #require(editor.currentPage?.id)
            _ = editor.drawing(for: shown)   // on the canvas
            let generation = editor.canvasGeneration
            let total = editor.pages.map { editor.liveStrokes(of: $0.id).count }.reduce(0, +)

            await editor.setLayout(pageless: true)
            #expect(editor.currentPage?.id == shown, "page 1 keeps its id")
            #expect(editor.canvasGeneration != generation, "so the canvas must be told to reload")
            #expect(editor.liveStrokes(of: shown).count == total)
            if let ready = editor.readyDrawing(for: shown) { #expect(ready.strokes.count == total) }
            let before = try await F.myDeltas(vault, clock).count
            var drawing = editor.drawing(for: shown)   // what the reloaded canvas shows
            #expect(drawing.strokes.count == total)
            drawing.strokes.append(F.stroke(y: 900))
            let change = editor.drawingDidChange(pageID: shown, drawing: drawing, tool: nil)
            #expect(change.added.count == 1)
            #expect(change.removed.isEmpty)
            await editor.flush()
            let deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == before + 1)
            let last = try #require(deltas.last)
            #expect(last.allSatisfy { if case .addStroke = $0 { true } else { false } })
            try await expectSaved(editor, vault)

            let split = editor.canvasGeneration
            await editor.setLayout(pageless: false)
            #expect(editor.canvasGeneration != split)
            try await expectSaved(editor, vault)
        }

        @Test func pendingChangesAreReportedUntilSaved() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault, debounce: .seconds(60))
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
            let vault = try await F.vault()
            let (a, _) = try await F.open(vault)
            let (b, _) = try await F.open(vault)
            #expect(a.sessionID != b.sessionID)
        }

        @Test func readOnlyNotesTakeNoPageGestures() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, note: F.deleted)
            let page = try #require(editor.currentPage)
            let before = editor.pages
            editor.addPageAfterCurrent()
            editor.duplicatePage(page.id)
            editor.deletePage(page.id)
            editor.movePage(from: 0, to: 1)
            await editor.setLayout(pageless: !editor.isPageless)
            #expect(editor.pages == before)
            await editor.flush()
            #expect(try await F.myDeltas(vault, clock, note: F.deleted).isEmpty)
        }

        /// A closed editor (a window or view may still show it) takes no page gestures: they would change what it
        /// shows without ever being written.
        @Test func aClosedEditorTakesNoPageGestures() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault)
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
            #expect(try await F.myDeltas(vault, clock).isEmpty)
        }
    }

    /// Recordings of the open note through the editor (rename, remove, place): one delta each, and the canvas's hooks
    /// are told (playback stops for a removed recording; a card goes where the canvas says the page is on screen).
    @MainActor
    struct RecordingEditorModelTests {
        typealias F = EditorFixture

        static func noteWithARecording() async throws -> (Vault, TestEditor, DeviceClock, Recording) {
            let vault = try await F.vault()
            let audio = BlobRef(sha256: String(repeating: "ef", count: 32), size: 10, type: "audio/mp4")
            let recording = NoteOps.recording(blob: audio, started: Date(timeIntervalSince1970: 1_000), title: "Lecture")
            try await F.apply([.addRecording(recording)], to: F.lecture, in: vault, deviceState: F.deviceStateURL())
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            return (vault, editor, clock, recording)
        }

        @Test func renameIsOneDeltaAndTheSameTitleNone() async throws {
            let (vault, editor, clock, recording) = try await Self.noteWithARecording()
            await editor.renameRecording(recording.id, to: "  Week 2 ")
            #expect(editor.recording(recording.id)?.title == "Week 2")
            await editor.renameRecording(recording.id, to: "Week 2")
            #expect(try await F.myDeltas(vault, clock) == [[.setRecording(recordingId: recording.id, change: .title("Week 2"))]])
            #expect(editor.glue.failures.isEmpty)
        }

        @Test func placingThenRemovingTellsTheCanvas() async throws {
            let (vault, editor, clock, recording) = try await Self.noteWithARecording()
            editor.glue.visible = CGRect(x: 100, y: 300, width: 300, height: 200)
            let card = try #require(editor.placeRecording(recording.id))
            #expect(card.frame.y >= 300, "inside what is on screen: \(card.frame)")
            #expect(await F.waitUntil { editor.deltasWritten == 1 })
            await editor.removeRecording(recording.id)
            #expect(editor.glue.removedRecordings == [recording.id])
            #expect(editor.recordings.isEmpty)
            #expect(editor.items(on: try #require(editor.currentPage).id).isEmpty, "its card went with it")
            let deltas = try await F.myDeltas(vault, clock)
            #expect(deltas.count == 2)
            #expect(deltas.last?.contains(.removeRecording(recordingId: recording.id)) == true)
        }
    }
}
