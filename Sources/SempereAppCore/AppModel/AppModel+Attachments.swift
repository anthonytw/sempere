import Foundation
import Observation
import Sempere

/// Attachments of the open vault (docs/attachments.md §4, §13): the cache of
/// decrypted blobs the canvas draws from, the cache of drawn ones, fetching a partial copy's blobs on
/// demand, and pasting copied items.
extension AppModelCore {
    /// The open vault's blob cache, created on first use; nil while no vault
    /// is unlocked. Each blob is fetched through the vault's checks; in a partial
    /// copy (a join) a blob still a stand-in is fetched from the server first
    /// (`partialBlobFetcher`).
    ///
    /// Its folder is the same for every launch while the vault secret is
    /// (`LocalCacheKey`, purpose `blob-cache`), so attachments opened before
    /// are not decrypted again; folders of other vaults are
    /// deleted. Where files are
    /// not encrypted at rest (a Mac: `blobCacheAcrossLaunches` false), what an
    /// earlier launch left is deleted instead: plaintext lasts one session
    /// (the app also deletes the whole folder at quit and at launch,
    /// `BlobCache.purgeAtQuit` / `purgeAtLaunch`).
    public func attachmentCache() -> BlobCache? {
        if let blobCache { return blobCache }
        guard let vault, phase == .unlocked,
              let key = try? LocalCacheKey(vault: vault, purpose: "blob-cache", magic: [0x53, 0x4D, 0x50, 0x42, 0x01])
        else { return nil }
        let partial = partialBlobFetcher()
        let folder = blobCacheFolder
        let root = folder.appendingPathComponent(key.name, isDirectory: true)
        // Renamed away before the cache writes there: the background delete below takes it.
        if !blobCacheAcrossLaunches { BlobCache.retire(root) }
        Task.detached(priority: .utility) { BlobCache.removeOthers(in: folder, keeping: key.name) }
        let cache = BlobCache(root: root, maxBytes: BlobCache.configuredMaxBytes(in: services.settings),
                              naming: BlobCache.keyedNaming(key)) { note, ref, destination in
            if let partial { try await partial(note, try vault.blobFileName(for: ref)) }
            try await Self.fetchBlob(ref, of: note, from: vault, to: destination)
        }
        blobCache = cache
        return cache
    }

    /// Writes the verified content of blob `ref` of `note` to `destination`.
    public nonisolated static func fetchBlob(_ ref: BlobRef, of note: UUID, from vault: Vault, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try BlobCache.writeFile(destination) { write in
                try vault.streamBlob(note: note, ref) { try write($0) }
            }
        }.value
    }

    /// The open vault's cache of drawn attachments, made on first use (`services.makeRenderCache`; in memory only
    /// without `renderCacheRoot`); nil while no vault is unlocked.
    public func attachmentRenders() -> (any RenderCaching)? {
        if let renderCache { return renderCache }
        guard let vault, phase == .unlocked else { return nil }
        let cache = services.makeRenderCache(renderCacheRoot, vault)
        renderCache = cache
        return cache
    }

    /// Deletes the decrypted attachments and their pictures and forgets
    /// copied items (the vault closed, or changed under them).
    public func dropAttachments() {
        if let cache = blobCache { Task { await cache.clear() } }
        blobCache = nil
        renderCache?.close()
        renderCache = nil
        itemClipboard.clear()
    }

    /// Fetches the `image` and `pdf` blobs of `items` (a page of `note` was shown) that are still stand-ins in
    /// a partial copy, without waiting; other kinds come when used (docs/attachments.md §4). No-op otherwise.
    public func prefetchBlobs(note: UUID, items: [Item]) {
        guard let partial = partialBlobFetcher(), let vault else { return }
        let refs = BlobFetchPolicy.prefetch(for: items)
        guard !refs.isEmpty else { return }
        Task {
            for ref in refs {
                guard let name = try? vault.blobFileName(for: ref) else { continue }
                try? await partial(note, name)
            }
        }
    }

    /// What an editor of `note` runs before writing or copying a blob into it
    /// (`NoteEditor.prepareBlobWrite`): in a partial copy, this note's blob, if
    /// still a stand-in, is fetched so the write reuses it (blob files are
    /// write-once, format.md §8.1.4); nil otherwise.
    public func blobWritePreparer(note: UUID) -> (@Sendable (BlobRef) async throws -> Void)? {
        guard let partial = partialBlobFetcher(), let vault else { return nil }
        return { ref in try? await partial(note, try vault.blobFileName(for: ref)) }
    }

    /// Makes the blob `ref` of `note` local (a partial copy), waiting for it.
    public func ensureBlobLocal(_ ref: BlobRef, of note: UUID) async throws {
        guard let partial = partialBlobFetcher(), let vault else { return }
        try await partial(note, try vault.blobFileName(for: ref))
    }

    /// What pasting the copied items onto `page` of `editor`'s note takes: the entry, where it lands, and
    /// the fetch of its blobs that a partial copy may still lack (blobs from another note are copied by the
    /// editor's paste). Nil when nothing is copied. The app's `ItemActions.paste` writes it (one delta, one
    /// undo step).
    public func clipboardPaste(onto page: UUID, of editor: Editor) -> ClipboardPaste? {
        guard let entry = itemClipboard.entry else { return nil }
        let offset = itemClipboard.nextOffset(samePage: entry.note == editor.noteID
                                              && editor.items(on: page).contains { $0.id == entry.items.first?.id })
        let vault = self.vault
        let partial = partialBlobFetcher()
        return ClipboardPaste(entry: entry, offset: offset) { ref in
            guard let partial, let vault else { return }
            try await partial(entry.note, try vault.blobFileName(for: ref))
        }
    }
}

/// One paste of the item clipboard (`AppModel.clipboardPaste`).
public struct ClipboardPaste: Sendable {
    public var entry: ItemClipboard.Entry
    /// Points right and down of the copied items (repeated pastes on the same page do not stack).
    public var offset: Double
    /// Makes a blob of the copied items local first (a partial copy).
    public var prepare: @Sendable (BlobRef) async throws -> Void
}

/// Items copied for pasting, in this app only (never the system pasteboard:
/// the plaintext would leave the app). Tied to one open vault: the model
/// empties it when the vault closes or changes keys.
@MainActor
@Observable
public final class ItemClipboard {
    /// What was copied: items and the note whose blobs they reference.
    public struct Entry: Equatable, Sendable {
        public var note: UUID
        public var items: [Item]

        public init(note: UUID, items: [Item]) {
            self.note = note
            self.items = items
        }
    }

    public private(set) var entry: Entry?
    /// Pastes since the last copy, so repeated pastes do not stack exactly.
    @ObservationIgnored public private(set) var pasteCount = 0

    public init() {}

    public func copy(_ items: [Item], from note: UUID) {
        let usable = items.filter { $0.validationError == nil }
        entry = usable.isEmpty ? nil : Entry(note: note, items: usable)
        pasteCount = 0
    }

    public func clear() {
        entry = nil
        pasteCount = 0
    }

    /// The offset of the next paste: on the same page as the copy, each
    /// paste lands 20 points further down and right.
    public func nextOffset(samePage: Bool) -> Double {
        pasteCount += 1
        return samePage ? Double(pasteCount) * 20 : 0
    }
}

/// Which blobs a partial copy fetches when (docs/attachments.md §4): a note's `att/` is not fetched with its
/// revisions. When a page is shown, the `image` and `pdf` blobs its items reference are fetched; `audio`,
/// `video` and transcripts only when they are played or shown. Pure logic.
public enum BlobFetchPolicy {
    /// Whether blobs of `kind` are fetched as soon as a page that uses them is shown.
    public static func fetchesWithPage(_ kind: BlobKind) -> Bool {
        kind == .image || kind == .pdf
    }

    /// The blobs to fetch when a page with `items` is shown: those of kinds
    /// fetched with the page (a video's poster, never its clip), each once,
    /// in drawing order.
    public static func prefetch(for items: [Item]) -> [BlobRef] {
        var seen: Set<String> = []
        return items.sorted(by: Item.drawsBefore).flatMap { [$0.blob, $0.poster].compactMap { $0 } }.filter {
            $0.isValid && fetchesWithPage($0.kind) && seen.insert($0.sha256).inserted
        }
    }
}
