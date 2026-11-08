import Age
import Foundation
import Sempere
import SempereAppCore
import SempereSync
import SempereWebDAV
import TempDirSupport
import Testing

// The WebDAV and two-device fakes of the model's sync suites (moved from the app's tests in wave 5b part 3, step 4b,
// with every suite that uses them: `WebDAVTests`, `WebDAVPartialTests`, `TwoDeviceSyncTests`, `JoinTests`,
// `UnlistedOverSyncTests`, `JoinOverSyncTests`), and the fixture's setup they share.

/// A WebDAV server as the model sees it (`WebDAVRemote`): downloads copy a vault
/// folder (the "server"), pushes and re-downloads return scripted results.
/// The library's sync itself is tested in `Tests/SempereWebDAVTests`.
final class FakeWebDAVRemote: WebDAVRemote, @unchecked Sendable {
    private let lock = NSLock()
    let server: URL
    private var _downloads = 0, _pushes = 0, _redownloads = 0
    private var _pushedUnlocked: [Bool] = []
    private var _redownloadKeys: [Int] = []
    private var _releases = 0
    /// How often the model told the remote the open vault closed (`releaseConnections`).
    var releases: Int { lock.lock(); defer { lock.unlock() }; return _releases }
    func releaseConnections() { lock.lock(); _releases += 1; lock.unlock() }
    var downloadError: (any Error)?
    var downloadReport = SyncReport()
    var pushError: (any Error)?
    var pushReport = SyncReport()
    var redownloadReplaces = true
    /// When set, a download reports these as its progress, then waits for `downloadGate`
    /// (or a cancellation) before it places the copy.
    var downloadSteps: [SyncProgress] = []
    var downloadGate: DispatchSemaphore?
    private var _optionsSeen: [Int] = []
    /// The concurrency each download was given.
    var concurrencySeen: [Int] { lock.lock(); defer { lock.unlock() }; return _optionsSeen }
    /// When set, a push waits for it before it returns (a slow upload).
    var pushGate: DispatchSemaphore?
    /// When set, a fetch waits for it before it starts (a slow server).
    var fetchGate: DispatchSemaphore?
    var fetchError: (any Error)?
    private var _fetchScopes: [FetchScope] = []
    private var _fetchedUnlocked: [Bool] = []
    private var _inFlight = 0, _mostInFlight = 0
    var probe: WebDAVProbe = .reachable(WebDAVCheckResult(outcome: .noVault, vaults: [], foldersChecked: 0,
                                                          foldersSkipped: 0, unreadable: []))
    private(set) var passwordsSeen: [String?] = []

    init(server: URL) { self.server = server }

    var downloads: Int { lock.lock(); defer { lock.unlock() }; return _downloads }
    var pushes: Int { lock.lock(); defer { lock.unlock() }; return _pushes }
    var redownloads: Int { lock.lock(); defer { lock.unlock() }; return _redownloads }
    /// The most pushes and re-downloads of the copy that ever ran at once.
    var mostInFlight: Int { lock.lock(); defer { lock.unlock() }; return _mostInFlight }
    var pushedUnlocked: [Bool] { lock.lock(); defer { lock.unlock() }; return _pushedUnlocked }
    /// How many identities each re-download was given (the new copy is checked under them).
    var redownloadKeys: [Int] { lock.lock(); defer { lock.unlock() }; return _redownloadKeys }
    /// Every fetch's scope, in order.
    var fetchScopes: [FetchScope] { lock.lock(); defer { lock.unlock() }; return _fetchScopes }
    /// Whether each fetch was given the unlocked vault (checks under the key).
    var fetchedUnlocked: [Bool] { lock.lock(); defer { lock.unlock() }; return _fetchedUnlocked }

    /// A client of the fixture `server` folder (read-only, `FolderDAVTransport`): the
    /// metadata pull, fetches and re-downloads run the real library against it.
    func folderClient() throws -> WebDAVClient {
        try WebDAVClient(baseURL: URL(string: "https://dav.example.org/notes/")!,
                         transport: FolderDAVTransport(root: server, base: "/notes"))
    }

    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport {
        lock.lock(); _downloads += 1; let error = downloadError, report = downloadReport
        let steps = downloadSteps, gate = downloadGate
        _optionsSeen.append(options.concurrency)
        passwordsSeen.append(endpoint.password); lock.unlock()
        if let error { throw error }
        for step in steps { options.progress?(step) }
        if let gate {
            // Waits like a slow server, checking the Cancel as the library does between requests.
            while gate.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
                if options.isCancelled?() == true {
                    var stopped = report
                    stopped.stoppedEarly = SyncError.cancelled.errorDescription
                    return stopped
                }
            }
        }
        let pulled = try copy.downloadMetadata(client: try folderClient(), options: options)
        return report.errors.isEmpty ? pulled : report
    }

    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport {
        lock.lock(); _fetchScopes.append(scope); _fetchedUnlocked.append(vault?.canRead == true)
        let gate = fetchGate, error = fetchError; lock.unlock()
        gate?.wait()
        if let error { throw error }
        return try copy.fetch(client: try folderClient(), vault: vault, scope: scope)
    }

    /// Lets every fetch through from now on (and the ones waiting).
    func openFetchGate() {
        lock.lock(); let gate = fetchGate; fetchGate = nil; lock.unlock()
        for _ in 0..<64 { gate?.signal() }
    }

    func set(_ change: (FakeWebDAVRemote) -> Void) { lock.lock(); change(self); lock.unlock() }

    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe {
        lock.lock(); defer { lock.unlock() }
        passwordsSeen.append(endpoint.password)
        return probe
    }

    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport {
        lock.lock(); _downloads += 1; let error = downloadError, report = downloadReport
        passwordsSeen.append(endpoint.password); lock.unlock()
        if let error { throw error }
        try place(into: copy)
        return report
    }

    private func enter() { lock.lock(); _inFlight += 1; _mostInFlight = max(_mostInFlight, _inFlight); lock.unlock() }
    private func leave() { lock.lock(); _inFlight -= 1; lock.unlock() }

    private var _twoWay = 0
    private var _stagings = 0
    /// Staging runs of a locked vault (`LockedStaging`).
    var stagings: Int { lock.lock(); defer { lock.unlock() }; return _stagings }
    /// How many of the runs were two-way (`sync`); the others were upload-only pushes.
    var twoWayRuns: Int { lock.lock(); defer { lock.unlock() }; return _twoWay }

    /// A two-way run counts as a push here (the same scripted report), and is counted on its own too.
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        // A locked vault's staging run (`LockedStaging`: no key, the shadow copy) is not one of the vault's runs.
        if vault == nil { lock.lock(); _stagings += 1; lock.unlock(); return SyncReport() }
        lock.lock(); _twoWay += 1; lock.unlock()
        return try push(endpoint, copy: copy, vault: vault, options: options)
    }

    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        enter()
        defer { leave() }
        lock.lock()
        _pushes += 1
        _pushedUnlocked.append(vault?.canRead == true)
        let gate = pushGate, error = pushError, report = pushReport
        lock.unlock()
        gate?.wait()
        if let error { throw error }
        return report
    }

    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        enter()
        defer { leave() }
        lock.lock(); _redownloads += 1; _redownloadKeys.append(identities.count); let replaces = redownloadReplaces; lock.unlock()
        guard replaces else { return (SyncReport(), false) }
        return try copy.redownload(client: try folderClient(), identities: identities, partial: partial, options: options)
    }

    private func place(into copy: LocalCopy) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: copy.directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: copy.folder)
        try fm.copyItem(at: server, to: copy.folder)
    }
}

/// A read-only WebDAV server over a local folder (PROPFIND Depth 1 and GET),
/// so the model's tests run the library's real metadata pulls, fetches and
/// re-downloads (`FakeWebDAVRemote`). It ignores `Range` (the library then
/// takes the whole file, as from such a server).
final class FolderDAVTransport: WebDAVTransport, @unchecked Sendable {
    let root: URL
    let base: String

    init(root: URL, base: String) {
        self.root = root
        self.base = base
    }

    func send(_ r: WebDAVRequest) throws -> WebDAVResponse {
        var path = r.url.path.removingPercentEncoding ?? r.url.path
        guard path.hasPrefix(base) else { return WebDAVResponse(status: 404) }
        path = String(path.dropFirst(base.count))
        let rel = path.split(separator: "/").map(String.init)
        guard !rel.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { return WebDAVResponse(status: 404) }
        let url = rel.reduce(root) { $0.appendingPathComponent($1) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return WebDAVResponse(status: 404) }
        switch r.method {
        case "PROPFIND":
            let href = base + (rel.isEmpty ? "" : "/" + rel.joined(separator: "/"))
            var xml = entry(href + "/", url: url, collection: isDir.boolValue)
            if isDir.boolValue {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() where !name.hasPrefix(".") {
                    var d: ObjCBool = false
                    let child = url.appendingPathComponent(name)
                    _ = FileManager.default.fileExists(atPath: child.path, isDirectory: &d)
                    xml += entry(href + "/" + name + (d.boolValue ? "/" : ""), url: child, collection: d.boolValue)
                }
            }
            return WebDAVResponse(status: 207, headers: ["Content-Type": "application/xml"],
                                  body: Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(xml)</d:multistatus>".utf8))
        case "GET":
            guard !isDir.boolValue else { return WebDAVResponse(status: 405) }
            let data = try Data(contentsOf: url)
            let etag = Self.etag(url, size: data.count)
            if let out = r.responseFile {
                FileManager.default.createFile(atPath: out.path, contents: data, attributes: [.posixPermissions: 0o600])
                return WebDAVResponse(status: 200, headers: ["ETag": etag])
            }
            return WebDAVResponse(status: 200, headers: ["ETag": etag], body: data)
        default:
            return WebDAVResponse(status: 405)
        }
    }

    private static func etag(_ url: URL, size: Int) -> String {
        "\"\(abs(url.lastPathComponent.hashValue))-\(size)\""
    }

    private func entry(_ href: String, url: URL, collection: Bool) -> String {
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        var props = collection ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
        if !collection, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
            props += "<d:getcontentlength>\(size)</d:getcontentlength>"
            props += "<d:getetag>\(Self.etag(url, size: size).replacingOccurrences(of: "\"", with: "&quot;"))</d:getetag>"
        }
        return "<d:response><d:href>\(encoded)</d:href><d:propstat><d:prop>\(props)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
}

/// A WebDAV server as the model sees it, backed by the real engine on a shared in-memory store
/// (`MemoryRemote`): two models (two devices) connected to it sync through it for real. Faults are
/// injected per call (`failNext`, `gate`).
final class EngineWebDAVRemote: WebDAVRemote, @unchecked Sendable {
    let store: MemoryStore
    private let lock = NSLock()
    private var _runs = 0, _twoWay = 0, _fetches = 0
    private var _failure: (any Error)?
    private var _gate: DispatchSemaphore?
    private var _fetchGate: DispatchSemaphore?
    private var _faults: MemoryFaults?

    init(store: MemoryStore) { self.store = store }

    var remote: MemoryRemote { lock.lock(); defer { lock.unlock() }; return MemoryRemote(store: store, base: ["vault"], faults: _faults) }
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
    var twoWayRuns: Int { lock.lock(); defer { lock.unlock() }; return _twoWay }
    /// Every run throws this until it is cleared (the server gone, offline).
    func failing(_ error: (any Error)?) { lock.lock(); _failure = error; lock.unlock() }
    /// Runs wait for this before they start (a slow server).
    func gating(_ gate: DispatchSemaphore?) { lock.lock(); _gate = gate; lock.unlock() }
    /// Seeded transport faults on every operation (cut bodies, lost answers...).
    func faulting(_ faults: MemoryFaults?) { lock.lock(); _faults = faults; lock.unlock() }

    private func enter(twoWay: Bool) throws -> MemoryRemote {
        lock.lock()
        _runs += 1
        if twoWay { _twoWay += 1 }
        let failure = _failure, gate = _gate
        lock.unlock()
        gate?.wait()
        if let failure { throw failure }
        return remote
    }

    func check(_ endpoint: WebDAVEndpoint) -> WebDAVProbe { .failed(.notFound, message: "not used", certificate: nil) }
    func download(_ endpoint: WebDAVEndpoint, into copy: LocalCopy) throws -> SyncReport {
        try copy.download(remote: remote)
    }
    func downloadMetadata(_ endpoint: WebDAVEndpoint, into copy: LocalCopy, options: SyncOptions) throws -> SyncReport {
        try copy.downloadMetadata(remote: remote, options: options)
    }
    func fetch(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, scope: FetchScope) throws -> SyncReport {
        lock.lock(); let failure = _failure, fetchGate = _fetchGate; _fetches += 1; lock.unlock()
        fetchGate?.wait()
        if let failure { throw failure }   // offline: an on-demand fetch fails like a run
        return try copy.fetch(remote: remote, vault: vault, scope: scope)
    }
    /// On-demand fetches wait for this before they start (a fetch queued behind a long fill run).
    func gatingFetches(_ gate: DispatchSemaphore?) { lock.lock(); _fetchGate = gate; lock.unlock() }
    /// On-demand fetches made (`AppModel+Join`).
    var fetches: Int { lock.lock(); defer { lock.unlock() }; return _fetches }
    func push(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.push(remote: try enter(twoWay: false), vault: vault, options: options)
    }
    func sync(_ endpoint: WebDAVEndpoint, copy: LocalCopy, vault: Vault?, options: SyncOptions) throws -> SyncReport {
        try copy.sync(remote: try enter(twoWay: true), vault: vault, options: options)
    }
    func redownload(_ endpoint: WebDAVEndpoint, copy: LocalCopy, identities: [any AgeIdentity],
                    partial: Bool, options: SyncOptions) throws -> (report: SyncReport, replaced: Bool) {
        try copy.redownload(remote: remote, identities: identities, partial: partial, options: options)
    }
}

/// The fixture vault as a server's listing, and the model's WebDAV settings the sync suites share.
enum WebDAVFixture {
    /// The listing of `vault` (its id from `vault.json`), read off the main actor.
    @concurrent static func listing(of vault: URL, name: String, url: String) async throws -> WebDAVVaultListing {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: vault.appendingPathComponent("vault.json")))
        let vaultId = try #require((manifest as? [String: Any])?["vaultId"] as? String).lowercased()
        return WebDAVVaultListing(path: [], name: name, vaultId: vaultId, format: "sempere/1", url: url)
    }

    /// The fixture vault uploaded to `server` by a keyless run (as the CLI's first push), off the main actor.
    @concurrent static func seed(_ server: EngineWebDAVRemote, from vault: URL) async throws -> SyncReport {
        try SyncEngine(directory: vault, vault: nil, remote: server.remote,
                       stateURL: vault.deletingLastPathComponent().appendingPathComponent("seed.json"),
                       options: SyncOptions()).run()
    }

    /// An image attachment of `size` bytes (6 MB by default) placed on a new page of `note` in `vault`, as another
    /// writer of this device's copy would (its own device state), off the main actor: the blob's reference and its bytes.
    @concurrent static func writeBigAttachment(to note: UUID, in vault: Vault, size: Int = 6 << 20) async throws
        -> (ref: BlobRef, bytes: Data) {
        var bytes = Data(count: size)
        for i in stride(from: 0, to: bytes.count, by: 997) { bytes[i] = UInt8(truncatingIfNeeded: i) }
        let ref = try vault.writeBlob(note: note, bytes, type: "image/png")
        let page = UUID()
        _ = try vault.apply([.addPage(Page(id: page, order: "z")),
                             .addItem(page: page, item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                               frame: Rect(x: 0, y: 0, w: 40, h: 30), z: "a"))],
                            to: note, deviceState: TS.deviceStateURL(), app: "test/0")
        return (ref, bytes)
    }

    /// A model on `remote` with the short ticks of the sync suites, and its library.
    @MainActor static func device(_ remote: any WebDAVRemote, trust: (any EpochTrustStore)? = nil) -> (AppModel, VaultLibrary) {
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), editorDebounce: .milliseconds(50), trust: trust)
        model.webdavRemote = remote
        model.webdavPasswords = MemoryWebDAVPasswordStore()
        model.webdavTick = .milliseconds(20)
        model.webdavWriteDelay = 0.05
        let library = VaultLibrary(storeURL: TestTemp.root.appendingPathComponent("recents-\(UUID().uuidString).json"))
        return (model, library)
    }
}
