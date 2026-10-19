import Age
import Foundation
import Sempere
import SempereSync
import SempereWebDAV
import Testing
@testable import SempereApp

/// A read-only WebDAV server over a local folder (PROPFIND Depth 1 and GET),
/// so the app tests run the library's real metadata pulls, fetches and
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

/// Opening a WebDAV vault without downloading everything first (W2,
/// docs/io.md "WebDAV vaults in the app", format.md §1.2): the root files and
/// note list, then the notes in the background through the iCloud machinery.
@MainActor
struct WebDAVPartialAppTests {
    let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func copy(_ s: WebDAVAppTests.Setup, _ id: UUID) throws -> LocalCopy {
        s.model.webdavLocations.copy(of: try #require(s.model.webdavLocations.location(id)))
    }

    @Test func opensFromTheNoteListAndFillsInTheBackground() async throws {
        let s = try WebDAVAppTests.setup()
        s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        #expect(c.isPartial && c.isUsable)
        #expect(s.remote.downloads == 1, "one metadata pull")
        #expect(Set(PartialCopyState.incompleteNotes(c.folder)) == [first.uuidString.lowercased(), second.uuidString.lowercased()])
        #expect(s.model.isCloudVault, "the iCloud machinery runs the copy")
        #expect(s.model.cloudSource == .server("dav.example.org"))
        #expect(s.model.cloudHooks.source == .server("dav.example.org"))

        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil { s.model.pendingNoteIDs == [first, second] })
        #expect(s.model.cloudSync?.isDownloading == true)
        #expect(s.model.cloudSync?.headline.contains("dav.example.org") == true)
        #expect(await TS.waitUntil { s.model.notes.count == 2 }, "pending rows")

        s.remote.openFetchGate()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { s.model.pendingNoteIDs.isEmpty && !c.isPartial })
        #expect(s.model.notes.allSatisfy { !$0.title.isEmpty || $0.problem == nil })
        s.model.close()
        #expect(s.model.cloudSource == .iCloudDrive)
    }

    @Test func rowsComeFromTheServersSummaries() async throws {
        let s = try WebDAVAppTests.setup()
        // The server publishes its summaries (format.md §12), as `sync webdav --web-viewer` does.
        let identity = try IdentityFile.parse(s.key)
        let serverVault = try Vault.open(at: s.remote.server, identities: [identity])
        let entries = try serverVault.publishedSummaryEntries().entries
        try serverVault.sealPublishedSummaries(entries).write(to: s.remote.server.appendingPathComponent(PublishedSummaries.fileName))
        s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
        _ = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        try await s.model.unlock(identityText: s.key)
        let expected = Set(entries.values.map(\.title))
        #expect(await TS.waitUntil { Set(s.model.notes.map(\.title)) == expected }, "titles before any revision arrived")
        #expect(s.model.placeholderNoteIDs.isEmpty)
        #expect(s.model.pendingNoteIDs == [first, second])
        s.remote.openFetchGate()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { s.model.pendingNoteIDs.isEmpty })
        s.model.close()
    }

    @Test func aNoteOpenedFirstIsFetchedFirst() async throws {
        let s = try WebDAVAppTests.setup()
        let c = LocalCopy(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                folderName: "Notes.sempere")
        #expect(try c.downloadMetadata(client: s.remote.folderClient()).errors.isEmpty)
        // Asked for the second note before it starts: that note is the first fetch.
        let recorded = ScopeLog()
        let remote = s.remote
        let fetcher = WebDAVFetcher(copy: c, serverName: "dav.example.org", fillsBlobs: true, fetch: { scope, vault in
            recorded.append(scope)
            return try remote.fetch(WebDAVEndpoint(url: URL(string: "https://dav.example.org/notes/")!),
                                    copy: c, vault: vault, scope: scope)
        }, changed: { _, _, _ in })
        fetcher.want(note: second)
        fetcher.start()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { !c.isPartial })
        #expect(recorded.scopes.first?.notes == [second], "\(recorded.scopes)")
        #expect(recorded.scopes.count >= 3, "then the rest, then the attachments in the background")
        fetcher.stop()
        try? c.remove()
    }

    @Test func hooksDescribeThePartialCopy() async throws {
        let s = try WebDAVAppTests.setup()
        s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        let hooks = s.model.cloudHooks
        let note = c.folder.appendingPathComponent("notes/\(first.uuidString.lowercased())")
        #expect(hooks.isUbiquitous(c.folder))
        #expect(hooks.state(.init(url: note.appendingPathComponent("x.delta.age"), placeholder: false)) == .missing)
        #expect(hooks.state(.init(url: c.folder.appendingPathComponent("vault.json"), placeholder: false)) == .current)
        #expect(throws: CloudVault.CloudError.noteNotLocal(missing: 0, total: 0, source: .server("dav.example.org"))) {
            try CloudVault.requireLocal(note: first, vault: c.folder, hooks: hooks)
        }
        // The pending stand-ins read as iCloud placeholders do.
        #expect(CloudPlaceholder.realName(of: ".abc.pdf.age.sempere-pending") == "abc.pdf.age")
        #expect(CloudPlaceholder.realName(of: PartialCopy.noteMarkerName) == nil)
        s.remote.openFetchGate()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { PartialCopyState.incompleteNotes(c.folder).isEmpty })
        #expect(throws: Never.self) { try CloudVault.requireLocal(note: first, vault: c.folder, hooks: hooks) }
        s.model.close()
    }

    /// Attachments arrive on demand (`CloudBlobs`), and only then with the background fill off.
    @Test func attachmentsArriveOnDemand() async throws {
        let s = try WebDAVAppTests.setup()
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: AppModel.webdavFillsBlobsKey)
        defaults.set(false, forKey: AppModel.webdavFillsBlobsKey)
        defer { defaults.set(before, forKey: AppModel.webdavFillsBlobsKey) }
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { PartialCopyState.incompleteNotes(c.folder).isEmpty })
        let pending = PartialCopyState.pendingBlobsByNote(c.folder)
        let (noteDir, names) = try #require(pending.first, "the fixture has an attachment")
        let note = try #require(UUID(uuidString: noteDir))
        let name = try #require(names.first)
        try await Task.sleep(for: .milliseconds(200))
        #expect(PartialCopyState.pendingBlobsByNote(c.folder)[noteDir]?.contains(name) == true, "not fetched in the background")
        try await CloudVault.downloadBlob(note: note, fileName: name, vault: c.folder, hooks: s.model.cloudHooks,
                                          stallTimeout: .seconds(10), pollInterval: .milliseconds(20))
        #expect(FileManager.default.fileExists(atPath: c.folder.appendingPathComponent("notes/\(noteDir)/att/\(name)").path))
        #expect(await TS.waitUntil { !c.isPartial }, "the last blob completes the copy")
        s.model.close()
    }

    @Test func offlineFetchesReportTheServerAndRetry() async throws {
        let s = try WebDAVAppTests.setup()
        s.model.cloudStallTimeout = .milliseconds(600)
        s.model.cloudPollInterval = .milliseconds(50)
        s.remote.set { $0.fetchError = WebDAVError.offline("The Internet connection appears to be offline.") }
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        try await s.model.unlock(identityText: s.key)
        // Nothing arrives: the list's bar names the server, and opening the note says so too.
        #expect(await TS.waitUntil(timeout: .seconds(10)) { s.model.cloudSync?.problem?.contains("dav.example.org") == true })
        await #expect(throws: AppModel.ModelError.noteNotDownloadedFromServer("dav.example.org")) {
            try await s.model.downloadNote(first)
        }
        s.remote.set { $0.fetchError = nil }
        s.model.cloudStallTimeout = .seconds(10)
        try await s.model.downloadNote(first)
        #expect(!PartialCopyState.incompleteNotes(c.folder).contains(first.uuidString.lowercased()))
        s.model.close()
    }

    @Test func downloadingAgainMakesAPartialCopy() async throws {
        let s = try WebDAVAppTests.setup()
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil(timeout: .seconds(10)) { !c.isPartial })
        s.remote.set { $0.fetchGate = DispatchSemaphore(value: 0) }
        try await s.model.downloadWebDAVAgain(library: s.library)
        #expect(c.isPartial, "every note is checked against the server again")
        #expect(s.model.phase == .unlocked)
        s.remote.openFetchGate()
        #expect(await TS.waitUntil(timeout: .seconds(10)) { !c.isPartial && s.model.pendingNoteIDs.isEmpty })
        s.model.close()
    }
}

/// The scopes a fetcher asked for.
final class ScopeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FetchScope] = []
    var scopes: [FetchScope] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ s: FetchScope) { lock.lock(); stored.append(s); lock.unlock() }
}
