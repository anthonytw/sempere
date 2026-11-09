import Foundation
import Sempere
import SempereRender

/// What the model knows of the open vault's cache of drawn attachments: it makes one per unlocked vault
/// (`AppModelServices.makeRenderCache`) and closes it with the vault (`dropAttachments`). The drawing is the app's
/// (`RenderCache`, a `RenderStore` of CoreGraphics pictures).
public protocol RenderCaching: AnyObject, Sendable {
    /// Forgets everything and deletes the vault's folder (the vault closed or its keys changed).
    func close()
}

/// How a `RenderStore` keeps its pictures: the app's are `CGImage`s (JPEG or LZFSE-compressed RGBA); tests use
/// plain bytes.
public protocol RenderPictureCodec: Sendable {
    associatedtype Picture: Sendable
    /// The bytes of a stored file's plaintext; nil when `picture` cannot be stored.
    static func encode(_ picture: Picture) -> Data?
    /// The picture in `data`, nil when it is not one (a damaged or older file).
    static func decode(_ data: Data) -> Picture?
    /// What `picture` costs in memory.
    static func byteCount(_ picture: Picture) -> Int
}

/// Drawn attachments, kept between note opens and launches so that a note
/// with images or PDF pages opened before shows them at once (TestFlight
/// build 6: reopening a PDF note was as slow as the first open):
///
/// - **pictures**: what the app's item drawing made of an image item (decoded,
///   cropped, oriented, scaled), by everything it depends on (`pictureLabel`);
/// - **PDF page previews**: one bitmap per PDF page item at the screen's
///   scale for an unzoomed page (`previewLabel`), shown under the page's
///   tiles while they are drawn, and at once on the next open, before the PDF
///   blob is even opened.
///
/// Two levels: pictures in memory (least recently used out beyond
/// `memoryCapBytes`), and files sealed like the drawing cache's
/// (`LocalCacheKey`, purpose `render-cache`: folder and file names keyed by
/// the vault secret, each file ChaCha20-Poly1305 with its name bound) under
/// the root (the app's `Library/Caches/Sempere/Renders`), least recently used out beyond `capBytes`.
/// Without a root (tests) only the memory level is used. The folder is
/// deleted when the vault closes (`close`), and folders of other vaults when
/// it is first written. What a picture is and how it is stored is `Codec`'s.
///
/// Thread-safe; disk work happens on the caller's thread (call it off the
/// main actor).
public final class RenderStore<Codec: RenderPictureCodec>: RenderCaching, @unchecked Sendable {
    public typealias Picture = Codec.Picture

    /// `SMPI` then format version 1.
    static var magic: [UInt8] { [0x53, 0x4D, 0x50, 0x49, 0x01] }
    /// Bumped whenever how a picture or preview is drawn changes: older entries are then never found.
    static var schemaVersion: Int { 4 }
    static var defaultCapBytes: Int { 256 << 20 }
    /// The settings key of the disk size limit in megabytes (unset: 256).
    static var capDefaultsKey: String { "Sempere.renderCacheMegabytes" }
    static var memoryCapBytes: Int { 96 << 20 }
    /// The largest single file read.
    static var maxFileBytes: Int { 96 << 20 }
    /// Largest preview, in pixels.
    public static var maxPreviewPixels: Int { 4_000_000 }

    /// The configured disk size limit (`capDefaultsKey` in `settings`).
    public static func configuredCapBytes(in settings: any KeyValueStore) -> Int {
        let mb = settings.integer(forKey: capDefaultsKey)
        return mb > 0 ? min(mb, 1 << 14) << 20 : defaultCapBytes
    }

    /// The vault's folder; nil: memory only.
    public let directory: URL?
    let capBytes: Int
    /// What the native (text) drawing depends on (the app's: the system and its fonts at launch); tests stand
    /// in an OS update or a font install by giving another (check c16).
    let salt: String
    private let key: LocalCacheKey?
    private let lock = NSLock()
    /// Held while the folder is made (`prepareFolder`), so that no write overtakes it.
    private let prepareLock = NSLock()
    private var closed = false
    private var prepared = false
    private var memoryWarning: (any NSObjectProtocol)?
    private var memory: [String: (picture: Picture, bytes: Int, use: UInt64)] = [:]
    private var memoryBytes = 0
    private var tick: UInt64 = 0
    private var diskBytes = 0
    /// Background writes scheduled and not finished, and who waits for them to drain.
    private var pendingWrites = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var hits = (memory: 0, disk: 0, misses: 0)
    /// Lookups answered from memory, from disk, and missed (tests, timing).
    public var memoryHits: Int { lock.withLock { hits.memory } }
    public var diskHits: Int { lock.withLock { hits.disk } }
    var misses: Int { lock.withLock { hits.misses } }

    /// The cache of `vault` (unlocked) under `root`; nil `root`: memory only. The memory level is dropped on
    /// `memoryWarning` (posted on the default center; the app's is UIKit's). Cheap: the folder is made, and other
    /// vaults' folders deleted, on the first write.
    public init(root: URL?, vault: Vault, capBytes: Int, salt: String, memoryWarning: Notification.Name?) {
        self.salt = salt
        let key = root == nil ? nil : try? LocalCacheKey(vault: vault, purpose: "render-cache", magic: Self.magic)
        self.key = key
        directory = key.flatMap { k in root?.appendingPathComponent(k.name, isDirectory: true) }
        self.capBytes = max(capBytes, 1 << 20)
        // Pictures in memory are a convenience: let them go when the system is short.
        if let memoryWarning {
            self.memoryWarning = NotificationCenter.default.addObserver(forName: memoryWarning, object: nil, queue: nil) {
                [weak self] _ in self?.trimMemory()
            }
        }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    // MARK: - Labels

    /// What a picture of `key` depends on, or nil for items that are not
    /// cached (PDF pages: previews; Markdown boxes). Text boxes and equations
    /// not yet typeset are drawn natively (CoreText in the app), so their label also names
    /// what that drawing depends on (`salt`).
    public static func pictureLabel(_ key: ItemRenderKey, salt: String) -> String? {
        let native = (key.item.kind == .text && key.item.text.map { !$0.isMarkdown } == true)
            || (key.item.kind == .math && key.item.math.map { $0.render == nil } == true)
        guard key.item.blob != nil || native, key.item.kind != .pdfPage else { return nil }
        var item = key.item
        item.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        item.z = ""
        item.parent = nil
        item.rec = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let itemJSON = try? encoder.encode(item) else { return nil }
        let paperJSON = key.paper.flatMap { try? encoder.encode($0) } ?? Data()
        let kind = native ? "txt|\(salt)" : "pic"
        return "\(kind)|\(schemaVersion)|\(String(decoding: itemJSON, as: UTF8.self))|\(key.scale)|\(String(decoding: paperJSON, as: UTF8.self))"
    }

    /// `pictureLabel` with this cache's salt (`salt`).
    public func label(for key: ItemRenderKey) -> String? { Self.pictureLabel(key, salt: salt) }

    /// What the preview of PDF page item `item` at `scale` depends on.
    public static func previewLabel(_ item: Item, scale: Double) -> String? {
        guard item.kind == .pdfPage, let blob = item.blob, let index = item.pageIndex else { return nil }
        func r(_ v: Rect?) -> String { v.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "-" }
        let size = item.pageSize.map { "\($0.w),\($0.h)" } ?? "-"
        return "pdf|\(schemaVersion)|\(blob.sha256)|\(blob.size)|\(index)|\(r(item.shownCrop))|\(size)|"
            + "\(item.frame.w),\(item.frame.h)|\(item.rotation ?? 0)|\(scale)"
    }

    /// Pixels per page point of a PDF page preview: the screen's scale at the
    /// unzoomed width, at most `maxPreviewPixels` for the page.
    public static func previewScale(for item: Item, screenScale: Double) -> Double {
        let b = ItemFrames.bounds(item.frame, rotation: item.rotation)
        let want = max(1, screenScale.rounded(.up))
        let area = b.w * b.h
        guard area > 0, area.isFinite else { return want }
        return min(want, max(0.25, (Double(maxPreviewPixels) / area).squareRoot()))
    }

    /// `Codec.encode`.
    public static func encode(_ picture: Picture) -> Data? { Codec.encode(picture) }
    /// `Codec.decode`.
    public static func decode(_ data: Data) -> Picture? { Codec.decode(data) }

    // MARK: - Lookups

    /// The picture stored as `label`: from memory, else from disk (then kept in memory).
    public func picture(_ label: String) -> Picture? {
        if let hit = pictureInMemory(label) { return hit }
        guard let picture = readDisk(label) else {
            lock.withLock { hits.misses += 1 }
            return nil
        }
        lock.withLock { hits.disk += 1 }
        remember(picture, label)
        return picture
    }

    /// Whether `label` is in memory now (no disk read: for the main actor).
    public func pictureInMemory(_ label: String) -> Picture? {
        lock.withLock { () -> Picture? in
            guard !closed, var entry = memory[label] else { return nil }
            tick &+= 1
            entry.use = tick
            memory[label] = entry
            hits.memory += 1
            return entry.picture
        }
    }

    /// Stores `picture` as `label` (memory at once, then the disk).
    public func store(_ picture: Picture, label: String) {
        guard !isClosed else { return }
        remember(picture, label)
        writeDisk(picture, label)
    }

    /// `store(_:label:)` on a utility-priority task nothing awaits. The write is counted when it is
    /// scheduled, not when it starts, so `waitForWrites()` covers tasks that have not run yet.
    public func storeInBackground(_ picture: Picture, label: String) {
        lock.withLock { pendingWrites += 1 }
        Task.detached(priority: .utility) { [self] in
            store(picture, label: label)
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                pendingWrites -= 1
                guard pendingWrites == 0 else { return [] }
                defer { writeWaiters = [] }
                return writeWaiters
            }
            for waiter in waiting { waiter.resume() }
        }
    }

    /// Returns once every write started by `storeInBackground` has finished (tests: an event to wait on,
    /// not a clock).
    public func waitForWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = lock.withLock { () -> Bool in
                if pendingWrites == 0 { return true }
                writeWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    /// Forgets everything and deletes the folder (the vault closed or its keys changed).
    public func close() {
        lock.withLock {
            closed = true
            memory = [:]
            memoryBytes = 0
        }
        guard let directory else { return }
        let fm = FileManager.default
        let doomed = directory.deletingLastPathComponent().appendingPathComponent(".closed-\(UUID().uuidString)")
        if (try? fm.moveItem(at: directory, to: doomed)) != nil {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: doomed) }
        } else {
            try? fm.removeItem(at: directory)
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Bytes held in memory.
    var bytesInMemory: Int { lock.withLock { memoryBytes } }

    /// Drops the memory level (a memory warning); the disk keeps everything.
    func trimMemory() {
        lock.withLock {
            memory = [:]
            memoryBytes = 0
        }
    }

    private func remember(_ picture: Picture, _ label: String) {
        let bytes = Codec.byteCount(picture)
        let cap = Self.memoryCapBytes
        guard bytes <= cap / 4 else { return }
        lock.withLock {
            guard !closed else { return }
            tick &+= 1
            if let old = memory[label] { memoryBytes -= old.bytes }
            memory[label] = (picture, bytes, tick)
            memoryBytes += bytes
            guard memoryBytes > cap else { return }
            for (k, v) in memory.sorted(by: { $0.value.use < $1.value.use }) where memoryBytes > cap * 3 / 4 {
                memory[k] = nil
                memoryBytes -= v.bytes
            }
        }
    }

    // MARK: - Disk

    private func fileName(_ label: String) -> String? {
        key.map { $0.entryName(label) + ".render" }
    }

    private func readDisk(_ label: String) -> Picture? {
        guard let directory, let key, let name = fileName(label), !isClosed else { return nil }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? BoundedRead.contents(of: url, maxBytes: Self.maxFileBytes),
              let plain = try? key.open(sealed, fileName: name),
              let picture = Codec.decode(plain) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return picture
    }

    private func writeDisk(_ picture: Picture, _ label: String) {
        guard let directory, let key, let name = fileName(label), let plain = Codec.encode(picture),
              let sealed = try? key.seal(plain, fileName: name) else { return }
        prepareFolder(directory)
        guard !isClosed, (try? sealed.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { return }
        let total = lock.withLock { () -> Int in
            diskBytes += sealed.count
            return diskBytes
        }
        if total > capBytes { trim() }
        if isClosed { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// Makes the folder and deletes other vaults' (once). Concurrent first
    /// writes wait until it is done: one that went ahead found no folder yet,
    /// and its picture was lost.
    private func prepareFolder(_ directory: URL) {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        guard !lock.withLock({ prepared }) else { return }
        defer { lock.withLock { prepared = true } }
        let fm = FileManager.default
        let root = directory.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = root
        try? dir.setResourceValues(values)
        #endif
        for other in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where other != directory.lastPathComponent {
            try? fm.removeItem(at: root.appendingPathComponent(other))
        }
        let size = Self.files(in: directory).reduce(0) { $0 + $1.size }
        lock.withLock { diskBytes = size }
    }

    /// Deletes the least recently used files until the total is at most 90 % of `capBytes`.
    func trim() {
        guard let directory else { return }
        var files = Self.files(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        if total > capBytes {
            files.sort { $0.used < $1.used }
            for f in files where total > capBytes / 10 * 9 {
                if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
            }
        }
        lock.withLock { diskBytes = total }
    }

    /// Bytes in the folder now.
    var totalBytes: Int { directory.map { Self.files(in: $0).reduce(0) { $0 + $1.size } } ?? 0 }

    private static func files(in dir: URL) -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
    }
}

/// Pictures that are their stored bytes: the headless services' render cache (`AppModelServices.dataRenderCache`)
/// and the store's tests.
enum DataPictureCodec: RenderPictureCodec {
    static func encode(_ picture: Data) -> Data? { picture.isEmpty ? nil : picture }
    static func decode(_ data: Data) -> Data? { data.isEmpty ? nil : data }
    static func byteCount(_ picture: Data) -> Int { picture.count }
}
