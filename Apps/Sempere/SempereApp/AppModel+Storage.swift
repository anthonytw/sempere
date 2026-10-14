import Foundation
import Sempere

/// Sizes of this device's caches (all of it can be rebuilt from the vault).
struct CacheSizes: Equatable, Sendable {
    var drawings: Int64 = 0
    var attachments: Int64 = 0
    var total: Int64 { drawings + attachments }
}

/// *Storage* in Settings (docs/attachments.md §15).
extension AppModel {
    /// Bytes held by the open vault's drawing cache and decrypted-attachment
    /// cache; both zero while no vault is unlocked or before a cache exists.
    func cacheSizes() async -> CacheSizes {
        var sizes = CacheSizes()
        if let cache = drawingCache {
            sizes.drawings = Int64(await Task.detached(priority: .utility) { cache.totalBytes }.value)
        }
        if let cache = blobCache { sizes.attachments = await cache.totalBytes }
        return sizes
    }

    /// Deletes the drawing cache's files and the decrypted attachments. The
    /// vault, the note list's summary cache and every setting stay as they
    /// are; an open canvas redraws what it shows from the vault.
    func clearCaches() async {
        if let cache = drawingCache { await Task.detached(priority: .utility) { cache.removeAll() }.value }
        if let cache = blobCache { await cache.clear() }
        blobCache = nil
    }
}
