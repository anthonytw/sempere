import Foundation
import Sempere
import SempereRender

/// Video clips (format.md §8.2.7, docs/attachments.md §14 G2): adding a picked, recorded or dropped clip, and the
/// file a player reads. A clip is prepared off the main actor (`services.attachmentPreparation`: AVFoundation in the
/// app) and written through the editor (blobs, then one delta); it is fetched from iCloud and decrypted only when it
/// is played, into the model's `BlobCache` (a verified private file the player reads), and released when the player
/// closes. The audio session stays in the app (`VideoViews.swift`). Failures go to `errorMessage` (`InsertNotice`).
extension AppModelCore {
    /// Adds the clip at `file` (a work copy, which this removes) to `page` of the editor's note, its metadata removed
    /// as the photo privacy setting says (`privacy`; nil: `PhotoPrivacy` in `services.settings`).
    @discardableResult
    public func insertVideo(file: URL, into editor: Editor, page: UUID? = nil, visible: CGRect?, at point: CGPoint? = nil,
                            privacy: Bool? = nil) async -> Item? {
        // Every work file of this clip (a converted copy included) is in the copy's folder.
        defer { ImportWorkFolder.discard(file) }
        guard let page = page ?? editor.currentPage?.id else { return nil }
        let privacy = privacy ?? PhotoPrivacy.isOn(services.settings)
        let preparation = services.attachmentPreparation
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await preparation.prepareVideo(file, privacy: privacy)
            }.value
            return try await editor.insertVideo(prepared, on: page, visible: visible, at: point)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = "\(InsertNotice.videoNotAdded(error))"
            return nil
        }
    }

    /// The verified clip of video `item` of `note` as a private local file, downloaded from iCloud first (videos come
    /// down only when played, docs/attachments.md §4). Call `releaseVideo` once for each success.
    public func acquireVideo(_ item: Item, note: UUID) async throws -> URL {
        guard let ref = item.blob, let cache = attachmentCache() else { throw BlobError.invalidReference }
        return try await cache.acquire(note: note, ref: ref)
    }

    /// Lets the cache delete the decrypted clip (a video is large and rarely replayed).
    public func releaseVideo(_ item: Item, note: UUID) {
        guard let ref = item.blob, let cache = attachmentCache() else { return }
        Task { await cache.release(note: note, ref: ref, discard: true) }
    }

    /// A clip stored without a poster (by the CLI on Linux) gets one from its first frames the first time it plays
    /// here, when the platform can take one (`AttachmentPreparing.videoPoster`): one `setItem(poster)`.
    public func addPosterIfMissing(_ item: Item, page: UUID, editor: Editor, file: URL) async {
        guard item.kind == .video, item.poster == nil, editor.canEditItems,
              editor.item(item.id, on: page)?.poster == nil else { return }
        let type = item.blob?.type
        let preparation = services.attachmentPreparation
        guard let poster = try? await preparation.videoPoster(file: file, mediaType: type) else { return }
        _ = try? await editor.setVideoPoster(item.id, to: poster, on: page)
    }
}
