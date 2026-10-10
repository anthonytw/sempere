import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// HTTP Basic credentials.
public struct WebDAVCredentials: Sendable {
    public var user: String
    public var password: String

    public init(user: String, password: String) { self.user = user; self.password = password }
}

/// One child of a collection, from PROPFIND.
public struct RemoteEntry: Hashable, Sendable {
    public var name: String
    public var isCollection: Bool
    public var etag: String?
    public var lastModified: String?
    public var size: Int?

    public init(name: String, isCollection: Bool, etag: String? = nil, lastModified: String? = nil, size: Int? = nil) {
        self.name = name; self.isCollection = isCollection
        self.etag = etag; self.lastModified = lastModified; self.size = size
    }

    /// What identifies this version of the file: the ETag, else the modification time.
    public var stamp: String? { etag ?? lastModified }
}

/// How a PUT is made conditional.
public enum PutCondition: Sendable, Equatable {
    /// `If-None-Match: *`: only create, never replace.
    case create
    /// `If-Match: <etag>`: replace only that version.
    case replace(etag: String)
    /// No precondition (the server gave no ETag).
    case unconditional
}

/// The minimal WebDAV verbs the sync needs: PROPFIND (Depth 1), GET, PUT,
/// MKCOL, MOVE and DELETE, over Basic auth on HTTPS (or plain HTTP to localhost).
/// Paths are component lists below `baseURL`, so no caller builds a URL string.
public struct WebDAVClient: Sendable {
    public private(set) var baseURL: URL
    private let transport: any WebDAVTransport
    private let authorization: String?
    private var baseComponents: [String]
    private let origin: String

    /// Largest response body read for listings, manifests and status replies (16 MiB).
    public static let defaultMaxResponseBytes = 16 << 20

    /// Hosts that may be reached over plain HTTP.
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Validates the URL before any request is made.
    ///
    /// - Throws: `WebDAVError.insecureURL` for a scheme other than `https`
    ///   (plain `http` is accepted only for localhost), a missing host, or
    ///   credentials embedded in the URL.
    public init(baseURL: URL, credentials: WebDAVCredentials? = nil,
                transport: any WebDAVTransport = URLSessionTransport()) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host?.lowercased(), !host.isEmpty else {
            throw WebDAVError.insecureURL("not a usable URL: \(baseURL.absoluteString)")
        }
        guard baseURL.user == nil, baseURL.password == nil else {
            throw WebDAVError.insecureURL("do not put credentials in the URL; use --user and --password-env")
        }
        switch scheme {
        case "https": break
        case "http":
            guard Self.localHosts.contains(host) else {
                throw WebDAVError.insecureURL("refusing plain http to \(host): Basic auth and the vault travel unprotected; use https")
            }
        default:
            throw WebDAVError.insecureURL("unsupported URL scheme '\(scheme)'; use https")
        }
        self.baseURL = baseURL
        self.transport = transport
        if let credentials {
            authorization = "Basic " + Data("\(credentials.user):\(credentials.password)".utf8).base64EncodedString()
        } else {
            authorization = nil
        }
        baseComponents = Self.components(of: baseURL.path)
        var o = "\(scheme)://\(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)"
        if let port = baseURL.port { o += ":\(port)" }
        origin = o
    }

    /// A client for the collection `path` below this one, with the same
    /// credentials and transport (a vault found one level down).
    public func descendant(_ path: [String]) throws -> WebDAVClient {
        guard !path.isEmpty else { return self }
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }),
              let url = url(for: path, collection: true) else {
            throw WebDAVError.malformedResponse("not a usable folder name: \(SyncReport.printable(path.joined(separator: "/")))")
        }
        var c = self
        c.baseURL = url
        c.baseComponents = baseComponents + path
        return c
    }

    // MARK: - Verbs

    /// Lists the children of a collection (Depth: 1). Nil when it does not exist.
    public func list(_ path: [String]) throws -> [RemoteEntry]? {
        var h = ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"]
        h["Accept"] = "application/xml, text/xml"
        let r = try send("PROPFIND", path, collection: true, headers: h, body: Data(Self.propfindBody.utf8))
        if r.status == 404 { return nil }
        guard r.status == 207 else { throw try failure("PROPFIND", path, r) }
        let parsed = try PropfindParser.parse(r.body)
        let prefix = baseComponents + path
        var out: [RemoteEntry] = []
        for item in parsed {
            let comps = Self.components(of: Self.decodedPath(item.href))
            guard comps.count == prefix.count + 1, Array(comps.prefix(prefix.count)) == prefix else { continue }
            out.append(RemoteEntry(name: comps[prefix.count], isCollection: item.isCollection, etag: item.etag,
                                   lastModified: item.lastModified, size: item.size))
        }
        return out
    }

    /// Metadata of one file; nil when it does not exist.
    public func stat(_ path: [String]) throws -> RemoteEntry? {
        guard let name = path.last else { return nil }
        let r = try send("PROPFIND", path, collection: false,
                         headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"],
                         body: Data(Self.propfindBody.utf8))
        if r.status == 404 { return nil }
        guard r.status == 207 else { throw try failure("PROPFIND", path, r) }
        guard let item = try PropfindParser.parse(r.body).first else { return nil }
        return RemoteEntry(name: name, isCollection: item.isCollection, etag: item.etag,
                           lastModified: item.lastModified, size: item.size)
    }

    /// Downloads one file; returns its bytes and the response ETag, if any.
    ///
    /// - Throws: `WebDAVError.responseTooLarge` once the body exceeds `maxBytes`
    ///   (reading stops there; nothing larger is buffered).
    public func get(_ path: [String], maxBytes: Int = defaultMaxResponseBytes) throws -> (data: Data, etag: String?) {
        let r = try send("GET", path, collection: false, maxResponseBytes: maxBytes)
        guard r.status == 200 else { throw try failure("GET", path, r) }
        return (r.body, r.headers["etag"])
    }

    /// Uploads one file. Returns false when the precondition failed (the
    /// file exists, or is not the version expected).
    @discardableResult
    public func put(_ path: [String], _ data: Data, condition: PutCondition) throws -> Bool {
        var h = ["Content-Type": "application/octet-stream"]
        switch condition {
        case .create: h["If-None-Match"] = "*"
        case .replace(let etag): h["If-Match"] = etag
        case .unconditional: break
        }
        let r = try send("PUT", path, collection: false, headers: h, body: data)
        switch r.status {
        case 200, 201, 204: return true
        case 412: return false
        default: throw try failure("PUT", path, r)
        }
    }

    /// Uploads a file, streamed from disk (never held in memory). Returns
    /// false when the precondition failed.
    @discardableResult
    public func put(_ path: [String], fromFile file: URL, condition: PutCondition) throws -> Bool {
        let size: Int
        do {
            size = try (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw WebDAVError.io("read \(file.path): \(error.localizedDescription)")
        }
        var h = ["Content-Type": "application/octet-stream", "Content-Length": String(size)]
        switch condition {
        case .create: h["If-None-Match"] = "*"
        case .replace(let etag): h["If-Match"] = etag
        case .unconditional: break
        }
        let r = try send("PUT", path, collection: false, headers: h, bodyFile: file)
        switch r.status {
        case 200, 201, 204: return true
        case 412: return false
        default: throw try failure("PUT", path, r)
        }
    }

    /// What `download` received.
    public struct Download: Sendable, Equatable {
        /// True when the bytes already in the file were kept and only the
        /// rest was fetched; false when the file now holds a fresh copy.
        public var resumed: Bool
        /// The response ETag, if any.
        public var etag: String?
    }

    /// The default size of one `Range` request in `download` (2 MiB). On
    /// Linux, URLSession queues every 16 KiB delivery for its delegate with
    /// no flow control, so a server faster than the disk piles up to one
    /// response in memory; measured against a local server, 2 MiB segments
    /// kept resident memory flat (about 20 MiB) for blobs of 300 MB to 1 GB
    /// at about 5 % more time than 8 MiB ones, which grew to 85 MiB.
    public static let defaultSegmentBytes = 2 << 20

    /// Downloads one file into `file` in `Range` requests of at most
    /// `segmentBytes`, each streamed to the file, so memory stays bounded by
    /// one segment however fast the server sends. A server that ignores
    /// `Range` sends the whole file in one streamed response instead.
    ///
    /// With `resumeFrom` > 0 and an `ifRange` validator, the bytes already in
    /// `file` up to that offset are kept and only the rest is requested
    /// (`If-Range`: if the remote file changed, it comes whole and replaces
    /// them). Without a validator the download starts over.
    ///
    /// - Parameter maxBytes: the largest file accepted.
    /// - Throws: `WebDAVError.responseTooLarge` past `maxBytes` (reading stops
    ///   there), `.http` for any other status (416 included), and
    ///   `.malformedResponse` for a partial response that does not continue
    ///   at the right byte. What was written to `file` before a failure stays
    ///   there.
    @discardableResult
    public func download(_ path: [String], to file: URL, resumeFrom: Int = 0, ifRange: String? = nil,
                         maxBytes: Int, segmentBytes: Int = defaultSegmentBytes) throws -> Download {
        let shown = "/" + path.joined(separator: "/")
        var offset = ifRange == nil ? 0 : max(resumeFrom, 0)
        try Self.truncate(file, to: offset)
        let segment = max(segmentBytes, 1)
        var resumed = offset > 0
        var etag: String?
        while true {
            var h = ["Accept-Encoding": "identity", "Range": "bytes=\(offset)-\(offset + segment - 1)"]
            if let validator = ifRange ?? etag { h["If-Range"] = validator }
            let r = try send("GET", path, collection: false, headers: h, maxResponseBytes: maxBytes, responseFile: file)
            etag = etag ?? r.headers["etag"]
            switch r.status {
            case 200:
                // The whole file (no range support, or it changed): it replaced what was there.
                return Download(resumed: false, etag: r.headers["etag"] ?? etag)
            case 206:
                guard let range = Self.contentRange(r.headers["content-range"]), range.start == offset,
                      range.end >= range.start, range.end < range.total else {
                    throw WebDAVError.malformedResponse("a partial response for \(shown) does not continue at byte \(offset)")
                }
                guard range.total <= maxBytes else { throw WebDAVError.responseTooLarge(path: shown, limit: maxBytes) }
                guard LocalFS.regularFileSize(file) == range.end + 1 else {
                    throw WebDAVError.malformedResponse("a partial response for \(shown) does not match its Content-Range")
                }
                offset = range.end + 1
                if offset == range.total { return Download(resumed: resumed, etag: etag) }
            default:
                throw try failure("GET", path, r)
            }
        }
    }

    /// Cuts `file` to `length` bytes (creating it, mode 0600, if missing).
    private static func truncate(_ file: URL, to length: Int) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw WebDAVError.io("cannot create \(file.path)")
            }
        }
        do {
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            if Int(try h.seekToEnd()) > length { try h.truncate(atOffset: UInt64(length)) }
        } catch {
            throw WebDAVError.io("truncate \(file.path): \(error.localizedDescription)")
        }
    }

    /// `Content-Range: bytes a-b/n` as (a, b, n); nil for anything else
    /// (an unknown total `*` included).
    static func contentRange(_ value: String?) -> (start: Int, end: Int, total: Int)? {
        guard let value else { return nil }
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased().hasPrefix("bytes ") else { return nil }
        let rest = v.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let ends = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ s: Substring) -> Int? {
            guard !s.isEmpty, s.count <= 18, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(s)
        }
        guard ends.count == 2, let a = number(ends[0]), let b = number(ends[1]), let n = number(parts[1]) else { return nil }
        return (a, b, n)
    }

    /// Renames a file on the server (`MOVE`). With `overwrite` false
    /// (`Overwrite: F`) an existing destination is never replaced and the
    /// result is false.
    @discardableResult
    public func move(_ path: [String], to destination: [String], overwrite: Bool) throws -> Bool {
        guard let target = url(for: destination, collection: false) else {
            throw WebDAVError.malformedResponse("cannot form a URL for \(destination.joined(separator: "/"))")
        }
        let r = try send("MOVE", path, collection: false,
                         headers: ["Destination": target.absoluteString, "Overwrite": overwrite ? "T" : "F"])
        switch r.status {
        case 200, 201, 204: return true
        case 412: return false
        default: throw try failure("MOVE", path, r)
        }
    }

    /// What `mkcol` found.
    public enum MkcolResult: Sendable { case created, exists, missingParent }

    /// Creates a collection.
    public func mkcol(_ path: [String]) throws -> MkcolResult {
        let r = try send("MKCOL", path, collection: true)
        switch r.status {
        case 200, 201: return .created
        case 405: return .exists
        case 409: return .missingParent
        default: throw try failure("MKCOL", path, r)
        }
    }

    /// Creates the base collection and any missing ancestors (`mkcol([])`
    /// answered 409). Ancestors that cannot be created are ignored: only the
    /// base itself has to exist in the end.
    public func createBase() throws {
        for depth in 1...max(baseComponents.count, 1) {
            let comps = Array(baseComponents.prefix(depth))
            let isBase = depth >= baseComponents.count
            guard let url = self.url(forAbsolute: comps) else { continue }
            var h: [String: String] = ["User-Agent": "sempere-webdav/0.1"]
            if let authorization { h["Authorization"] = authorization }
            let r = try transport.send(WebDAVRequest(method: "MKCOL", url: url, headers: h,
                                                     maxResponseBytes: Self.defaultMaxResponseBytes))
            try Self.checkSize(r, url: url, limit: Self.defaultMaxResponseBytes)
            if isBase && ![200, 201, 405].contains(r.status) { throw try failure("MKCOL", [], r) }
        }
    }

    /// Deletes a file. A file that is already gone is fine.
    public func delete(_ path: [String]) throws {
        let r = try send("DELETE", path, collection: false)
        guard [200, 202, 204, 404].contains(r.status) else { throw try failure("DELETE", path, r) }
    }

    // MARK: - Plumbing

    static let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop>\
        <d:getetag/><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>
        """

    func url(for path: [String], collection: Bool) -> URL? {
        let all = (baseComponents + path).map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? $0 }
        var s = origin + "/" + all.joined(separator: "/")
        if collection && !all.isEmpty { s += "/" }
        return URL(string: s)
    }

    func url(forAbsolute comps: [String]) -> URL? {
        let all = comps.map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? $0 }
        return URL(string: origin + "/" + all.joined(separator: "/") + "/")
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    private func send(_ method: String, _ path: [String], collection: Bool, headers: [String: String] = [:],
                      body: Data? = nil, maxResponseBytes: Int = defaultMaxResponseBytes,
                      bodyFile: URL? = nil, responseFile: URL? = nil) throws -> WebDAVResponse {
        guard let url = url(for: path, collection: collection) else {
            throw WebDAVError.malformedResponse("cannot form a URL for \(path.joined(separator: "/"))")
        }
        var h = headers
        if let authorization { h["Authorization"] = authorization }
        h["User-Agent"] = "sempere-webdav/0.1"
        let r = try transport.send(WebDAVRequest(method: method, url: url, headers: h, body: body,
                                                 maxResponseBytes: maxResponseBytes, bodyFile: bodyFile,
                                                 responseFile: responseFile))
        try Self.checkSize(r, url: url, limit: responseFile == nil ? maxResponseBytes : Self.defaultMaxResponseBytes)
        return r
    }

    /// The same limit for transports that do not enforce `maxResponseBytes` themselves.
    private static func checkSize(_ r: WebDAVResponse, url: URL, limit: Int) throws {
        if r.body.count > limit { throw WebDAVError.responseTooLarge(path: url.path, limit: limit) }
    }

    private func failure(_ method: String, _ path: [String], _ r: WebDAVResponse) throws -> WebDAVError {
        let shown = path.joined(separator: "/")
        if (300..<400).contains(r.status) {
            return .redirect(path: shown, location: r.headers["location"] ?? "?")
        }
        return .http(method: method, path: shown, status: r.status)
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The decoded path part of an `href` (absolute URL or absolute path).
    static func decodedPath(_ href: String) -> String {
        var s = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") {
            let rest = s[r.upperBound...]
            s = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        return s.removingPercentEncoding ?? s
    }
}

// MARK: - PROPFIND multistatus

struct PropfindItem {
    var href = ""
    var isCollection = false
    var etag: String?
    var lastModified: String?
    var size: Int?
}

/// Reads the handful of DAV properties the sync needs; ignores namespaces'
/// prefixes and everything else.
final class PropfindParser: NSObject, XMLParserDelegate {
    private var items: [PropfindItem] = []
    private var current: PropfindItem?
    private var text = ""
    private var inResourceType = false
    private var failed: String?

    static func parse(_ data: Data) throws -> [PropfindItem] {
        // swift-corelibs-foundation's XMLParser crashes on an element name
        // that is not valid UTF-8 (`<a><b\u{C3}/></a>` traps) and on a
        // processing instruction without data (`<?x?>` calls strlen(NULL)),
        // so both are refused before parsing. A multistatus has no use for a
        // DTD either; refusing one rules out entity expansion whatever
        // libxml2's own limits are.
        // A NUL byte first: XML 1.0 forbids U+0000, and UTF-16 or UTF-32
        // text (which libxml2 detects from its declaration) is otherwise
        // valid UTF-8 whose markup the byte searches below cannot see.
        guard !data.contains(0) else {
            throw WebDAVError.malformedResponse("PROPFIND body holds a NUL byte (not UTF-8 XML)")
        }
        guard isValidUTF8(data) else {
            throw WebDAVError.malformedResponse("PROPFIND body is not valid UTF-8")
        }
        guard data.firstRange(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw WebDAVError.malformedResponse("PROPFIND body has a DTD")
        }
        guard afterDeclaration(data).firstRange(of: Data("<?".utf8)) == nil else {
            throw WebDAVError.malformedResponse("PROPFIND body has a processing instruction")
        }
        let p = PropfindParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldResolveExternalEntities = false
        guard xml.parse(), p.failed == nil else {
            throw WebDAVError.malformedResponse("PROPFIND body is not valid XML: \(p.failed ?? xml.parserError?.localizedDescription ?? "?")")
        }
        return p.items
    }

    /// `data` after a leading `<?xml …?>` declaration (and any BOM or
    /// whitespace before it); all of `data` when there is none.
    static func afterDeclaration(_ data: Data) -> Data.SubSequence {
        var rest = data[...]
        if rest.starts(with: [0xEF, 0xBB, 0xBF]) { rest = rest.dropFirst(3) }
        rest = rest.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
        guard rest.starts(with: Data("<?xml".utf8)), rest.count > 5,
              [0x20, 0x09, 0x0A, 0x0D].contains(rest[rest.startIndex + 5]),
              let end = rest.firstRange(of: Data("?>".utf8)) else { return data[...] }
        return rest[end.upperBound...]
    }

    static func isValidUTF8(_ data: Data) -> Bool {
        var it = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    private func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch local(elementName) {
        case "response": current = PropfindItem()
        case "resourcetype": inResourceType = true
        case "collection": if inResourceType { current?.isCollection = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(elementName) {
        case "href": if current != nil, current?.href.isEmpty == true { current?.href = value }
        case "getetag": if !value.isEmpty { current?.etag = value }
        case "getlastmodified": if !value.isEmpty { current?.lastModified = value }
        case "getcontentlength": if let n = Int(value) { current?.size = n }
        case "resourcetype": inResourceType = false
        case "response":
            if let c = current, !c.href.isEmpty { items.append(c) }
            current = nil
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = parseError.localizedDescription }
}
