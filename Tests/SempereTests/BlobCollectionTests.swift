import Age
import Foundation
import XCTest
@testable import Sempere

/// Per-note inventory, collection (format.md §8.1.6 rules 1–4, each tested
/// on its own), repair, and blob entries in `verify`.
final class BlobCollectionTests: VaultTestCase {
    let day: TimeInterval = 86400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A vault where note `testNote` has a referenced blob and an
    /// unreferenced one, and `otherNote` an unreferenced one.
    func setUpNotes() throws -> (Vault, NativeIdentity, used: BlobRef, unused: BlobRef, otherUnused: BlobRef, LogBuilder) {
        let id = pqIdentity()
        let vault = try makeVault(id)
        var log = LogBuilder()
        let used = try vault.writeBlob(note: testNote, Data("synthetic used".utf8), type: "image/png")
        let unused = try vault.writeBlob(note: testNote, Data("synthetic unused".utf8), type: "application/pdf")
        try vault.write(referencingDelta(&log, 0, refs: [used]))
        var otherLog = LogBuilder()
        try vault.write(referencingDelta(&otherLog, 0, note: otherNote, refs: []))
        let otherUnused = try vault.writeBlob(note: otherNote, Data("synthetic other".utf8), type: "image/jpeg")
        return (vault, id, used, unused, otherUnused, log)
    }

    func testInventory() throws {
        let (vault, _, used, unused, _, _) = try setUpNotes()
        try plant(vault, testNote, Data(), as: "notes.txt")
        let inv = try vault.blobInventory(note: testNote)
        XCTAssertTrue(inv.isComplete)
        XCTAssertEqual(inv.referencedHashes, [used.sha256])
        XCTAssertEqual(Set(inv.files.map(\.fileName)), [try vault.blobFileName(for: used), try vault.blobFileName(for: unused)])
        XCTAssertEqual(inv.unreferenced.map(\.fileName), [try vault.blobFileName(for: unused)])
        XCTAssertEqual(inv.unknownEntries, ["notes.txt"])
        XCTAssertEqual(inv.missing, [])
        XCTAssertTrue(inv.files.allSatisfy { $0.bytes > 0 })
    }

    /// Any object with a `sha256` counts, inside unknown kinds and fields.
    func testReferencesAreFoundStructurally() throws {
        let (vault, _, _, unused, _, _) = try setUpNotes()
        var log = LogBuilder()
        _ = log.delta(devA, 0, [])   // keep seqs apart from setUpNotes' log
        let rev = unknownKindDelta(&log, 50, ref: unused)
        try vault.write(rev)
        let inv = try vault.blobInventory(note: testNote)
        XCTAssertEqual(inv.references[rev.name]?.map(\.sha256), [unused.sha256])
        XCTAssertEqual(inv.unreferenced, [])
        // The scan itself, on raw JSON.
        let json = Data(#"{"a":[{"b":{"sha256":"x","size":3,"type":"t"}}],"sha256":5,"c":{"sha256":"y","size":true}}"#.utf8)
        let found = try BlobReferenceScan.references(in: json)
        XCTAssertEqual(Set(found.map(\.sha256)), ["x", "y"])
        XCTAssertEqual(found.first { $0.sha256 == "x" }?.size, 3)
        XCTAssertNil(found.first { $0.sha256 == "y" }?.size, "a boolean is not a size")
        let small = try BlobReferenceScan.references(in: Data(#"[{"sha256":"z","size":1},{"sha256":"w","size":0},{"sha256":"v","size":false},{"sha256":"u","size":1.5}]"#.utf8))
        let sizes = Dictionary(uniqueKeysWithValues: small.map { ($0.sha256, $0.size.map(String.init) ?? "none") })
        XCTAssertEqual(sizes, ["z": "1", "w": "0", "v": "none", "u": "none"], "0 and 1 are sizes; false and 1.5 are not")
    }

    func testMissingReferenceIsReported() throws {
        let (vault, _, used, _, _, _) = try setUpNotes()
        try FileManager.default.removeItem(at: blobURL(vault, testNote, used))
        XCTAssertEqual(try vault.blobInventory(note: testNote).missing, [used])
        let report = vault.verify()
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.files.filter { $0.status == .missing }.map(\.path),
                       ["notes/\(testNote.uuidString.lowercased())/att/\(try vault.blobFileName(for: used))"])
    }

    // MARK: - Rules 1-4

    /// Rule 4: recorded on the first look, deleted only once the window has
    /// passed since then; nothing else in the note goes.
    func testRule4RetentionWindow() throws {
        let (vault, _, used, unused, _, _) = try setUpNotes()
        var state = BlobCollectorState()
        var r = try vault.collectBlobs(note: testNote, state: &state, now: t0)
        XCTAssertNil(r.blocked)
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(r.referenced, 1)
        XCTAssertEqual(r.unused.map(\.fileName), [try vault.blobFileName(for: unused)])
        XCTAssertEqual(r.unused.first?.deletableFrom, t0.addingTimeInterval(30 * day))
        r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(30 * day - 1))
        XCTAssertEqual(r.deleted, [], "one second short of the window")
        XCTAssertEqual(r.unused.first?.firstSeen, t0, "the first sighting is kept")
        r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(30 * day), dryRun: true)
        XCTAssertEqual(r.deleted, [try vault.blobFileName(for: unused)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobURL(vault, testNote, unused).path), "dry run")
        r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(30 * day))
        XCTAssertEqual(r.deleted, [try vault.blobFileName(for: unused)])
        XCTAssertEqual(attEntries(vault, testNote), [try vault.blobFileName(for: used)])
        XCTAssertNil(state.notes[testNote.uuidString.lowercased()], "nothing left to record")
        XCTAssertEqual(try vault.readBlob(note: testNote, used), Data("synthetic used".utf8))
    }

    /// Rule 4: a blob that becomes referenced again (a late delta) loses its
    /// record; unreferenced again (its revision compacted away), its window
    /// starts over.
    func testRule4ReferenceResetsTheWindow() throws {
        var (vault, _, _, unused, _, log) = try setUpNotes()
        var state = BlobCollectorState()
        _ = try vault.collectBlobs(note: testNote, state: &state, now: t0)
        let late = referencingDelta(&log, 10, refs: [unused], newPage: false)
        try vault.write(late)
        var r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(40 * day))
        XCTAssertEqual(r.unused, [])
        XCTAssertNil(state.notes[testNote.uuidString.lowercased()])
        try FileManager.default.removeItem(at: fileURL(vault, testNote, late.name))
        r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(41 * day))
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(r.unused.first?.firstSeen, t0.addingTimeInterval(41 * day))
        r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(71 * day))
        XCTAssertEqual(r.deleted, [try vault.blobFileName(for: unused)])
    }

    /// Rule 3: a blob referenced by any surviving revision stays, even when
    /// the current state no longer shows it (a restore point needs it), in a
    /// deleted note too, and when referenced only from an unknown item kind.
    func testRule3AnyRevisionKeepsItsBlobs() throws {
        var (vault, _, used, unused, _, log) = try setUpNotes()
        let item = try XCTUnwrap(vault.loadNote(testNote).revisions.first?.ops.compactMap { op -> UUID? in
            if case .addItem(_, let item) = op { return item.id }
            return nil
        }.first)
        try vault.write(log.delta(devA, 20, [.removeItem(page: blobPage, itemId: item), .deleteNote]))
        var other = LogBuilder()
        for _ in 0..<5 { _ = other.nextSeq(devB) }
        var rev = unknownKindDelta(&other, 30, ref: unused)
        rev.device = devB
        try vault.write(rev)
        var state = BlobCollectorState()
        _ = try vault.collectBlobs(note: testNote, state: &state, now: t0)
        let r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(365 * day))
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(r.unused, [])
        XCTAssertEqual(r.referenced, 2)
        XCTAssertEqual(try vault.readBlob(note: testNote, used), Data("synthetic used".utf8))
    }

    /// Rule 1: one unreadable revision stops collection in its note (and
    /// restarts the window there), and only there.
    func testRule1UnreadableRevisionBlocksOnlyItsNote() throws {
        let (vault, _, _, unused, otherUnused, _) = try setUpNotes()
        var state = BlobCollectorState()
        _ = try vault.collectBlobs(note: testNote, state: &state, now: t0)
        _ = try vault.collectBlobs(note: otherNote, state: &state, now: t0)
        let names = try vault.revisionNames(of: testNote)
        try flipByte(fileURL(vault, testNote, names[0]), at: 5)
        let later = t0.addingTimeInterval(31 * day)
        var r = try vault.collectBlobs(note: testNote, state: &state, now: later)
        XCTAssertNotNil(r.blocked)
        XCTAssertTrue(r.blocked?.contains("rule 1") == true)
        XCTAssertEqual(r.deleted, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try blobURL(vault, testNote, unused).path))
        XCTAssertNil(state.notes[testNote.uuidString.lowercased()], "the window restarts")
        let o = try vault.collectBlobs(note: otherNote, state: &state, now: later)
        XCTAssertNil(o.blocked)
        XCTAssertEqual(o.deleted, [try vault.blobFileName(for: otherUnused)], "the other note is unaffected")
        // Fixed (the file restored): collection resumes, with a new window.
        try flipByte(fileURL(vault, testNote, names[0]), at: 5)
        r = try vault.collectBlobs(note: testNote, state: &state, now: later)
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(r.unused.first?.firstSeen, later)
    }

    /// Rule 2: nothing is collected while a recipient change is unfinished.

    /// Blobs that cannot be decrypted or verified are reported, never deleted.
    func testUnverifiableBlobIsNeverDeleted() throws {
        let (vault, _, _, _, _, _) = try setUpNotes()
        let bogus = String(repeating: "7", count: 64) + ".image.age"
        try plant(vault, testNote, blobPlaintext(Data("planted".utf8)), as: bogus)
        let junk = String(repeating: "8", count: 64) + ".bin.age"
        try Data("not age".utf8).write(to: attDir(vault, testNote).appendingPathComponent(junk))
        // Authentic and with a valid first chunk, but damaged further on.
        let tail = try vault.writeBlob(note: testNote, syntheticBytes(200_000), type: "image/png")
        let tailName = try vault.blobFileName(for: tail)
        try flipByte(attDir(vault, testNote).appendingPathComponent(tailName), at: 7)
        var state = BlobCollectorState()
        _ = try vault.collectBlobs(note: testNote, state: &state, now: t0)
        let r = try vault.collectBlobs(note: testNote, state: &state, now: t0.addingTimeInterval(31 * day))
        XCTAssertEqual(Set(r.failures.keys), [bogus, junk, tailName])
        XCTAssertTrue(attEntries(vault, testNote).contains(tailName))
        XCTAssertTrue(attEntries(vault, testNote).contains(bogus))
        XCTAssertTrue(attEntries(vault, testNote).contains(junk))
    }

    func testCollectorStateFile() throws {
        let vaultId = UUID()
        let url = BlobCollectorState.defaultURL(vaultId: vaultId, environment: ["XDG_STATE_HOME": tmp.path], home: tmp)
        XCTAssertEqual(url.path, tmp.appendingPathComponent("sempere/blobs/\(vaultId.uuidString.lowercased()).json").path)
        XCTAssertEqual(try BlobCollectorState.load(from: url, vaultId: vaultId), BlobCollectorState(vaultId: vaultId))
        var s = BlobCollectorState(vaultId: vaultId)
        s.notes["n"] = ["f.image.age": t0]
        try s.save(to: url)
        XCTAssertEqual(try BlobCollectorState.load(from: url, vaultId: vaultId), s)
        XCTAssertEqual(try BlobCollectorState.load(from: url, vaultId: UUID()).notes, [:], "another vault's state is not used")
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try BlobCollectorState.load(from: url, vaultId: vaultId), "never silently reset")
    }

    // MARK: - verify

    func testVerifyReportsBlobs() throws {
        let (vault, _, used, unused, _, _) = try setUpNotes()
        var report = vault.verify()
        XCTAssertTrue(report.isHealthy, "\(report)")
        let base = "notes/\(testNote.uuidString.lowercased())/att/"
        let usedPath = base + (try vault.blobFileName(for: used)), unusedPath = base + (try vault.blobFileName(for: unused))
        XCTAssertEqual(report.files.first { $0.path == usedPath }?.status, .ok)
        XCTAssertEqual(report.files.first { $0.path == unusedPath }?.status, .unreferenced)
        try plant(vault, testNote, Data(), as: "stray.txt")
        try flipByte(try blobURL(vault, testNote, unused), at: 3)
        report = vault.verify()
        XCTAssertEqual(report.files.first { $0.path == base + "stray.txt" }?.status, .unknownFile)
        XCTAssertEqual(report.files.first { $0.path == unusedPath }?.status, .invalid)
        XCTAssertFalse(report.isHealthy)
        // Restricted to the other note, the damage is not seen.
        XCTAssertTrue(vault.verify(notes: [otherNote]).isHealthy)
        // Locked: listed, not checked.
        let locked = try Vault.open(at: vault.url)
        XCTAssertEqual(locked.verify().files.first { $0.path == usedPath }?.status, .notChecked)
    }

    // MARK: - repair

    /// What a recipient change by a build without blobs leaves: blobs under a
    /// name from an old secret. Referenced ones are renamed (and re-encrypted);
    /// unreferenced misnamed ones are left alone.
    func testRepairRenamesOnlyAuthenticBlobs() throws {
        let (vault, id, used, unused, _, _) = try setUpNotes()
        let oldSecret = VaultEpochKey.random()
        func rename(_ ref: BlobRef) throws -> String {
            let name = BlobName.fileName(name: BlobName.name(digest: try XCTUnwrap(ref.digest), secret: oldSecret), kind: ref.kind)
            try FileManager.default.moveItem(at: try blobURL(vault, testNote, ref),
                                             to: attDir(vault, testNote).appendingPathComponent(name))
            return name
        }
        let oldUsed = try rename(used), oldUnused = try rename(unused)
        XCTAssertThrowsError(try vault.readBlob(note: testNote, used))
        XCTAssertFalse(vault.verify().isHealthy)

        let r = try vault.repairBlobs(note: testNote)
        XCTAssertEqual(r.repaired, [oldUsed: [try vault.blobFileName(for: used)]])
        XCTAssertEqual(r.leftAlone, [oldUnused])
        XCTAssertEqual(r.failures, [:])
        XCTAssertEqual(try vault.readBlob(note: testNote, used), Data("synthetic used".utf8))
        XCTAssertEqual(Set(attEntries(vault, testNote)), [try vault.blobFileName(for: used), oldUnused])
        // Idempotent.
        XCTAssertEqual(try vault.repairBlobs(note: testNote).repaired, [:])
        _ = id
    }

    /// A blob left under an old secret's name next to a copy under the
    /// current name that is damaged past its first chunk: repair must not
    /// delete the good old copy on the strength of the damaged one's first
    /// chunk; it rewrites the current name from the old copy.
    func testRepairNeverTrustsADamagedCopy() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        var log = LogBuilder()
        let content = syntheticBytes(70_000, seed: 3)   // two STREAM chunks
        let ref = try vault.writeBlob(note: testNote, content, type: "image/png")
        try vault.write(referencingDelta(&log, 0, refs: [ref]))
        let current = try blobURL(vault, testNote, ref)
        let oldName = BlobName.fileName(name: BlobName.name(digest: try XCTUnwrap(ref.digest), secret: VaultEpochKey.random()),
                                        kind: ref.kind)
        try FileManager.default.copyItem(at: current, to: attDir(vault, testNote).appendingPathComponent(oldName))
        var bytes = try Data(contentsOf: current)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: current)
        XCTAssertNoThrow(try Vault.peekBlobFile(current, identities: vault.identities), "damage is past the first chunk")

        let r = try vault.repairBlobs(note: testNote)
        XCTAssertEqual(r.repaired, [oldName: [current.lastPathComponent]])
        XCTAssertEqual(attEntries(vault, testNote), [current.lastPathComponent])
        XCTAssertEqual(try vault.readBlob(note: testNote, ref), content)
        XCTAssertTrue(vault.verify().isHealthy)
    }

    /// Stale recipients (a removal by an old build left the old stanzas) and
    /// a wrong kind suffix are repaired too.
    func testRepairFixesStaleRecipientsAndKind() throws {
        let (vault, id, used, _, _, _) = try setUpNotes()
        let url = try blobURL(vault, testNote, used)
        let extra = pqIdentity()
        try AgeFile.encrypt(try decryptBlob(url, id), to: [try vault.vaultRecipient(), extra.recipient]).write(to: url)
        let wrongKind = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".image.", with: ".bin."))
        try FileManager.default.moveItem(at: url, to: wrongKind)
        let r = try vault.repairBlobs(note: testNote)
        XCTAssertEqual(r.repaired, [wrongKind.lastPathComponent: [url.lastPathComponent]])
        XCTAssertEqual(try stanzaCount(url), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongKind.path))
        XCTAssertTrue(vault.verify().isHealthy)
    }
}
