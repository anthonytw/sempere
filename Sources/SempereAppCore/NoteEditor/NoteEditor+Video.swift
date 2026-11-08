import Foundation
import Sempere
import SempereRender

/// A clip ready to store (format.md §8.2.7; the app's `VideoPreparation`): the work copy to stream into the
/// blob, what its container says, the edits that blank its location and device metadata on the way (none when
/// the privacy setting is off), and its poster frame (nil when no frame could be taken: readers then draw a
/// placeholder with the play mark).
public struct PreparedVideo: Sendable {
    /// Plaintext work copy: `discard` it when done.
    public var file: URL
    public var info: VideoInfo
    public var edits: [ByteEdit]
    public var poster: PreparedImage?

    public init(file: URL, info: VideoInfo, edits: [ByteEdit], poster: PreparedImage?) {
        self.file = file
        self.info = info
        self.edits = edits
        self.poster = poster
    }
}

/// Adding video clips to the open note and giving them a poster (format.md
/// §8.2.7, docs/attachments.md §14 G2). Blobs first (the poster, then the
/// clip, streamed with its metadata edits), then one delta; the frame and z
/// come from the shared `NoteOps.placeVideo` that `sempere attach video` uses.
extension NoteEditorModel {
    /// Places `video` (from `VideoPreparation`) on `pageID`: fitted into the
    /// part of the page on screen (`visible`, page points), centered on
    /// `point` when given (a drop), else on what is on screen.
    @discardableResult
    public func insertVideo(_ video: PreparedVideo, on pageID: UUID, visible: CGRect?, at point: CGPoint? = nil) async throws -> Item {
        guard canEditItems else { throw ItemError.notEditable }
        guard let page = pages.first(where: { $0.id == pageID }) else { throw ItemError.noPage }
        let size = pageSize
        let frame = placedFrame(NoteOps.viewFrame(for: video.info.pixelSize, pageSize: size, visible: visible.map { Rect($0) },
                                                  centre: point.map { ItemFrames.Point(x: Double($0.x), y: Double($0.y)) }),
                                on: page, dropped: point != nil)
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
    public func setVideoPoster(_ id: UUID, to poster: PreparedImage, on pageID: UUID) async throws -> Bool {
        guard canEditItems else { throw ItemError.notEditable }
        let stored = try await storeBlob(poster.data, type: poster.mediaType)
        guard canEditItems, let page = pages.first(where: { $0.id == pageID }),
              let edit = try NoteOps.setPoster(id, to: stored, on: page) else { return false }
        return applyItemEdit(edit)
    }
}
