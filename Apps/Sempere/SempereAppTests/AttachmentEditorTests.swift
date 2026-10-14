import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Attachment plumbing in the editor (docs/attachments.md §14, task E0):
/// blobs through `NoteWriter`, then one delta per item gesture (add, move,
/// resize, delete, duplicate, bring to front, copy to another note), undo
/// and redo through `ItemActions`, and what a reader of the vault then sees.
@MainActor
struct AttachmentEditorTests {
    static let lecture = AppModelTests.lecture
    static let other = AppModelTests.deleted

    /// A 4 × 3 PNG, red on the left, blue on the right.
    static func png() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3), format: format).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 3))
        }
    }

    nonisolated static func imageItem(_ ref: BlobRef, frame: Rect = Rect(x: 40, y: 50, w: 120, h: 90)) -> Item {
        .image(blob: ref, pixelSize: Size(w: 4, h: 3), frame: frame, z: "a")
    }

    nonisolated static func textItem(_ s: String = "Hello") -> Item {
        .text(TextContent(size: 14, color: .black, runs: [TextRun(s)]), frame: Rect(x: 10, y: 10, w: 200, h: 40), z: "a")
    }

    /// An undo manager whose groups the test opens and closes (no run loop
    /// turns between steps here).
    static func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// Runs `body` as one undo group.
    static func grouped(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// The editor's items on `page` are what a reader reconstructs.
    func expectSaved(_ editor: NoteEditor, _ vault: Vault, page: UUID, note: UUID = lecture) throws {
        let state = try vault.reconstruct(noteId: note)
        let stored = try #require(state.pages.first { $0.id == page }).items.map { item -> Item in
            var i = item
            i.origin = nil
            i.clocks = nil
            return i
        }
        #expect(stored == editor.items(on: page))
    }

    @Test func addAttachmentWritesTheBlobThenOneDelta() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let att = vault.url.appendingPathComponent("notes/\(Self.lecture.uuidString.lowercased())/att")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: att.path)) ?? [])
        let data = Self.png()
        let item = try await editor.addAttachment(data: data, type: "image/png", on: page) { ref in Self.imageItem(ref) }
        await editor.flush()
        let deltas = try NoteEditorTests.myDeltas(vault, clock)
        #expect(deltas.count == 1)
        guard case .addItem(let p, let added)? = deltas.first?.first else { Issue.record("\(deltas)"); return }
        #expect(p == page)
        #expect(added.id == item.id)
        let ref = try #require(item.blob)
        #expect(try vault.readBlob(note: Self.lecture, ref) == data)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: att.path)).subtracting(before)
        #expect(names.count == 1 && names.first?.hasSuffix(".image.age") == true)
        try expectSaved(editor, vault, page: page)
    }

    @Test func addAttachmentFromAFileStreamsIt() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try await editor.addAttachment(file: file, type: "image/png", on: page) { Self.imageItem($0) }
        await editor.flush()
        #expect(try vault.readBlob(note: Self.lecture, try #require(item.blob)) == Self.png())
        try expectSaved(editor, vault, page: page)
    }

    @Test func eachGestureIsOneDeltaAndUndoRedoWork() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, clock) = try await NoteEditorTests.open(vault, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        let undo = Self.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let text = try editor.addItems([Self.textItem()], on: page)[0]
        await editor.flush()
        var count = try NoteEditorTests.myDeltas(vault, clock).count
        // A gesture is one undo group; undo() and redo() run outside any group
        // (undo() would close a group opened for it and undo that empty group).
        func step(grouped: Bool = true, _ body: () -> Void) async throws -> [Op] {
            if grouped { undo.beginUndoGrouping() }
            body()
            if grouped { undo.endUndoGrouping() }
            await editor.flush()
            let deltas = try NoteEditorTests.myDeltas(vault, clock)
            #expect(deltas.count == count + 1, "one delta per gesture")
            count = deltas.count
            return deltas.last ?? []
        }
        // Move.
        let moved = Rect(x: 60, y: 70, w: 200, h: 40)
        let moveOps = try await step { actions.setFrame(text.id, to: moved, on: page) }
        #expect(moveOps.count == 1)
        if case .setItem(_, let id, .frame(let f))? = moveOps.first { #expect(id == text.id && f == moved) } else {
            Issue.record("\(moveOps)")
        }
        // Undo the move: back to the old frame, as a new delta.
        _ = try await step(grouped: false) { undo.undo() }
        #expect(editor.item(text.id, on: page)?.frame == text.frame)
        _ = try await step(grouped: false) { undo.redo() }
        #expect(editor.item(text.id, on: page)?.frame == moved)
        // Delete, undo (restored under a new id with parent), redo.
        let deleteOps = try await step { actions.delete([text.id], on: page) }
        #expect(deleteOps == [.removeItem(page: page, itemId: text.id)])
        #expect(editor.items(on: page).isEmpty)
        _ = try await step(grouped: false) { undo.undo() }
        let back = try #require(editor.items(on: page).first)
        #expect(back.id != text.id)
        #expect(back.parent == text.id)
        #expect(back.frame == moved)
        _ = try await step(grouped: false) { undo.redo() }
        #expect(editor.items(on: page).isEmpty)
        try expectSaved(editor, vault, page: page)
    }

    @Test func duplicateAndBringToFrontWithUndo() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let undo = Self.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let a = try editor.addItems([Self.textItem("a")], on: page)[0]
        let b = try editor.addItems([Self.textItem("b")], on: page)[0]
        #expect(editor.items(on: page).map(\.id) == [a.id, b.id])
        Self.grouped(undo) { actions.bringToFront(a.id, on: page) }
        #expect(editor.items(on: page).map(\.id) == [b.id, a.id])
        undo.undo()
        #expect(editor.items(on: page).map(\.id) == [a.id, b.id])
        undo.redo()
        #expect(editor.items(on: page).map(\.id) == [b.id, a.id])
        var copies: [Item] = []
        Self.grouped(undo) { copies = actions.duplicate([a.id], on: page) }
        #expect(copies.count == 1)
        #expect(copies[0].frame.x == a.frame.x + 20)
        #expect(editor.items(on: page).last?.id == copies[0].id, "the copy is on top")
        undo.undo()
        #expect(editor.items(on: page).count == 2)
        await editor.flush()
        try expectSaved(editor, vault, page: page)
    }

    /// Rotate (GA-02): the menu's quarter turns and the two-finger turn are one delta and one
    /// undo step each; undo and redo restore the rotation.
    @Test func rotatingAnItemIsOneUndoStep() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        let undo = Self.undoManager()
        let actions = ItemActions(editor: editor, undoManager: undo)
        let a = try editor.addItems([Self.textItem("a")], on: page)[0]
        Self.grouped(undo) { actions.rotate(a.id, by: 90, on: page) }
        #expect(editor.item(a.id, on: page)?.rotation == 90)
        Self.grouped(undo) { actions.rotate(a.id, by: -90, on: page) }   // back to upright: stored as none
        #expect(editor.item(a.id, on: page)?.rotation == nil)
        Self.grouped(undo) { actions.rotate(a.id, by: -90, on: page) }   // Rotate Left from upright
        #expect(editor.item(a.id, on: page)?.rotation == 270)
        undo.undo()
        #expect(editor.item(a.id, on: page)?.rotation == nil)
        undo.redo()
        #expect(editor.item(a.id, on: page)?.rotation == 270)
        // A two-finger turn ending near a multiple of 15° snaps to it; no change writes nothing.
        Self.grouped(undo) { actions.rotate(a.id, by: 88.5, on: page, snapping: true) }
        #expect(editor.item(a.id, on: page)?.rotation == 0 || editor.item(a.id, on: page)?.rotation == nil)
        let steps = editor.items(on: page).count
        actions.rotate(a.id, by: 0, on: page, snapping: true)   // already upright: nothing to undo
        #expect(editor.items(on: page).count == steps)
        await editor.flush()
        try expectSaved(editor, vault, page: page)
    }

    @Test func pastingIntoAnotherNoteCopiesTheBlobFirst() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (source, _) = try await NoteEditorTests.open(vault)
        let sourcePage = try #require(source.currentPage).id
        let image = try await source.addAttachment(data: Self.png(), type: "image/png", on: sourcePage) { Self.imageItem($0) }
        await source.close()
        // The other note (in Recently Deleted in the fixture: restore it first so it is editable).
        _ = try vault.apply([.restoreNote], to: Self.other, deviceState: TS.deviceStateURL(), app: "test/1")
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let target = try await NoteEditor.open(vault: vault, noteID: Self.other, clock: clock)
        #expect(!target.isReadOnly)
        let page = try #require(target.currentPage).id
        let undo = Self.undoManager()
        let actions = ItemActions(editor: target, undoManager: undo)
        undo.beginUndoGrouping()
        let pasted = try await actions.paste(ItemClipboard.Entry(note: Self.lecture, items: [image]), on: page, offset: 0)
        undo.endUndoGrouping()
        await target.flush()
        #expect(pasted.count == 1)
        #expect(pasted[0].id != image.id)
        let ref = try #require(image.blob)
        #expect(try vault.readBlob(note: Self.other, ref) == Self.png(), "the blob is in the target note's att/")
        let deltas = try NoteEditorTests.myDeltas(vault, clock, note: Self.other)
        #expect(deltas.count == 1)
        #expect(deltas.first?.count == 1)
        try expectSaved(target, vault, page: page, note: Self.other)
        undo.undo()
        #expect(target.items(on: page).isEmpty)
        await target.close()
    }

    @Test func readOnlyEditorsRefuseItems() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let editor = try await NoteEditor.open(vault: vault, noteID: Self.other, clock: clock)   // in Recently Deleted
        #expect(editor.isReadOnly)
        let page = try #require(editor.currentPage).id
        #expect(throws: NoteEditor.ItemError.notEditable) { try editor.addItems([Self.textItem()], on: page) }
        await #expect(throws: NoteEditor.ItemError.notEditable) {
            try await editor.addAttachment(data: Self.png(), type: "image/png", on: page) { Self.imageItem($0) }
        }
        #expect(editor.setItemFrame(UUID(), to: Rect(x: 0, y: 0, w: 1, h: 1), on: page) == nil)
        #expect(editor.removeItems([UUID()], from: page).isEmpty)
    }

    @Test func itemsSurviveAPageLayoutSwitch() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let (editor, _) = try await NoteEditorTests.open(vault)
        let page = try #require(editor.currentPage).id
        _ = try editor.addItems([Self.textItem()], on: page)
        await editor.flush()
        await editor.setLayout(pageless: true)
        #expect(editor.pages.flatMap(\.items).count == 1)
        await editor.setLayout(pageless: false)
        #expect(editor.pages.flatMap(\.items).count == 1)
        let state = try vault.reconstruct(noteId: Self.lecture)
        #expect(state.pages.flatMap(\.items).count == 1)
    }

    @Test func modelClipboardCopiesAndPastesAcrossNotes() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        try await model.openEditor(for: Self.lecture)
        let editor = try #require(model.editor)
        let page = try #require(editor.currentPage).id
        let image = try await editor.addAttachment(data: Self.png(), type: "image/png", on: page) { Self.imageItem($0) }
        model.itemCommands.copy([image], editor.noteID)
        #expect(model.itemCommands.canPaste())
        let pasted = await model.itemCommands.paste(page, ItemActions(editor: editor, undoManager: nil))
        #expect(pasted.count == 1)
        #expect(pasted[0].frame.x == image.frame.x + 20, "a paste on the same page lands beside the original")
        // The cache serves the blob, and closing the vault empties it and the clipboard.
        let cache = try #require(model.attachmentCache())
        let file = try await cache.acquire(note: Self.lecture, ref: try #require(image.blob))
        #expect(FileManager.default.fileExists(atPath: file.path))
        await cache.release(note: Self.lecture, ref: try #require(image.blob))
        model.close()
        #expect(model.itemClipboard.entry == nil)
        #expect(model.blobCache == nil)
        #expect(await TS.waitUntil { !FileManager.default.fileExists(atPath: file.path) })
    }
}
