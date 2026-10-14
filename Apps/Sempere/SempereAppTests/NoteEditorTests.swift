import Foundation
import Sempere
import PencilKit
import Testing
@testable import SempereApp

/// Autosave: drawing changes → one delta per pause, readable by the package.
@MainActor
struct NoteEditorTests {
    static let lecture = AppModelTests.lecture

    static func open(_ vault: Vault, note: UUID = lecture, debounce: Duration = .milliseconds(300))
        async throws -> (NoteEditor, DeviceClock) {
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault, noteID: note, clock: clock, debounce: debounce)
        return (editor, clock)
    }

    /// Deltas this device wrote to `note`, oldest first.
    static func myDeltas(_ vault: Vault, _ clock: DeviceClock, note: UUID = lecture) throws -> [[Op]] {
        try vault.loadNote(note).revisions.filter { $0.device == clock.device }.sorted { $0.seq < $1.seq }.map {
            if case .delta(let ops) = $0.body { return ops }
            return []
        }
    }

    @Test func autosaveWritesOneDeltaPerPause() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await Self.open(vault)
        #expect(!editor.isReadOnly)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        #expect(drawing.strokes.count == 2)
        for i in 0..<3 {
            drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 50 + 60 * Double(i), y: 400)))
            editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(editor.deltasWritten == 0)
        #expect(await TS.waitUntil { editor.deltasWritten == 1 })
        try await Task.sleep(for: .milliseconds(700))
        #expect(editor.deltasWritten == 1)
        var deltas = try Self.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        #expect(deltas.first?.count == 3)
        #expect(deltas.first?.allSatisfy { if case .addStroke(let p, _) = $0 { return p == page.id } else { return false } } == true)

        // A second pause: erase one stored stroke.
        let erased = try #require(editor.liveStrokes(of: page.id).first)
        drawing.strokes.removeFirst()
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(await TS.waitUntil { editor.deltasWritten == 2 })
        deltas = try Self.myDeltas(vault, clock)
        #expect(deltas.count == 2)
        #expect(deltas.last == [.removeStroke(page: page.id, strokeId: erased.id)])

        let state = try vault.reconstruct(noteId: Self.lecture)
        let saved = try #require(state.pages.first { $0.id == page.id })
        #expect(saved.strokes.count == 4)
        #expect(Set(saved.strokes.map(\.id)) == Set(editor.liveStrokes(of: page.id).map(\.id)))
    }

    @Test func closeFlushesImmediately() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await Self.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.close()
        #expect(editor.deltasWritten == 1)
        #expect(try Self.myDeltas(vault, clock).count == 1)
        await editor.flush()   // nothing pending: no empty delta
        #expect(try Self.myDeltas(vault, clock).count == 1)
    }

    @Test func undoOfASavedEraseWritesANewIdWithParent() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await Self.open(vault)
        let page = try #require(editor.currentPage)
        let full = editor.drawing(for: page.id)
        let victim = try #require(editor.liveStrokes(of: page.id).first)
        var erased = full
        erased.strokes.removeFirst()
        editor.drawingDidChange(pageID: page.id, drawing: erased, tool: nil)
        await editor.flush()
        editor.drawingDidChange(pageID: page.id, drawing: full, tool: nil)   // undo
        await editor.flush()

        let state = try vault.reconstruct(noteId: Self.lecture)
        let strokes = try #require(state.pages.first { $0.id == page.id }).strokes
        #expect(!strokes.contains { $0.id == victim.id })
        let restored = try #require(strokes.first { $0.parent == victim.id })
        StrokeConversionTests.expectClose(restored.points, victim.points, tolerance: 0.0005 + StrokeConversionTests.pencilKitPrecision)
        #expect(strokes.count == 2)
    }

    @Test func infinitePageGrowsAndSavesItsHeight() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let note = UUID()
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let size = PageSize(width: 612, height: 800, infinite: true)
        try await NoteWriter(vault: vault, noteID: note, clock: clock, nextSeq: 1)
            .write([.addPage(Page(order: PageOrder.between(nil, nil))), .setMeta(.pageSize(size))])
        let editor = try await NoteEditor.open(vault: vault, noteID: note, clock: clock, debounce: .seconds(60))
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 100)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(editor.pageSize == size)   // far from the bottom
        drawing.strokes.append(TS.canvasStroke(TS.stroke(y: 700)))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(editor.pageSize.height > 1000)
        await editor.flush()
        let state = try vault.reconstruct(noteId: note)
        #expect(state.meta.pageSize == editor.pageSize)
        #expect(state.pages.first?.strokes.count == 2)
    }

    @Test func finitePagesNeverGrow() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await Self.open(vault)
        let before = editor.pageSize
        #expect(!before.infinite)
        editor.growPage(toFit: before.height + 500)
        #expect(editor.pageSize == before)
        await editor.flush()
        #expect(try Self.myDeltas(vault, clock).isEmpty)
    }

    @Test func addPageIsSavedBeforeItsStrokes() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await Self.open(vault)
        editor.addPage()
        let page = try #require(editor.currentPage)
        #expect(editor.pageIndex == 2)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        await editor.flush()
        let ops = try #require(try Self.myDeltas(vault, clock).first)
        #expect(ops.count == 2)
        if case .addPage(let p) = ops[0] { #expect(p.id == page.id) } else { Issue.record("first op \(ops[0])") }
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.count == 3)
        #expect(state.pages.last?.strokes.count == 1)
    }

    @Test func deletedNotesOpenReadOnly() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await Self.open(vault, note: AppModelTests.deleted)
        #expect(editor.isReadOnly)
        let page = try #require(editor.currentPage)
        var drawing = editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke()))
        #expect(editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil).isEmpty)
        await editor.flush()
        #expect(try Self.myDeltas(vault, clock, note: AppModelTests.deleted).isEmpty)
    }

    @Test func clockAndDeviceLiveInTheStateFile() async throws {
        let url = TS.deviceStateURL()
        let a = try DeviceClock(url: url)
        let first = try await a.tick()
        let b = try DeviceClock(url: url)   // a relaunch
        #expect(b.device == a.device)
        let second = try await b.tick()
        #expect(second > first)
    }
}
