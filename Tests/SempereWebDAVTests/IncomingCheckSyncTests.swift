import Age
import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// Security review 2026-10, W2 and W5: downloads are checked before they are
/// placed (bad ones quarantined and reported, never placed), one bad file
/// never blocks a note, and a run is bounded as a whole.
final class IncomingCheckSyncTests: SyncTestCase {
    var id: String { noteID.uuidString.lowercased() }

    /// A snapshot the server made with only the public keys: valid age to
    /// the vault's recipient, framed under a secret of its own.
    func forgedSnapshot(_ vault: Vault, seq: Int = 1) throws -> (RevisionName, Data) {
        let name = RevisionName(hlc: HLC(millis: baseMillis + 50_000, counter: 0)!, device: DeviceID("cccccccc")!,
                                seq: seq, kind: .snapshot)
        let rev = Revision(noteId: noteID, device: name.device, seq: seq, hlc: name.hlc, wall: Date(), app: "x/0",
                           body: .snapshot(included: Included([:]), state: try vault.reconstruct(noteId: noteID)))
        let body = try BodyFraming.frame(json: InkJSON.encoder().encode(rev), noteId: id, filename: name.filename,
                                         secret: .random())
        return (name, try AgeFile.encrypt(body, to: [identity.recipient]))
    }

    func run(_ name: String, _ server: MockDAV, vault: Vault?, configure: (inout WebDAVSyncOptions) -> Void = { _ in })
        throws -> SyncReport {
        var options = WebDAVSyncOptions(deviceLabel: name)
        options.firstPullIdentities = [identity]
        configure(&options)
        return try WebDAVSync(directory: dir(name), vault: vault, client: try client(server),
                              stateURL: tmp.appendingPathComponent("state-\(name).json"), options: options).run()
    }

    func testForgedSnapshotIsQuarantinedNotPlaced() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        let (name, bytes) = try forgedSnapshot(a)
        let rel = "notes/\(id)/\(name.filename)"
        server.putDirect(rel, bytes)

        let report = try run("B", server, vault: nil)
        XCTAssertEqual(report.quarantined.map(\.path), [rel], "\(report)")
        XCTAssertTrue(report.quarantined[0].message.contains("tag does not verify"), report.quarantined[0].message)
        XCTAssertFalse(report.downloaded.contains(rel))
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        let b = try openVault("B")
        XCTAssertFalse(try fileNames(b).contains(name.filename), "never placed in the vault")
        let kept = tmp.appendingPathComponent("state-B.quarantine/\(rel)")
        XCTAssertEqual(try Data(contentsOf: kept), bytes, "kept for inspection, outside the vault")
        XCTAssertEqual(try title(b), "one")
        XCTAssertNoThrow(try delta(b, device: devB, t: 100, title: "two"), "the note can be edited")

        // The next run does not fetch it again while it is unchanged...
        let gets = { server.requestLog.filter { $0.method == "GET" && $0.path.hasSuffix(name.filename) }.count }
        let before = gets()
        let again = try sync("B", server)
        XCTAssertTrue(again.quarantined.isEmpty)
        XCTAssertTrue(again.skipped.contains { $0.path == rel && $0.message.contains("quarantined") }, "\(again)")
        XCTAssertEqual(gets(), before, "not fetched again")
        // ...and checks it again when asked to.
        let retried = try run("B", server, vault: try openVault("B")) { $0.retryQuarantined = true }
        XCTAssertEqual(retried.quarantined.map(\.path), [rel])
    }

    func testWrongNoteOrNameIsQuarantined() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        let r = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        // A genuine revision replayed under another name.
        let other = RevisionName(hlc: HLC(millis: baseMillis + 9, counter: 0)!, device: devA, seq: 7, kind: .delta)
        let rel = "notes/\(id)/\(other.filename)"
        server.putDirect(rel, try XCTUnwrap(server.file("notes/\(id)/\(r.name.filename)")))
        let report = try run("B", server, vault: nil)
        XCTAssertEqual(report.quarantined.map(\.path), [rel], "\(report)")
    }

    /// Locked, only the structure can be checked: junk and files for other
    /// recipients are quarantined, a well-formed forgery is placed, and it
    /// still does not block the note once the vault is unlocked.
    func testLockedSyncChecksStructureAndAForgeryNeverBlocksTheNote() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        try sync("B", server)

        let junk = RevisionName(hlc: HLC(millis: baseMillis + 60_000, counter: 0)!, device: DeviceID("dddddddd")!,
                                seq: 1, kind: .snapshot)
        server.putDirect("notes/\(id)/\(junk.filename)", Data("age-encryption.org/v1\nnot really".utf8))
        let stranger = RevisionName(hlc: HLC(millis: baseMillis + 61_000, counter: 0)!, device: DeviceID("eeeeeeee")!,
                                    seq: 1, kind: .snapshot)
        server.putDirect("notes/\(id)/\(stranger.filename)", try AgeFile.encrypt(Data("x".utf8), to: [pqIdentity().recipient,
                                                                                                    pqIdentity().recipient]))
        let (forged, bytes) = try forgedSnapshot(a)
        server.putDirect("notes/\(id)/\(forged.filename)", bytes)

        let report = try run("B", server, vault: try Vault.open(at: dir("B"))) { $0.firstPullIdentities = [] }
        XCTAssertEqual(Set(report.quarantined.map(\.path)),
                       ["notes/\(id)/\(junk.filename)", "notes/\(id)/\(stranger.filename)"], "\(report)")
        XCTAssertTrue(report.downloaded.contains("notes/\(id)/\(forged.filename)"), "structure is all a locked run sees")

        let b = try openVault("B")
        XCTAssertEqual(try b.nextSeq(noteId: noteID, device: devB), 1, "the forged snapshot covers nothing")
        XCTAssertNoThrow(try b.apply([.setMeta(.title("two"))], to: noteID,
                                     deviceState: tmp.appendingPathComponent("dev-b.json"), app: "test/0"))
    }

    func testPlantedBlobUnderAnotherNameIsQuarantined() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        _ = try delta(a, device: devA, t: 0, title: "n")
        let ref = try a.writeBlob(note: noteID, syntheticBlob(5_000), type: "image/png")
        try sync("A", server)
        let real = try a.blobFileName(for: ref)
        // The server copies a real blob under a name it chose.
        let planted = String(repeating: "ab", count: 32) + ".image.age"
        server.putDirect("notes/\(id)/att/\(planted)", try XCTUnwrap(server.file("notes/\(id)/att/\(real)")))
        let report = try run("B", server, vault: nil)
        XCTAssertEqual(report.quarantined.map(\.path), ["notes/\(id)/att/\(planted)"], "\(report)")
        XCTAssertTrue(report.downloaded.contains("notes/\(id)/att/\(real)"))
        let att = dir("B").appendingPathComponent("notes/\(id)/att")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: att.path).sorted(), [real])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("state-B.quarantine/notes/\(id)/att/\(planted)").path))
    }

    /// A rotation that arrives with `vault.json` in the same run: revisions
    /// written under the new secret are checked under it, not quarantined.
    func testRevisionsUnderARotatedSecretArrivingWithTheManifestAreKept() throws {
        let server = MockDAV()
        let other = pqIdentity()
        var a = try Vault.create(at: dir("A"), recipients: [identity.recipient, other.recipient], labels: ["a", "o"],
                                 identities: [identity])
        _ = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server, vault: a)
        try sync("B", server)
        try a.removeRecipient(other.recipient)
        let r = try delta(a, device: devA, t: 100, title: "two")
        try sync("A", server, vault: a)
        let report = try sync("B", server)
        XCTAssertTrue(report.downloaded.contains("vault.json"), "\(report)")
        XCTAssertTrue(report.downloaded.contains("notes/\(id)/\(r.name.filename)"), "\(report)")
        XCTAssertTrue(report.quarantined.isEmpty, "\(report)")
    }

    // MARK: W5

    func testTooManyNotesStopsTheRunWithAClearError() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        for i in 0..<3 {
            _ = try delta(a, device: devA, t: Int64(i), title: "n\(i)", note: UUID())
        }
        try sync("A", server)
        let report = try run("B", server, vault: nil) { $0.limits.maxNotes = 2 }
        XCTAssertNotNil(report.stoppedEarly, "\(report)")
        XCTAssertTrue(report.errors.contains { $0.message.contains("--max-notes") }, "\(report)")
        XCTAssertFalse(report.downloaded.contains { $0.hasPrefix("notes/") })
        let full = try run("B", server, vault: nil)
        XCTAssertNil(full.stoppedEarly)
        XCTAssertEqual(full.downloaded.filter { $0.hasPrefix("notes/") }.count, 3)
    }

    func testDownloadBudgetStopsTheRunAndTheNextOneContinues() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        for i in 0..<4 { _ = try delta(a, device: devA, t: Int64(i), title: "t\(i)") }
        try sync("A", server)
        let one = try XCTUnwrap(server.size("notes/\(id)/\(try fileNames(a)[0])"))
        let manifest = try XCTUnwrap(server.size("vault.json"))
        let budget = Int64(manifest + one * 2 + one / 2)
        let first = try run("B", server, vault: nil) { $0.limits.maxDownloadBytes = budget }
        XCTAssertNotNil(first.stoppedEarly, "\(first)")
        // The number is in the flag's unit.
        XCTAssertTrue(first.errors.contains { $0.message.contains("\(budget >> 20) MiB") && $0.message.contains("--max-download-mib") },
                      "\(first)")
        let got = first.downloaded.filter { $0.hasPrefix("notes/") }.count
        XCTAssertLessThan(got, 4)
        let second = try run("B", server, vault: nil)
        XCTAssertEqual(second.downloaded.filter { $0.hasPrefix("notes/") }.count, 4 - got, "\(second)")
        XCTAssertEqual(try fileNames(try openVault("B")).count, 4)
    }

    func testEntryAndTimeLimits() throws {
        let server = MockDAV()
        let a = try makeVault("A")
        for i in 0..<3 { _ = try delta(a, device: devA, t: Int64(i), title: "t\(i)") }
        try sync("A", server)
        let entries = try run("B", server, vault: nil) { $0.limits.maxEntries = 4 }
        XCTAssertTrue(entries.errors.contains { $0.message.contains("--max-entries") }, "\(entries)")
        let time = try run("C", server, vault: nil) { $0.limits.maxDuration = -1 }
        XCTAssertTrue(time.errors.contains { $0.message.contains("0 minutes (--max-minutes)") }, "\(time)")
        XCTAssertFalse(time.downloaded.contains { $0.hasPrefix("notes/") })
    }
}
