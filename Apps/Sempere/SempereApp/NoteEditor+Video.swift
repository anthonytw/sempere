import CoreGraphics
import Foundation
import Sempere
import SempereRender

/// Adding video clips to the open note and giving them a poster (format.md
/// §8.2.7, docs/attachments.md §14 G2). Blobs first (the poster, then the
/// clip, streamed with its metadata edits), then one delta; the frame and z
/// come from the shared `NoteOps.placeVideo` that `sempere attach video` uses.
extension NoteEditor {
    /// Places `video` (from `VideoPreparation`) on `pageID`: fitted into the
    /// part of the page on screen (`visible`, page points), centred on
    /// `point` when given (a drop), else on what is on screen.
    @discardableResult
    func insertVideo(_ video: PreparedVideo, on pageID: UUID, visible: CGRect?, at point: CGPoint? = nil) async throws -> Item {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let size = pageSize
        let frame = NoteOps.viewFrame(for: video.info.pixelSize, pageSize: size, visible: visible.map { Rect($0) },
                                      centre: point.map { ItemFrames.Point(x: Double($0.x), y: Double($0.y)) })
        // Refuse before anything is written.
        let placeholder = BlobRef(sha256: String(repeating: "0", count: 64), size: 1, type: video.info.mediaType)
        _ = try NoteOps.placeVideo(blob: placeholder, info: video.info, on: page, pageSize: size, frame: frame)
        var posterRef: BlobRef?
        if let poster = video.poster {
            posterRef = try await storeBlob(poster.data, type: poster.mediaType)
        }
        let clip = try await storeBlob(file: video.file, type: video.info.mediaType, edits: video.edits)
        // The note may have changed (or closed) while the blobs were written.
        guard let current = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let item = try NoteOps.placeVideo(blob: clip, info: video.info, poster: posterRef, on: current, pageSize: size,
                                          frame: frame).item
        return try addItems([item], on: pageID)[0]
    }

    /// Sets the poster of video `id` on `pageID` (one `setItem(poster)`),
    /// after writing the image as a blob of this note. A clip added where no
    /// frame could be taken (the CLI on Linux) gets one the first time it
    /// plays here. Returns false when nothing changed.
    @discardableResult
    func setVideoPoster(_ id: UUID, to poster: PreparedImage, on pageID: UUID) async throws -> Bool {
        guard canEditItems else { throw ItemError.notEditable }
        let stored = try await storeBlob(poster.data, type: poster.mediaType)
        guard canEditItems, let page = pages.first(where: { $0.id == pageID }),
              let edit = try NoteOps.setPoster(id, to: stored, on: page) else { return false }
        return applyItemEdit(edit)
    }
}
