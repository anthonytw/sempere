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

/// Opening a WebDAV vault without downloading everything first (W2, P7a,
/// docs/io.md "WebDAV vaults in the app", format.md §1.2): the root files and
/// note list, then the notes on demand and through the two-way runs (`AppModel+Join`).
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
        #expect(s.model.partialCopyRoot != nil)
        #expect(s.model.joinLocation?.host == "dav.example.org")

        try await s.model.unlock(identityText: s.key)
        #expect(await TS.waitUntil { s.model.pendingNoteIDs == [first, second] })
        #expect(await TS.waitUntil { s.model.notes.count == 2 }, "pending rows")

        s.remote.openFetchGate()
        try await s.model.downloadNote(first)
        try await s.model.downloadNote(second)
        #expect(s.model.pendingNoteIDs.isEmpty)
        #expect(s.model.notes.allSatisfy { !$0.title.isEmpty || $0.problem == nil })
        s.model.close()
        #expect(s.model.joinLocation == nil)
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
        try await s.model.downloadNote(first)
        try await s.model.downloadNote(second)
        #expect(s.model.pendingNoteIDs.isEmpty)
        s.model.close()
    }

    /// An attachment still a stand-in is fetched alone when a page needs it (`partialBlobFetcher`).
    @Test func attachmentsArriveOnDemand() async throws {
        let s = try WebDAVAppTests.setup()
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        try await s.model.unlock(identityText: s.key)
        try await s.model.downloadNote(first)
        try await s.model.downloadNote(second)
        #expect(PartialCopyState.incompleteNotes(c.folder).isEmpty)
        let pending = PartialCopyState.pendingBlobsByNote(c.folder)
        let (noteDir, names) = try #require(pending.first, "the fixture has an attachment")
        let note = try #require(UUID(uuidString: noteDir))
        let name = try #require(names.first)
        let fetchBlob = try #require(s.model.partialBlobFetcher())
        try await fetchBlob(note, name)
        #expect(FileManager.default.fileExists(atPath: c.folder.appendingPathComponent("notes/\(noteDir)/att/\(name)").path))
        #expect(await TS.waitUntil { !c.isPartial }, "the last blob completes the copy")
        s.model.close()
    }

    @Test func offlineFetchesReportTheServerAndRetry() async throws {
        let s = try WebDAVAppTests.setup()
        s.remote.set { $0.fetchError = WebDAVError.offline("The Internet connection appears to be offline.") }
        let id = try await s.model.connectWebDAV(s.listing, user: nil, password: "", pin: nil, library: s.library)
        let c = try copy(s, id)
        try await s.model.unlock(identityText: s.key)
        // Opening a pending note offline names the server, and nothing is waited for.
        await #expect(throws: AppModel.ModelError.noteNotDownloadedFromServer("dav.example.org")) {
            try await s.model.downloadNote(first)
        }
        #expect(s.model.pendingNoteIDs.contains(first))
        s.remote.set { $0.fetchError = nil }
        try await s.model.downloadNote(first)
        #expect(!PartialCopyState.incompleteNotes(c.folder).contains(first.uuidString.lowercased()))
        #expect(!s.model.pendingNoteIDs.contains(first))
        s.model.close()
    }

}
