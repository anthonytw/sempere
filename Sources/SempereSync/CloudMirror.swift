import Crypto
import Sempere
import Foundation

// MARK: - Record names and the metadata mirror (docs/design/1.4-cloudkit.md §2.2, §3.1)

/// How vault paths become record names, and what a path or a change tag must look like to be believed.
public enum CloudRecordNaming {
    /// The zone's own record: layout version and creation (not a vault file).
    public static let zoneInfoName = "zone-info"
    /// The longest path component, in UTF-8 bytes.
    public static let maxComponentBytes = 255
    /// Deepest path the transport represents.
    public static let maxDepth = 16
    /// Longest change tag taken.
    public static let maxTagBytes = 256

    /// `sempere-<vault id>`, the vault id lowercased.
    public static func zoneName(vaultId: String) -> String { "sempere-" + vaultId.lowercased() }

    /// Hex SHA-256 of the vault path (components joined by `/`).
    public static func pathHash(_ path: [String]) -> String {
        Hex.encode(SHA256.hash(data: Data(path.joined(separator: "/").utf8)))
    }

    /// `f-` + the path's hash: 66 ASCII characters whatever the path.
    public static func fileName(_ path: [String]) -> String { "f-" + pathHash(path) }

    /// `p-<file record's hash>-<n>`.
    public static func partName(fileName: String, index: Int) -> String { "p-" + String(fileName.dropFirst(2)) + "-\(index)" }

    /// The hash and index a part name carries; nil for any other name.
    public static func parsePartName(_ name: String) -> (fileHash: String, index: Int)? {
        let u = Array(name.utf8)
        guard u.count > 67, u[0] == UInt8(ascii: "p"), u[1] == UInt8(ascii: "-"), u[66] == UInt8(ascii: "-") else { return nil }
        let hash = String(decoding: u[2..<66], as: UTF8.self)
        guard isHex64(hash), u.count <= 66 + 1 + 9 else { return nil }
        let digits = u[67...]
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), digits.first != 0x30 || digits.count == 1,
              let n = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
        return (hash, n)
    }

    /// The hash of a `f-<hex>` file record name; nil for any other name.
    public static func fileHash(ofName name: String) -> String? {
        guard name.utf8.count == 66, name.hasPrefix("f-") else { return nil }
        let h = String(name.dropFirst(2))
        return isHex64(h) ? h : nil
    }

    static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Whether `component` can be a path component: not empty, not `.` or `..`, no `/`, NUL or control character, at
    /// most `maxComponentBytes`.
    public static func isValidComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != "..", component.utf8.count <= maxComponentBytes else { return false }
        return component.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && $0 != "/" }
    }

    /// Whether `path` (a file's) can be represented: 1 to `maxDepth` valid components.
    public static func isValidPath(_ path: [String]) -> Bool {
        !path.isEmpty && path.count <= maxDepth && path.allSatisfy(isValidComponent)
    }

    /// The components of a stored `path` field; nil when it is not a valid path.
    public static func components(ofStoredPath p: String) -> [String]? {
        guard p.utf8.count <= maxDepth * (maxComponentBytes + 1) else { return nil }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return isValidPath(comps) ? comps : nil
    }

    /// Whether a change tag is something the mirror can hold and a version token can carry: printable ASCII, no
    /// quote or tab or space, at most `maxTagBytes`.
    public static func isValidTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.utf8.count <= maxTagBytes && tag.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f && $0 != 0x22 }
    }
}

/// Why a mirror file was refused.
public enum CloudMirrorError: Error, Equatable, Sendable {
    case tooLarge
    case malformed(line: Int, reason: String)
}

/// What the transport keeps of the zone: the change token, and one metadata row per record (about 150 bytes a file,
/// no payload). A cache, never the truth: dropped and refetched when lost, corrupt or expired.
struct CloudMirror: Equatable {
    /// A vault file's row.
    struct File: Equatable {
        var name: String
        var path: [String]
        var tag: String
        /// Milliseconds since 1970, 0 when the record had no date.
        var modified: Int64
        var size: Int64
        var sha256: Data?
        var tomb: Bool
        var parts: Int
        var schema: Int64
        /// A layout newer than this build: listed, never read, written or deleted.
        var isNewer: Bool { schema > CloudSchema.current }
    }

    /// A part's row.
    struct Part: Equatable {
        var name: String
        var fileHash: String
        var index: Int
        var tag: String
        var modified: Int64
    }

    /// Where a skipped record went wrong, for the counts.
    enum Skip: String { case name, path, tag, schema, size, hash, parts }

    var token: CloudChangeToken?
    /// Whether the zone exists; false until it is seen or made.
    var zoneExists = false
    /// The zone's own record's layout version, when seen.
    var zoneSchema: Int64?
    /// Collections made on this device that no file holds yet (`makeCollection`): keys of `pathKey`.
    var declared = Set<String>()
    /// Files (live and tombstoned) by `pathKey`.
    private(set) var files: [String: File] = [:]
    /// Parts by record name.
    private(set) var parts: [String: Part] = [:]
    /// Child names of every collection that a live file lies below, by `pathKey`.
    private var children: [String: Set<String>] = [:]
    private var folderMemo: [String: String] = [:]
    /// Path key of the file each record name belongs to.
    private var byName: [String: String] = [:]

    static func pathKey(_ path: [String]) -> String { path.joined(separator: "/") }

    var recordCount: Int { files.count + parts.count }

    /// Forgets everything but the zone's existence (a full fetch follows).
    mutating func reset(zoneExists: Bool) {
        self = CloudMirror()
        self.zoneExists = zoneExists
    }

    func file(_ path: [String]) -> File? { files[Self.pathKey(path)] }

    /// The live file at `path`.
    func liveFile(_ path: [String]) -> File? {
        guard let f = files[Self.pathKey(path)], !f.tomb else { return nil }
        return f
    }

    mutating func upsert(_ f: File) {
        let key = Self.pathKey(f.path)
        if let old = files[key], !old.tomb { removeChild(f.path) }
        if let old = files[key], old.name != f.name { byName[old.name] = nil }
        files[key] = f
        byName[f.name] = key
        if !f.tomb { addChild(f.path) }
        invalidateFolders(above: f.path)
    }

    mutating func removeFile(_ path: [String]) {
        let key = Self.pathKey(path)
        guard let old = files.removeValue(forKey: key) else { return }
        byName[old.name] = nil
        if !old.tomb { removeChild(path) }
        invalidateFolders(above: path)
    }

    /// Removes the record of this name (a file or a part), as the feed's deletions say.
    mutating func removeRecord(named name: String) {
        if let key = byName[name], let f = files[key] { removeFile(f.path) }
        parts[name] = nil
    }

    /// The row of the file record of this name.
    func file(named name: String) -> File? { byName[name].flatMap { files[$0] } }

    mutating func upsert(_ p: Part) { parts[p.name] = p }
    mutating func removePart(_ name: String) { parts[name] = nil }

    private mutating func addChild(_ path: [String]) {
        for depth in 0..<path.count {
            children[Self.pathKey(Array(path.prefix(depth))), default: []].insert(path[depth])
        }
    }

    private mutating func removeChild(_ path: [String]) {
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let parentKey = Self.pathKey(Array(path.prefix(depth)))
            if depth < path.count - 1 {
                // A collection goes when no live file lies below it any more.
                let childKey = Self.pathKey(Array(path.prefix(depth + 1)))
                if !(children[childKey]?.isEmpty ?? true) { break }
                children[childKey] = nil
            }
            children[parentKey]?.remove(path[depth])
        }
        if children[""]?.isEmpty == true { children[""] = nil }
    }

    private mutating func invalidateFolders(above path: [String]) {
        guard !folderMemo.isEmpty else { return }
        for depth in 0..<path.count { folderMemo[Self.pathKey(Array(path.prefix(depth)))] = nil }
    }

    /// Whether the collection at `path` exists: the base while the zone does; a folder while a live file lies below
    /// it, or this device made it.
    func collectionExists(_ path: [String]) -> Bool {
        if path.isEmpty { return zoneExists }
        let key = Self.pathKey(path)
        if children[key] != nil || declared.contains(key) { return true }
        // Below a collection this device made.
        let prefix = key + "/"
        return declared.contains { $0.hasPrefix(prefix) }
    }

    /// The names under the collection at `path` (live files and collections), sorted.
    func childNames(_ path: [String]) -> [String] {
        let key = Self.pathKey(path)
        var names = children[key] ?? []
        // Collections this device made, directly below.
        let prefix = path.isEmpty ? "" : key + "/"
        for d in declared where d.hasPrefix(prefix) {
            names.insert(String(d.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).first ?? ""))
        }
        return names.sorted()
    }

    /// A digest of the tags below the collection at `path`: changes when any file below it does.
    mutating func folderTag(_ path: [String]) -> String {
        let key = Self.pathKey(path)
        if let memo = folderMemo[key] { return memo }
        var h = SHA256()
        for name in childNames(path) {
            let childPath = path + [name]
            if let f = liveFile(childPath) {
                h.update(data: Data("f\u{0}\(name)\u{0}\(f.tag)\n".utf8))
            } else {
                h.update(data: Data("d\u{0}\(name)\u{0}\(folderTag(childPath))\n".utf8))
            }
        }
        let tag = "\"d-" + Hex.encode(h.finalize()) + "\""
        folderMemo[key] = tag
        return tag
    }

    /// Whether a name under `path` is a file (live) rather than a collection.
    func isFile(_ path: [String]) -> Bool { liveFile(path) != nil }

    /// Every live file below `path` (a collection), for a delete of the collection. Bounded by the mirror itself.
    func liveFiles(below path: [String]) -> [File] {
        files.values.filter { !$0.tomb && $0.path.count > path.count && Array($0.path.prefix(path.count)) == path }
    }

    /// The tombstones.
    var tombstones: [File] { files.values.filter(\.tomb) }

    // MARK: Taking in a record from the feed (untrusted)

    /// What a record from the feed became.
    enum Ingested { case file(File), part(Part), zoneInfo(Int64), skipped(Skip) }

    /// Judges one record of the feed: its name, path, hash, tag, schema, sizes and counts. Nothing is trusted.
    static func ingest(_ r: CloudRecord) -> Ingested {
        guard CloudRecordNaming.isValidTag(r.changeTag) else { return .skipped(.tag) }
        let modified = r.modified.map { Self.millis($0) } ?? 0
        switch r.kind {
        case .part:
            guard let p = CloudRecordNaming.parsePartName(r.name) else { return .skipped(.name) }
            return .part(Part(name: r.name, fileHash: p.fileHash, index: p.index, tag: r.changeTag, modified: modified))
        case .file:
            if r.name == CloudRecordNaming.zoneInfoName {
                guard let s = r.fields.schema, s >= 1 else { return .skipped(.schema) }
                return .zoneInfo(s)
            }
            guard CloudRecordNaming.fileHash(ofName: r.name) != nil else { return .skipped(.name) }
            guard let stored = r.fields.path, let path = CloudRecordNaming.components(ofStoredPath: stored),
                  CloudRecordNaming.fileName(path) == r.name else { return .skipped(.path) }
            guard let schema = r.fields.schema, schema >= 1 else { return .skipped(.schema) }
            let tomb = (r.fields.tomb ?? 0) != 0
            var size: Int64 = 0, parts = 0
            var sha: Data?
            if !tomb {
                if schema <= CloudSchema.current {
                    guard let s = r.fields.size, s >= 0, s <= maxFileBytes else { return .skipped(.size) }
                    guard let h = r.fields.sha256, h.count == 32 else { return .skipped(.hash) }
                    let n = r.fields.parts ?? 0
                    guard n >= 0, n <= maxParts, n == 0 || s > 0 else { return .skipped(.parts) }
                    size = s; sha = h; parts = Int(n)
                } else {
                    // A newer layout: only what lists it (a size, if sane).
                    size = max(0, min(r.fields.size ?? 0, maxFileBytes))
                    sha = r.fields.sha256.flatMap { $0.count == 32 ? $0 : nil }
                }
            }
            return .file(File(name: r.name, path: path, tag: r.changeTag, modified: modified, size: size, sha256: sha, tomb: tomb,
                              parts: parts, schema: schema))
        }
    }

    /// The largest file taken (1 GiB of content plus its framing, format.md §8.4, with room).
    static let maxFileBytes: Int64 = (1 << 30) + (256 << 20)
    /// The most parts a file may have.
    static let maxParts: Int64 = 1 << 16

    static func millis(_ d: Date) -> Int64 {
        let ms = d.timeIntervalSince1970 * 1000
        guard ms.isFinite, abs(ms) < 1e15 else { return 0 }
        return Int64(ms)
    }

    // MARK: Persisting

    private static let header = "sempere-cloud-mirror/1"
    private static let maxLine = 4 * (CloudRecordNaming.maxDepth * (CloudRecordNaming.maxComponentBytes + 1)) + 256

    /// The mirror as a file (a line per record).
    func encoded() -> Data {
        var out = Self.header + "\n"
        if let token { out += "T\t" + Hex.encode(token.data) + "\n" }
        out += "Z\t\(zoneExists ? 1 : 0)\t\(zoneSchema.map(String.init) ?? "-")\n"
        for d in declared.sorted() { out += "D\t" + d + "\n" }
        for f in files.values.sorted(by: { $0.name < $1.name }) {
            out += ["F", f.path.joined(separator: "/"), f.tag, String(f.modified), String(f.size), f.sha256.map { Hex.encode($0) } ?? "-",
                    f.tomb ? "1" : "0", String(f.parts), String(f.schema)].joined(separator: "\t") + "\n"
        }
        for p in parts.values.sorted(by: { $0.name < $1.name }) {
            out += ["P", p.name, p.tag, String(p.modified)].joined(separator: "\t") + "\n"
        }
        return Data(out.utf8)
    }

    /// Reads a mirror file. Every line is checked as a feed record is; any problem refuses the whole file (the
    /// caller drops the mirror and fetches again).
    static func decode(_ data: Data, maxRecords: Int, maxBytes: Int = 512 << 20) throws -> CloudMirror {
        guard data.count <= maxBytes else { throw CloudMirrorError.tooLarge }
        var mirror = CloudMirror()
        var lineNo = 0
        var seenHeader = false
        var start = data.startIndex
        func bad(_ why: String) -> CloudMirrorError { .malformed(line: lineNo, reason: why) }
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0a) ?? data.endIndex
            guard end - start <= maxLine else { throw CloudMirrorError.malformed(line: lineNo + 1, reason: "line too long") }
            lineNo += 1
            let line = String(decoding: data[start..<end], as: UTF8.self)
            start = end < data.endIndex ? end + 1 : end
            if !seenHeader {
                guard line == header else { throw bad("not a mirror file") }
                seenHeader = true
                continue
            }
            guard mirror.recordCount <= maxRecords else { throw bad("too many records") }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch cols.first {
            case "T" where cols.count == 2:
                guard let raw = Hex.decode(cols[1], count: cols[1].utf8.count / 2), let t = CloudChangeToken(raw) else { throw bad("token") }
                mirror.token = t
            case "Z" where cols.count == 3:
                guard cols[1] == "0" || cols[1] == "1" else { throw bad("zone") }
                mirror.zoneExists = cols[1] == "1"
                if cols[2] != "-" { guard let s = Int64(cols[2]), s >= 1 else { throw bad("zone schema") }; mirror.zoneSchema = s }
            case "D" where cols.count == 2:
                guard let comps = CloudRecordNaming.components(ofStoredPath: cols[1]) else { throw bad("declared path") }
                mirror.declared.insert(pathKey(comps))
            case "F" where cols.count == 9:
                guard let path = CloudRecordNaming.components(ofStoredPath: cols[1]), CloudRecordNaming.isValidTag(cols[2]),
                      let mod = Int64(cols[3]), let size = Int64(cols[4]), size >= 0, size <= maxFileBytes,
                      cols[6] == "0" || cols[6] == "1", let parts = Int(cols[7]), parts >= 0, parts <= Int(maxParts),
                      let schema = Int64(cols[8]), schema >= 1 else { throw bad("file row") }
                var sha: Data?
                if cols[5] != "-" { guard let h = Hex.decode(cols[5]) else { throw bad("hash") }; sha = h }
                mirror.upsert(File(name: CloudRecordNaming.fileName(path), path: path, tag: cols[2], modified: mod, size: size,
                                   sha256: sha, tomb: cols[6] == "1", parts: parts, schema: schema))
            case "P" where cols.count == 4:
                guard let p = CloudRecordNaming.parsePartName(cols[1]), CloudRecordNaming.isValidTag(cols[2]), let mod = Int64(cols[3]) else {
                    throw bad("part row")
                }
                mirror.upsert(Part(name: cols[1], fileHash: p.fileHash, index: p.index, tag: cols[2], modified: mod))
            default:
                throw bad("unknown row")
            }
        }
        guard seenHeader else { throw bad("empty") }
        return mirror
    }
}
