import CryptoKit
import Foundation
import Sempere

/// Placed items on the open note (format.md §8.2, docs/attachments.md §13):
/// the plumbing E1–E5 build on. Every gesture is one delta through the
/// editor's `NoteWriter`, built by the shared `NoteOps` item builders (the
/// CLI writes the same ops). Blobs are written first, then the delta that
/// references them (format.md §8.1.4).
extension NoteEditor {
    /// Why an item gesture was not made.
    enum ItemError: Error, Equatable {
        /// The note is read-only, being read, or closed.
        case notEditable
        /// The page is not in the note.
        case noPage
    }

    /// Whether items can be added, moved or deleted now.
    var canEditItems: Bool { !isReadOnly && !isShutDown }

    /// The page's items in drawing order (`Item.drawsBefore`).
    func items(on pageID: UUID) -> [Item] {
        (pages.first { $0.id == pageID }?.items ?? []).sorted(by: Item.drawsBefore)
    }

    /// The item `id` on the page, if it is there.
    func item(_ id: UUID, on pageID: UUID) -> Item? {
        pages.first { $0.id == pageID }?.items.first { $0.id == id }
    }

    private func page(_ id: UUID) throws -> Page {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == id }) else { throw ItemError.noPage }
        return page
    }

    /// Adds `items` (whose blobs are already in this note) to the page, each
    /// above everything in its layer when `onTop`, else with its own `z`.
    /// One delta. Returns the items as added.
    @discardableResult
    func addItems(_ items: [Item], on pageID: UUID, onTop: Bool = true) throws -> [Item] {
        var current = try page(pageID)
        var ops: [Op] = []
        var added: [Item] = []
        let stamp = recordingStamp
        for var item in items {
            // Placed while recording: linked to the audio (format.md §8.3.3).
            if item.rec == nil, let link = stamp?(Date()) { item.rec = link }
            let edit = onTop ? try NoteOps.placeOnTop(item, on: current) : try NoteOps.addItems([item], to: current)
            ops += edit.ops
            current = edit.page
            added += edit.page.items.filter { edit.added.contains($0.id) }
        }
        guard applyItemEdit(ItemEdit(ops: ops, page: current, added: added.map(\.id))) else { throw ItemError.notEditable }
        return added
    }

    /// Writes the file at `file` as a blob of this note, then adds the item
    /// `make` builds from its reference on top of the page: two files, the
    /// blob first (format.md §8.1.4), the item in one delta. The entry point
    /// for images, PDF pages and recordings (E1, E3, E4).
    @discardableResult
    func addAttachment(file: URL, type: String, on pageID: UUID,
                       item make: @Sendable (BlobRef) throws -> Item) async throws -> Item {
        _ = try page(pageID)
        let ref = try await storeBlob(file: file, type: type)
        return try addItems([try make(ref)], on: pageID)[0]
    }

    /// `addAttachment(file:...)` for content in memory.
    @discardableResult
    func addAttachment(data: Data, type: String, on pageID: UUID,
                       item make: @Sendable (BlobRef) throws -> Item) async throws -> Item {
        _ = try page(pageID)
        let ref = try await storeBlob(data, type: type)
        return try addItems([try make(ref)], on: pageID)[0]
    }

    /// Writes `data` as a blob of this note (format.md §8.1.4), after
    /// `prepareBlobWrite` has seen the reference it will have. Returns it.
    ///
    /// - Throws: `ItemError.notEditable` when the note is closed, or a write error.
    func storeBlob(_ data: Data, type: String) async throws -> BlobRef {
        guard let writer = attachmentWriter else { throw ItemError.notEditable }
        if let prepare = prepareBlobWrite { try await prepare(BlobRef(content: data, type: type)) }
        return try await writer.addBlob(data, type: type)
    }

    /// `storeBlob(_:type:)` for the file at `file`, streamed, with `edits`
    /// changing bytes on the way (a video's metadata). The reference is
    /// planned off the main actor, and only when `prepareBlobWrite` wants it.
    func storeBlob(file: URL, type: String, edits: [ByteEdit]? = nil) async throws -> BlobRef {
        guard let writer = attachmentWriter else { throw ItemError.notEditable }
        if let prepare = prepareBlobWrite {
            let planned = try await Task.detached(priority: .userInitiated) {
                if let edits { try Vault.blobRef(contentsOf: file, type: type, edits: edits) }
                else { try BlobPlanning.ref(ofFile: file, type: type) }
            }.value
            try await prepare(planned)
        }
        return try await writer.addBlob(from: file, type: type, edits: edits ?? [])
    }

    /// Moves or resizes an item (one `setItem(frame)`). A text box that gets
    /// another width is laid out again (TextKit breaks, the height of its
    /// lines), in the same delta. Returns the frame it had, for undo; nil when
    /// nothing changed.
    @discardableResult
    func setItemFrame(_ id: UUID, to frame: Rect, on pageID: UUID) -> Rect? {
        guard let page = try? page(pageID), let old = page.items.first(where: { $0.id == id })?.frame,
              let edit = NoteOps.setFrame(id, to: frame, on: page, relayout: TextKitBreaks.relayout),
              applyItemEdit(edit) else { return nil }
        return old
    }

    /// Sets a text box's text and frame (one delta: `setItem(text)` and, if
    /// it changed, `setItem(frame)`). Returns what it had, for undo; nil when
    /// nothing changed or the content is not valid.
    @discardableResult
    func setItemText(_ id: UUID, to content: TextContent, frame: Rect, on pageID: UUID) -> (content: TextContent, frame: Rect)? {
        guard let page = try? page(pageID), let item = page.items.first(where: { $0.id == id }), let old = item.text,
              let edit = try? NoteOps.setText(id, to: content, frame: frame, on: page), applyItemEdit(edit) else { return nil }
        return (old, item.frame)
    }

    /// Adds a new text box on top of the page (one `addItem`). Nil when the
    /// text is empty (an empty new box is not written) or not valid.
    func addTextBox(_ content: TextContent, frame: Rect, on pageID: UUID) -> Item? {
        guard !content.string.isEmpty, content.limitViolation == nil else { return nil }
        return try? addItems([Item.text(content, frame: frame, z: "a")], on: pageID).first
    }

    /// Turns an item (degrees clockwise). Returns the rotation it had (nil
    /// is 0), wrapped in an optional; nil when nothing changed.
    @discardableResult
    func setItemRotation(_ id: UUID, to degrees: Double, on pageID: UUID) -> Double?? {
        guard let page = try? page(pageID), let item = page.items.first(where: { $0.id == id }),
              let edit = NoteOps.setRotation(id, to: degrees, on: page), applyItemEdit(edit) else { return nil }
        return .some(item.rotation)
    }

    /// Draws an item above the others of its layer. Returns its old `z`.
    @discardableResult
    func bringItemToFront(_ id: UUID, on pageID: UUID) -> String? {
        guard let page = try? page(pageID), let item = page.items.first(where: { $0.id == id }),
              let edit = NoteOps.bringToFront(id, on: page), applyItemEdit(edit) else { return nil }
        return item.z
    }

    /// Sets an item's `z` back (undo of `bringItemToFront`).
    @discardableResult
    func setItemZ(_ id: UUID, to z: String, on pageID: UUID) -> Bool {
        guard let page = try? page(pageID), let i = page.items.firstIndex(where: { $0.id == id }),
              page.items[i].z != z else { return false }
        var out = page
        out.items[i].z = z
        out.items.sort(by: Item.drawsBefore)
        return applyItemEdit(ItemEdit(ops: [.setItem(page: pageID, itemId: id, change: .z(z))], page: out))
    }

    /// Deletes items (one `removeItem` each, one delta). Returns those that
    /// were there, for undo (`restoreItems`). Their blobs stay until
    /// collection (format.md §8.1.6), so undo needs no blob.
    @discardableResult
    func removeItems(_ ids: [UUID], from pageID: UUID) -> [Item] {
        guard let page = try? page(pageID), let edit = NoteOps.removeItems(ids, from: page) else { return [] }
        let gone = page.items.filter { ids.contains($0.id) }
        return applyItemEdit(edit) ? gone : []
    }

    /// Puts deleted items back where they were, under new ids with `parent`
    /// (tombstones are permanent, format.md §8.2.2). Returns the new items.
    @discardableResult
    func restoreItems(_ items: [Item], on pageID: UUID) -> [Item] {
        guard let page = try? page(pageID), let edit = try? NoteOps.restoreItems(items, to: page),
              applyItemEdit(edit) else { return [] }
        return edit.page.items.filter { edit.added.contains($0.id) }
    }

    /// Replaces item `id` with `replacement` (one delta: `removeItem`, then
    /// `addItem` as given, `parent` included: `NoteOps.replaceItem`), whose
    /// blobs are already in this note. Returns what was there, for undo; nil
    /// when nothing changed.
    @discardableResult
    func replaceItem(_ id: UUID, with replacement: Item, on pageID: UUID) -> Item? {
        guard let page = try? page(pageID), let old = page.items.first(where: { $0.id == id }),
              let edit = try? NoteOps.replaceItem(id, with: replacement, on: page), applyItemEdit(edit) else { return nil }
        return old
    }

    /// Copies of items of this page, shifted by `dx`, `dy`, on top. One delta.
    @discardableResult
    func duplicateItems(_ ids: [UUID], on pageID: UUID, dx: Double = 20, dy: Double = 20) -> [Item] {
        guard let page = try? page(pageID) else { return [] }
        let originals = page.items.sorted(by: Item.drawsBefore).filter { ids.contains($0.id) }
        guard !originals.isEmpty, let edit = try? NoteOps.copyItems(originals, to: page, dx: dx, dy: dy),
              applyItemEdit(edit) else { return [] }
        return edit.page.items.filter { edit.added.contains($0.id) }
    }

    /// Pastes `items` copied from note `source` onto the page: their blobs
    /// are copied into this note first (`NoteWriter.copyBlob`, after
    /// `prepare` made each local), then the copies are added on top in one
    /// delta. Returns the new items.
    @discardableResult
    func pasteItems(_ items: [Item], from source: UUID, on pageID: UUID, dx: Double = 0, dy: Double = 0,
                    prepare: @Sendable (BlobRef) async throws -> Void = { _ in }) async throws -> [Item] {
        _ = try page(pageID)
        // A recording belongs to its note: its cards cannot show it in another one (format.md §8.2.9).
        let copied = source == noteID ? items : NoteOps.copyableToOtherNote(items)
        guard !copied.isEmpty else { return [] }
        if source != noteID {
            guard let writer = attachmentWriter else { throw ItemError.notEditable }
            for ref in NoteOps.blobs(of: copied) {
                try await prepare(ref)
                try await prepareBlobWrite?(ref)   // this note's own copy, if iCloud has one
                try await writer.copyBlob(ref, from: source)
            }
        }
        let edit = try NoteOps.copyItems(copied, to: try page(pageID), dx: dx, dy: dy)
        guard applyItemEdit(edit) else { throw ItemError.notEditable }
        return edit.page.items.filter { edit.added.contains($0.id) }
    }
}


/// The reference a file will have as a blob, computed before it is written
/// (the name of the blob file depends only on it).
enum BlobPlanning {
    /// SHA-256 and size of the file at `url`, streamed in 1 MiB pieces.
    static func ref(ofFile url: URL, type: String) throws -> BlobRef {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
            size += Int64(piece.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return BlobRef(sha256: hex, size: size, type: type)
    }
}
