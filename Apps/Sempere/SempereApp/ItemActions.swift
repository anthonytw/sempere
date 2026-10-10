import Foundation
import Observation
import Sempere

/// Items copied for pasting, in this app only (never the system pasteboard:
/// the plaintext would leave the app). Tied to one open vault: the model
/// empties it when the vault closes or changes keys.
@MainActor
@Observable
final class ItemClipboard {
    /// What was copied: items and the note whose blobs they reference.
    struct Entry: Equatable {
        var note: UUID
        var items: [Item]
    }

    private(set) var entry: Entry?
    /// Pastes since the last copy, so repeated pastes do not stack exactly.
    @ObservationIgnored private(set) var pasteCount = 0

    func copy(_ items: [Item], from note: UUID) {
        let usable = items.filter { $0.validationError == nil }
        entry = usable.isEmpty ? nil : Entry(note: note, items: usable)
        pasteCount = 0
    }

    func clear() {
        entry = nil
        pasteCount = 0
    }

    /// The offset of the next paste: on the same page as the copy, each
    /// paste lands 20 points further down and right.
    func nextOffset(samePage: Bool) -> Double {
        pasteCount += 1
        return samePage ? Double(pasteCount) * 20 : 0
    }
}

/// Item gestures with undo: each change is one delta through the editor and
/// one step on `undoManager` (the canvas's, so the system undo gestures and
/// ⌘Z reach it). Undoing a delete puts the items back under new ids
/// (`NoteEditor.restoreItems`); redoing deletes those.
@MainActor
final class ItemActions {
    let editor: NoteEditor
    weak var undoManager: UndoManager?

    init(editor: NoteEditor, undoManager: UndoManager?) {
        self.editor = editor
        self.undoManager = undoManager
    }

    /// Moves or resizes an item to `frame`.
    func setFrame(_ id: UUID, to frame: Rect, on page: UUID, name: String = String(localized: "Move", comment: "Undo action name (Edit menu: Undo …)")) {
        guard let old = editor.setItemFrame(id, to: frame, on: page) else { return }
        register(name) { $0.setFrame(id, to: old, on: page, name: name) }
    }

    /// Sets a text box's text and frame (an edit in its editor).
    func setText(_ id: UUID, to content: TextContent, frame: Rect, on page: UUID) {
        guard let old = editor.setItemText(id, to: content, frame: frame, on: page) else { return }
        register(String(localized: "Typing", comment: "Undo action name (Edit menu: Undo …)")) { $0.setText(id, to: old.content, frame: old.frame, on: page) }
    }

    /// Adds a new text box. Returns it (nil for an empty one).
    @discardableResult
    func addText(_ content: TextContent, frame: Rect, on page: UUID) -> Item? {
        guard let item = editor.addTextBox(content, frame: frame, on: page) else { return nil }
        return added([item], on: page, name: String(localized: "Add Text", comment: "Undo action name (Edit menu: Undo …)")).first
    }

    /// Deletes items. Returns the ones deleted.
    @discardableResult
    func delete(_ ids: [UUID], on page: UUID) -> [Item] {
        let gone = editor.removeItems(ids, from: page)
        guard !gone.isEmpty else { return [] }
        register(String(localized: "Delete", comment: "Undo action name (Edit menu: Undo …)")) { $0.restore(gone, on: page) }
        return gone
    }

    /// Puts deleted items back (as undo does). Returns the new items.
    @discardableResult
    func restore(_ items: [Item], on page: UUID) -> [Item] {
        let back = editor.restoreItems(items, on: page)
        guard !back.isEmpty else { return [] }
        register(String(localized: "Delete", comment: "Undo action name (Edit menu: Undo …)")) { $0.delete(back.map(\.id), on: page) }
        return back
    }

    /// Duplicates items on their page. Returns the copies.
    @discardableResult
    func duplicate(_ ids: [UUID], on page: UUID) -> [Item] {
        added(editor.duplicateItems(ids, on: page), on: page, name: String(localized: "Duplicate", comment: "Undo action name (Edit menu: Undo …)"))
    }

    /// Registers the undo of a replacement made elsewhere (Replace Image:
    /// `old` was replaced by `new`, already written).
    func replaced(_ old: Item, by new: Item, on page: UUID) {
        register("Replace Image") { $0.swap(new.id, back: old, on: page) }
    }

    /// Puts `content` back in place of the item `current` (undo or redo of
    /// a replacement): one delta, the item under a new id whose `parent`
    /// names `content` (tombstones are permanent, format.md §8.2.2). Returns
    /// the item put back.
    @discardableResult
    func swap(_ current: UUID, back content: Item, on page: UUID) -> Item? {
        var back = content
        back.id = UUID()
        back.parent = content.id
        back.origin = nil
        back.clocks = nil
        guard let was = editor.replaceItem(current, with: back, on: page) else { return nil }
        register("Replace Image") { $0.swap(back.id, back: was, on: page) }
        return back
    }

    /// Turns an item by `degrees` clockwise (anticlockwise when negative) from the
    /// rotation it has; `snapping` rounds the result as a two-finger turn does
    /// (`NoteOps.snappedRotation`). One delta, one undo step.
    func rotate(_ id: UUID, by degrees: Double, on page: UUID, snapping: Bool = false) {
        guard let item = editor.item(id, on: page) else { return }
        let turned = NoteOps.rotation(item.rotation, turnedBy: degrees)
        setRotation(id, to: snapping ? NoteOps.snappedRotation(turned) : turned, on: page)
    }

    /// Sets an item's rotation (degrees clockwise; also undo and redo of `rotate`).
    func setRotation(_ id: UUID, to degrees: Double, on page: UUID) {
        guard let old = editor.setItemRotation(id, to: degrees, on: page) else { return }
        register(String(localized: "Rotate", comment: "Undo action name (Edit menu: Undo …)")) {
            $0.setRotation(id, to: old ?? 0, on: page)
        }
    }

    /// Draws an item above the others of its layer.
    func bringToFront(_ id: UUID, on page: UUID) {
        guard let old = editor.bringItemToFront(id, on: page) else { return }
        register(String(localized: "Bring to Front", comment: "Undo action name (Edit menu: Undo …)")) { $0.setZ(id, to: old, on: page) }
    }

    /// Sets an item's order key (undo and redo of `bringToFront`).
    func setZ(_ id: UUID, to z: String, on page: UUID) {
        guard let now = editor.item(id, on: page)?.z, editor.setItemZ(id, to: z, on: page) else { return }
        register(String(localized: "Bring to Front", comment: "Undo action name (Edit menu: Undo …)")) { $0.setZ(id, to: now, on: page) }
    }

    /// Pastes the clipboard onto the page (copying blobs from another note
    /// first). Returns the new items.
    @discardableResult
    func paste(_ entry: ItemClipboard.Entry, on page: UUID, offset: Double,
               prepare: @escaping @Sendable (BlobRef) async throws -> Void = { _ in }) async throws -> [Item] {
        let pasted = try await editor.pasteItems(entry.items, from: entry.note, on: page, dx: offset, dy: offset,
                                                 prepare: prepare)
        return added(pasted, on: page, name: String(localized: "Paste", comment: "Undo action name (Edit menu: Undo …)"))
    }

    /// Registers the undo of adding `items` (removing them; redo restores).
    @discardableResult
    func added(_ items: [Item], on page: UUID, name: String) -> [Item] {
        guard !items.isEmpty else { return [] }
        register(name) { actions in
            let gone = actions.editor.removeItems(items.map(\.id), from: page)
            guard !gone.isEmpty else { return }
            actions.register(name) { $0.added($0.editor.restoreItems(gone, on: page), on: page, name: name) }
        }
        return items
    }

    /// One undo step: `body` runs on the main actor with this object.
    func register(_ name: String, _ body: @escaping @MainActor @Sendable (ItemActions) -> Void) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { body(target) }
        }
        undoManager?.setActionName(name)
    }
}
