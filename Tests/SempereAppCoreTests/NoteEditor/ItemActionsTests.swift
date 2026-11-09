import Foundation
import Sempere
@testable import SempereAppCore
import Testing

extension NoteEditorSuites {
    /// Item gestures with undo (`ItemActionsCore`, moved from the app with wave 6 follow-up F1): one delta per
    /// gesture, undo and redo through a fake undo stack, and what a reader of the vault then sees. The rules moved
    /// from the app's `AttachmentEditorTests`; the app keeps `eachGestureIsOneDeltaAndUndoRedoWork` on the real
    /// `UndoManager`, the two blob tests (on the PNG its UIKit helper draws), the model clipboard test and the helpers
    /// the other app suites use.
    @MainActor
    struct ItemActionsTests {
        typealias F = EditorFixture

        /// Picture bytes: the editor stores them as they are.
        static let png = Data((0..<64).map { UInt8($0) })

        nonisolated static func imageItem(_ ref: BlobRef, frame: Rect = Rect(x: 40, y: 50, w: 120, h: 90)) -> Item {
            .image(blob: ref, pixelSize: Size(w: 4, h: 3), frame: frame, z: "a")
        }

        nonisolated static func textItem(_ s: String = "Hello") -> Item {
            .text(TextContent(size: 14, color: .black, runs: [TextRun(s)]), frame: Rect(x: 10, y: 10, w: 200, h: 40), z: "a")
        }

        /// Foundation's `UndoManager` does not exist on Linux: a stack of steps that undoes and redoes as it does (a step
        /// registered while one is undone is its redo; a new step clears the redo stack).
        @MainActor
        final class FakeUndoStack: ItemUndoStack {
            private struct Step {
                var name: String
                var run: @MainActor () -> Void
            }
            private enum Mode { case idle, undoing, redoing }
            private var undos: [Step] = [], redos: [Step] = []
            private var mode = Mode.idle

            var undoActionName: String { undos.last?.name ?? "" }
            var redoActionName: String { redos.last?.name ?? "" }
            var canUndo: Bool { !undos.isEmpty }
            var canRedo: Bool { !redos.isEmpty }

            func registerStep<Target: AnyObject>(for target: Target, name: String, _ step: @escaping @MainActor @Sendable (Target) -> Void) {
                let entry = Step(name: name) { [weak target] in if let target { step(target) } }
                switch mode {
                case .undoing: redos.append(entry)
                case .redoing: undos.append(entry)
                case .idle:
                    undos.append(entry)
                    redos.removeAll()
                }
            }

            func undo() {
                guard let step = undos.popLast() else { return }
                mode = .undoing
                step.run()
                mode = .idle
            }

            func redo() {
                guard let step = redos.popLast() else { return }
                mode = .redoing
                step.run()
                mode = .idle
            }
        }

        static func undoManager() -> FakeUndoStack { FakeUndoStack() }

        /// Runs `body` as one gesture (a gesture registers one step).
        static func grouped(_ undo: FakeUndoStack, _ body: () -> Void) { body() }

        /// The actions, with the step names this test file reads back.
        static func actions(editor: TestEditor, undoManager: FakeUndoStack?) -> ItemActionsCore<TestCanvas> {
            ItemActionsCore(editor: editor, undoStack: undoManager, wording: { "\($0)" })
        }

        /// The editor's items on `page` are what a reader reconstructs.
        func expectSaved(_ editor: TestEditor, _ vault: Vault, page: UUID, note: UUID = F.lecture) async throws {
            let state = try await F.state(vault, note)
            let stored = try #require(state.pages.first { $0.id == page }).items.map { item -> Item in
                var i = item
                i.origin = nil
                i.clocks = nil
                return i
            }
            #expect(stored == editor.items(on: page))
        }

        @Test func eachGestureIsOneDeltaAndUndoRedoWork() async throws {
            let vault = try await F.vault()
            let (editor, clock) = try await F.open(vault, debounce: .seconds(60))
            let page = try #require(editor.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: editor, undoManager: undo)
            let text = try editor.addItems([Self.textItem()], on: page)[0]
            await editor.flush()
            var count = try await F.myDeltas(vault, clock).count
            // A gesture is one undo group; undo() and redo() run outside any group
            // (undo() would close a group opened for it and undo that empty group).
            func step(grouped: Bool = true, _ body: () -> Void) async throws -> [Op] {
                body()
                await editor.flush()
                let deltas = try await F.myDeltas(vault, clock)
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
            try await expectSaved(editor, vault, page: page)
        }

        @Test func duplicateAndBringToFrontWithUndo() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: editor, undoManager: undo)
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
            try await expectSaved(editor, vault, page: page)
        }

        /// Rotate (GA-02): the menu's quarter turns and the two-finger turn are one delta and one
        /// undo step each; undo and redo restore the rotation.
        @Test func rotatingAnItemIsOneUndoStep() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: editor, undoManager: undo)
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
            try await expectSaved(editor, vault, page: page)
        }

        @Test func pastingIntoAnotherNoteCopiesTheBlobFirst() async throws {
            let vault = try await F.vault()
            let (source, _) = try await F.open(vault)
            let sourcePage = try #require(source.currentPage).id
            let image = try await source.addAttachment(data: Self.png, type: "image/png", on: sourcePage) { Self.imageItem($0) }
            await source.close()
            // The other note (in Recently Deleted in the fixture: restore it first so it is editable).
            _ = try vault.apply([.restoreNote], to: F.deleted, deviceState: F.deviceStateURL(), app: "test/1")
            let clock = try DeviceClock(url: F.deviceStateURL(), app: "sempere-test/1")
            let target = try await TestEditor.open(vault: vault, noteID: F.deleted, clock: clock)
            #expect(!target.isReadOnly)
            let page = try #require(target.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: target, undoManager: undo)
                        let pasted = try await actions.paste(ItemClipboard.Entry(note: F.lecture, items: [image]), on: page, offset: 0)
                        await target.flush()
            #expect(pasted.count == 1)
            #expect(pasted[0].id != image.id)
            let ref = try #require(image.blob)
            #expect(try vault.readBlob(note: F.deleted, ref) == Self.png, "the blob is in the target note's att/")
            let deltas = try await F.myDeltas(vault, clock, note: F.deleted)
            #expect(deltas.count == 1)
            #expect(deltas.first?.count == 1)
            try await expectSaved(target, vault, page: page, note: F.deleted)
            undo.undo()
            #expect(target.items(on: page).isEmpty)
            await target.close()
        }

        @Test func readOnlyEditorsRefuseItems() async throws {
            let vault = try await F.vault()
            let clock = try DeviceClock(url: F.deviceStateURL(), app: "sempere-test/1")
            let editor = try await TestEditor.open(vault: vault, noteID: F.deleted, clock: clock)   // in Recently Deleted
            #expect(editor.isReadOnly)
            let page = try #require(editor.currentPage).id
            #expect(throws: TestEditor.ItemError.notEditable) { try editor.addItems([Self.textItem()], on: page) }
            await #expect(throws: TestEditor.ItemError.notEditable) {
                try await editor.addAttachment(data: Self.png, type: "image/png", on: page) { Self.imageItem($0) }
            }
            #expect(editor.setItemFrame(UUID(), to: Rect(x: 0, y: 0, w: 1, h: 1), on: page) == nil)
            #expect(editor.removeItems([UUID()], from: page).isEmpty)
        }

        @Test func itemsSurviveAPageLayoutSwitch() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage).id
            _ = try editor.addItems([Self.textItem()], on: page)
            await editor.flush()
            await editor.setLayout(pageless: true)
            #expect(editor.pages.flatMap(\.items).count == 1)
            await editor.setLayout(pageless: false)
            #expect(editor.pages.flatMap(\.items).count == 1)
            let state = try await F.state(vault)
            #expect(state.pages.flatMap(\.items).count == 1)
        }


        /// Each gesture names its undo step (the app words the names, `ItemActions.undoName`).
        @Test func eachGestureNamesItsUndoStep() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: editor, undoManager: undo)
            let a = try editor.addItems([Self.textItem("a")], on: page)[0]
            _ = try editor.addItems([Self.textItem("b")], on: page)   // a is below b: bringing it forward changes something
            func name(_ body: () -> Void) -> String {
                Self.grouped(undo, body)
                return undo.undoActionName
            }
            #expect(name { actions.setFrame(a.id, to: Rect(x: 1, y: 1, w: 50, h: 20), on: page) } == "move")
            #expect(name { actions.setFrame(a.id, to: Rect(x: 2, y: 2, w: 60, h: 20), on: page, name: "Resize") } == "Resize")
            #expect(name { actions.rotate(a.id, by: 90, on: page) } == "rotate")
            #expect(name { actions.bringToFront(a.id, on: page) } == "bringToFront")
            #expect(name { _ = actions.duplicate([a.id], on: page) } == "duplicate")
            #expect(name { _ = actions.delete([a.id], on: page) } == "delete")
            #expect(name { _ = actions.addText(TextContent(size: 14, color: .black, runs: [TextRun("t")]),
                                               frame: Rect(x: 0, y: 0, w: 50, h: 20), on: page) } == "addText")
        }

        /// No change, no step: a move to the same frame or an item that is not there registers nothing.
        @Test func aGestureThatChangesNothingRegistersNothing() async throws {
            let vault = try await F.vault()
            let (editor, _) = try await F.open(vault)
            let page = try #require(editor.currentPage).id
            let undo = Self.undoManager()
            let actions = Self.actions(editor: editor, undoManager: undo)
            let a = try editor.addItems([Self.textItem("a")], on: page)[0]
            Self.grouped(undo) {
                actions.setFrame(UUID(), to: Rect(x: 1, y: 1, w: 5, h: 5), on: page)
                #expect(actions.delete([UUID()], on: page).isEmpty)
                #expect(actions.duplicate([UUID()], on: page).isEmpty)
                actions.setZ(UUID(), to: "z", on: page)
            }
            #expect(!undo.canUndo, "nothing was registered")
            Self.grouped(undo) { actions.bringToFront(a.id, on: page) }   // the only item of its layer: already on top
            #expect(!undo.canUndo)
        }
    }
}
