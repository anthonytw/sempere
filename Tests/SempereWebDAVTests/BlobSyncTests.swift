import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Synthetic attachment content (never real data).
func syntheticBlob(_ n: Int, seed: UInt8 = 7) -> Data {
    var x = UInt32(seed) &* 2_654_435_761 | 1
    return Data((0..<n).map { _ in
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        return UInt8(truncatingIfNeeded: x)
    })
}

class BlobSyncTestCase: SyncTestCase {
    var id: String { noteID.uuidString.lowercased() }

    func att(_ name: String, _ note: UUID? = nil) -> URL {
        dir(name).appendingPathComponent("notes/\((note ?? noteID).uuidString.lowercased())/att")
    }

    func attEntries(_ name: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: att(name).path)) ?? []).sorted()
    }

    func blobFile(_ vault: Vault, _ ref: BlobRef) throws -> String { try vault.blobFileName(for: ref) }

    /// A delta in the test note with one image item per reference (on a new page).
    @discardableResult
    func referencing(_ vault: Vault, device: DeviceID, t: Int64, _ refs: [BlobRef]) throws -> Revision {
        let page = UUID()
        var ops: [Op] = [.addPage(Page(id: page, order: "a\(t)"))]
        for (i, r) in refs.enumerated() {
            ops.append(.addItem(page: page, item: .image(blob: r, pixelSize: Size(w: 4, h: 3),
                                                         frame: Rect(x: 10, y: 10, w: 40, h: 30), z: "a\(i)")))
        }
        let seq = try vault.nextSeq(noteId: noteID, device: device)
        let ms = baseMillis + t
        let r = Revision(noteId: noteID, device: device, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                         wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "test/0", body: .delta(ops: ops))
        try vault.write(r)
        return r
    }
}

/// Each note's `att/` through WebDAV (docs/attachments.md §4, task B3): the
/// write-once table with blobs, GC-safe deletes, hostile names, limits.
final class BlobSyncTests: BlobSyncTestCase {
    // MARK: write-once table

    /// Rows 1 and 2: a blob only one side has is copied to the other, before
    /// the revision that references it; uploads go to a temporary name and
    /// are moved into place without overwriting.
    func testNewBlobsCopyBothWaysBeforeTheirRevisions() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(70_000), type: "image/png")
        let d = try referencing(a, device: devA, t: 0, [ref])
        let name = try blobFile(a, ref)

        let up = try sync("A", server)
        XCTAssertTrue(up.errors.isEmpty, "\(up)")
        XCTAssertTrue(up.uploaded.contains("notes/\(id)/att/\(name)"), "\(up)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name], "no temporary name left")
        XCTAssertEqual(server.file("notes/\(id)/att/\(name)"), try Data(contentsOf: att("A").appendingPathComponent(name)))
        let log = server.headers
        let move = try XCTUnwrap(log.firstIndex { $0.method == "MOVE" })
        XCTAssertEqual(log[move].headers["Overwrite"], "F")
        XCTAssertTrue(log[move].headers["Destination"]?.hasSuffix("/att/\(name)") == true)
        let putTemp = try XCTUnwrap(log.firstIndex { $0.method == "PUT" && $0.path.contains("/att/.sempere-tmp-") })
        XCTAssertEqual(log[putTemp].headers["If-None-Match"], "*")
        let putDelta = try XCTUnwrap(log.firstIndex { $0.method == "PUT" && $0.path.hasSuffix(d.name.filename) })
        XCTAssertLessThan(move, putDelta, "the blob is on the server before the revision that references it")

        let down = try sync("B", server)
        XCTAssertTrue(down.errors.isEmpty, "\(down)")
        let b = try openVault("B")
        XCTAssertEqual(try b.readBlob(note: noteID, ref), syntheticBlob(70_000))
        XCTAssertEqual(attEntries("B"), [name], "no partial file left")
        let getBlob = try XCTUnwrap(server.requestLog.lastIndex { $0.method == "GET" && $0.path.hasSuffix(name) })
        let getDelta = try XCTUnwrap(server.requestLog.lastIndex { $0.method == "GET" && $0.path.hasSuffix(d.name.filename) })
        XCTAssertLessThan(getBlob, getDelta, "the blob is local before the revision that references it")
        XCTAssertTrue(b.verify().isHealthy)

        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    /// Row "both": an existing blob is never overwritten on either side,
    /// whatever the two copies hold.
    func testNeverOverwritesBlobsEitherSide() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5000), type: "application/pdf")
        let name = try blobFile(a, ref)
        try sync("A", server); try sync("B", server)
        let local = att("B").appendingPathComponent(name)
        try Data("age-encryption.org/v1\nlocal".utf8).write(to: local)
        server.putDirect("notes/\(id)/att/\(name)", Data("age-encryption.org/v1\nremote".utf8))
        XCTAssertTrue(try sync("B", server).isEmpty)
        XCTAssertEqual(try Data(contentsOf: local), Data("age-encryption.org/v1\nlocal".utf8))
        XCTAssertEqual(server.file("notes/\(id)/att/\(name)"), Data("age-encryption.org/v1\nremote".utf8))
        XCTAssertFalse(server.requestLog.contains { $0.method == "PUT" && $0.path.contains("/att/") && !$0.path.contains("tmp") })
    }

    /// A blob that reached the server by another route is not uploaded again,
    /// and the losing MOVE leaves no temporary file.
    func testUploadRaceWithSameNameKeepsServerCopy() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(3000), type: "image/jpeg")
        let name = try blobFile(a, ref)
        let path = "notes/\(id)/att/\(name)"
        server.interceptor = { [unowned server] r in
            if r.method == "MOVE" { server.interceptor = nil; server.putDirect(path, Data("age-encryption.org/v1\nfirst".utf8)) }
            return nil
        }
        let report = try sync("A", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(server.file(path), Data("age-encryption.org/v1\nfirst".utf8))
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        XCTAssertTrue(try sync("A", server).isEmpty)
    }

    // MARK: deletions (format.md §8.1.6 rules 1–3 on the deleting side)

    /// An unreferenced blob that another device collected on the server
    /// is deleted here.
    func testServerDroppedUnreferencedBlobIsDeletedLocally() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server); try sync("B", server)
        server.removeDirect("notes/\(id)/att/\(name)")
        let report = try sync("B", server)
        XCTAssertEqual(report.deleted, [.init(side: "local", path: "notes/\(id)/att/\(name)")], "\(report)")
        XCTAssertEqual(attEntries("B"), [])
        XCTAssertTrue(try sync("B", server).isEmpty)
        // A's turn: the server dropped it, A deletes it too.
        XCTAssertEqual(try sync("A", server).deleted.map(\.side), ["local"])
    }

    /// A referenced blob the server lost is copied back, never deleted.
    func testServerDroppedReferencedBlobIsUploadedAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let name = try blobFile(a, ref)
        try sync("A", server)
        server.removeDirect("notes/\(id)/att/\(name)")
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(report.uploaded, ["notes/\(id)/att/\(name)"])
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        XCTAssertEqual(attEntries("A"), [name])
    }

    /// A blob this device collected is deleted on the server when no
    /// revision on either side references it.
    func testLocallyCollectedBlobIsDeletedOnServer() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server); try sync("B", server)
        var state = BlobCollectorState()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try a.collectBlobs(note: noteID, state: &state, now: t0)
        XCTAssertEqual(try a.collectBlobs(note: noteID, state: &state, now: t0.addingTimeInterval(31 * 86400)).deleted, [name])
        let report = try sync("A", server)
        XCTAssertEqual(report.deleted, [.init(side: "remote", path: "notes/\(id)/att/\(name)")], "\(report)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [])
        let b = try sync("B", server)
        XCTAssertEqual(b.deleted, [.init(side: "local", path: "notes/\(id)/att/\(name)")], "\(b)")
        XCTAssertTrue(try sync("A", server).isEmpty)
        XCTAssertTrue(try sync("B", server).isEmpty)
    }

    /// A referenced blob that went missing locally is downloaded again and
    /// stays on the server.
    func testLocallyDroppedReferencedBlobIsDownloadedAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(100), type: "audio/mp4")
        try referencing(a, device: devA, t: 0, [ref])
        let name = try blobFile(a, ref)
        try sync("A", server)
        try FileManager.default.removeItem(at: att("A").appendingPathComponent(name))
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(report.downloaded, ["notes/\(id)/att/\(name)"])
        XCTAssertEqual(try a.readBlob(note: noteID, ref), syntheticBlob(100))
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
    }

    /// The reference test is structural and counts every revision: an older
    /// snapshot or a deleted note still keeps its blobs on both sides.
    func testReferenceFromAnyRevisionKeepsTheBlob() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        try referencing(a, device: devA, t: 0, [ref])
        let seq = try a.nextSeq(noteId: noteID, device: devA)
        try a.write(Revision(noteId: noteID, device: devA, seq: seq, hlc: HLC(millis: baseMillis + 10, counter: 0)!,
                             wall: Date(), app: "test/0", body: .delta(ops: [.deleteNote])))
        let name = try blobFile(a, ref)
        try sync("A", server); try sync("B", server)
        try FileManager.default.removeItem(at: att("B").appendingPathComponent(name))
        server.removeDirect("notes/\(id)/att/\(name)")
        _ = try sync("B", server)   // B dropped it, the server dropped it: both are gone
        XCTAssertEqual(attEntries("A"), [name])
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        XCTAssertEqual(try sync("B", server).downloaded, ["notes/\(id)/att/\(name)"])
    }

    /// Rule 1: one unreadable revision of the note stops deletion in that
    /// note (it might hold the only reference); the blob is copied back.
    func testUnreadableRevisionBlocksBlobDeletion() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server)
        let bogus = RevisionName("\(baseMillis + 50)0000-\(devB.rawValue)-1.delta.age")!
        try Vault.encrypt(Data("not a revision".utf8), to: a.ageRecipients())
            .write(to: dir("A").appendingPathComponent("notes/\(id)/\(bogus.filename)"))
        try FileManager.default.removeItem(at: att("A").appendingPathComponent(name))
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertTrue(report.downloaded.contains("notes/\(id)/att/\(name)"), "\(report)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
    }

    /// Rule 1 for the server side: a revision the server holds that could
    /// not be read here may reference the blob, so it stays on the server.
    func testServerRevisionNotReadHereBlocksRemoteDeletion() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let blob = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, blob)
        try sync("A", server); try sync("B", server)
        let d = try referencing(a, device: devA, t: 10, [blob])   // A starts using it
        try sync("A", server)
        // B collected it (it saw no reference) and cannot fetch A's new delta.
        try FileManager.default.removeItem(at: att("B").appendingPathComponent(name))
        server.interceptor = { r in
            r.method == "GET" && r.url.path.hasSuffix(d.name.filename) ? WebDAVResponse(status: 503) : nil
        }
        let report = try sync("B", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertTrue(report.downloaded.contains("notes/\(id)/att/\(name)"), "\(report)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        server.interceptor = nil
        try sync("B", server)
        XCTAssertEqual(try openVault("B").readBlob(note: noteID, blob), syntheticBlob(100))
    }

    /// Rule 2: a pending recipient change (on either side) stops deletions.
    func testRewrapJournalBlocksBlobDeletion() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server); try sync("B", server)
        // An addition interrupted on A: its journal is bound by vault.json (format.md §3.3.1).
        var changing = try openVault("A")
        XCTAssertThrowsError(try changing.addRecipient(pqIdentity().recipient, label: "x", added: Date(), stopAfter: 0))
        try sync("A", server)
        XCTAssertNotNil(server.file("rewrap-journal.json"))
        server.removeDirect("notes/\(id)/att/\(name)")
        let report = try sync("B", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertTrue(report.uploaded.contains("notes/\(id)/att/\(name)"), "\(report)")
        XCTAssertEqual(attEntries("B"), [name])
    }

    /// Without an unlocked vault nothing can be checked: a dropped blob is
    /// neither deleted nor copied back, only reported.
    func testLockedVaultNeitherDeletesNorRestoresBlobs() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let other = try a.writeBlob(note: noteID, syntheticBlob(200, seed: 3), type: "image/png")
        try sync("A", server)
        server.removeDirect("notes/\(id)/att/\(try blobFile(a, unused))")
        try FileManager.default.removeItem(at: att("A").appendingPathComponent(try blobFile(a, other)))
        let report = try sync("A", server, vault: .some(try Vault.open(at: dir("A"))))
        XCTAssertTrue(report.deleted.isEmpty && report.uploaded.isEmpty && report.downloaded.isEmpty, "\(report)")
        XCTAssertEqual(report.skipped.count, 2, "\(report)")
        XCTAssertEqual(attEntries("A"), [try blobFile(a, unused)])
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [try blobFile(a, other)])
        // Unlocked, the next run settles both.
        let settled = try sync("A", server)
        XCTAssertEqual(Set(settled.deleted.map(\.side)), ["local", "remote"], "\(settled)")
    }

    /// An emptied or recreated remote `att/` (the collection itself is gone)
    /// is not a collection: everything is uploaded again.
    func testWipedRemoteAttIsUploadedAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server)
        server.removeCollection("notes/\(id)/att")
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [name])
        XCTAssertEqual(attEntries("A"), [name])
    }

    /// A removed local `att/` folder is not a collection either.
    func testRemovedLocalAttIsDownloadedAgain() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let unused = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let name = try blobFile(a, unused)
        try sync("A", server)
        try FileManager.default.removeItem(at: att("A"))
        let report = try sync("A", server)
        XCTAssertTrue(report.deleted.isEmpty, "\(report)")
        XCTAssertEqual(attEntries("A"), [name])
    }

    // MARK: untrusted names and sizes

    func testHostileBlobNamesAreIgnored() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        try sync("A", server)
        let hex = String(repeating: "ab", count: 32)
        let bad = [hex.uppercased() + ".image.age", String(hex.dropLast()) + ".image.age", hex + ".IMAGE.age",
                   hex + ".abcdefghijklmnopq.age", hex + ".image.age.x", hex + "..age", "x\u{1B}[2J.age",
                   hex + ".image"]
        for n in bad { server.putDirect("notes/\(id)/att/\(n)", Data("age-encryption.org/v1\nx".utf8)) }
        server.putDirect("notes/\(id)/att/\(hex).image.age/inner", Data("x".utf8))   // a collection with a blob's name
        server.putDirect("notes/\(id)/att/.sempere-tmp-in-flight", Data("x".utf8))
        server.putDirect("notes/\(id)/att/../../escape.age", Data("x".utf8))
        let report = try sync("B", server)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertFalse(report.downloaded.contains { $0.contains("/att/") }, "\(report)")
        XCTAssertGreaterThanOrEqual(report.ignored.filter { $0.contains("/att/") }.count, bad.count)
        XCTAssertFalse(report.ignored.contains { $0.contains("in-flight") }, "uploads in flight are not reported")
        for name in report.ignored {
            XCTAssertFalse(name.unicodeScalars.contains { $0.properties.generalCategory == .control }, name)
        }
        XCTAssertEqual(attEntries("B"), [])
    }

    func testDownloadedBlobMustBeAnAgeFile() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        try sync("A", server)
        let name = String(repeating: "cd", count: 32) + ".pdf.age"
        server.putDirect("notes/\(id)/att/\(name)", Data("<html>login</html>".utf8))
        let report = try sync("B", server)
        XCTAssertEqual(report.quarantined.map(\.path), ["notes/\(id)/att/\(name)"], "\(report)")
        XCTAssertEqual(attEntries("B"), [], "nothing under the name, no partial file")
    }

    func testBlobSizeLimitBothWays() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let big = try a.writeBlob(note: noteID, syntheticBlob(20_000), type: "image/png")
        let small = try a.writeBlob(note: noteID, syntheticBlob(10, seed: 2), type: "image/png")
        func run(_ name: String, limit: Int) throws -> SyncReport {
            try WebDAVSync(directory: dir(name), vault: try? openVault(name), client: try client(server),
                           stateURL: tmp.appendingPathComponent("state-\(name).json"),
                           options: WebDAVSyncOptions(deviceLabel: name, maxBlobBytes: limit)).run()
        }
        let up = try run("A", limit: 10_000)
        XCTAssertEqual(up.errors.map(\.path), ["notes/\(id)/att/\(try blobFile(a, big))"], "\(up)")
        XCTAssertEqual(server.names(under: "notes/\(id)/att"), [try blobFile(a, small)])
        XCTAssertNil(up.errors.first?.message.range(of: "maxFileBytes"))
        _ = try run("A", limit: 1 << 20)
        // Over the limit by the listing: never requested.
        try FileManager.default.createDirectory(at: dir("B"), withIntermediateDirectories: true)
        let down = try run("B", limit: 10_000)
        XCTAssertEqual(down.errors.map(\.path), ["notes/\(id)/att/\(try blobFile(a, big))"], "\(down)")
        XCTAssertFalse(server.requestLog.contains { $0.method == "GET" && $0.path.hasSuffix(try! blobFile(a, big)) })
        // Over the limit by the body although the listing says less: reading stops at the limit.
        let bigName = try blobFile(a, big)
        let noteName = id
        server.interceptor = { r in
            guard r.method == "PROPFIND", r.url.path.hasSuffix("/att/") else { return nil }
            let xml = "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>\(MockDAV.base)/notes/\(noteName)/att/\(bigName)</d:href>"
                + "<d:propstat><d:prop><d:resourcetype/><d:getetag>\"x\"</d:getetag><d:getcontentlength>100</d:getcontentlength></d:prop></d:propstat></d:response></d:multistatus>"
            return WebDAVResponse(status: 207, body: Data(xml.utf8))
        }
        let lying = try run("B", limit: 10_000)
        XCTAssertEqual(lying.errors.map(\.path), ["notes/\(id)/att/\(bigName)"], "\(lying)")
        XCTAssertFalse(attEntries("B").contains(bigName))
        XCTAssertFalse(attEntries("B").contains { $0.hasPrefix(".sempere-tmp-") }, "\(attEntries("B"))")
    }

    // MARK: sempere-index.json (#63)

    /// The server's index keeps listing revisions only, current after a
    /// sync that moved blobs too.
    func testServerIndexStaysCurrentAndListsNoBlobs() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        server.putDirect(WebIndex.fileName, Data("{\"format\":\"sempere-index/1\",\"notes\":{}}\n".utf8))
        let ref = try a.writeBlob(note: noteID, syntheticBlob(100), type: "image/png")
        let d = try referencing(a, device: devA, t: 0, [ref])
        try sync("A", server)
        let index = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(server.file(WebIndex.fileName))) as? [String: Any])
        XCTAssertEqual(index["notes"] as? [String: [String]], [id: [d.name.filename]])
        XCTAssertEqual(server.file(WebIndex.fileName), try WebIndex.encode([id: [d.name.filename]]))
    }
}
