import Foundation
import Sempere

/// Which blobs come down from iCloud when (docs/attachments.md §4 "iCloud
/// Drive"): a note's `att/` is never downloaded with its revisions. When a
/// page is shown, the `image` and `pdf` blobs its items reference are
/// requested; `audio`, `video` and transcripts only when they are played or
/// shown. Pure logic, tested without iCloud.
enum BlobFetchPolicy {
    /// Whether blobs of `kind` are requested as soon as a page that uses them is shown.
    static func fetchesWithPage(_ kind: BlobKind) -> Bool {
        kind == .image || kind == .pdf
    }

    /// The blobs to request when a page with `items` is shown: those of kinds
    /// fetched with the page (a video's poster, never its clip), each once,
    /// in drawing order.
    static func prefetch(for items: [Item]) -> [BlobRef] {
        var seen: Set<String> = []
        return items.sorted(by: Item.drawsBefore).flatMap { [$0.blob, $0.poster].compactMap { $0 } }.filter {
            $0.isValid && fetchesWithPage($0.kind) && seen.insert($0.sha256).inserted
        }
    }
}

extension CloudVault {
    /// The state of the blob file `fileName` of note `id`.
    static func blobState(note id: UUID, fileName: String, vault url: URL, hooks: Hooks) -> CloudItemState {
        hooks.state(CloudScan.blobItem(inVault: url, id: id, fileName: fileName))
    }

    /// Throws `blobNotLocal` unless the blob file `fileName` of note `id` is
    /// local (or not there at all: the read then reports it missing, and a
    /// blob still under the previous secret's name is found by the vault).
    /// Run inside the coordinated read of the blob.
    static func requireBlob(note id: UUID, fileName: String, vault url: URL, hooks: Hooks) throws {
        let state = blobState(note: id, fileName: fileName, vault: url, hooks: hooks)
        if case .failed(let reason) = state { throw CloudError.failed(name: fileName, reason: reason, source: hooks.source) }
        if !state.isSettled { throw CloudError.blobNotLocal(name: fileName, source: hooks.source) }
    }

    /// Asks iCloud for the blob files `fileNames` of note `id` without
    /// waiting (a page with images or PDF pages was shown).
    static func requestBlobs(note id: UUID, fileNames: [String], vault url: URL, hooks: Hooks) {
        for name in fileNames {
            let item = CloudScan.blobItem(inVault: url, id: id, fileName: name)
            let state = hooks.state(item)
            if state == .current || state == .gone { continue }
            try? hooks.request(item)
        }
    }

    /// Makes the blob file `fileName` of note `id` local, waiting for it
    /// (`download(items:)`: `CloudError.timedOut` after `stallTimeout`
    /// without progress). No-op when it is local or not there.
    static func downloadBlob(note id: UUID, fileName: String, vault url: URL, hooks: Hooks,
                             stallTimeout: Duration = .seconds(90),
                             pollInterval: Duration = .milliseconds(400)) async throws {
        let item = CloudScan.blobItem(inVault: url, id: id, fileName: fileName)
        try await download(items: [item], hooks: hooks, stallTimeout: stallTimeout, pollInterval: pollInterval) { _ in }
    }
}
