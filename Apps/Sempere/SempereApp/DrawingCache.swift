import Foundation
import Sempere

/// Ready-to-show canvas drawings of note pages, so a note opened before
/// opens without decoding, reconstructing and converting its ink
/// (docs/io.md "Opening a note fast", format.md §10.1).
///
/// Per note and *set of revision file names* (revision files are
/// write-once, so the same names are the same note) the cache keeps:
/// - a layout: the note's state without stroke points' geometry (pages,
///   paper, page size, meta) and each page's stroke count, enough to show
///   the note before it is read;
/// - per page, PencilKit's `dataRepresentation` of the page's drawing, one
///   canvas stroke per stored stroke in stored order (what
///   `StrokeConversion` builds), as opaque bytes.
///
/// Every file is sealed with a key derived from the vault secret
/// (`LocalCacheKey`, purpose `drawing-cache`), named by a keyed hash of its
/// note, revision names and page, and lives in this device's caches folder,
/// never in the vault. A vault whose secret changes gets another folder;
/// the others are deleted when a cache is opened, and the open vault's
/// folder is deleted when the vault is closed. The total size is kept
/// under `capBytes` by deleting the least recently used files.
///
/// Nothing read from here is trusted blindly: the editor checks a cached
/// drawing against the strokes it reads from the vault before it lets the
/// user draw on it, and rebuilds it on any mismatch (`DrawingPreparation`).
/// Thread-safe; file I/O happens on the caller's thread (call it off the
/// main actor).
final class DrawingCache: @unchecked Sendable {
    /// `SMPD` then format version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x44, 0x01]
    /// Bumped whenever what a page entry holds changes (conversion, the
    /// layout's shape): older entries are then never found.
    static let schemaVersion = 3   // 2: concurrent replacements merged (format.md §5.6.1); 3: PKStroke.id is the stored id
    /// The default size limit.
    static let defaultCapBytes = 200 << 20
    /// The `UserDefaults` key of the size limit in megabytes (unset: 200).
    static let capDefaultsKey = "Sempere.drawingCacheMegabytes"
    /// The largest single file read.
    static let maxFileBytes = 256 << 20

    /// The configured size limit (`capDefaultsKey`).
    static var configuredCapBytes: Int {
        let mb = UserDefaults.standard.integer(forKey: capDefaultsKey)
        return mb > 0 ? min(mb, 1 << 14) << 20 : defaultCapBytes
    }

    /// `Library/Caches/Sempere/Drawings` in the app's container.
    static var defaultRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sempere/Drawings", isDirectory: true)
    }

    /// What one note version is, for the cache.
    struct Key: Hashable, Sendable {
        var note: UUID
        /// Sorted revision file names.
        var revisions: [String]

        init(note: UUID, revisions: [String]) {
            self.note = note
            self.revisions = revisions.sorted()
        }

        var label: String { "\(DrawingCache.schemaVersion)|\(note.uuidString.lowercased())|\(revisions.joined(separator: ","))" }
    }

    /// The pages of a note version, without ink.
    struct Layout: Codable, Hashable, Sendable {
        /// The note's state with every page's `strokes` empty.
        var state: NoteState
        /// Strokes per page id.
        var strokeCounts: [UUID: Int]

        /// The layout of `state`.
        init(_ state: NoteState) {
            var bare = state
            for i in bare.pages.indices { bare.pages[i].strokes = [] }
            self.state = bare
            strokeCounts = Dictionary(state.pages.map { ($0.id, $0.strokes.count) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// This vault's folder.
    let directory: URL
    /// Total size kept, in bytes.
    let capBytes: Int
    private let key: LocalCacheKey
    private let lock = NSLock()
    private var closed = false
    /// Bytes stored, as far as this instance knows (exact after `trim`).
    private var approximateBytes = 0

    /// The cache of `vault` under `root`; deletes the folders of other vaults
    /// (and of this vault under an earlier secret).
    ///
    /// - Throws: `VaultError.locked` when the vault secret is not known, or a
    ///   file error when the folder cannot be created.
    init(root: URL, vault: Vault, capBytes: Int = DrawingCache.configuredCapBytes) throws {
        key = try LocalCacheKey(vault: vault, purpose: "drawing-cache", magic: Self.magic)
        directory = root.appendingPathComponent(key.name, isDirectory: true)
        self.capBytes = max(capBytes, 1 << 20)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = root
        try? dir.setResourceValues(values)
        for other in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where other != key.name {
            try? fm.removeItem(at: root.appendingPathComponent(other))
        }
        approximateBytes = Self.files(in: directory).reduce(0) { $0 + $1.size }
    }

    // MARK: - Entries

    private func layoutName(_ k: Key) -> String { key.entryName("layout|" + k.label) + ".layout" }
    private func pageName(_ k: Key, _ page: UUID) -> String {
        key.entryName("page|" + k.label + "|" + page.uuidString.lowercased()) + ".page"
    }

    /// The stored layout of `k`, or nil (missing, damaged, other schema).
    func layout(_ k: Key) -> Layout? {
        guard let plain = read(layoutName(k)) else { return nil }
        return try? JSONDecoder().decode(Layout.self, from: plain)
    }

    /// The stored drawing bytes of page `page` of `k`, or nil.
    func drawing(_ k: Key, page: UUID) -> Data? {
        read(pageName(k, page))
    }

    /// Stores the layout of `k`.
    func store(_ layout: Layout, for k: Key) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        write(data, layoutName(k))
    }

    /// Stores the drawing bytes of page `page` of `k`.
    func store(drawing data: Data, for k: Key, page: UUID) {
        write(data, pageName(k, page))
    }

    /// Deletes what is stored for `k` (a version of a note the editor has
    /// just replaced with a newer one).
    func remove(_ k: Key, pages: [UUID]) {
        let fm = FileManager.default
        for name in [layoutName(k)] + pages.map({ pageName(k, $0) }) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Deletes every stored file but keeps the cache open ("Clear Caches" in
    /// Settings); notes rebuild their entries the next time they are opened.
    func removeAll() {
        let fm = FileManager.default
        for f in Self.files(in: directory) { try? fm.removeItem(at: f.url) }
        lock.withLock { approximateBytes = 0 }
    }

    /// Deletes everything and refuses later writes (the vault closed).
    func close() {
        lock.withLock { closed = true }
        let fm = FileManager.default
        // A rename is instant; the files go in the background.
        let doomed = directory.deletingLastPathComponent().appendingPathComponent(".closed-\(UUID().uuidString)")
        if (try? fm.moveItem(at: directory, to: doomed)) != nil {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: doomed) }
        } else {
            try? fm.removeItem(at: directory)
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    // MARK: - Files

    private func read(_ name: String) -> Data? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes),
              let plain = try? key.open(sealed, fileName: name) else { return nil }
        // Least recently used goes first: a read is a use.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return plain
    }

    private func write(_ plain: Data, _ name: String) {
        guard !isClosed, let sealed = try? key.seal(plain, fileName: name) else { return }
        let url = directory.appendingPathComponent(name)
        guard (try? sealed.write(to: url, options: .atomic)) != nil else { return }
        let total = lock.withLock { () -> Int in
            approximateBytes += sealed.count
            return approximateBytes
        }
        if total > capBytes { trim() }
        if isClosed { try? FileManager.default.removeItem(at: url) }   // closed while writing
    }

    /// Deletes the least recently used files until the total is at most
    /// `capBytes` (to 90 % of it, so a full cache is not trimmed per write).
    func trim() {
        var files = Self.files(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        if total > capBytes {
            files.sort { $0.used < $1.used }
            let target = capBytes / 10 * 9
            for f in files where total > target {
                if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
            }
        }
        lock.withLock { approximateBytes = total }
    }

    /// Bytes in the folder now.
    var totalBytes: Int { Self.files(in: directory).reduce(0) { $0 + $1.size } }

    private struct File { var url: URL; var size: Int; var used: Date }

    private static func files(in dir: URL) -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return File(url: url, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast)
        }
    }
}
