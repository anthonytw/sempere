import CoreGraphics
import Foundation
import Sempere

/// Equations on the open note (format.md §8.2.8, docs/attachments.md §14
/// G1): typeset with SwiftMath (`MathTypesetter`), the rendered PDF written as
/// a blob first, then one delta built by the shared `NoteOps` math builders
/// the CLI's `attach math` and `items math` use.
extension NoteEditor {
    /// Typesets `content` and adds it on `pageID`: at its natural size (one
    /// point per point), shrunk to fit and centred in what is on screen
    /// (`visible`, page points; `NoteOps.viewFrame`). Two files: the render,
    /// then one `addItem`.
    @discardableResult
    func insertMath(_ content: MathContent, on pageID: UUID, visible: CGRect?) async throws -> Item {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let (data, value) = try MathTypesetter.rendered(content)
        let size = pageSize
        let natural = value.renderSize ?? Size(w: 1, h: 1)
        let frame = NoteOps.viewFrame(for: natural, pageSize: size, visible: visible.map { Rect($0) })
        return try await addAttachment(data: data, type: MathContent.renderType, on: pageID) { ref in
            var stored = value
            stored.render = ref
            return try NoteOps.placeMath(stored, on: page, pageSize: size, frame: frame).item
        }
    }

    /// Changes the equation `id` to `content` (source, style, size, colour):
    /// typesets it and writes the new render first, then one delta
    /// (`NoteOps.setMath`: the value, and the frame at the same scale). An
    /// unchanged equation keeps its render and writes nothing. Returns the
    /// value it had, for undo; nil when nothing changed.
    @discardableResult
    func setItemMath(_ id: UUID, to content: MathContent, on pageID: UUID) async throws -> MathContent? {
        guard canEditItems else { throw ItemError.notEditable }
        guard let old = item(id, on: pageID)?.math else { throw ItemError.noPage }
        var value = content
        if old.render != nil, old.typesetsLike(content) {
            value = old
        } else {
            let (data, rendered) = try MathTypesetter.rendered(content)
            let ref = try await storeBlob(data, type: MathContent.renderType)
            value = rendered
            value.render = ref
        }
        // The note may have changed (or closed) while the blob was written.
        guard canEditItems, let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.notEditable }
        guard let edit = try NoteOps.setMath(id, to: value, on: page) else { return nil }
        guard applyItemEdit(edit) else { throw ItemError.notEditable }
        return old
    }

    /// Sets an equation back to a value it had (undo and redo): its render is
    /// still in the note (blobs stay until collection), so nothing is
    /// typeset. Returns false when nothing changed.
    @discardableResult
    func restoreItemMath(_ id: UUID, to content: MathContent, on pageID: UUID) -> Bool {
        guard canEditItems, let page = pages.first(where: { $0.id == pageID }),
              let edit = try? NoteOps.setMath(id, to: content, on: page) else { return false }
        return applyItemEdit(edit)
    }
}

extension ItemActions {
    /// Changes an equation (one delta, one undo step that puts the old value back).
    func setMath(_ id: UUID, to content: MathContent, on page: UUID) async throws {
        guard let old = try await editor.setItemMath(id, to: content, on: page) else { return }
        register("Edit Equation") { $0.restoreMath(id, to: old, on: page) }
    }

    /// Puts an equation's earlier value back (undo and redo of `setMath`).
    func restoreMath(_ id: UUID, to content: MathContent, on page: UUID) {
        guard let now = editor.item(id, on: page)?.math, editor.restoreItemMath(id, to: content, on: page) else { return }
        register("Edit Equation") { $0.restoreMath(id, to: now, on: page) }
    }
}
