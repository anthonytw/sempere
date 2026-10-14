import AVFoundation
import CoreGraphics
import Foundation
import Sempere
import SempereRender

/// Video clips (format.md §8.2.7, docs/attachments.md §14 G2): adding a
/// picked, recorded or dropped clip, and playing one. A clip is prepared off
/// the main actor (`VideoPreparation`) and written through the editor (blobs,
/// then one delta); it is fetched from iCloud and decrypted only when it is
/// played, into the model's `BlobCache` (a verified private file AVPlayer
/// reads), and released when the player closes. Failures go to `errorMessage`.
extension AppModel {
    /// Adds the clip at `file` (a work copy, which this removes) to `page` of
    /// the editor's note, its metadata removed as the photo privacy setting says.
    @discardableResult
    func insertVideo(file: URL, into editor: NoteEditor, page: UUID? = nil, visible: CGRect?, at point: CGPoint? = nil,
                     privacy: Bool = PhotoPrivacy.isOn()) async -> Item? {
        // Every work file of this clip (a converted copy included) is in the copy's folder.
        defer { VideoPreparation.discard(file) }
        guard let page = page ?? editor.currentPage?.id else { return nil }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try await VideoPreparation.prepare(file, privacy: privacy)
            }.value
            return try await editor.insertVideo(prepared, on: page, visible: visible, at: point)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = String(localized: "Could not add the video. \(Self.describe(error))", comment: "The value is a sentence saying why")
            return nil
        }
    }

    /// The verified clip of video `item` of `note` as a private local file,
    /// downloaded from iCloud first (videos come down only when played,
    /// docs/attachments.md §4). Call `releaseVideo` once for each success.
    func acquireVideo(_ item: Item, note: UUID) async throws -> URL {
        guard let ref = item.blob, let cache = attachmentCache() else { throw BlobError.invalidReference }
        return try await cache.acquire(note: note, ref: ref)
    }

    /// Lets the cache delete the decrypted clip (a video is large and rarely replayed).
    func releaseVideo(_ item: Item, note: UUID) {
        guard let ref = item.blob, let cache = attachmentCache() else { return }
        Task { await cache.release(note: note, ref: ref, discard: true) }
    }

    /// A clip stored without a poster (by the CLI on Linux) gets one from its
    /// first frames the first time it plays here: one `setItem(poster)`.
    func addPosterIfMissing(_ item: Item, page: UUID, editor: NoteEditor, file: URL) async {
        guard item.kind == .video, item.poster == nil, editor.canEditItems,
              editor.item(item.id, on: page)?.poster == nil else { return }
        let type = item.blob?.type
        guard let poster = try? await VideoPoster.jpeg(file: file, mediaType: type) else { return }
        _ = try? await editor.setVideoPoster(item.id, to: poster, on: page)
    }

    /// The audio session for a clip: playback, unless a recording is running
    /// (then it stays `.playAndRecord`, as for recordings).
    static func activateVideoAudio() {
        guard RecordingSession.active?.isActive != true else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    static func deactivateVideoAudio() {
        guard RecordingSession.active?.isActive != true else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
