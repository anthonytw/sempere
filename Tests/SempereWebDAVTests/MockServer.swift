import Foundation
import SempereWebDAV

/// An in-memory WebDAV server: PROPFIND (Depth 0/1), GET (with `Range` /
/// `If-Range`), PUT with If-Match / If-None-Match, MKCOL, MOVE (with
/// `Overwrite`), DELETE. Just enough for the sync. Request and response
/// bodies may be files (`bodyFile`, `responseFile`); with `storage` set,
/// file contents live on disk and are copied in 1 MiB pieces, so a large
/// blob never sits in memory on either end.
final class MockDAV: WebDAVTransport, @unchecked Sendable {
    struct Stored {
        var data: Data?
        var disk: URL?
        var size: Int
        var etag: String
    }
    private let lock = NSLock()
    private var files: [String: Stored] = [:]
    private var collections: Set<String>
    private let storage: URL?

    init(collections: Set<String> = ["", "/dav", "/dav/vault"], storage: URL? = nil) {
        self.collections = collections
        self.storage = storage
    }
    private var counter = 0
    private(set) var requests: [(method: String, path: String)] = []
    private(set) var headerLog: [(method: String, path: String, headers: [String: String])] = []
    /// When set, called for each request; return a response to short-circuit.
    var interceptor: (@Sendable (WebDAVRequest) -> WebDAVResponse?)?
    /// Expected `Authorization` header, if any.
    var requiredAuthorization: String?
    /// For a GET of a path ending in the key: send this many body bytes,
    /// then fail as a dropped connection would (used once, then removed).
    var cutGET: [String: Int] = [:]
    /// Like `cutGET`, for only the `n`th GET (1-based) of paths ending in `suffix`.
    var cutNthGET: (suffix: String, n: Int, bytes: Int)?
    private var nthGETs = 0
    /// For a PUT of a path whose final component starts with the key's
    /// prefix: store this many bytes, then fail (used once, then removed).
    var cutPUT: [String: Int] = [:]
    /// Answer `Range` requests (a server may ignore them and send 200).
    var honoursRange = true

    /// What a collection's `getetag` follows, as servers differ.
    enum CollectionETags {
        /// None (the default, like many servers).
        case none
        /// Its direct children's names (a directory's mtime, Apache mod_dav-like).
        case direct
        /// Everything below it, names and contents (Nextcloud-like).
        case deep
        /// Never changes.
        case constant
        /// Weak, following the direct children.
        case weak
    }
    var collectionETags = CollectionETags.none

    private func collectionETag(_ c: String) -> String? {
        func fnv(_ s: String) -> String {
            var h: UInt64 = 0xcbf29ce484222325
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return String(h, radix: 16)
        }
        let direct = { () -> String in
            let kids = self.collections.filter { $0 != c && self.parent($0) == c }
                + self.files.keys.filter { self.parent($0) == c }
            return fnv(kids.sorted().joined(separator: "\n"))
        }
        switch collectionETags {
        case .none: return nil
        case .constant: return "\"c\""
        case .direct: return "\"d\(direct())\""
        case .weak: return "W/\"d\(direct())\""
        case .deep:
            let below = collections.filter { $0.hasPrefix(c + "/") }.sorted()
                + files.filter { $0.key.hasPrefix(c + "/") }.map { "\($0.key)=\($0.value.etag)" }.sorted()
            return "\"r\(fnv(below.joined(separator: "\n")))\""
        }
    }

    static let base = "/dav/vault"

    func file(_ rel: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let s = files[Self.base + "/" + rel] else { return nil }
        return s.data ?? s.disk.flatMap { try? Data(contentsOf: $0) }
    }
    func size(_ rel: String) -> Int? { lock.lock(); defer { lock.unlock() }; return files[Self.base + "/" + rel]?.size }
    func putDirect(_ rel: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        collect(parentOf: Self.base + "/" + rel)
        counter += 1
        files[Self.base + "/" + rel] = Stored(data: data, size: data.count, etag: "\"e\(counter)\"")
    }
    func removeDirect(_ rel: String) { lock.lock(); files[Self.base + "/" + rel] = nil; lock.unlock() }
    /// Removes a collection and everything below it.
    func removeCollection(_ rel: String) {
        lock.lock(); defer { lock.unlock() }
        let p = Self.base + "/" + rel
        files = files.filter { !$0.key.hasPrefix(p + "/") }
        collections = collections.filter { $0 != p && !$0.hasPrefix(p + "/") }
    }
    func names(under rel: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = Self.base + "/" + rel + "/"
        return files.keys.filter { $0.hasPrefix(p) }.map { String($0.dropFirst(p.count)) }.sorted()
    }
    var requestLog: [(method: String, path: String)] { lock.lock(); defer { lock.unlock() }; return requests }
    var headers: [(method: String, path: String, headers: [String: String])] {
        lock.lock(); defer { lock.unlock() }; return headerLog
    }

    private func collect(parentOf path: String) {
        var p = path
        while let i = p.lastIndex(of: "/"), i != p.startIndex {
            p = String(p[..<i]); collections.insert(p)
        }
    }

    func send(_ r: WebDAVRequest) throws -> WebDAVResponse {
        if let hit = interceptor?(r) { return hit }
        lock.lock(); defer { lock.unlock() }
        let path = (r.url.path.removingPercentEncoding ?? r.url.path)
        let key = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        requests.append((r.method, key))
        headerLog.append((r.method, key, r.headers))
        if let want = requiredAuthorization, r.headers["Authorization"] != want { return WebDAVResponse(status: 401) }
        switch r.method {
        case "PROPFIND":
            let depth = r.headers["Depth"] ?? "1"
            if collections.contains(key) {
                var xml = entry(key + "/", etag: collectionETag(key), collection: true, size: nil)
                if depth == "1" {
                    var kids = Set<String>()
                    for c in collections where c != key && parent(c) == key { kids.insert(c) }
                    for c in kids.sorted() { xml += entry(c + "/", etag: collectionETag(c), collection: true, size: nil) }
                    for (f, s) in files.sorted(by: { $0.key < $1.key }) where parent(f) == key {
                        xml += entry(f, etag: s.etag, collection: false, size: s.size)
                    }
                }
                return multistatus(xml)
            }
            if let s = files[key] { return multistatus(entry(key, etag: s.etag, collection: false, size: s.size)) }
            return WebDAVResponse(status: 404)
        case "GET":
            guard let s = files[key] else { return WebDAVResponse(status: 404) }
            var start = 0, end = s.size - 1
            var status = 200
            if honoursRange, let range = r.headers["Range"], range.hasPrefix("bytes="),
               r.headers["If-Range"].map({ $0 == s.etag }) ?? true {
                let ends = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                if ends.count == 2, let from = Int(ends[0]) {
                    guard from < s.size else { return WebDAVResponse(status: 416) }
                    start = from
                    if let to = Int(ends[1]) { end = min(to, s.size - 1) }
                    status = 206
                }
            }
            var headers = ["ETag": s.etag]
            if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(s.size)" }
            var cut = cutGET.first { key.hasSuffix($0.key) }
            if let c = cut { cutGET[c.key] = nil }
            if let nth = cutNthGET, key.hasSuffix(nth.suffix) {
                nthGETs += 1
                if nthGETs == nth.n { cut = (nth.suffix, nth.bytes) }
            }
            if let out = r.responseFile {
                let h = try openResponse(out, status: status)
                defer { try? h.close() }
                var sent = 0
                try forEachPiece(of: s, from: start, count: end + 1 - start) { piece in
                    var piece = piece
                    if let cut, sent + piece.count > cut.value { piece = piece.prefix(cut.value - sent) }
                    if let limit = r.maxResponseBytes, sent + piece.count > limit {
                        try autoreleasing { try h.write(contentsOf: piece.prefix(limit - sent)) }
                        throw WebDAVError.responseTooLarge(path: key, limit: limit)
                    }
                    try autoreleasing { try h.write(contentsOf: piece) }
                    sent += piece.count
                    if let cut, sent >= cut.value { throw WebDAVError.transport("connection lost (test)") }
                }
                return WebDAVResponse(status: status, headers: headers)
            }
            var body = Data()
            try forEachPiece(of: s, from: start, count: end + 1 - start) { body.append($0) }
            return WebDAVResponse(status: status, headers: headers, body: body)
        case "PUT":
            guard collections.contains(parent(key)) else { return WebDAVResponse(status: 409) }
            let existing = files[key]
            if r.headers["If-None-Match"] == "*", existing != nil { return WebDAVResponse(status: 412) }
            if let m = r.headers["If-Match"], existing?.etag != m { return WebDAVResponse(status: 412) }
            counter += 1
            let name = String(key[key.index(after: key.lastIndex(of: "/")!)...])
            let cut = cutPUT.first { name.hasPrefix($0.key) }
            if let cut { cutPUT[cut.key] = nil }
            var stored = Stored(size: 0, etag: "\"e\(counter)\"")
            if let storage {
                let url = storage.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try forEachPiece(of: r) { piece in
                    let piece = cut.map { piece.prefix(max($0.value - stored.size, 0)) } ?? piece
                    try autoreleasing { try h.write(contentsOf: piece) }
                    stored.size += piece.count
                }
                stored.disk = url
            } else {
                var data = Data()
                try forEachPiece(of: r) { data.append($0) }
                if let cut { data = data.prefix(cut.value) }
                stored.data = data
                stored.size = data.count
            }
            // Like a server that writes in place: a cut upload leaves its part behind.
            files[key] = stored
            if cut != nil { throw WebDAVError.transport("connection lost (test)") }
            return WebDAVResponse(status: existing == nil ? 201 : 204)
        case "MKCOL":
            if collections.contains(key) { return WebDAVResponse(status: 405) }
            guard collections.contains(parent(key)) else { return WebDAVResponse(status: 409) }
            collections.insert(key)
            return WebDAVResponse(status: 201)
        case "MOVE":
            guard let dest = r.headers["Destination"].flatMap(URL.init(string:)) else { return WebDAVResponse(status: 400) }
            let to = dest.path.removingPercentEncoding ?? dest.path
            guard let s = files[key] else { return WebDAVResponse(status: 404) }
            guard collections.contains(parent(to)) else { return WebDAVResponse(status: 409) }
            let exists = files[to] != nil
            if exists && r.headers["Overwrite"] == "F" { return WebDAVResponse(status: 412) }
            files[to] = s
            files[key] = nil
            return WebDAVResponse(status: exists ? 204 : 201)
        case "DELETE":
            return WebDAVResponse(status: files.removeValue(forKey: key) == nil ? 404 : 204)
        default:
            return WebDAVResponse(status: 405)
        }
    }

    private func openResponse(_ url: URL, status: Int) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        if status == 200 { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
        return h
    }

    private func forEachPiece(of s: Stored, from start: Int, count: Int, _ body: (Data) throws -> Void) throws {
        if let data = s.data { return try body(Data(data.dropFirst(start).prefix(count))) }
        guard let disk = s.disk else { return }
        let h = try FileHandle(forReadingFrom: disk)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(start))
        var left = count
        while left > 0 {
            let more = try autoreleasing { () throws -> Bool in
                guard let piece = try h.read(upToCount: min(1 << 20, left)), !piece.isEmpty else { return false }
                left -= piece.count
                try body(piece)
                return true
            }
            if !more { break }
        }
    }

    private func forEachPiece(of r: WebDAVRequest, _ body: (Data) throws -> Void) throws {
        guard let file = r.bodyFile else { return try body(r.body ?? Data()) }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        while try autoreleasing({ () throws -> Bool in
            guard let piece = try h.read(upToCount: 1 << 20), !piece.isEmpty else { return false }
            try body(piece)
            return true
        }) {}
    }

    private func parent(_ p: String) -> String { String(p[..<(p.lastIndex(of: "/") ?? p.startIndex)]) }

    private func entry(_ href: String, etag: String?, collection: Bool, size: Int?) -> String {
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        var props = collection ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
        if let etag { props += "<d:getetag>\(etag.replacingOccurrences(of: "\"", with: "&quot;"))</d:getetag>" }
        if let size { props += "<d:getcontentlength>\(size)</d:getcontentlength>" }
        return "<d:response><d:href>\(encoded)</d:href><d:propstat><d:prop>\(props)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private func multistatus(_ body: String) -> WebDAVResponse {
        WebDAVResponse(status: 207, headers: ["Content-Type": "application/xml"],
                       body: Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(body)</d:multistatus>".utf8))
    }
}

/// Runs `body` in its own autorelease pool on Apple platforms, where
/// `FileHandle` reads and writes autorelease their buffers (in a loop over a
/// large file they would pile up until the test's pool drains). A no-op elsewhere.
func autoreleasing<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool { try body() }
    #else
    return try body()
    #endif
}
