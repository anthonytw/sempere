import Foundation
import Sempere

// MARK: - Installing a model from a folder or a zip the user picked
//
// For trying a converted model without a catalog entry or a download
// (tools/math-model/README.md): the user picks a model folder
// (`manifest.json` and the files it lists) or a zip of one in Files, and it is
// copied into the store after every listed file matched its SHA-256 and size.
// Only the files the manifest lists are read; everything else in the folder
// or zip (and every zip entry's own name) is ignored, so a hostile archive
// cannot write outside the store.

/// A model in the store, however it got there.
public struct InstalledMathModel: Hashable, Sendable, Identifiable {
    public var id: String { manifest.id }
    public var manifest: MathModelManifest
    /// SHA-256 of the manifest's bytes: the pin the store's marker holds.
    public var manifestSHA256: String
    public var folder: URL
    public var totalBytes: Int64 { manifest.files.reduce(0) { $0 + $1.size } }
    public var name: String { manifest.name }
    public init(manifest: MathModelManifest, manifestSHA256: String, folder: URL) {
        self.manifest = manifest; self.manifestSHA256 = manifestSHA256; self.folder = folder
    }
}

extension MathModelStore {
    /// Every model in `root` whose manifest hashes to its marker and whose files have their sizes, by name.
    public static func installedModels(root: URL) -> [InstalledMathModel] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var found: [InstalledMathModel] = []
        for name in names where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let data = try? BoundedRead.contents(of: folder.appendingPathComponent("manifest.json"),
                                                       maxBytes: MathModelManifest.maxBytes),
                  let m = try? MathModelManifest.parse(data), m.id == name else { continue }
            let sha = FileDigest.sha256(data)
            guard let marker = try? BoundedRead.contents(of: folder.appendingPathComponent(markerName), maxBytes: 128),
                  String(decoding: marker, as: UTF8.self) == sha else { continue }
            let intact = m.files.allSatisfy { f in
                let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(f.path).path)
                return (attrs?[.size] as? NSNumber)?.int64Value == f.size
            }
            if intact { found.append(InstalledMathModel(manifest: m, manifestSHA256: sha, folder: folder)) }
        }
        return found.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

public enum MathModelImport {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noManifest
        case unsupportedZip(String)
        case missingEntry(String)

        public var description: String {
            switch self {
            case .noManifest: return "there is no manifest.json in it (pick the model's folder or its zip)"
            case .unsupportedZip(let why): return "this zip cannot be read: \(why). Make it with `zip -0 -r` (stored, not compressed)"
            case .missingEntry(let path): return "the model file \(path) is not in it"
            }
        }
    }

    /// Checks the model in `source` (a folder, or a zip file of one) and
    /// installs it into `root` as `root/<manifest id>`, replacing a model with
    /// the same id. Slow for a big model (it reads every file): call it off
    /// the main thread.
    @discardableResult
    public static func install(from source: URL, root: URL) throws -> InstalledMathModel {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw Failure.noManifest }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let manifestData: Data
        if isDir.boolValue {
            manifestData = try copyFolder(source, to: staging)
        } else {
            manifestData = try copyZip(source, to: staging)
        }
        let sha = FileDigest.sha256(manifestData)
        let folder = try MathModelStore.install(from: staging, manifestSHA256: sha, root: root)
        let manifest = try MathModelStore.manifest(in: folder)
        return InstalledMathModel(manifest: manifest, manifestSHA256: sha, folder: folder)
    }

    private static func copyFolder(_ source: URL, to staging: URL) throws -> Data {
        let fm = FileManager.default
        let data: Data
        do { data = try BoundedRead.contents(of: source.appendingPathComponent("manifest.json"), maxBytes: MathModelManifest.maxBytes) }
        catch { throw Failure.noManifest }
        let manifest = try MathModelManifest.parse(data)
        for f in manifest.files {
            // The file a link points to, never the link: the store holds copies (a Hugging Face
            // snapshot links every file to a blob), and the picked folder's access ends after this.
            let from = source.appendingPathComponent(f.path).resolvingSymlinksInPath()
            guard fm.fileExists(atPath: from.path) else { throw Failure.missingEntry(f.path) }
            let to = staging.appendingPathComponent(f.path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
        try data.write(to: staging.appendingPathComponent("manifest.json"))
        return data
    }

    // MARK: stored zips

    struct ZipEntry { var name: String; var offset: UInt64; var size: UInt64 }

    private static func le16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func le32(_ d: Data, _ o: Int) -> UInt64 { UInt64(le16(d, o)) | UInt64(le16(d, o + 2)) << 16 }

    /// The central directory of a zip whose entries are all stored (method 0).
    static func zipEntries(_ h: FileHandle) throws -> [ZipEntry] {
        let end = try h.seekToEnd()
        let tailSize = min(end, 65_557)
        try h.seek(toOffset: end - tailSize)
        let tail = try h.read(upToCount: Int(tailSize)) ?? Data()
        guard let at = (0...max(tail.count - 22, 0)).reversed().first(where: {
            tail.count >= 22 && le32(tail, $0) == 0x0605_4b50
        }) else { throw Failure.unsupportedZip("no end-of-archive record") }
        let count = le16(tail, at + 10), cdSize = le32(tail, at + 12), cdOffset = le32(tail, at + 16)
        guard count != 0xFFFF, cdSize != 0xFFFF_FFFF, cdOffset != 0xFFFF_FFFF else { throw Failure.unsupportedZip("zip64") }
        guard cdSize <= 4 << 20, cdOffset + cdSize <= end else { throw Failure.unsupportedZip("bad central directory") }
        try h.seek(toOffset: cdOffset)
        let cd = try h.read(upToCount: Int(cdSize)) ?? Data()
        var entries: [ZipEntry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4b50 else { throw Failure.unsupportedZip("bad central directory") }
            let flags = le16(cd, p + 8), method = le16(cd, p + 10)
            let csize = le32(cd, p + 20), usize = le32(cd, p + 24)
            let n = le16(cd, p + 28), x = le16(cd, p + 30), c = le16(cd, p + 32), off = le32(cd, p + 42)
            guard p + 46 + n <= cd.count else { throw Failure.unsupportedZip("bad central directory") }
            let name = String(decoding: cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + n)], as: UTF8.self)
            p += 46 + n + x + c
            if name.hasSuffix("/") { continue }
            guard flags & 1 == 0 else { throw Failure.unsupportedZip("encrypted entry") }
            guard method == 0, csize == usize else { throw Failure.unsupportedZip("\(name) is compressed") }
            entries.append(ZipEntry(name: name, offset: off, size: usize))
        }
        return entries
    }

    /// Copies `entry`'s bytes to `target` (a local header first tells where the data starts).
    private static func extract(_ entry: ZipEntry, from h: FileHandle, to target: URL) throws {
        try h.seek(toOffset: entry.offset)
        let header = try h.read(upToCount: 30) ?? Data()
        guard header.count == 30, le32(header, 0) == 0x0403_4b50 else { throw Failure.unsupportedZip("bad local header") }
        try h.seek(toOffset: entry.offset + 30 + UInt64(le16(header, 26)) + UInt64(le16(header, 28)))
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: target.path, contents: nil) else { throw Failure.missingEntry(entry.name) }
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        var left = entry.size
        while left > 0 {
            let piece = try h.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
            guard !piece.isEmpty else { throw Failure.unsupportedZip("\(entry.name) is cut short") }
            try out.write(contentsOf: piece)
            left -= UInt64(piece.count)
        }
    }

    private static func copyZip(_ source: URL, to staging: URL) throws -> Data {
        let h = try BoundedRead.openRegularFile(source)   // a regular file only: never blocks on a FIFO
        defer { try? h.close() }
        let entries = try zipEntries(h)
        // The manifest sits at the top, or in the single folder the zip was made from.
        let manifestEntry = entries.first { $0.name == "manifest.json" }
            ?? entries.first { $0.name.hasSuffix("/manifest.json") && !$0.name.hasPrefix("__MACOSX")
                && $0.name.filter({ $0 == "/" }).count == 1 }
        guard let manifestEntry else { throw Failure.noManifest }
        guard manifestEntry.size <= UInt64(MathModelManifest.maxBytes) else { throw Failure.noManifest }
        let prefix = String(manifestEntry.name.dropLast("manifest.json".count))
        try extract(manifestEntry, from: h, to: staging.appendingPathComponent("manifest.json"))
        let data = try BoundedRead.contents(of: staging.appendingPathComponent("manifest.json"), maxBytes: MathModelManifest.maxBytes)
        let manifest = try MathModelManifest.parse(data)
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for f in manifest.files {
            guard let e = byName[prefix + f.path] else { throw Failure.missingEntry(f.path) }
            guard e.size == UInt64(f.size) else { throw MathModelManifest.Failure.mismatch(f.path) }
            try extract(e, from: h, to: staging.appendingPathComponent(f.path))
        }
        return data
    }
}
