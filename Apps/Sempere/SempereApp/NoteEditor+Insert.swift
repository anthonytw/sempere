import CoreGraphics
import Foundation
import Sempere
import SempereRender

/// Adding images and PDF pages to the open note (docs/attachments.md §14
/// tasks E1, E3), and cropping. The blob is written first, then one delta;
/// frames, z order and pages come from the shared `NoteOps` builders the
/// CLI's `attach image`, `attach pdf` and `items crop` use.
extension NoteEditor {
    /// Places `image` (from `ImagePreparation`) on `pageID`: fitted into the
    /// part of the page on screen (`visible`, page points), centred on `point`
    /// when given (a drop), else on what is on screen (`NoteOps.viewFrame`).
    @discardableResult
    func insertImage(_ image: PreparedImage, on pageID: UUID, visible: CGRect?,
                     at point: CGPoint? = nil) async throws -> Item {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let size = pageSize
        let frame = NoteOps.viewFrame(for: image.pixelSize, pageSize: size, visible: visible.map { Rect($0) },
                                      centre: point.map { ItemFrames.Point(x: Double($0.x), y: Double($0.y)) })
        return try await addAttachment(data: image.data, type: image.mediaType, on: pageID) { ref in
            try NoteOps.placeImage(blob: ref, pixelSize: image.pixelSize, orientation: image.orientation, on: page,
                                   pageSize: size, frame: frame).item
        }
    }

    /// Replaces the image `id` with another picture (Replace Image): the
    /// picture is written as a blob of this note first, then one delta
    /// removes the old image and adds the new one in its place
    /// (`NoteOps.replaceImage`, as `sempere items replace`). Returns the old
    /// and the new item.
    ///
    /// - Throws: `AttachmentOpsError.noSuchImage` when the page has no image
    ///   `id` (checked again after the blob is written), `ItemError`, or a write error.
    @discardableResult
    func replaceImage(_ id: UUID, with image: PreparedImage, on pageID: UUID) async throws -> (old: Item, new: Item) {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let planned = BlobRef(content: image.data, type: image.mediaType)
        _ = try NoteOps.replaceImage(id, blob: planned, pixelSize: image.pixelSize, orientation: image.orientation, on: page)
        let ref = try await storeBlob(image.data, type: image.mediaType)
        // The page as it is now: it may have changed while the blob was written.
        guard canEditItems else { throw ItemError.notEditable }
        guard let current = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        guard let old = current.items.first(where: { $0.id == id }) else {
            throw AttachmentOpsError.noSuchImage(id.uuidString.lowercased())
        }
        let edit = try NoteOps.replaceImage(id, blob: ref, pixelSize: image.pixelSize, orientation: image.orientation, on: current)
        guard applyItemEdit(edit), let new = edit.page.items.first(where: { edit.added.contains($0.id) }) else {
            throw ItemError.notEditable
        }
        return (old, new)
    }

    /// Inserts the pages of `pdf` after the first `index` pages (one finite
    /// page per PDF page, its background the PDF page: `NoteOps.insertPDFPages`)
    /// and shows the first of them. The PDF is one blob; the pages and items
    /// are one delta. Returns the new pages' ids.
    ///
    /// - Throws: `AttachmentOpsError.pagelessNote` for a pageless note (it has
    ///   one infinite page; import the PDF as a new note, or switch to pages),
    ///   `ItemError.notEditable`, or a write error.
    @discardableResult
    func insertPDFPages(_ pdf: PreparedPDF, after index: Int) async throws -> [UUID] {
        guard canEditItems else { throw ItemError.notEditable }
        guard !isPageless else { throw AttachmentOpsError.pagelessNote }
        // Fail before anything is written when the pages cannot be added.
        _ = try NoteOps.insertPDFPages(blob: BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: "application/pdf"),
                                       pdf.pages, after: index, in: pages, pageSize: pageSize)
        let ref = try await storeBlob(file: pdf.file, type: "application/pdf")
        // The note may have changed (or closed) while the blob was written.
        guard canEditItems, !isPageless else { throw ItemError.notEditable }
        let before = Set(pages.map(\.id))
        let edit = try NoteOps.insertPDFPages(blob: ref, pdf.pages, after: index, in: pages, pageSize: pageSize)
        let added = edit.pages.map(\.id).filter { !before.contains($0) }
        applyInsertedPages(edit, show: added.first)
        return added
    }

    /// Crops the image or PDF page `id` (`NoteOps.setCrop`: the visible part
    /// stays in place). Returns the crop it had (nil: none), wrapped; nil when
    /// nothing changed.
    @discardableResult
    func setItemCrop(_ id: UUID, to crop: Rect?, on pageID: UUID) -> Rect?? {
        guard canEditItems, let page = pages.first(where: { $0.id == pageID }),
              let item = page.items.first(where: { $0.id == id }),
              let edit = try? NoteOps.setCrop(id, to: crop, on: page), applyItemEdit(edit) else { return nil }
        return .some(item.crop)
    }
}

extension Rect {
    /// A rect in page points from a Core Graphics one.
    init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
    }
}

extension ItemActions {
    /// Crops an item (one delta, one undo step that puts the old crop back).
    func setCrop(_ id: UUID, to crop: Rect?, on page: UUID) {
        guard let old = editor.setItemCrop(id, to: crop, on: page) else { return }
        register(String(localized: "Crop", comment: "Undo action name (Edit menu: Undo …)")) { $0.setCrop(id, to: old, on: page) }
    }
}
