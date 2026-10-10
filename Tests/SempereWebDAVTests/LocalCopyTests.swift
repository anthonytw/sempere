import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// The app's WebDAV vaults: a local copy downloaded once, pushed with
/// push-only runs that keep other writers' manifests, and downloaded again on
/// demand (docs/io.md, "WebDAV vaults in the app").
final class LocalCopyTests: BlobSyncTestCase {
    func copy(_ name: String) -> WebDAVLocalCopy {
        WebDAVLocalCopy(directory: tmp.appendingPathComponent("loc-\(name)"), folderName: "V.sempere")
    }

    func openCopy(_ c: WebDAVLocalCopy) throws -> Vault { try Vault.open(at: c.folder, identities: [identity]) }

    /// Pushes vault `name` the way `sempere sync webdav --push-only` does.
    @discardableResult
    func mirror(_ name: String, _ server: MockDAV, keep: Bool = false) throws -> SyncReport {
        var o = WebDAVSyncOptions(deviceLabel: name)
        o.pushOnly = true
        o.keepServerChanges = keep
        return try WebDAVSync(directory: dir(name), vault: try openVault(name), client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    func revisionFiles(_ folder: URL) -> Set<String> {
        var out = Set<String>()
        let notes = folder.appendingPathComponent("notes")
        for id in (try? FileManager.default.contentsOfDirectory(atPath: notes.path)) ?? [] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent(id).path)) ?? []
            where f.hasSuffix(".age") {
                out.insert("\(id)/\(f)")
            }
        }
        return out
    }

    // MARK: - keepServerChanges

    func testKeepServerChangesKeepsAManifestAnotherWriterChanged() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try mirror("A", server, keep: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try vaultJSON("A")) as? [String: Any])
        json["labels"] = ["changed elsewhere"]
        let theirs = try JSONSerialization.data(withJSONObject: json)
        server.putDirect("vault.json", theirs)
        let d = try delta(a, device: devA, t: 1, title: "two")
        let r = try mirror("A", server, keep: true)
        XCTAssertEqual(r.conflicts.map(\.path), ["vault.json"], "\(r)")
        XCTAssertNil(r.conflicts.first?.remoteCopy, "a push-only run writes no conflict copy")
        XCTAssertTrue(r.overwritten.isEmpty)
        XCTAssertEqual(server.file("vault.json"), theirs, "the server's copy is kept")
        XCTAssertTrue(r.uploaded.contains("notes/\(id)/\(d.name.filename)"), "notes still upload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("A").appendingPathComponent("vault.json.conflict").path))
        // Reported again on every run while the copies differ.
        XCTAssertEqual(try mirror("A", server, keep: true).conflicts.map(\.path), ["vault.json"])
        // Without the option the push-only run replaces it, as before.
        XCTAssertEqual(try mirror("A", server).overwritten, ["vault.json"])
    }

    func testKeepServerChangesReplacesWhatOnlyThisDeviceChanged() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server, keep: true)
        // The same manifest, serialized differently: a local change the server never saw.
        let obj = try JSONSerialization.jsonObject(with: try vaultJSON("A"))
        let rewritten = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        XCTAssertNotEqual(rewritten, try vaultJSON("A"))
        try rewritten.write(to: dir("A").appendingPathComponent("vault.json"))
        let r = try mirror("A", server, keep: true)
        XCTAssertEqual(r.overwritten, ["vault.json"], "\(r)")
        XCTAssertTrue(r.conflicts.isEmpty)
        XCTAssertEqual(server.file("vault.json"), rewritten)
    }

    func testKeepServerChangesWithoutAnEarlierSyncKeepsADifferingManifest() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        server.putDirect("vault.json", Data("not json".utf8))
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
        let r = try mirror("A", server, keep: true)
        XCTAssertEqual(r.conflicts.map(\.path), ["vault.json"])
        XCTAssertEqual(server.file("vault.json"), Data("not json".utf8))
    }

    // MARK: - Download and push

    func testDownloadThenPushRoundTrip() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(3000), type: "image/png")
        try referencing(a, device: devA, t: 5, [ref])
        try mirror("A", server)

        let c = copy("iPad")
        XCTAssertFalse(c.exists)
        let down = try c.download(client: try client(server))
        XCTAssertTrue(down.errors.isEmpty && down.uploaded.isEmpty, "\(down)")
        XCTAssertTrue(c.exists)
        XCTAssertEqual(revisionFiles(c.folder), revisionFiles(dir("A")))
        XCTAssertEqual(c.unconfirmedChanges(), 0)

        let v = try openCopy(c)
        XCTAssertEqual(try v.reconstruct(noteId: noteID).meta.title, "one")
        let d = try delta(v, device: devB, t: 9, title: "edited on the iPad")
        XCTAssertEqual(c.unconfirmedChanges(), 1)
        let up = try c.push(client: try client(server), vault: v)
        XCTAssertEqual(up.uploaded, ["notes/\(id)/\(d.name.filename)"], "\(up)")
        XCTAssertTrue(up.downloaded.isEmpty && up.conflicts.isEmpty && up.errors.isEmpty)
        XCTAssertEqual(c.unconfirmedChanges(), 0)
        XCTAssertNotNil(server.file("notes/\(id)/\(d.name.filename)"))
        XCTAssertTrue(try c.push(client: try client(server), vault: v).isEmpty)
    }

    func testUnconfirmedChangesCountBlobsAndTheManifest() throws {
        let server = MockDAV()
        // A first write tags the vault (format.md §2.1), which changes vault.json: done before the mirror.
        _ = try delta(try makeVault("A"), device: devA, t: 0, title: "one")
        try mirror("A", server)
        let c = copy("iPad")
        _ = try c.download(client: try client(server))
        let v = try openCopy(c)
        _ = try v.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        XCTAssertEqual(c.unconfirmedChanges(), 2, "the blob, and vault.json: the first blob adds the attachments feature")
        _ = try c.push(client: try client(server), vault: v)
        XCTAssertEqual(c.unconfirmedChanges(), 0)
        _ = try v.writeBlob(note: noteID, syntheticBlob(200), type: "image/png")
        XCTAssertEqual(c.unconfirmedChanges(), 1)
    }

    func testDownloadNeedsAVaultOnTheServer() throws {
        let server = MockDAV()
        let c = copy("iPad")
        XCTAssertThrowsError(try c.download(client: try client(server))) {
            guard case WebDAVError.io = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.folder.path), "nothing is created")
        XCTAssertFalse(server.requestLog.contains { $0.method != "PROPFIND" })
    }

    func testAnInterruptedDownloadContinues() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        for t in 0..<4 { _ = try delta(a, device: devA, t: Int64(t), title: "t\(t)", note: UUID()) }
        try mirror("A", server)
        let c = copy("iPad")
        let gets = RequestCounter()
        server.interceptor = { r in
            // The third revision GET fails as if the network dropped.
            guard r.method == "GET", r.url.path.hasSuffix(".age") else { return nil }
            return gets.next() == 3 ? WebDAVResponse(status: 503) : nil
        }
        let first = try c.download(client: try client(server))
        XCTAssertFalse(first.errors.isEmpty, "the run reports the failure: the copy is not complete")
        server.interceptor = nil
        let second = try c.download(client: try client(server))
        XCTAssertTrue(second.errors.isEmpty && second.uploaded.isEmpty, "\(second)")
        XCTAssertEqual(second.downloaded.count, 1, "only what was missing")
        XCTAssertEqual(revisionFiles(c.folder), revisionFiles(dir("A")))
    }

    func testPushNeedsTheCopy() throws {
        XCTAssertThrowsError(try copy("iPad").push(client: try client(MockDAV()), vault: nil))
    }

    func testPushOfAnotherVaultsFolderStopsBeforeAnyChange() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let c = copy("iPad")
        _ = try c.download(client: try client(server))
        _ = try makeVault("B")
        server.removeCollection("notes")
        server.putDirect("vault.json", try vaultJSON("B"))
        let log = server.requestLog.count
        XCTAssertThrowsError(try c.push(client: try client(server), vault: try openCopy(c))) {
            XCTAssertEqual(WebDAVSyncProblem.from(error: $0), .otherVault)
        }
        XCTAssertFalse(server.requestLog.dropFirst(log).contains { $0.method == "PUT" || $0.method == "DELETE" })
    }

    // MARK: - Other writers and downloading again

    func testAnotherDevicesNotesArriveOnlyByDownloadingAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try mirror("A", server)
        let ipad = copy("iPad"), phone = copy("phone")
        _ = try ipad.download(client: try client(server))
        _ = try phone.download(client: try client(server))
        let ipadVault = try openCopy(ipad)
        let mine = try delta(ipadVault, device: devA, t: 5, title: "from the iPad", note: UUID())
        _ = try ipad.push(client: try client(server), vault: ipadVault)
        let theirs = try delta(try openCopy(phone), device: devB, t: 9, title: "from the phone", note: UUID())
        _ = try phone.push(client: try client(server), vault: try openCopy(phone))

        // The push never takes the phone's note and never deletes it.
        let r = try ipad.push(client: try client(server), vault: ipadVault)
        XCTAssertTrue(r.downloaded.isEmpty && r.deleted.isEmpty, "\(r)")
        XCTAssertTrue(r.extraneous.contains { $0.hasSuffix(theirs.name.filename) }, "\(r)")
        XCTAssertNotNil(server.file("notes/\(theirs.noteId.uuidString.lowercased())/\(theirs.name.filename)"))
        XCTAssertFalse(revisionFiles(ipad.folder).contains { $0.hasSuffix(theirs.name.filename) })

        let log = server.requestLog.count
        let again = try ipad.redownload(client: try client(server), identities: [identity])
        XCTAssertTrue(again.replaced, "\(again.report)")
        XCTAssertTrue(again.report.uploaded.isEmpty, "\(again.report)")
        let files = revisionFiles(ipad.folder)
        XCTAssertTrue(files.contains { $0.hasSuffix(theirs.name.filename) })
        XCTAssertTrue(files.contains { $0.hasSuffix(mine.name.filename) })
        let gets = server.requestLog.dropFirst(log).filter { $0.method == "GET" }.map(\.path)
        XCTAssertFalse(gets.contains { $0.hasSuffix(mine.name.filename) }, "the copy's own files are reused, not downloaded")
        XCTAssertEqual(try openCopy(ipad).reconstruct(noteId: theirs.noteId).meta.title, "from the phone")
        // The download's state became the copy's: the next push has nothing to do.
        XCTAssertEqual(ipad.unconfirmedChanges(), 0)
        XCTAssertTrue(try ipad.push(client: try client(server), vault: try openCopy(ipad)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipad.stagingFolder.path))
    }

    func testDownloadingAgainKeepsTheCopyWhenItFails() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let ipad = copy("iPad"), phone = copy("phone")
        _ = try ipad.download(client: try client(server))
        _ = try phone.download(client: try client(server))
        let theirs = try delta(try openCopy(phone), device: devB, t: 9, title: "phone")
        _ = try phone.push(client: try client(server), vault: try openCopy(phone))
        let keysDir = ipad.folder.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)
        try Data("stored key".utf8).write(to: keysDir.appendingPathComponent("age1pq-test.key.age"))
        let before = revisionFiles(ipad.folder)
        server.interceptor = { r in
            r.method == "GET" && r.url.path.hasSuffix(theirs.name.filename) ? WebDAVResponse(status: 500) : nil
        }
        let again = try ipad.redownload(client: try client(server), identities: [identity])
        XCTAssertFalse(again.replaced)
        XCTAssertFalse(again.report.errors.isEmpty)
        XCTAssertEqual(revisionFiles(ipad.folder), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipad.stagingFolder.path), "the partial copy is removed")

        server.interceptor = nil
        XCTAssertTrue(try ipad.redownload(client: try client(server), identities: [identity]).replaced)
        XCTAssertEqual(try Data(contentsOf: keysDir.appendingPathComponent("age1pq-test.key.age")), Data("stored key".utf8),
                       "keys/ (never on the server) comes along")
    }

    /// Review of #137: the re-download pulls `vault.json` into an empty folder, where nothing checked it,
    /// and the copy was then replaced by whatever the server held, another vault's included.
    func testDownloadingAgainRefusesAManifestTheKeyDoesNotVouchFor() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let ipad = copy("iPad")
        _ = try ipad.download(client: try client(server))
        let manifest = ipad.folder.appendingPathComponent("vault.json")
        let before = try Data(contentsOf: manifest)
        // Another vault's vault.json (same key, another vault id and secret), put on the server.
        _ = try makeVault("X")
        server.putDirect("vault.json", try Data(contentsOf: dir("X").appendingPathComponent("vault.json")))
        let again = try ipad.redownload(client: try client(server), identities: [identity])
        XCTAssertFalse(again.replaced, "\(again.report)")
        XCTAssertTrue(again.report.errors.contains { $0.path == "vault.json" && $0.message.contains("another vault") },
                      "\(again.report.errors)")
        XCTAssertEqual(try Data(contentsOf: manifest), before, "the copy keeps its own vault.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ipad.stagingFolder.path))
        XCTAssertNoThrow(try openCopy(ipad))
    }

    /// A key change made on another device (written with the vault's key) still arrives by downloading again.
    func testDownloadingAgainTakesAKeyChangeMadeElsewhere() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let ipad = copy("iPad"), phone = copy("phone")
        _ = try ipad.download(client: try client(server))
        _ = try phone.download(client: try client(server))
        var phoneVault = try openCopy(phone)
        let added = pqIdentity()
        _ = try phoneVault.addRecipient(added.recipient, label: "laptop")
        let pushed = try phone.push(client: try client(server), vault: phoneVault)
        XCTAssertTrue(pushed.overwritten.contains("vault.json"), "\(pushed)")
        let again = try ipad.redownload(client: try client(server), identities: [identity])
        XCTAssertTrue(again.replaced, "\(again.report)")
        XCTAssertTrue(try openCopy(ipad).recipients.contains { $0.key == added.recipient.string })
    }

    func testDownloadingAgainChecksWhatArrivesUnderTheKey() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let ipad = copy("iPad")
        _ = try ipad.download(client: try client(server))
        // A revision that is an age file of another vault, planted on the server.
        let other = try makeVault("X")
        let planted = try delta(other, device: devB, t: 99, title: "planted")
        server.putDirect("notes/\(id)/\(planted.name.filename)",
                         try Data(contentsOf: dir("X").appendingPathComponent("notes/\(id)/\(planted.name.filename)")))
        let again = try ipad.redownload(client: try client(server), identities: [identity])
        XCTAssertEqual(again.report.quarantined.count, 1, "\(again.report)")
        XCTAssertFalse(revisionFiles(ipad.folder).contains { $0.hasSuffix(planted.name.filename) })
    }

    func testRemoveDeletesTheCopyAndItsState() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try mirror("A", server)
        let c = copy("iPad")
        _ = try c.download(client: try client(server))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.stateURL.path))
        try c.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path))
        try c.remove()   // twice is fine
    }
}

/// A thread-safe counter for interceptors.
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
