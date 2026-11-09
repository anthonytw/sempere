import Foundation
import Sempere

/// The undo stack the item gestures register their steps on: the app's is the canvas's `UndoManager` (so the system
/// undo gestures and ⌘Z reach it); Foundation has none on Linux, so tests use a fake.
@MainActor
public protocol ItemUndoStack: AnyObject {
    /// One undo step named `name`: `step` runs on the main actor with `target` when it is undone (a step registered
    /// while one runs is its redo). The stack holds `target` weakly and keeps no strong reference to it in `step`, as
    /// `UndoManager.registerUndo(withTarget:)` does: the steps go when the target does.
    func registerStep<Target: AnyObject>(for target: Target, name: String, _ step: @escaping @MainActor @Sendable (Target) -> Void)
}

/// Item gestures with undo: each change is one delta through the editor and
/// one step on `undoStack` (the canvas's). Undoing a delete puts the items back under new ids
/// (`NoteEditor.restoreItems`); redoing deletes those.
@MainActor
public final class ItemActionsCore<Canvas: NoteCanvas> {
    public typealias Editor = NoteEditorModel<Canvas>

    /// The names of the undo steps this type registers (the app words them; Edit menu: Undo …).
    public enum UndoName: Equatable, Sendable {
        case move, typing, addText, delete, duplicate, replaceImage, rotate, bringToFront, paste, crop
    }

    public let editor: Editor
    public weak var undoStack: (any ItemUndoStack)?
    /// The words of an undo step's name.
    public let wording: @Sendable (UndoName) -> String

    public init(editor: Editor, undoStack: (any ItemUndoStack)?, wording: @escaping @Sendable (UndoName) -> String) {
        self.editor = editor
        self.undoStack = undoStack
        self.wording = wording
    }

    /// Moves or resizes an item to `frame`.
    public func setFrame(_ id: UUID, to frame: Rect, on page: UUID, name: String? = nil) {
        guard let old = editor.setItemFrame(id, to: frame, on: page) else { return }
        let name = name ?? wording(.move)
        register(name) { $0.setFrame(id, to: old, on: page, name: name) }
    }

    /// Sets a text box's text and frame (an edit in its editor).
    public func setText(_ id: UUID, to content: TextContent, frame: Rect, on page: UUID) {
        guard let old = editor.setItemText(id, to: content, frame: frame, on: page) else { return }
        register(wording(.typing)) { $0.setText(id, to: old.content, frame: old.frame, on: page) }
    }

    /// Adds a new text box. Returns it (nil for an empty one).
    @discardableResult
    public func addText(_ content: TextContent, frame: Rect, on page: UUID) -> Item? {
        guard let item = editor.addTextBox(content, frame: frame, on: page) else { return nil }
        return added([item], on: page, name: wording(.addText)).first
    }

    /// Deletes items. Returns the ones deleted.
    @discardableResult
    public func delete(_ ids: [UUID], on page: UUID) -> [Item] {
        let gone = editor.removeItems(ids, from: page)
        guard !gone.isEmpty else { return [] }
        register(wording(.delete)) { $0.restore(gone, on: page) }
        return gone
    }

    /// Puts deleted items back (as undo does). Returns the new items.
    @discardableResult
    public func restore(_ items: [Item], on page: UUID) -> [Item] {
        let back = editor.restoreItems(items, on: page)
        guard !back.isEmpty else { return [] }
        register(wording(.delete)) { $0.delete(back.map(\.id), on: page) }
        return back
    }

    /// Duplicates items on their page. Returns the copies.
    @discardableResult
    public func duplicate(_ ids: [UUID], on page: UUID) -> [Item] {
        added(editor.duplicateItems(ids, on: page), on: page, name: wording(.duplicate))
    }

    /// Registers the undo of a replacement made elsewhere (Replace Image:
    /// `old` was replaced by `new`, already written).
    public func replaced(_ old: Item, by new: Item, on page: UUID) {
        register(wording(.replaceImage)) { $0.swap(new.id, back: old, on: page) }
    }

    /// Puts `content` back in place of the item `current` (undo or redo of
    /// a replacement): one delta, the item under a new id whose `parent`
    /// names `content` (tombstones are permanent, format.md §8.2.2). Returns
    /// the item put back.
    @discardableResult
    public func swap(_ current: UUID, back content: Item, on page: UUID) -> Item? {
        var back = content
        back.id = UUID()
        back.parent = content.id
        back.origin = nil
        back.clocks = nil
        guard let was = editor.replaceItem(current, with: back, on: page) else { return nil }
        register(wording(.replaceImage)) { $0.swap(back.id, back: was, on: page) }
        return back
    }

    /// Turns an item by `degrees` clockwise (counterclockwise when negative) from the
    /// rotation it has; `snapping` rounds the result as a two-finger turn does
    /// (`NoteOps.snappedRotation`). One delta, one undo step.
    public func rotate(_ id: UUID, by degrees: Double, on page: UUID, snapping: Bool = false) {
        guard let item = editor.item(id, on: page) else { return }
        let turned = NoteOps.rotation(item.rotation, turnedBy: degrees)
        setRotation(id, to: snapping ? NoteOps.snappedRotation(turned) : turned, on: page)
    }

    /// Sets an item's rotation (degrees clockwise; also undo and redo of `rotate`).
    public func setRotation(_ id: UUID, to degrees: Double, on page: UUID) {
        guard let old = editor.setItemRotation(id, to: degrees, on: page) else { return }
        register(wording(.rotate)) {
            $0.setRotation(id, to: old ?? 0, on: page)
        }
    }

    /// Draws an item above the others of its layer.
    public func bringToFront(_ id: UUID, on page: UUID) {
        guard let old = editor.bringItemToFront(id, on: page) else { return }
        register(wording(.bringToFront)) { $0.setZ(id, to: old, on: page) }
    }

    /// Sets an item's order key (undo and redo of `bringToFront`).
    public func setZ(_ id: UUID, to z: String, on page: UUID) {
        guard let now = editor.item(id, on: page)?.z, editor.setItemZ(id, to: z, on: page) else { return }
        register(wording(.bringToFront)) { $0.setZ(id, to: now, on: page) }
    }

    /// Pastes the clipboard onto the page (copying blobs from another note
    /// first). Returns the new items.
    @discardableResult
    public func paste(_ entry: ItemClipboard.Entry, on page: UUID, offset: Double,
               prepare: @escaping @Sendable (BlobRef) async throws -> Void = { _ in }) async throws -> [Item] {
        let pasted = try await editor.pasteItems(entry.items, from: entry.note, on: page, dx: offset, dy: offset,
                                                 prepare: prepare)
        return added(pasted, on: page, name: wording(.paste))
    }

    /// Registers the undo of adding `items` (removing them; redo restores).
    @discardableResult
    public func added(_ items: [Item], on page: UUID, name: String) -> [Item] {
        guard !items.isEmpty else { return [] }
        register(name) { actions in
            let gone = actions.editor.removeItems(items.map(\.id), from: page)
            guard !gone.isEmpty else { return }
            actions.register(name) { $0.added($0.editor.restoreItems(gone, on: page), on: page, name: name) }
        }
        return items
    }

    /// One undo step: `body` runs on the main actor with this object.
    public func register(_ name: String, _ body: @escaping @MainActor @Sendable (ItemActionsCore) -> Void) {
        undoStack?.registerStep(for: self, name: name, body)
    }
}

extension ItemActionsCore {
    /// Crops an item (one delta, one undo step that puts the old crop back).
    public func setCrop(_ id: UUID, to crop: Rect?, on page: UUID) {
        guard let old = editor.setItemCrop(id, to: crop, on: page) else { return }
        register(wording(.crop)) { $0.setCrop(id, to: old, on: page) }
    }
}

extension AppModelCore {
    /// Replace Image with its undo step on `actions` (`replaceImage(_:on:with:in:privacy:)` writes the delta). Returns the new
    /// image.
    @discardableResult
    public func replaceImage(_ item: UUID, on page: UUID, with data: Data, in editor: Editor, actions: ItemActionsCore<Host.Canvas>?,
                             privacy: Bool? = nil) async -> Item? {
        guard let (old, new) = await replaceImage(item, on: page, with: data, in: editor, privacy: privacy) else { return nil }
        actions?.replaced(old, by: new, on: page)
        return new
    }
}
