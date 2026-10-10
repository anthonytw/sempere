import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Sempere
import UIKit
import UniformTypeIdentifiers

/// Drawn attachments, kept between note opens and launches so that a note
/// with images or PDF pages opened before shows them at once (TestFlight
/// build 6: reopening a PDF note was as slow as the first open):
///
/// - **pictures**: what `ItemRendering` made of an image item (decoded,
///   cropped, oriented, scaled: an `ItemPicture.image`), by everything it
///   depends on (`pictureLabel`);
/// - **PDF page previews**: one bitmap per PDF page item at the screen's
///   scale for an unzoomed page (`previewLabel`), shown under the page's
///   tiles while Core Graphics draws them (`ItemLayerView`), and at once on
///   the next open, before the PDF blob is even opened.
///
/// Two levels: decoded images in memory (least recently used out beyond
/// `memoryCapBytes`), and files sealed like the drawing cache's
/// (`LocalCacheKey`, purpose `render-cache`: folder and file names keyed by
/// the vault secret, each file ChaCha20-Poly1305 with its name bound) in
/// `Library/Caches/Sempere/Renders`, least recently used out beyond `capBytes`.
/// Without a root (tests) only the memory level is used. The folder is
/// deleted when the vault closes (`close`), and folders of other vaults when
/// it is first written.
///
/// Thread-safe; disk work happens on the caller's thread (call it off the
/// main actor).
final class RenderCache: @unchecked Sendable {
    /// `SMPI` then format version 1.
    static let magic: [UInt8] = [0x53, 0x4D, 0x50, 0x49, 0x01]
    /// Bumped whenever how a picture or preview is drawn changes: older entries are then never found.
    static let schemaVersion = 3   // 2: video items drawn as poster + play mark (format.md §8.2.7); 3: Markdown text boxes (§8.5.4)
    static let defaultCapBytes = 256 << 20
    /// The `UserDefaults` key of the disk size limit in megabytes (unset: 256).
    static let capDefaultsKey = "Sempere.renderCacheMegabytes"
    static let memoryCapBytes = 96 << 20
    /// The largest single file read.
    static let maxFileBytes = 96 << 20
    /// Largest preview, in pixels.
    static let maxPreviewPixels = 4_000_000

    /// `Library/Caches/Sempere/Renders` in the app's container.
    static var defaultRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sempere/Renders", isDirectory: true)
    }

    /// The configured disk size limit (`capDefaultsKey`).
    static var configuredCapBytes: Int {
        let mb = UserDefaults.standard.integer(forKey: capDefaultsKey)
        return mb > 0 ? min(mb, 1 << 14) << 20 : defaultCapBytes
    }

    /// A drawn picture: pixels covering `bounds` (page points).
    struct Picture: @unchecked Sendable {
        var image: CGImage
        var bounds: Rect
    }

    /// The vault's folder; nil: memory only.
    let directory: URL?
    let capBytes: Int
    private let key: LocalCacheKey?
    private let lock = NSLock()
    private var closed = false
    private var prepared = false
    private var memoryWarning: (any NSObjectProtocol)?
    private var memory: [String: (picture: Picture, bytes: Int, use: UInt64)] = [:]
    private var memoryBytes = 0
    private var tick: UInt64 = 0
    private var diskBytes = 0
    /// Lookups answered from memory, from disk, and missed (tests, timing).
    private(set) var memoryHits = 0, diskHits = 0, misses = 0

    /// The cache of `vault` (unlocked) under `root`; nil `root`: memory only.
    /// Cheap: the folder is made, and other vaults' folders deleted, on the first write.
    init(root: URL?, vault: Vault, capBytes: Int = RenderCache.configuredCapBytes) {
        let key = root == nil ? nil : try? LocalCacheKey(vault: vault, purpose: "render-cache", magic: Self.magic)
        self.key = key
        directory = key.flatMap { k in root?.appendingPathComponent(k.name, isDirectory: true) }
        self.capBytes = max(capBytes, 1 << 20)
        // Pictures in memory are a convenience: let them go when the system is short.
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                               object: nil, queue: nil) { [weak self] _ in
            self?.trimMemory()
        }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    // MARK: - Labels

    /// What a picture of `key` depends on, or nil for items that are not
    /// cached (PDF pages: previews; Markdown boxes). Text boxes and equations
    /// not yet typeset are drawn by CoreText here, so their label also names
    /// the system and its fonts (`nativeSalt`).
    static func pictureLabel(_ key: ItemRenderKey) -> String? {
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
        let kind = native ? "txt|\(nativeSalt)" : "pic"
        return "\(kind)|\(schemaVersion)|\(String(decoding: itemJSON, as: UTF8.self))|\(key.scale)|\(String(decoding: paperJSON, as: UTF8.self))"
    }

    /// What CoreText drawing depends on beyond the item: the system version and the installed font
    /// families (read once per launch).
    static let nativeSalt: String = {
        let families = Data(UIFont.familyNames.sorted().joined(separator: "\n").utf8)
        let digest = SHA256.hash(data: families).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ProcessInfo.processInfo.operatingSystemVersionString + "|" + digest
    }()

    /// What the preview of PDF page item `item` at `scale` depends on.
    static func previewLabel(_ item: Item, scale: Double) -> String? {
        guard item.kind == .pdfPage, let blob = item.blob, let index = item.pageIndex else { return nil }
        func r(_ v: Rect?) -> String { v.map { "\($0.x),\($0.y),\($0.w),\($0.h)" } ?? "-" }
        let size = item.pageSize.map { "\($0.w),\($0.h)" } ?? "-"
        return "pdf|\(schemaVersion)|\(blob.sha256)|\(blob.size)|\(index)|\(r(item.shownCrop))|\(size)|"
            + "\(item.frame.w),\(item.frame.h)|\(item.rotation ?? 0)|\(scale)"
    }

    /// Pixels per page point of a PDF page preview: the screen's scale at the
    /// unzoomed width, at most `maxPreviewPixels` for the page.
    static func previewScale(for item: Item, screenScale: Double) -> Double {
        let b = ItemFrames.bounds(item.frame, rotation: item.rotation)
        let want = max(1, screenScale.rounded(.up))
        let area = b.w * b.h
        guard area > 0, area.isFinite else { return want }
        return min(want, max(0.25, (Double(maxPreviewPixels) / area).squareRoot()))
    }

    // MARK: - Lookups

    /// The picture stored as `label`: from memory, else from disk (then kept in memory).
    func picture(_ label: String) -> Picture? {
        if let hit = lock.withLock({ () -> Picture? in
            guard !closed, var entry = memory[label] else { return nil }
            tick &+= 1
            entry.use = tick
            memory[label] = entry
            memoryHits += 1
            return entry.picture
        }) { return hit }
        guard let picture = readDisk(label) else {
            lock.withLock { misses += 1 }
            return nil
        }
        lock.withLock { diskHits += 1 }
        remember(picture, label)
        return picture
    }

    /// Whether `label` is in memory now (no disk read: for the main actor).
    func pictureInMemory(_ label: String) -> Picture? {
        lock.withLock { () -> Picture? in
            guard !closed, var entry = memory[label] else { return nil }
            tick &+= 1
            entry.use = tick
            memory[label] = entry
            memoryHits += 1
            return entry.picture
        }
    }

    /// Stores `picture` as `label` (memory at once, then the disk).
    func store(_ picture: Picture, label: String) {
        guard !isClosed else { return }
        remember(picture, label)
        writeDisk(picture, label)
    }

    /// Forgets everything and deletes the folder (the vault closed or its keys changed).
    func close() {
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
        let bytes = picture.image.bytesPerRow * picture.image.height
        guard bytes <= Self.memoryCapBytes / 4 else { return }
        lock.withLock {
            guard !closed else { return }
            tick &+= 1
            if let old = memory[label] { memoryBytes -= old.bytes }
            memory[label] = (picture, bytes, tick)
            memoryBytes += bytes
            guard memoryBytes > Self.memoryCapBytes else { return }
            for (k, v) in memory.sorted(by: { $0.value.use < $1.value.use }) where memoryBytes > Self.memoryCapBytes * 3 / 4 {
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
              let picture = Self.decode(plain) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return picture
    }

    private func writeDisk(_ picture: Picture, _ label: String) {
        guard let directory, let key, let name = fileName(label), let plain = Self.encode(picture),
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

    /// Makes the folder and deletes other vaults' (once).
    private func prepareFolder(_ directory: URL) {
        let first = lock.withLock { () -> Bool in
            defer { prepared = true }
            return !prepared
        }
        guard first else { return }
        let fm = FileManager.default
        let root = directory.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = root
        try? dir.setResourceValues(values)
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

    private struct File { var url: URL; var size: Int; var used: Date }

    private static func files(in dir: URL) -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return File(url: url, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast)
        }
    }

    // MARK: - Encoding

    private struct Header: Codable {
        var width: Int
        var height: Int
        var bounds: Rect
        /// "jpeg" (opaque pictures) or "rgba" (premultiplied RGBA, LZFSE).
        var format: String
    }

    /// `header length (4 bytes, big endian) ‖ header JSON ‖ payload`.
    static func encode(_ picture: Picture) -> Data? {
        let image = picture.image
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        var payload: Data?
        var format = "rgba"
        if opaque {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                if CGImageDestinationFinalize(dest) { payload = out as Data; format = "jpeg" }
            }
        }
        if payload == nil {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let raw = ctx.data else { return nil }
            let pixels = NSData(bytes: raw, length: w * h * 4)
            payload = try? pixels.compressed(using: .lzfse) as Data
            format = "rgba"
        }
        guard let payload, let header = try? JSONEncoder().encode(Header(width: w, height: h, bounds: picture.bounds, format: format))
        else { return nil }
        var data = Data()
        var length = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(payload)
        return data
    }

    /// The picture in `data`, nil when it is not one (a damaged or older file).
    static func decode(_ data: Data) -> Picture? {
        guard data.count > 4 else { return nil }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 4096, data.count >= 4 + length,
              let header = try? JSONDecoder().decode(Header.self, from: data.dropFirst(4).prefix(length)),
              header.width > 0, header.height > 0, header.width <= 16_384, header.height <= 16_384,
              header.width * header.height <= 64_000_000 else { return nil }
        let payload = Data(data.dropFirst(4 + length))
        switch header.format {
        case "jpeg":
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == header.width, image.height == header.height else { return nil }
            return Picture(image: image, bounds: header.bounds)
        case "rgba":
            let expected = header.width * header.height * 4
            guard let pixels = try? (payload as NSData).decompressed(using: .lzfse) as Data, pixels.count == expected,
                  let provider = CGDataProvider(data: pixels as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: header.width, height: header.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: header.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return Picture(image: image, bounds: header.bounds)
        default:
            return nil
        }
    }

    // MARK: - PDF page previews

    /// Draws the preview of PDF page item `item` of `document` at `scale`
    /// pixels per page point: the page in the item's rotated frame, transparent
    /// around it (bounds: the rotated frame's, page points). Nil when it cannot be drawn.
    static func drawPreview(_ item: Item, document: PDFDocumentBox, scale: Double) -> Picture? {
        let bounds = ItemFrames.bounds(item.frame, rotation: item.rotation)
        // Sizes as Double first: a frame from the vault can be huge (or make the
        // bounds infinite or NaN), and Int(_:) traps on any of those.
        let wd = (bounds.w * scale).rounded(.up), hd = (bounds.h * scale).rounded(.up)
        guard wd.isFinite, hd.isFinite, wd > 0, hd > 0, wd * hd <= Double(maxPreviewPixels * 2),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(wd), h = Int(hd)
        let rotated = (item.rotation ?? 0).truncatingRemainder(dividingBy: 360) != 0
        let info = rotated ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: info) else { return nil }
        if !rotated {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // y down, page points, origin at the bounds' top left; then the frame's centre, turned.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.translateBy(x: CGFloat(item.frame.x + item.frame.w / 2 - bounds.x), y: CGFloat(item.frame.y + item.frame.h / 2 - bounds.y))
        ctx.rotate(by: CGFloat(ItemFrames.radians(item.rotation)))
        ctx.translateBy(x: -CGFloat(item.frame.w / 2), y: -CGFloat(item.frame.h / 2))
        let drawn = document.lock.withLock { PDFItemDrawing.draw(document.document, item: item, in: ctx) }
        guard drawn, let image = ctx.makeImage() else { return nil }
        return Picture(image: image, bounds: bounds)
    }
}
