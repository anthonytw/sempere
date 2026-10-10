import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Revisions another device writes while a note is open reach the editor in
/// place (`NoteEditor.mergeRevisions`, `AppModel+RemoteMerge`): nothing
/// unsaved is lost, nothing is written for the merge (no echo), and the
/// format's merge rules decide concurrent edits.
@MainActor
struct RemoteMergeTests {
    static let lecture = AppModelTests.lecture

    @MainActor
    struct Fixture {
        var url: URL
        var key: URL
        var vault: Vault
        var editor: NoteEditor
        var clock: DeviceClock

        /// Merges whatever is on disk into the editor.
        @discardableResult
        func merge() async throws -> NoteEditor.RemoteMergeOutcome {
            try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
        }

        /// Another device writes `ops` into the note.
        func elsewhere(_ ops: [Op]) throws {
            try TS.writeAsAnotherDevice(ops, to: RemoteMergeTests.lecture, vault: url, key: key)
        }

        /// Deltas this device wrote to the note.
        func mine() throws -> [[Op]] { try NoteEditorTests.myDeltas(vault, clock) }

        /// The note as every device reads it.
        func onDisk() throws -> NoteState { try vault.reconstruct(noteId: RemoteMergeTests.lecture) }

        /// The canvas shows the editor's drawing of `page` and reports it, as
        /// PencilKit does after a drawing is set.
        @discardableResult
        func canvasReports(_ page: UUID) throws -> StrokeLedger.Change {
            let drawing = try #require(editor.readyDrawing(for: page))
            return editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
        }
    }

    static func open(debounce: Duration = .seconds(60)) async throws -> Fixture {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault, noteID: lecture, clock: clock, debounce: debounce)
        return Fixture(url: url, key: key, vault: vault, editor: editor, clock: clock)
    }

    @Test func newStrokesArriveWhileTheNoteIsOpen() async throws {
        let f = try await Self.open()
        let page = try #require(f.editor.currentPage)
        let shown = f.editor.drawing(for: page.id)   // on the canvas
        let names = try f.vault.revisionNames(of: Self.lecture).map(\.filename)
        #expect(!f.editor.hasUnmergedRevisions(names))

        let remote = TS.stroke(x: 300, y: 500)
        try f.elsewhere([.addStroke(page: page.id, stroke: remote)])
        #expect(f.editor.hasUnmergedRevisions(try f.vault.revisionNames(of: Self.lecture).map(\.filename)))
        #expect(try await f.merge() == .merged(fromOtherDevice: true))

        #expect(f.editor.liveStrokes(of: page.id).last?.id == remote.id)
        let drawing = try #require(f.editor.readyDrawing(for: page.id))
        #expect(drawing.strokes.count == shown.strokes.count + 1)
        // Strokes that were on the canvas are reused as they were, not converted again.
        for i in shown.strokes.indices { #expect(drawing.strokes[i].randomSeed == shown.strokes[i].randomSeed) }
        #expect(f.editor.remoteUpdates == 1)
        #expect(f.editor.lastRemoteUpdate != nil)
        #expect(!f.editor.hasUnmergedRevisions(try f.vault.revisionNames(of: Self.lecture).map(\.filename)))
        #expect(try f.canvasReports(page.id).isEmpty)
        await f.editor.close()
        #expect(try f.mine().isEmpty, "the merge wrote nothing")
    }

    /// Merges read only the new files (`NoteEditor.read(reuse:)`): after
    /// several, including a revision older than everything the editor read
    /// (a late arrival), the editor shows what a fresh read of the note shows.
    @Test func repeatedMergesMatchAFreshRead() async throws {
        let f = try await Self.open()
        let page = try #require(f.editor.currentPage)
        for i in 0..<3 {
            try f.elsewhere([.addStroke(page: page.id, stroke: TS.stroke(x: 100 + Double(i) * 50, y: 400))])
            #expect(try await f.merge() == .merged(fromOtherDevice: true))
        }
        let late = TS.stroke(x: 50, y: 50)
        let identity = try IdentityFile.parse(try String(contentsOf: f.key, encoding: .utf8))
        let other = try Vault.open(at: f.url, identities: [identity])
        try other.write(Revision(noteId: Self.lecture, device: DeviceID("cccccccc")!, seq: 1,
                                 hlc: HLC(millis: 1_000, counter: 0)!, wall: Date(timeIntervalSince1970: 1),
                                 app: "late-device/1", body: .delta(ops: [.addStroke(page: page.id, stroke: late)])))
        #expect(try await f.merge() == .merged(fromOtherDevice: true))
        let disk = try f.onDisk()
        #expect(f.editor.pages.map(\.id) == disk.pages.map(\.id))
        for p in disk.pages { #expect(f.editor.liveStrokes(of: p.id).map(\.id) == p.strokes.map(\.id)) }
        #expect(f.editor.liveStrokes(of: page.id).contains { $0.id == late.id })
        await f.editor.close()
        #expect(try f.mine().isEmpty)
    }

    @Test func aPageAddedElsewhereAppears() async throws {
        let f = try await Self.open()
        let before = f.editor.pages
        let edit = NoteOps.addPage(at: before.count, in: before)
        guard case .addPage(let added)? = edit.ops.first else { Issue.record("no page added"); return }
        try f.elsewhere(edit.ops)
        #expect(try await f.merge() == .merged(fromOtherDevice: true))
        #expect(f.editor.pages.map(\.id) == before.map(\.id) + [added.id])
        #expect(f.editor.currentPage?.id == before.first?.id, "the page on screen stays")
        await f.editor.close()
        #expect(try f.mine().isEmpty)
    }

    @Test func anItemMovedElsewhereMoves() async throws {
        let f = try await Self.open()
        let page = try #require(f.editor.currentPage)
        let item = AttachmentEditorTests.textItem("Board")
        try f.elsewhere(try NoteOps.addItems([item], to: page).ops)
        try await f.merge()
        let placed = try #require(f.editor.pages.first { $0.id == page.id }?.items.first)
        let itemsBefore = f.editor.itemRevisions[page.id] ?? 0

        let onPage = try #require(try f.onDisk().pages.first { $0.id == page.id })
        let moved = Rect(x: 300, y: 400, w: placed.frame.w, h: placed.frame.h)
        let edit = try #require(NoteOps.setFrame(placed.id, to: moved, on: onPage))
        try f.elsewhere(edit.ops)
        #expect(try await f.merge() == .merged(fromOtherDevice: true))
        #expect(f.editor.pages.first { $0.id == page.id }?.items.first { $0.id == placed.id }?.frame == moved)
        #expect((f.editor.itemRevisions[page.id] ?? 0) > itemsBefore, "the item layer redraws")
        await f.editor.close()
        #expect(try f.mine().isEmpty)
    }

    @Test func unsavedInkAndARemoteChangeBothSurvive() async throws {
        let f = try await Self.open()   // autosave far away: the stroke stays unsaved
        let page = try #require(f.editor.currentPage)
        var drawing = f.editor.drawing(for: page.id)
        let first = try #require(f.editor.liveStrokes(of: page.id).first)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 60, y: 700)))
        f.editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        let mine = try #require(f.editor.liveStrokes(of: page.id).last)
        #expect(f.editor.hasPendingChanges)

        let remote = TS.stroke(x: 300, y: 500)
        try f.elsewhere([.addStroke(page: page.id, stroke: remote), .removeStroke(page: page.id, strokeId: first.id)])
        #expect(try await f.merge() == .merged(fromOtherDevice: true))

        let live = f.editor.liveStrokes(of: page.id).map(\.id)
        #expect(live.contains(mine.id))
        #expect(live.contains(remote.id))
        #expect(!live.contains(first.id), "removed elsewhere")
        #expect(!f.editor.hasPendingChanges, "the local stroke was saved before the read")
        // One delta adding this canvas's stroke (compared by id: points are stored rounded, InkJSON.round3).
        let saved = try f.mine().map { ops in
            ops.map { op -> String in
                if case .addStroke(let p, let s) = op, p == page.id { return "add \(s.id)" }
                return "\(op)"
            }
        }
        #expect(saved == [["add \(mine.id)"]])
        let disk = try #require(try f.onDisk().pages.first { $0.id == page.id })
        #expect(Set(disk.strokes.map(\.id)) == Set(live))
        #expect(try f.canvasReports(page.id).isEmpty)
        await f.editor.close()
        #expect(try f.mine().count == 1, "no echo of the remote add or removal")
    }

    @Test func inkDrawnAfterTheMergeIsSavedAloneAndNothingIsEchoed() async throws {
        let f = try await Self.open(debounce: .milliseconds(50))
        let page = try #require(f.editor.currentPage)
        _ = f.editor.drawing(for: page.id)
        let gone = try #require(f.editor.liveStrokes(of: page.id).first)
        try f.elsewhere([.removeStroke(page: page.id, strokeId: gone.id),
                         .addStroke(page: page.id, stroke: TS.stroke(x: 200, y: 300))])
        try await f.merge()
        // The canvas shows the merged drawing, then the user draws on it.
        var drawing = try #require(f.editor.readyDrawing(for: page.id))
        #expect(try f.canvasReports(page.id).isEmpty)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 80, y: 650)))
        let change = f.editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(change.removed.isEmpty)
        #expect(change.added.count == 1)
        #expect(await TS.waitUntil { f.editor.deltasWritten == 1 })
        let deltas = try f.mine()
        #expect(deltas.count == 1)
        #expect(deltas.first?.count == 1)
        #expect(deltas.first?.allSatisfy { if case .addStroke = $0 { return true } else { return false } } == true)
        await f.editor.close()
    }

    @Test func concurrentMovesOfOneItemShowTheFormatsWinner() async throws {
        let f = try await Self.open()
        let page = try #require(f.editor.currentPage)
        try f.elsewhere(try NoteOps.addItems([AttachmentEditorTests.textItem("Shared")], to: page).ops)
        try await f.merge()
        let placed = try #require(f.editor.pages.first { $0.id == page.id }?.items.first)
        let base = try #require(try f.onDisk().pages.first { $0.id == page.id })

        // Both devices move it, neither having seen the other's move.
        let here = Rect(x: 20, y: 20, w: placed.frame.w, h: placed.frame.h)
        let there = Rect(x: 500, y: 600, w: placed.frame.w, h: placed.frame.h)
        let current = try #require(f.editor.pages.first { $0.id == page.id })
        let local = try #require(NoteOps.setFrame(placed.id, to: here, on: current))
        #expect(f.editor.applyItemEdit(local))
        await f.editor.flush()
        let remote = try #require(NoteOps.setFrame(placed.id, to: there, on: base))
        try f.elsewhere(remote.ops)
        try await f.merge()

        let winner = try #require(try f.onDisk().pages.first { $0.id == page.id }?.items.first { $0.id == placed.id })
        #expect(f.editor.pages.first { $0.id == page.id }?.items.first { $0.id == placed.id }?.frame == winner.frame)
        await f.editor.close()
        #expect(try f.mine().count == 1, "only the local move")
    }

    @Test func nothingNewChangesNothing() async throws {
        let f = try await Self.open(debounce: .milliseconds(50))
        let page = try #require(f.editor.currentPage)
        var drawing = f.editor.drawing(for: page.id)
        drawing.strokes.append(TS.canvasStroke(TS.stroke(x: 60, y: 700)))
        f.editor.drawingDidChange(pageID: page.id, drawing: drawing, tool: nil)
        #expect(try await f.merge() == .unchanged, "only this editor's own delta was new")
        #expect(f.editor.remoteUpdates == 0)
        #expect(f.editor.readyDrawing(for: page.id)?.strokes.count == drawing.strokes.count)
        await f.editor.close()
    }

    @Test func aNoteDeletedElsewhereBecomesReadOnly() async throws {
        let f = try await Self.open()
        try f.elsewhere([.deleteNote])
        #expect(try await f.merge() == .merged(fromOtherDevice: true))
        #expect(f.editor.isReadOnly)
        #expect(f.editor.readOnlyReason == NoteEditor.deletedReason)
        try f.elsewhere([.restoreNote])
        try await f.merge()
        #expect(!f.editor.isReadOnly)
        await f.editor.close()
        #expect(try f.mine().isEmpty)
    }

    /// The model: a listing that sees another device's revision of the open
    /// note merges it into the same editor (no reopen), and the list follows.
    @Test func aListingMergesIntoTheOpenEditor() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .seconds(60))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage)
        _ = editor.drawing(for: page.id)
        let remote = TS.stroke(x: 300, y: 500)
        try TS.writeAsAnotherDevice([.addStroke(page: page.id, stroke: remote), .setMeta(.title("Renamed elsewhere"))],
                                    to: Self.lecture, vault: url, key: key)
        try await model.reconcile()
        #expect(await TS.waitUntil { editor.liveStrokes(of: page.id).contains { $0.id == remote.id } })
        #expect(model.editor === editor, "merged in place, not reopened")
        #expect(editor.meta.title == "Renamed elsewhere")
        #expect(editor.remoteUpdates == 1)
        #expect(await TS.waitUntil { model.notes.first { $0.id == Self.lecture }?.title == "Renamed elsewhere" })
        #expect(await TS.waitUntil { model.remoteMerges.isEmpty })
        // A second pass finds nothing new.
        try await model.reconcile()
        #expect(model.remoteMerges.isEmpty)
        #expect(editor.remoteUpdates == 1)
        let vault = try #require(model.vault)
        let device = try DeviceState.loadOrCreate(at: model.deviceStateURL).device
        model.close()
        await model.closingEditor?.value
        #expect(try vault.revisionNames(of: Self.lecture).filter { $0.device == device }.isEmpty, "no echo delta")
    }

    /// iCloud Drive, as iPadOS 26 presents an evicted note (dataless files
    /// under their real names): another device's revision of the open note is
    /// listed but not downloaded. The merge downloads every revision of the
    /// note first and applies nothing until they are all local.
    @Test func aRemoteRevisionNotYetDownloadedIsMergedOnlyOnceLocal() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = try await ProgressiveLoadTests.cloudModel(cloud, key: key)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        model.stopCloudSync()   // the test drives the merge
        let page = try #require(editor.currentPage)
        _ = editor.drawing(for: page.id)
        let remote = TS.stroke(x: 300, y: 500)
        try TS.writeAsAnotherDevice([.addStroke(page: page.id, stroke: remote)], to: Self.lecture, vault: url, key: key)
        try cloud.evictDataless(Self.lecture)
        let names = try #require(try VaultEnumeration.listNotes(vault: url, only: [Self.lecture]).first?.names)
        #expect(editor.hasUnmergedRevisions(names), "the new name is listed")

        let merge = Task { try await model.mergeRemoteRevisions(into: editor) }
        #expect(await TS.waitUntil { cloud.requestedNotes.contains(Self.lecture.uuidString.lowercased()) })
        try await Task.sleep(for: .milliseconds(150))
        #expect(!editor.liveStrokes(of: page.id).contains { $0.id == remote.id }, "nothing applied from a partial log")
        try cloud.deliver(Self.lecture)
        #expect(try await merge.value == .merged(fromOtherDevice: true))
        #expect(editor.liveStrokes(of: page.id).contains { $0.id == remote.id })
        #expect(model.editor === editor)
        let vault = try #require(model.vault)
        let device = try DeviceState.loadOrCreate(at: model.deviceStateURL).device
        model.close()
        await model.closingEditor?.value
        #expect(try vault.revisionNames(of: Self.lecture).filter { $0.device == device }.isEmpty, "no echo delta")
    }
}

/// The canvases: a merge reaches the page canvases of the paged stack in the
/// same main-actor turn, keeps the scroll, and waits for a stroke under way.
@MainActor
@Suite(.serialized)
struct RemoteMergeCanvasTests {
    /// A saved two-page note open on a stack, and a way to write as another device.
    static func stackOnSavedNote() async throws
        -> (Vault, NoteEditor, DeviceClock, UUID, UIWindow, PageStackHost) {
        let (vault, _) = try TS.unlockedFixture()
        let id = UUID()
        var ops = NoteOps.newNote(title: "Stack")
        let order = ops.compactMap { op -> String? in if case .addPage(let p) = op { return p.order }; return nil }.last
        ops.append(.addPage(Page(id: UUID(), order: PageOrder.between(order, nil))))
        try vault.apply(ops, to: id, deviceState: TS.deviceStateURL(), app: "test")
        let (editor, clock) = try await NoteEditorTests.open(vault, note: id, debounce: .seconds(600))
        let (window, stack) = StackTS.stack(editor)
        return (vault, editor, clock, id, window, stack)
    }

    @Test func theShownCanvasTakesTheMergedInkAtOnceAndEchoesNothing() async throws {
        let (vault, editor, clock, id, window, stack) = try await Self.stackOnSavedNote()
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(slot))
        let offset = stack.scroller.contentOffset
        let page = editor.pages[0].id
        try vault.apply([.addStroke(page: page, stroke: TS.stroke(x: 100, y: 200))], to: id,
                        deviceState: TS.deviceStateURL(), app: "other-device/1")
        let outcome = try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
        #expect(outcome == .merged(fromOtherDevice: true))
        #expect(slot.host.canvas.drawing.strokes.count == 1, "shown without waiting for SwiftUI")
        #expect(slot.host.canvas.undoManager?.canUndo != true)
        #expect(stack.scroller.contentOffset == offset)
        // PencilKit reports the drawing it was given: nothing to save.
        slot.coordinator.canvasViewDrawingDidChange(slot.host.canvas)
        #expect(!editor.hasPendingChanges)
        await editor.close()
        #expect(try NoteEditorTests.myDeltas(vault, clock, note: id).isEmpty)
    }

    @Test func aMergeWaitsForTheStrokeUnderWay() async throws {
        let (vault, editor, clock, id, window, stack) = try await Self.stackOnSavedNote()
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(slot))
        let page = editor.pages[0].id
        try vault.apply([.addStroke(page: page, stroke: TS.stroke(x: 100, y: 200))], to: id,
                        deviceState: TS.deviceStateURL(), app: "other-device/1")
        slot.coordinator.canvasViewDidBeginUsingTool(slot.host.canvas)
        #expect(editor.isInkInUse)
        let merge = Task { try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(slot.host.canvas.drawing.strokes.isEmpty, "not under the pencil")
        slot.coordinator.canvasViewDidEndUsingTool(slot.host.canvas)
        #expect(try await merge.value == .merged(fromOtherDevice: true))
        #expect(slot.host.canvas.drawing.strokes.count == 1)
        await editor.close()
    }

    /// A canvas that never reports the end of a stroke cannot stall merges of
    /// the note: the merge gives up after `inkWaitLimit` without applying
    /// anything, and a canvas that loads a page again forgets the stroke.
    @Test func aStrokeThatNeverEndsDoesNotStallMerges() async throws {
        let (vault, editor, clock, id, window, stack) = try await Self.stackOnSavedNote()
        defer { window.isHidden = true }
        let slot = try StackTS.slot(stack, editor, page: 0)
        #expect(await StackTS.ready(slot))
        let page = editor.pages[0].id
        try vault.apply([.addStroke(page: page, stroke: TS.stroke(x: 100, y: 200))], to: id,
                        deviceState: TS.deviceStateURL(), app: "other-device/1")
        editor.inkWaitLimit = .milliseconds(300)
        slot.coordinator.canvasViewDidBeginUsingTool(slot.host.canvas)   // and no end, ever
        #expect(try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil) == .skipped)
        #expect(slot.host.canvas.drawing.strokes.isEmpty)
        #expect(editor.liveStrokes(of: page).isEmpty)
        slot.coordinator.load(editor: editor, pageID: page, host: slot.host, keepScroll: true)
        #expect(!editor.isInkInUse)
        #expect(try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
            == .merged(fromOtherDevice: true))
        #expect(slot.host.canvas.drawing.strokes.count == 1)
        await editor.close()
        #expect(try NoteEditorTests.myDeltas(vault, clock, note: id).isEmpty)
    }
}
