import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

final class SyncTests: SyncTestCase {
    // MARK: transport safety

    func testRefusesPlainHTTPExceptLocalhost() throws {
        let server = MockDAV()
        XCTAssertThrowsError(try WebDAVClient(baseURL: URL(string: "http://dav.example.com/x/")!, transport: server)) {
            guard case WebDAVError.insecureURL = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try WebDAVClient(baseURL: URL(string: "http://192.168.1.5/x/")!, transport: server))
        XCTAssertThrowsError(try WebDAVClient(baseURL: URL(string: "ftp://localhost/x/")!, transport: server))
        XCTAssertThrowsError(try WebDAVClient(baseURL: URL(string: "https://me:pw@dav.example.com/x/")!, transport: server))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "http://localhost:8080/x/")!, transport: server))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "http://127.0.0.1:8080/x/")!, transport: server))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "http://[::1]:8080/x/")!, transport: server))
        XCTAssertNoThrow(try WebDAVClient(baseURL: URL(string: "https://dav.example.com/x/")!, transport: server))
        XCTAssertTrue(server.requestLog.isEmpty, "refusal must happen before any request")
    }

    func testBasicAuthHeaderSent() throws {
        let server = MockDAV()
        server.requiredAuthorization = "Basic " + Data("me:s3cret".utf8).base64EncodedString()
        _ = try makeVault()
        let report = try {
            let s = WebDAVSync(directory: dir("A"), vault: try openVault("A"),
                               client: try client(server, auth: .init(user: "me", password: "s3cret")),
                               stateURL: tmp.appendingPathComponent("st.json"))
            return try s.run()
        }()
        XCTAssertEqual(report.uploaded, ["vault.json"])
        let bad = WebDAVSync(directory: dir("A"), vault: nil, client: try client(server, auth: .init(user: "me", password: "no")),
                             stateURL: tmp.appendingPathComponent("st2.json"))
        XCTAssertThrowsError(try bad.run()) {
            guard case WebDAVError.http(_, _, let status) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(status, 401)
            XCTAssertFalse("\($0)".contains("no"), "errors must not echo the password")
        }
    }

    func testCreatesMissingBaseAndAncestors() throws {
        let server = MockDAV(collections: [""])
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let report = try sync("A", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(report.uploaded.count, 2)
        XCTAssertNotNil(server.file("vault.json"))
        XCTAssertEqual(try sync("B", server).downloaded.count, 2)
    }

    // MARK: transfer

    func testTwoDevicesConvergeWithConcurrentDeltas() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let r1 = try sync("A", server)
        XCTAssertEqual(r1.uploaded.sorted(), ["notes/\(noteID.uuidString.lowercased())/\(try fileNames(a)[0])", "vault.json"].sorted())
        XCTAssertTrue(r1.errors.isEmpty && r1.conflicts.isEmpty)

        // B starts from nothing.
        let r2 = try sync("B", server)
        XCTAssertEqual(r2.downloaded.count, 2, "\(r2)")
        let b = try openVault("B")
        XCTAssertEqual(try title(b), "one")

        // Concurrent deltas on both, plus a second note on B.
        _ = try delta(a, device: devA, t: 100, title: "from A")
        _ = try delta(b, device: devB, t: 200, title: "from B")
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        _ = try delta(b, device: devB, t: 210, title: "second", note: other)
        try sync("A", server); try sync("B", server); try sync("A", server)

        let a2 = try openVault("A"), b2 = try openVault("B")
        XCTAssertEqual(try a2.noteIDs(), try b2.noteIDs())
        for id in try a2.noteIDs() {
            XCTAssertEqual(try fileNames(a2, id), try fileNames(b2, id))
            XCTAssertEqual(try a2.reconstruct(noteId: id), try b2.reconstruct(noteId: id))
        }
        XCTAssertEqual(try title(a2), "from B")      // later HLC wins
        let quiet = try sync("A", server)
        XCTAssertTrue(quiet.isEmpty, "\(quiet)")
    }

    func testNeverOverwritesExistingFilesEitherSide() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        try sync("B", server)
        let rel = "notes/\(noteID.uuidString.lowercased())/\(r.name.filename)"
        let localFile = dir("A").appendingPathComponent(rel)
        // Tamper with both copies differently; neither may be replaced.
        try Data("age-encryption.org/v1\nlocal".utf8).write(to: localFile)
        server.putDirect(rel, Data("age-encryption.org/v1\nremote".utf8))
        let report = try sync("A", server)
        XCTAssertTrue(report.isEmpty, "\(report)")
        XCTAssertEqual(try Data(contentsOf: localFile), Data("age-encryption.org/v1\nlocal".utf8))
        XCTAssertEqual(server.file(rel), Data("age-encryption.org/v1\nremote".utf8))
        // Uploads are conditional so a racing server-side copy survives too.
        let put = server.requestLog.filter { $0.method == "PUT" && $0.path.hasSuffix(r.name.filename) }
        XCTAssertEqual(put.count, 1)
    }

    func testDownloadNeverLeavesPartialFile() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let rel = "notes/\(noteID.uuidString.lowercased())/\(r.name.filename)"
        // Server returns an HTML page with 200 instead of the file.
        server.putDirect(rel, Data("<html>login required</html>".utf8))
        let report = try sync("B", server)
        XCTAssertEqual(report.quarantined.map(\.path), [rel], "\(report)")
        let noteDir = dir("B").appendingPathComponent("notes/\(noteID.uuidString.lowercased())")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: noteDir.path)) ?? [], [])
        // A transport failure mid-download behaves the same.
        server.interceptor = { r in r.method == "GET" && r.url.path.hasSuffix(".age") ? WebDAVResponse(status: 500) : nil }
        var options = WebDAVSyncOptions(deviceLabel: "B")
        options.retryQuarantined = true
        let report2 = try WebDAVSync(directory: dir("B"), vault: try openVault("B"), client: try client(server),
                                     stateURL: tmp.appendingPathComponent("state-B.json"), options: options).run()
        XCTAssertEqual(report2.errors.count, 1)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: noteDir.path)) ?? [], [])
    }

    func testMalformedRemoteNamesAreIgnored() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let id = noteID.uuidString.lowercased()
        server.putDirect("notes/\(id)/garbage.txt", Data("x".utf8))
        server.putDirect("notes/\(id)/../../evil.age", Data("x".utf8))
        server.putDirect("notes/\(id)/00000-zz-1.delta.age", Data("x".utf8))
        server.putDirect("notes/\(id)/17596320000000000-aaaaaaaa-01.delta.age", Data("x".utf8))
        server.putDirect("notes/NOT-A-UUID/17596320000000000-aaaaaaaa-1.delta.age", Data("x".utf8))
        server.putDirect("notes/\(id.uppercased())/17596320000000000-aaaaaaaa-1.delta.age", Data("x".utf8))
        server.putDirect("%2e%2e/x", Data("x".utf8))
        let report = try sync("B", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(report.downloaded.count, 2)          // vault.json + the real revision
        XCTAssertGreaterThanOrEqual(report.ignored.count, 4)
        let b = try openVault("B")
        XCTAssertEqual(try fileNames(b).count, 1)
        XCTAssertEqual(try b.noteIDs(), [noteID])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir("B").path).sorted(), ["notes", "vault.json"])
    }

    func testBadXMLFailsCleanly() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        server.interceptor = { r in r.method == "PROPFIND" ? WebDAVResponse(status: 207, body: Data("<d:multistatus><oops".utf8)) : nil }
        XCTAssertThrowsError(try sync("A", server)) {
            guard case WebDAVError.malformedResponse = $0 else { return XCTFail("\($0)") }
        }
    }

    func testServerManifestWithANonUUIDIdIsNotAnotherVault() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server)
        server.putDirect("vault.json", Data(#"{"vaultId":"0123abcd"}"#.utf8))
        XCTAssertThrowsError(try sync("A", server)) {
            guard case WebDAVError.malformedResponse = $0 else { return XCTFail("\($0)") }
        }
    }

    func testRefusesDifferentVault() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server)
        _ = try makeVault("B")
        _ = try delta(try openVault("B"), device: devB, t: 0, title: "x")
        XCTAssertThrowsError(try sync("B", server)) {
            guard case WebDAVError.vaultMismatch = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(server.names(under: "notes").isEmpty)
    }

    func testDryRunChangesNothing() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let plan = try sync("A", server, dryRun: true)
        XCTAssertEqual(plan.uploaded.count, 2)
        XCTAssertTrue(server.requestLog.allSatisfy { $0.method == "PROPFIND" || $0.method == "GET" })
        XCTAssertNil(server.file("vault.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("state-A.json").path))
        try sync("A", server)
        let pull = try sync("B", server, dryRun: true)
        XCTAssertEqual(pull.downloaded.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("B").path))
    }

    // MARK: vault.json

    private func editManifest(_ name: String, label: String) throws {
        let url = dir(name).appendingPathComponent("vault.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var rec = obj["recipients"] as! [[String: Any]]
        rec[0]["label"] = label
        obj["recipients"] = rec
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
    }

    func testManifestOneSidedChangesPropagateBothWays() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server); try sync("B", server)
        try editManifest("A", label: "renamed on A")
        let up = try sync("A", server)
        XCTAssertEqual(up.uploaded, ["vault.json"])
        let down = try sync("B", server)
        XCTAssertEqual(down.downloaded, ["vault.json"])
        XCTAssertEqual(try vaultJSON("A"), try vaultJSON("B"))
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    func testManifestConflictKeepsBothCopies() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server); try sync("B", server)
        try editManifest("A", label: "A's idea")
        try editManifest("B", label: "B's idea")
        try sync("A", server)                                  // A wins the race to the server
        let before = try vaultJSON("B")
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let report = try sync("B", server, label: "B-iPad", now: now)
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts.first?.path, "vault.json")
        let copy = try XCTUnwrap(report.conflicts.first?.remoteCopy)
        XCTAssertEqual(copy, "vault.conflict-B-iPad-20251009T085320Z.json")
        XCTAssertEqual(try vaultJSON("B"), before, "the local file is never replaced")
        XCTAssertEqual(try Data(contentsOf: dir("B").appendingPathComponent(copy)), server.file("vault.json"))
        XCTAssertTrue(report.uploaded.isEmpty && report.downloaded.isEmpty)
        // The server was not touched either.
        XCTAssertEqual(server.file("vault.json"), try vaultJSON("A"))
        // Still conflicting next time, but no pile of copies.
        let again = try sync("B", server, label: "B-iPad", now: now.addingTimeInterval(60))
        XCTAssertEqual(again.conflicts.count, 1)
        XCTAssertEqual(again.conflicts.first?.remoteCopy, copy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir("B").path).filter { $0.contains("conflict") }, [copy])
        // Resolving by hand (adopting the server copy) ends it.
        try server.file("vault.json")!.write(to: dir("B").appendingPathComponent("vault.json"))
        XCTAssertTrue(try sync("B", server).conflicts.isEmpty)
    }

    func testManifestRaceOnUploadBecomesConflict() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try sync("A", server)
        try editManifest("A", label: "mine")
        // Another device replaces the file between our GET and our PUT.
        let racing = Locked(false)
        server.interceptor = { [unowned server] r in
            if r.method == "PUT", r.headers["If-Match"] != nil, !racing.value {
                racing.value = true
                server.interceptor = nil
                server.putDirect("vault.json", Data("{\"vaultId\":\"x\"}".utf8))
            }
            return nil
        }
        let report = try sync("A", server)
        XCTAssertEqual(report.conflicts.count, 1, "\(report)")
        XCTAssertEqual(server.file("vault.json"), Data("{\"vaultId\":\"x\"}".utf8))
    }

    func testRewrapJournalRemovedLocallyIsNotRestoredNorDeletedRemotely() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        let journal = dir("A").appendingPathComponent("rewrap-journal.json")
        try Data("{\"format\":\"sempere/1\"}".utf8).write(to: journal)
        try sync("A", server)
        XCTAssertNotNil(server.file("rewrap-journal.json"))
        try FileManager.default.removeItem(at: journal)
        let report = try sync("A", server)
        XCTAssertTrue(report.downloaded.isEmpty && report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertNotNil(server.file("rewrap-journal.json"))
    }

    // MARK: compaction

    /// A writes 3 deltas and a snapshot; both devices hold everything.
    private func compactionSetup(_ server: MockDAV) throws -> (Vault, [Revision], Revision) {
        let a = try makeVault("A")
        let ds = [try delta(a, device: devA, t: 0, title: "1"), try delta(a, device: devA, t: 10, title: "2"),
                  try delta(a, device: devA, t: 20, title: "3")]
        var clock = HybridClock()
        let snap = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                  wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        try sync("A", server); try sync("B", server)
        return (a, ds, snap)
    }

    func testCompactionDeletePropagatesBothWays() throws {
        let server = MockDAV()
        let (a, ds, snap) = try compactionSetup(server)
        XCTAssertEqual(try fileNames(try openVault("B")).count, 4)
        let before = try title(a)

        let deleted = try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(Set(deleted), Set(ds.map(\.name)))
        let id = noteID.uuidString.lowercased()
        let report = try sync("A", server)
        XCTAssertEqual(Set(report.deleted.map(\.path)), Set(ds.map { "notes/\(id)/\($0.name.filename)" }))
        XCTAssertTrue(report.deleted.allSatisfy { $0.side == "remote" })
        XCTAssertEqual(server.names(under: "notes/\(id)"), [snap.name.filename])

        let b = try sync("B", server)
        XCTAssertEqual(Set(b.deleted.map(\.path)), Set(ds.map { "notes/\(id)/\($0.name.filename)" }))
        XCTAssertTrue(b.deleted.allSatisfy { $0.side == "local" })
        XCTAssertEqual(try fileNames(try openVault("B")), [snap.name.filename])
        XCTAssertEqual(try title(try openVault("B")), before)
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    func testUnjustifiedLocalDeletionIsRestoredNotPropagated() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d1 = try delta(a, device: devA, t: 0, title: "1")
        let d2 = try delta(a, device: devA, t: 10, title: "2")          // no snapshot anywhere
        try sync("A", server)
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent("notes/\(noteID.uuidString.lowercased())/\(d1.name.filename)"))
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(report.downloaded.count, 1)
        XCTAssertEqual(Set(try fileNames(try openVault("A"))), [d1.name.filename, d2.name.filename])
        XCTAssertEqual(server.names(under: "notes/\(noteID.uuidString.lowercased())").count, 2)
    }

    func testUnjustifiedRemoteDeletionIsRestored() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d1 = try delta(a, device: devA, t: 0, title: "1")
        try sync("A", server)
        server.removeDirect("notes/\(noteID.uuidString.lowercased())/\(d1.name.filename)")
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertEqual(report.uploaded.count, 1)
        XCTAssertEqual(try fileNames(try openVault("A")), [d1.name.filename])
        XCTAssertEqual(server.names(under: "notes/\(noteID.uuidString.lowercased())"), [d1.name.filename])
    }

    func testWipedServerNeverDeletesLocalHistory() throws {
        let server = MockDAV()
        let (_, ds, snap) = try compactionSetup(server)
        let id = noteID.uuidString.lowercased()
        // The remote folder was emptied (or recreated): every file is "deleted on the
        // server", and the local snapshot covers the deltas. That is not a compaction:
        // a compaction always leaves its covering snapshot on the server.
        for n in server.names(under: "notes/\(id)") { server.removeDirect("notes/\(id)/\(n)") }
        let report = try sync("B", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        let all = Set(ds.map(\.name.filename) + [snap.name.filename])
        XCTAssertEqual(Set(try fileNames(try openVault("B"))), all)
        XCTAssertEqual(Set(server.names(under: "notes/\(id)")), all)
    }

    func testRemoteNamesCannotInjectControlCharacters() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let id = noteID.uuidString.lowercased()
        server.putDirect("notes/\(id)/evil\u{1B}]0;pwned\u{07}\u{1B}[2J.age", Data("x".utf8))
        server.putDirect("notes/x\u{1B}[31my/1.delta.age", Data("x".utf8))
        let report = try sync("B", server)
        XCTAssertEqual(report.ignored.count, 2, "\(report)")
        for name in report.ignored {
            XCTAssertFalse(name.unicodeScalars.contains { $0.properties.generalCategory == .control }, name)
        }
        XCTAssertTrue(report.ignored.contains { $0.contains("\\u{1B}") }, "\(report.ignored)")
    }

    func testRedirectLocationIsPrintedWithoutControlCharacters() {
        let e = WebDAVError.redirect(path: "", location: "https://x/\u{1B}]52;c;cHduZWQ=\u{07}")
        let text = e.localizedDescription
        XCTAssertFalse(text.unicodeScalars.contains { $0.properties.generalCategory == .control }, text)
    }

    func testOversizedBodyIsRefusedWhateverTheListingSaid() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let id = noteID.uuidString.lowercased()
        // The listing reports the real (small) size; the GET answers with far more.
        let limits = Locked<[Int?]>([])
        server.interceptor = { r in
            guard r.method == "GET", r.url.path.hasSuffix(d.name.filename) else { return nil }
            limits.value.append(r.maxResponseBytes)
            return WebDAVResponse(status: 200, body: WebDAVSync.ageMagic + Data(count: 4096))
        }
        try FileManager.default.createDirectory(at: dir("B"), withIntermediateDirectories: true)
        let report = try WebDAVSync(directory: dir("B"), vault: nil, client: try client(server),
                                    stateURL: tmp.appendingPathComponent("state-B.json"),
                                    options: WebDAVSyncOptions(maxFileBytes: 3000)).run()
        XCTAssertEqual(limits.value, [3000], "the transport is told the limit")
        XCTAssertEqual(report.errors.map(\.path), ["notes/\(id)/\(d.name.filename)"], "\(report)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir("B").appendingPathComponent("notes/\(id)/\(d.name.filename)").path))
        // Over the limit by the listing's size: the same error, nothing fetched.
        server.interceptor = nil
        let listed = try WebDAVSync(directory: dir("B"), vault: nil, client: try client(server),
                                    stateURL: tmp.appendingPathComponent("state-B.json"),
                                    options: WebDAVSyncOptions(maxFileBytes: 10)).run()
        XCTAssertEqual(listed.errors.map(\.message),
                       ["the response for notes/\(id)/\(d.name.filename) is over 10 bytes; not read"], "\(listed)")
        // Listings and manifests have a limit too.
        server.interceptor = { r in
            r.method == "PROPFIND" ? WebDAVResponse(status: 207, body: Data(count: WebDAVClient.defaultMaxResponseBytes + 1)) : nil
        }
        XCTAssertThrowsError(try client(server).list([])) {
            guard case WebDAVError.responseTooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    func testLockedVaultNeverPropagatesDeletions() throws {
        let server = MockDAV()
        let (a, ds, _) = try compactionSetup(server)
        try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        let locked = try Vault.open(at: dir("A"))
        let report = try sync("A", server, vault: .some(locked))
        XCTAssertTrue(report.deleted.isEmpty && report.downloaded.isEmpty, "\(report)")
        XCTAssertEqual(report.skipped.count, ds.count)
        XCTAssertEqual(server.names(under: "notes/\(noteID.uuidString.lowercased())").count, 4)
        // No vault at all behaves the same.
        let none = try sync("A", server, vault: .some(nil))
        XCTAssertTrue(none.deleted.isEmpty)
    }

    func testSnapshotSupersededByNewerOneIsDeletedEverywhere() throws {
        let server = MockDAV()
        let (a, ds, snap1) = try compactionSetup(server)
        _ = ds
        _ = try delta(a, device: devA, t: 40, title: "4")
        var clock = HybridClock()
        let snap2 = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                   wall: Date(timeIntervalSince1970: Double(baseMillis + 50) / 1000), app: "test/0")
        try sync("A", server); try sync("B", server)
        try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try fileNames(a), [snap2.name.filename])
        let ra = try sync("A", server)
        XCTAssertTrue(ra.deleted.contains { $0.path.hasSuffix(snap1.name.filename) }, "\(ra)")
        let rb = try sync("B", server)
        XCTAssertEqual(try fileNames(try openVault("B")), [snap2.name.filename], "\(rb)")
        XCTAssertEqual(try title(try openVault("B")), "4")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}
