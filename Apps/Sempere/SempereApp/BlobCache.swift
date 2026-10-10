import CryptoKit
import Foundation
import Sempere
import SempereRender

/// Decrypted, verified attachments of the open vault, as private files
/// (docs/attachments.md §2 "Random access", §13): PDFKit and ImageIO need a
/// file, and decrypting a 40 MB PDF again for every redraw is slow. Files
/// live in the app's container (`Library/Caches/Sempere/Blobs`, Data
/// Protection "complete" on iOS, mode 0600, excluded from backups), never in a
/// shared or synced place.
///
/// The files outlive a note being closed and the app being quit (TestFlight
/// build 6: reopening a PDF note was as slow as the first open): the model
/// keeps one folder per vault secret, named by `LocalCacheKey` (purpose
/// `blob-cache`), with file names keyed the same way, so nothing in the
/// folder names a note or a content hash without the vault secret. A file
/// found there from an earlier launch is used only after its content is hashed
/// again and matches the reference (`adopt`). The folder is deleted when the
/// vault closes, locks or changes keys (`clear`), as the drawing cache's is.
///
/// Least recently used files go once the cache holds more than `maxBytes` or
/// `maxFiles`, except files in use (`acquire` without its `release`); files of
/// earlier launches count too, oldest use (modification date) first.
///
/// A file is placed only once `fetch` returned: the fetch streams the blob
/// through the vault's checks (`Vault.streamBlob`: framing, padding, hash,
/// keyed name) and throws on any failure, so a file in the cache is always
/// whole, verified content (format.md §8.1.4).
actor BlobCache {
    /// Writes the verified content of `ref` (a blob of `note`) to
    /// `destination` (a new file), throwing on any failure.
    typealias Fetch = @Sendable (_ note: UUID, _ ref: BlobRef, _ destination: URL) async throws -> Void
    /// The file name of `ref` in `note` (the same for every launch).
    typealias Naming = @Sendable (_ note: UUID, _ ref: BlobRef) -> String

    enum CacheError: Error, Equatable {
        /// The reference is not usable (bad hash or size).
        case invalidReference
        /// The fetched file is not the size the reference says.
        case sizeMismatch
        /// The cache was cleared while the blob was fetched.
        case cleared
    }

    /// The default size limit.
    static let defaultMaxBytes: Int64 = 512 << 20
    /// The `UserDefaults` key of the size limit in megabytes (unset: 512).
    static let capDefaultsKey = "Sempere.blobCacheMegabytes"

    /// The configured size limit (`capDefaultsKey`).
    static var configuredMaxBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: capDefaultsKey)
        return mb > 0 ? Int64(min(mb, 1 << 16)) << 20 : defaultMaxBytes
    }

    nonisolated let root: URL
    nonisolated let maxBytes: Int64
    nonisolated let maxFiles: Int
    private let fetch: Fetch
    private let naming: Naming

    private struct Entry {
        var url: URL
        var size: Int64
        var lastUse: UInt64
        var pins: Int
        /// Placed in this session, or hashed again since: its content is the reference's.
        var verified: Bool
    }

    /// By file name.
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Placed, any Error>] = [:]
    private var tick: UInt64 = 0
    /// Bumped by `clear`: a fetch that finishes afterwards is thrown away.
    private var epoch = 0
    /// Set by `clear`: the vault this cache decrypts for is gone, so nothing
    /// is fetched again (a view may still hold the cache for a moment).
    private var closed = false
    /// Files of earlier launches have been listed (`indexFolder`).
    private var indexed = false
    /// Fetches started (for tests).
    private(set) var fetchCount = 0
    /// Files of an earlier launch used after their content checked out (for tests and timing).
    private(set) var adoptedCount = 0

    private struct Placed: Sendable {
        var url: URL
        /// True when the file was fetched, false when an earlier launch's file was adopted.
        var fetched: Bool
    }

    /// - Parameters:
    ///   - root: a folder of this cache alone; created on first use, deleted by `clear`.
    ///   - naming: file names; by default the content hash and note id (tests). The
    ///     model passes names keyed by the vault secret (`keyedNaming`).
    init(root: URL, maxBytes: Int64 = BlobCache.defaultMaxBytes, maxFiles: Int = 1024,
         naming: @escaping Naming = BlobCache.plainName, fetch: @escaping Fetch) {
        self.root = root
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.naming = naming
        self.fetch = fetch
    }

    /// `<sha256>-<note><ext>`.
    nonisolated static func plainName(_ note: UUID, _ ref: BlobRef) -> String {
        ref.sha256 + "-" + note.uuidString.lowercased() + pathExtension(ref)
    }

    /// Names that say nothing about the note or the content without the vault
    /// secret: `entryName(note|sha256|size)` of `key`, plus the type's extension.
    nonisolated static func keyedNaming(_ key: LocalCacheKey) -> Naming {
        { note, ref in key.entryName("blob|\(note.uuidString.lowercased())|\(ref.sha256)|\(ref.size)") + pathExtension(ref) }
    }

    /// `Library/Caches/Sempere/Blobs`: one folder per vault secret inside it.
    static var folder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Sempere/Blobs", isDirectory: true)
    }

    /// Where builds before TestFlight build 7 kept their per-session caches (deleted at launch).
    static var legacyFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereBlobs", isDirectory: true)
    }

    /// Removes caches left by an earlier run (killed before it could clear).
    nonisolated static func purgeStale(in folder: URL = BlobCache.legacyFolder, olderThan age: TimeInterval = 3600,
                                       now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if modified.map({ now.timeIntervalSince($0) > age }) ?? true { try? fm.removeItem(at: entry) }
        }
    }

    /// Whether the decrypted files may outlive a launch: only where the system
    /// encrypts them at rest while the device is locked (iOS and iPadOS data
    /// protection, `.complete`, format.md §10). Mac Catalyst has no protection
    /// class, so there a launch starts from an empty folder.
    nonisolated static var keepsAcrossLaunches: Bool { !ProcessInfo.processInfo.isMacCatalystApp }

    /// Moves the folder `dir` aside at once (a `.closed-` sibling, which
    /// `removeOthers` deletes in the background), so nothing in it is reused.
    nonisolated static func retire(_ dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.moveItem(at: dir, to: dir.deletingLastPathComponent()
            .appendingPathComponent(".closed-\(UUID().uuidString)", isDirectory: true))
    }

    /// Deletes the folders in `folder` other than `keep` (other vaults, or
    /// this vault under an earlier secret), in the background.
    nonisolated static func removeOthers(in folder: URL, keeping keep: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name != keep && !name.hasPrefix(".closed-") {
            // A rename is instant; the files go in the background.
            try? fm.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent(".closed-\(UUID().uuidString)"))
        }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".closed-") }
        guard !leftovers.isEmpty else { return }
        Task.detached(priority: .utility) {
            for name in leftovers { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }

    /// The file holding `ref`'s verified content, fetched if needed. The file
    /// stays until `release` is called as many times as `acquire` returned.
    func acquire(note: UUID, ref: BlobRef) async throws -> URL {
        guard !closed else { throw CacheError.cleared }
        guard ref.isValid else { throw CacheError.invalidReference }
        indexFolder()
        let name = naming(note, ref)
        if var entry = entries[name], entry.verified, FileManager.default.fileExists(atPath: entry.url.path) {
            tick &+= 1
            entry.lastUse = tick
            entry.pins += 1
            entries[name] = entry
            Self.touch(entry.url)
            return entry.url
        }
        // An earlier launch's file (not verified yet) is checked by the task below.
        let previous = entries.removeValue(forKey: name)
        let task: Task<Placed, any Error>
        var started = false
        if let running = inFlight[name] {
            task = running
        } else {
            let root = self.root, fetch = self.fetch
            let candidate = previous.map(\.url)
            started = true
            task = Task.detached(priority: .userInitiated) {
                try Self.makeFolder(root)
                let final = root.appendingPathComponent(name)
                if let candidate, await Self.matches(candidate, ref) {
                    return Placed(url: candidate, fetched: false)
                }
                if let candidate { try? FileManager.default.removeItem(at: candidate) }
                let tmp = root.appendingPathComponent(".tmp-" + UUID().uuidString)
                do {
                    try await fetch(note, ref, tmp)
                    let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
                    guard size == ref.size else { throw CacheError.sizeMismatch }
                    try? FileManager.default.removeItem(at: final)
                    try FileManager.default.moveItem(at: tmp, to: final)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    throw error
                }
                return Placed(url: final, fetched: true)
            }
            inFlight[name] = task
        }
        let startedEpoch = epoch
        let placed: Placed
        do {
            placed = try await task.value
        } catch {
            if inFlight[name] == task { inFlight[name] = nil }
            if started { fetchCount += 1 }
            throw error
        }
        if inFlight[name] == task { inFlight[name] = nil }
        if started {
            if placed.fetched { fetchCount += 1 } else { adoptedCount += 1 }
        }
        guard startedEpoch == epoch, !closed else {
            try? FileManager.default.removeItem(at: placed.url)
            throw CacheError.cleared
        }
        tick &+= 1
        if var entry = entries[name] {
            // Another waiter on the same fetch placed it first.
            entry.pins += 1
            entry.lastUse = tick
            entries[name] = entry
        } else {
            entries[name] = Entry(url: placed.url, size: ref.size, lastUse: tick, pins: 1, verified: true)
        }
        Self.touch(placed.url)
        evict()
        return placed.url
    }

    /// Lists the files an earlier launch left (once): they count towards the
    /// limits, oldest use first, and are hashed before use.
    private func indexFolder() {
        guard !indexed else { return }
        indexed = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        var found: [(name: String, entry: Entry, used: Date)] = []
        for url in urls {
            let name = url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if name.hasPrefix(".") {   // an interrupted fetch
                try? FileManager.default.removeItem(at: url)
                continue
            }
            found.append((name, Entry(url: url, size: Int64(v.fileSize ?? 0), lastUse: 0, pins: 0, verified: false),
                          v.contentModificationDate ?? .distantPast))
        }
        for item in found.sorted(by: { $0.used < $1.used }) {
            tick &+= 1
            var entry = item.entry
            entry.lastUse = tick
            entries[item.name] = entry
        }
        evict()
    }

    /// Whether `url` holds exactly `ref`'s content (size and SHA-256).
    nonisolated static func matches(_ url: URL, _ ref: BlobRef) async -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size == ref.size, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` returns nil (not empty data) at the end of the file.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return false }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            await Task.yield()
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == ref.sha256.lowercased()
    }

    /// Marks a use for the least-recently-used order of the next launch.
    private nonisolated static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Ends one use of `ref`'s file (after `acquire`). With `discard`, the
    /// file is deleted as soon as no use is left, instead of being kept for
    /// later: recordings and transcripts (docs/attachments.md §13), whose
    /// plaintext is kept on disk only while it is played or read.
    func release(note: UUID, ref: BlobRef, discard: Bool = false) {
        let name = naming(note, ref)
        guard var entry = entries[name] else { return }
        entry.pins = max(0, entry.pins - 1)
        if discard && entry.pins == 0 {
            try? FileManager.default.removeItem(at: entry.url)
            entries[name] = nil
            return
        }
        entries[name] = entry
        evict()
    }

    /// Whether `ref`'s file is in the cache now (no fetch; an earlier
    /// launch's file counts once listed, before it is checked).
    func contains(note: UUID, ref: BlobRef) -> Bool {
        indexFolder()
        return entries[naming(note, ref)] != nil
    }

    /// Bytes held.
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    /// Files held.
    var count: Int { entries.count }

    /// Deletes every file (the vault closed, locked or changed keys). Fetches
    /// in flight are thrown away when they finish, and the cache fetches
    /// nothing more (`acquire` throws `cleared`): the model makes a new one.
    func clear() {
        closed = true
        epoch += 1
        entries = [:]
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        try? FileManager.default.removeItem(at: root)
    }

    /// Drops least recently used files that are not in use until the cache
    /// is within its limits.
    private func evict() {
        var bytes = totalBytes
        guard bytes > maxBytes || entries.count > maxFiles else { return }
        for (key, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where entry.pins == 0 {
            guard bytes > maxBytes || entries.count > maxFiles else { break }
            try? FileManager.default.removeItem(at: entry.url)
            entries[key] = nil
            bytes -= entry.size
        }
    }

    private static func makeFolder(_ root: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = root
        try? folder.setResourceValues(values)
    }

    /// A path extension readers may look at (PDF, images, audio).
    nonisolated static func pathExtension(_ ref: BlobRef) -> String {
        switch ref.type.lowercased() {
        case "application/pdf": return ".pdf"
        case "image/jpeg": return ".jpg"
        case "image/png": return ".png"
        case "image/heic": return ".heic"
        case "audio/mp4": return ".m4a"
        default: return ""
        }
    }

    /// Writes `produce`'s pieces to a new private file at `url` (mode 0600),
    /// removing it if `produce` throws: for `Fetch` implementations.
    nonisolated static func writeFile(_ url: URL, _ produce: ((Data) throws -> Void) throws -> Void) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            try produce { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Blobs already in a `BlobCache`, as the `BlobSource` the renderer reads
/// (`ItemRaster`): the files were verified when they were fetched; the
/// content is checked against the reference again on every read.
struct CachedBlobSource: BlobSource {
    /// Verified content files by SHA-256 (lowercase hex).
    var files: [String: URL]

    func data(for ref: BlobRef, maxBytes: Int) throws -> Data {
        guard ref.size <= Int64(maxBytes) else { throw BlobError.contentTooLarge(limit: Int64(maxBytes)) }
        guard let url = files[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Int(ref.size) + 1) ?? Data()
        } catch {
            throw BlobError.missing(ref.sha256)
        }
        guard Int64(data.count) == ref.size, BlobRef(content: data, type: ref.type).sha256 == ref.sha256 else {
            throw BlobError.referenceMismatch
        }
        return data
    }

    func withFile<T>(for ref: BlobRef, _ body: (URL) throws -> T) throws -> T {
        guard let url = files[ref.sha256] else { throw BlobError.missing(ref.sha256) }
        return try body(url)
    }

    /// The files were decrypted into the cache before the export began.
    var filesAreCached: Bool { true }
}
