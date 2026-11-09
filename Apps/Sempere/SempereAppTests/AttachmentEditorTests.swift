import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp
import SempereAppCore

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
        let file = TestTemp.root.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try await editor.addAttachment(file: file, type: "image/png", on: page) { Self.imageItem($0) }
        await editor.flush()
        #expect(try vault.readBlob(note: Self.lecture, try #require(item.blob)) == Self.png())
        try expectSaved(editor, vault, page: page)
    }

    /// The rest of the item gestures' tests (duplicate, bring to front, rotate, paste, read-only, layout switch) are
    /// `ItemActionsTests` in `SempereAppCoreTests`, on a fake undo stack; this one runs the real `UndoManager`.
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

    @Test func modelClipboardCopiesAndPastesAcrossNotes() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50))
        model.blobCacheFolder = TestTemp.root.appendingPathComponent(UUID().uuidString)
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
