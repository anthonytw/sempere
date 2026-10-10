import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// `--push-only`: a mirror to a server that is not trusted to write back.
final class PushOnlyTests: BlobSyncTestCase {
    @discardableResult
    func push(_ server: MockDAV, vault: Vault?? = nil, dryRun: Bool = false, deleteExtraneous: Bool = false) throws -> SyncReport {
        try push("A", server, vault: vault, dryRun: dryRun, deleteExtraneous: deleteExtraneous)
    }

    @discardableResult
    func push(_ name: String, _ server: MockDAV, vault: Vault?? = nil, dryRun: Bool = false,
              deleteExtraneous: Bool = false) throws -> SyncReport {
        var o = WebDAVSyncOptions(dryRun: dryRun, deviceLabel: name)
        o.pushOnly = true
        o.deleteExtraneous = deleteExtraneous
        let v: Vault? = vault ?? (try? openVault(name))
        return try WebDAVSync(directory: dir(name), vault: v, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: o).run()
    }

    /// Every file under the vault folder, by relative path.
    func tree(_ name: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir(name)
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out[String(u.path.dropFirst(base.path.count))] = try Data(contentsOf: u)
        }
        return out
    }

    func noteRel(_ file: String) -> String { "notes/\(id)/\(file)" }

    /// A revision file from another vault, as an attacker would plant it.
    func foreignRevision() throws -> (name: String, data: Data) {
        let other = try makeVault("X")
        let r = try delta(other, device: devB, t: 99, title: "planted")
        return (r.name.filename, try Data(contentsOf: dir("X").appendingPathComponent(noteRel(r.name.filename))))
    }

    func testFirstPushUploadsEverythingAndIsIdempotent() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "image/png")
        try referencing(a, device: devA, t: 5, [ref])
        let before = try tree("A")
        let r = try push(server)
        XCTAssertTrue(r.errors.isEmpty, "\(r)")
        XCTAssertTrue(r.downloaded.isEmpty && r.extraneous.isEmpty && r.overwritten.isEmpty)
        XCTAssertTrue(r.uploaded.contains("vault.json") && r.uploaded.contains(noteRel(d.name.filename)))
        XCTAssertEqual(r.uploaded.filter { $0.contains("/att/") }.count, 1)
        XCTAssertEqual(try tree("A"), before)
        XCTAssertTrue(try push(server).isEmpty)
        // A second device can read the mirror with the ordinary two-way sync.
        XCTAssertEqual(try sync("B", server).downloaded.count, r.uploaded.count)
    }

    func testServerSideManifestChangeIsOverwrittenNeverCopied() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try push(server)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try vaultJSON("A")) as? [String: Any])
        json["recipients"] = (json["recipients"] as? [String] ?? []) + ["age1attacker"]
        server.putDirect("vault.json", try JSONSerialization.data(withJSONObject: json))
        let before = try tree("A")
        let r = try push(server)
        XCTAssertEqual(r.overwritten, ["vault.json"])
        XCTAssertEqual(r.uploaded, ["vault.json"])
        XCTAssertTrue(r.downloaded.isEmpty && r.conflicts.isEmpty && r.errors.isEmpty, "\(r)")
        XCTAssertEqual(server.file("vault.json"), try vaultJSON("A"))
        XCTAssertEqual(try tree("A"), before, "nothing local changes, no conflict file")
        XCTAssertTrue(try push(server).isEmpty)
    }

    func testMalformedServerManifestIsRepaired() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try push(server)
        server.putDirect("vault.json", Data("not json".utf8))
        let r = try push(server)
        XCTAssertEqual(r.overwritten, ["vault.json"], "\(r)")
        XCTAssertEqual(server.file("vault.json"), try vaultJSON("A"))
    }

    func testOtherVaultOnTheServerStillAbortsBeforeAnyChange() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        _ = try makeVault("B")
        try push("B", server)
        let log = server.requestLog.count
        XCTAssertThrowsError(try push("A", server)) {
            guard case WebDAVError.vaultMismatch = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(server.requestLog.dropFirst(log).contains { $0.method == "PUT" || $0.method == "DELETE" })
    }

    func testServerOnlyJournalAndInjectedRevisionAreExtraneous() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        try push(server)
        let evil = try foreignRevision()
        server.putDirect(noteRel(evil.name), evil.data)
        server.putDirect("rewrap-journal.json", Data("{}".utf8))
        let before = try tree("A")

        let r = try push(server)
        XCTAssertEqual(Set(r.extraneous), [noteRel(evil.name), "rewrap-journal.json"], "\(r)")
        XCTAssertTrue(r.downloaded.isEmpty && r.deleted.isEmpty && r.errors.isEmpty)
        XCTAssertNotNil(server.file(noteRel(evil.name)))
        XCTAssertEqual(try tree("A"), before)
        XCTAssertEqual(try fileNames(try openVault("A")), [d.name.filename])

        let dry = try push(server, dryRun: true, deleteExtraneous: true)
        XCTAssertEqual(Set(dry.deleted.map(\.path)), Set(r.extraneous))
        XCTAssertNotNil(server.file(noteRel(evil.name)), "dry run changes nothing")

        let gone = try push(server, deleteExtraneous: true)
        XCTAssertEqual(Set(gone.deleted.map(\.path)), Set(r.extraneous))
        XCTAssertTrue(gone.deleted.allSatisfy { $0.side == "remote" })
        XCTAssertNil(server.file(noteRel(evil.name)))
        XCTAssertNil(server.file("rewrap-journal.json"))
        XCTAssertEqual(try tree("A"), before)
    }

    func testInjectedBlobAndJunkAreExtraneous() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try push(server)
        let blob = String(repeating: "0", count: 64) + ".image.age"
        server.putDirect("notes/\(id)/att/\(blob)", Data("age-encryption.org/v1\nx".utf8))
        server.putDirect("notes/\(id)/stray.txt", Data("x".utf8))
        let before = try tree("A")
        let r = try push(server)
        XCTAssertEqual(Set(r.extraneous), ["notes/\(id)/att/\(blob)", "notes/\(id)/stray.txt"], "\(r)")
        XCTAssertEqual(try tree("A"), before)
        XCTAssertNotNil(server.file("notes/\(id)/att/\(blob)"))
        let gone = try push(server, deleteExtraneous: true)
        XCTAssertTrue(gone.errors.isEmpty, "\(gone)")
        XCTAssertNil(server.file("notes/\(id)/att/\(blob)"))
        XCTAssertNil(server.file("notes/\(id)/stray.txt"))
        XCTAssertEqual(try tree("A"), before)
    }

    func testFilesDeletedOnTheServerAreUploadedAgainNotDeletedLocally() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(3000), type: "image/png")
        try referencing(a, device: devA, t: 5, [ref])
        let name = try blobFile(a, ref)
        try push(server)
        // Even a blob nothing references is restored: only local decisions delete.
        server.removeDirect(noteRel(d.name.filename))
        server.removeDirect("notes/\(id)/att/\(name)")
        let before = try tree("A")
        let r = try push(server)
        XCTAssertEqual(Set(r.uploaded), [noteRel(d.name.filename), "notes/\(id)/att/\(name)"], "\(r)")
        XCTAssertTrue(r.deleted.isEmpty && r.downloaded.isEmpty)
        XCTAssertEqual(try tree("A"), before)
        XCTAssertNotNil(server.file(noteRel(d.name.filename)))
    }

    func testCompactionDeletionsFollowToTheServer() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ds = [try delta(a, device: devA, t: 0, title: "1"), try delta(a, device: devA, t: 10, title: "2")]
        var clock = HybridClock()
        let snap = try a.snapshot(noteId: noteID, device: devA, clock: &clock,
                                  wall: Date(timeIntervalSince1970: Double(baseMillis + 30) / 1000), app: "test/0")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let blob = try blobFile(a, unused)
        try push(server)
        _ = try a.compact(noteId: noteID, retention: 0, now: Date(timeIntervalSince1970: 1_800_000_000))
        var state = BlobCollectorState()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0)
        XCTAssertEqual(try a.collectBlobs(note: noteID, state: &state, now: t0.addingTimeInterval(31 * 86400)).deleted, [blob])
        let before = try tree("A")

        let dry = try push(server, vault: .some(try openVault("A")), dryRun: true)
        XCTAssertEqual(dry.deleted.count, 3, "\(dry)")
        XCTAssertEqual(server.names(under: "notes/\(id)").count, 4, "dry run deletes nothing")

        let r = try push(server)
        XCTAssertTrue(r.deleted.allSatisfy { $0.side == "remote" })
        XCTAssertEqual(Set(r.deleted.map(\.path)),
                       Set(ds.map { noteRel($0.name.filename) } + ["notes/\(id)/att/\(blob)"]), "\(r)")
        XCTAssertEqual(server.names(under: "notes/\(id)"), [snap.name.filename])
        XCTAssertTrue(r.extraneous.isEmpty && r.errors.isEmpty)
        XCTAssertEqual(try tree("A"), before)
        XCTAssertTrue(try push(server).isEmpty)
    }

    /// A local deletion no compaction explains (or a locked vault) is neither
    /// propagated nor restored, even with --delete-extraneous: the file may
    /// only be missing from an evicted iCloud folder.
    func testUnexplainedLocalDeletionIsKeptOnTheServer() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d1 = try delta(a, device: devA, t: 0, title: "1")
        _ = try delta(a, device: devA, t: 10, title: "2")
        try push(server)
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent(noteRel(d1.name.filename)))
        let before = try tree("A")
        for locked in [false, true] {
            let r = try push(server, vault: locked ? .some(nil) : nil, deleteExtraneous: true)
            XCTAssertTrue(r.deleted.isEmpty && r.extraneous.isEmpty && r.downloaded.isEmpty, "\(r)")
            XCTAssertEqual(r.skipped.map(\.path), [noteRel(d1.name.filename)])
            XCTAssertNotNil(server.file(noteRel(d1.name.filename)))
            XCTAssertEqual(try tree("A"), before)
        }
    }

    /// On a first sync (no state) every server file looks never synced,
    /// including those of a note the local listing missed (an iCloud folder
    /// not listed yet): --delete-extraneous lists them and deletes nothing.
    func testFirstSyncNeverDeletesExtraneousFiles() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let d = try delta(a, device: devA, t: 0, title: "one")
        try push(server)
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("state-A.json"))
        try FileManager.default.removeItem(at: dir("A").appendingPathComponent(noteRel(d.name.filename)))
        let log = server.requestLog.count
        let r = try push(server, deleteExtraneous: true)
        XCTAssertEqual(r.extraneous, [noteRel(d.name.filename)], "\(r)")
        XCTAssertTrue(r.deleted.isEmpty && r.errors.isEmpty, "\(r)")
        XCTAssertTrue(r.skipped.contains { $0.path == noteRel(d.name.filename) && $0.message.contains("first sync") }, "\(r)")
        XCTAssertNotNil(server.file(noteRel(d.name.filename)))
        XCTAssertFalse(server.requestLog.dropFirst(log).contains { $0.method == "DELETE" })
    }

    /// The library refuses a push-only run without a local vault.json (the
    /// CLI checks too): everything on the server would be extraneous.
    func testPushOnlyNeedsALocalVault() throws {
        let server = MockDAV()
        _ = try makeVault("A")
        try push(server)
        try FileManager.default.createDirectory(at: dir("C"), withIntermediateDirectories: true)
        let log = server.requestLog.count
        XCTAssertThrowsError(try push("C", server, vault: .some(nil), deleteExtraneous: true))
        XCTAssertEqual(server.requestLog.count, log, "nothing is sent")
        XCTAssertNotNil(server.file("vault.json"))
    }

    /// A stray server journal blocks blob collection there (§8.1.6 rule 2)
    /// until it is actually gone: a failed DELETE of it keeps the blobs.
    func testStrayJournalStillBlocksBlobDeletionWhenItsRemovalFails() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "1")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let blob = try blobFile(a, unused)
        try push(server)
        var state = BlobCollectorState()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0)
        XCTAssertEqual(try a.collectBlobs(note: noteID, state: &state, now: t0.addingTimeInterval(31 * 86400)).deleted, [blob])
        server.putDirect("rewrap-journal.json", Data("{}".utf8))
        server.interceptor = { r in
            r.method == "DELETE" && r.url.lastPathComponent == "rewrap-journal.json" ? WebDAVResponse(status: 503) : nil
        }
        let r = try push(server, deleteExtraneous: true)
        XCTAssertTrue(r.errors.contains { $0.path == "rewrap-journal.json" }, "\(r)")
        XCTAssertNotNil(server.file("notes/\(id)/att/\(blob)"), "\(r)")
        server.interceptor = nil
        let ok = try push(server, deleteExtraneous: true)
        XCTAssertNil(server.file("rewrap-journal.json"))
        XCTAssertNil(server.file("notes/\(id)/att/\(blob)"), "\(ok)")
    }

    func testDryRunChangesNothingAnywhere() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        let before = try tree("A")
        let r = try push(server, dryRun: true)
        XCTAssertTrue(r.dryRun)
        XCTAssertGreaterThan(r.uploaded.count, 1)
        XCTAssertFalse(server.requestLog.contains { ["PUT", "DELETE", "MOVE", "MKCOL"].contains($0.method) })
        XCTAssertEqual(try tree("A"), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("state-A.json").path))
    }

    func testReportJSONKeepsItsShapeAndGainsTheNewCategories() throws {
        let data = try JSONEncoder().encode(SyncReport())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["dryRun", "uploaded", "downloaded", "deleted", "conflicts", "errors", "skipped",
                              "ignored", "rejected", "extraneous", "overwritten", "quarantined", "merged"])
    }
}
