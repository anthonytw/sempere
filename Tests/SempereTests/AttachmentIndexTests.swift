import Foundation
import XCTest
@testable import Sempere

/// An `AttachmentIndexSource` that forwards to a vault and counts, per note,
/// what an update touched.
final class CountingIndexSource: AttachmentIndexSource, @unchecked Sendable {
    let vault: Vault
    private let lock = NSLock()
    private var _listings: [UUID: Int] = [:]
    private var _revisionListings: [UUID: Int] = [:]
    private var _decrypted: [UUID: Int] = [:]

    init(_ vault: Vault) { self.vault = vault }

    var listings: [UUID: Int] { lock.withLock { _listings } }
    var revisionListings: [UUID: Int] { lock.withLock { _revisionListings } }
    var decrypted: [UUID: Int] { lock.withLock { _decrypted } }
    /// Every note any call touched.
    var touched: Set<UUID> { Set(listings.keys).union(revisionListings.keys).union(decrypted.keys) }

    func reset() { lock.withLock { _listings = [:]; _revisionListings = [:]; _decrypted = [:] } }

    func revisionNames(of note: UUID) throws -> [RevisionName] {
        lock.withLock { _revisionListings[note, default: 0] += 1 }
        return try vault.revisionNames(of: note)
    }

    func blobFacts(note: UUID, revision: RevisionName) throws -> AttachmentIndexEntry.RevisionFacts {
        lock.withLock { _decrypted[note, default: 0] += 1 }
        return try vault.blobFacts(note: note, revision: revision)
    }

    func blobFiles(note: UUID) throws -> [AttachmentIndexEntry.Listed] {
        lock.withLock { _listings[note, default: 0] += 1 }
        return try vault.blobFiles(note: note)
    }

    func blobNames(sha256: String) -> [String] { vault.blobNames(sha256: sha256) }
}

/// The device-local attachment index (docs/attachments.md §4): per-note
/// updates, the 30-day window and its reset, deletion through
/// `collectBlobs`, the sealed store and the report both the app and the CLI show.
final class AttachmentIndexTests: VaultTestCase {
    let day: TimeInterval = 86400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// `testNote` has a referenced image and an unreferenced PDF; `otherNote`
    /// an unreferenced image; a third note has no attachments.
    func setUpNotes() throws -> (Vault, used: BlobRef, unused: BlobRef, LogBuilder) {
        let vault = try makeVault(pqIdentity())
        var log = LogBuilder()
        let used = try vault.writeBlob(note: testNote, Data("synthetic used".utf8), type: "image/png")
        let unused = try vault.writeBlob(note: testNote, Data("synthetic unused".utf8), type: "application/pdf")
        try vault.write(referencingDelta(&log, 0, refs: [used]))
        var otherLog = LogBuilder()
        try vault.write(referencingDelta(&otherLog, 0, note: otherNote, refs: []))
        _ = try vault.writeBlob(note: otherNote, Data("synthetic other".utf8), type: "image/jpeg")
        var plainLog = LogBuilder()
        try vault.write(referencingDelta(&plainLog, 0, note: plainNote, refs: []))
        return (vault, used, unused, log)
    }

    let plainNote = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testEntryListsUnusedAndHeldByHistory() throws {
        let (vault, used, unused, _) = try setUpNotes()
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: [used.sha256], now: t0)
        XCTAssertTrue(e.isComplete)
        XCTAssertEqual(e.unused.map(\.fileName), [try vault.blobFileName(for: unused)])
        XCTAssertEqual(e.unusedSince, [try vault.blobFileName(for: unused): t0])
        XCTAssertEqual(e.heldByHistory, [])
        let usedFile = try XCTUnwrap(e.files.first { $0.sha256 == used.sha256 })
        XCTAssertEqual(usedFile.revisions, try vault.revisionNames(of: testNote).map(\.filename))
        XCTAssertEqual(usedFile.lastUse?.type, "image/png")
        XCTAssertNotNil(usedFile.lastUse?.wall)
        // The current note no longer shows the image: its bytes are held by history only.
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: [], now: t0)
        XCTAssertEqual(e.heldByHistory.map(\.sha256), [used.sha256])
        let report = AttachmentStorageReport(entries: [e])
        XCTAssertEqual(report.held.map(\.fileName), [try vault.blobFileName(for: used)])
        XCTAssertEqual(report.heldBytes, usedFile.bytes)
        XCTAssertEqual(report.unused.count, 1)
        XCTAssertGreaterThan(report.unusedBytes, 0)
    }

    /// An update reads only its own note, and decrypts only revisions it has not read before.
    func testUpdatesTouchOnlyTheChangedNote() throws {
        var (vault, used, _, log) = try setUpNotes()
        let source = CountingIndexSource(vault)
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: source, current: nil, now: t0)
        XCTAssertEqual(source.touched, [testNote])
        XCTAssertEqual(source.decrypted[testNote], 1)
        source.reset()
        // Unchanged: two listings, nothing decrypted.
        e = AttachmentIndexer.update(note: testNote, previous: e, source: source, current: nil, now: t0)
        XCTAssertEqual(source.touched, [testNote])
        XCTAssertNil(source.decrypted[testNote])
        source.reset()
        // A new revision: exactly that one is decrypted.
        try vault.write(referencingDelta(&log, 5, refs: [used], newPage: false))
        e = AttachmentIndexer.update(note: testNote, previous: e, source: source, current: nil, now: t0)
        XCTAssertEqual(source.decrypted[testNote], 1)
        XCTAssertEqual(source.touched, [testNote])
        XCTAssertEqual(e.revisions.count, 2)
        source.reset()
        // A note without attachments costs one listing of its `att/`.
        let plain = AttachmentIndexer.update(note: plainNote, previous: nil, source: source, current: nil, now: t0)
        XCTAssertEqual(source.listings, [plainNote: 1])
        XCTAssertEqual(source.revisionListings, [:])
        XCTAssertEqual(source.decrypted, [:])
        XCTAssertTrue(plain.files.isEmpty)
        _ = vault
    }

    /// Deletable exactly 30 days after first seen unreferenced; deleted only
    /// through `collectBlobs` with the index's records.
    func testWindowIsExactlyThirtyDaysAndDeletionGoesThroughCollection() throws {
        let (vault, _, unused, _) = try setUpNotes()
        let name = try vault.blobFileName(for: unused)
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: nil, now: t0)
        // Later looks keep the first sighting.
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, now: t0.addingTimeInterval(10 * day))
        let item = try XCTUnwrap(AttachmentStorageReport(entries: [e]).unused.first)
        XCTAssertEqual(item.firstSeen, t0)
        XCTAssertEqual(item.deletableFrom, t0.addingTimeInterval(30 * day))
        XCTAssertFalse(item.isEligible(at: t0.addingTimeInterval(30 * day - 1)))
        XCTAssertTrue(item.isEligible(at: t0.addingTimeInterval(30 * day)))
        XCTAssertEqual(AttachmentStorageReport(entries: [e]).eligible(at: t0.addingTimeInterval(30 * day - 1)), [])

        // Too early: collection with the index's records deletes nothing.
        var records = e.unusedSince
        var r = try vault.collectBlobs(note: testNote, records: &records, only: [name], now: t0.addingTimeInterval(30 * day - 1))
        XCTAssertEqual(r.deleted, [])
        XCTAssertEqual(records, [name: t0])
        // `only` limits what goes: another file name deletes nothing.
        r = try vault.collectBlobs(note: testNote, records: &records, only: ["other.image.age"], now: t0.addingTimeInterval(30 * day))
        XCTAssertEqual(r.deleted, [])
        XCTAssertTrue(attEntries(vault, testNote).contains(name))
        r = try vault.collectBlobs(note: testNote, records: &records, only: [name], now: t0.addingTimeInterval(30 * day))
        XCTAssertEqual(r.deleted, [name])
        XCTAssertFalse(attEntries(vault, testNote).contains(name))
        XCTAssertEqual(records, [:])
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, now: t0.addingTimeInterval(30 * day))
        XCTAssertEqual(e.unused, [])
    }

    /// A late delta that references the blob again resets its clock.
    func testLateReferenceResetsTheWindow() throws {
        var (vault, _, unused, log) = try setUpNotes()
        let name = try vault.blobFileName(for: unused)
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: nil, now: t0)
        XCTAssertEqual(e.unusedSince[name], t0)
        let late = referencingDelta(&log, 10, refs: [unused], newPage: false, device: devB)
        try vault.write(late)
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, now: t0.addingTimeInterval(29 * day))
        XCTAssertEqual(e.unusedSince, [:])
        XCTAssertEqual(AttachmentStorageReport(entries: [e]).unused, [])
        XCTAssertEqual(e.files.first { $0.fileName == name }?.lastUse?.revision, late.name.filename)
        // Unreferenced again (compaction dropped the revision): a new window from then.
        try FileManager.default.removeItem(at: fileURL(vault, testNote, late.name))
        let again = t0.addingTimeInterval(40 * day)
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, now: again)
        let item = try XCTUnwrap(AttachmentStorageReport(entries: [e]).unused.first)
        XCTAssertEqual(item.firstSeen, again)
        XCTAssertFalse(item.isEligible(at: t0.addingTimeInterval(60 * day)))
        XCTAssertEqual(item.lastUse?.revision, late.name.filename, "the last use is remembered after its revision is gone")
        var records = e.unusedSince
        XCTAssertEqual(try vault.collectBlobs(note: testNote, records: &records, now: t0.addingTimeInterval(60 * day)).deleted, [])
    }

    /// Nothing is decided while a revision is unreadable or (iCloud) not on
    /// this device; the window restarts, as collection's rule 1 does.
    func testIncompleteNotesDecideNothing() throws {
        let (vault, _, unused, _) = try setUpNotes()
        let name = try vault.blobFileName(for: unused)
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: nil, now: t0)
        XCTAssertEqual(e.unusedSince[name], t0)
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, local: false,
                                     now: t0.addingTimeInterval(day))
        XCTAssertFalse(e.isComplete)
        XCTAssertEqual(e.unusedSince, [:])
        var report = AttachmentStorageReport(entries: [e])
        XCTAssertEqual(report.unused, [])
        XCTAssertNotNil(report.unchecked[testNote])
        // An unreadable revision (never cached: a fresh entry reads it).
        let names = try vault.revisionNames(of: testNote)
        try flipByte(fileURL(vault, testNote, names[0]), at: 5)
        e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: nil, now: t0.addingTimeInterval(2 * day))
        XCTAssertEqual(Array(e.unreadable.keys), [names[0].filename])
        report = AttachmentStorageReport(entries: [e])
        XCTAssertEqual(report.unused, [])
        XCTAssertNotNil(report.unchecked[testNote])
        try flipByte(fileURL(vault, testNote, names[0]), at: 5)
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: nil, now: t0.addingTimeInterval(3 * day))
        XCTAssertTrue(e.isComplete)
        XCTAssertEqual(e.unusedSince[name], t0.addingTimeInterval(3 * day), "a new window")
    }

    /// The CLI's fresh computation equals the app's incremental one.
    func testFreshEntryMatchesIncrementalOne() throws {
        var (vault, used, _, log) = try setUpNotes()
        var e = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: [used.sha256], now: t0)
        try vault.write(referencingDelta(&log, 5, refs: [used], newPage: false))
        e = AttachmentIndexer.update(note: testNote, previous: e, source: vault, current: [used.sha256], now: t0 + day)
        var fresh = vault.attachmentIndexEntry(note: testNote, records: [:], current: [used.sha256], now: t0 + day)
        XCTAssertNotEqual(fresh.unusedSince, e.unusedSince, "records come from the caller")
        fresh = vault.attachmentIndexEntry(note: testNote, records: e.unusedSince, current: [used.sha256], now: t0 + day)
        fresh.checked = e.checked
        XCTAssertEqual(fresh, e)
    }

    func testHolderHintsAndWall() throws {
        let json = Data(#"""
            {"wall":"2026-10-07T14:32:41.000Z","ops":[{"op":"addRecording","recording":{"title":"Voice note","duration":24.5,
             "blob":{"sha256":"aa","size":10,"type":"audio/mp4"},"transcript":{"sha256":"bb","size":2,"type":"application/json"}}},
             {"items":[{"sha256":"cc","size":true}]}]}
            """#.utf8)
        let facts = try BlobReferenceScan.facts(in: json)
        XCTAssertEqual(facts.wall, RFC3339.parse("2026-10-07T14:32:41.000Z"))
        let by = Dictionary(uniqueKeysWithValues: facts.refs.map { ($0.sha256, $0) })
        XCTAssertEqual(by["aa"]?.duration, 24.5)
        XCTAssertEqual(by["aa"]?.title, "Voice note")
        XCTAssertEqual(by["aa"]?.size, 10)
        XCTAssertEqual(by["bb"]?.type, "application/json")
        XCTAssertNil(by["cc"]?.size, "a boolean is not a size")
        XCTAssertNil(by["cc"]?.duration)
    }

    func testStoreRoundTripPerNote() throws {
        let (vault, _, _, _) = try setUpNotes()
        let root = tmp.appendingPathComponent("index")
        let store = try AttachmentIndexStore(root: root, vault: vault)
        XCTAssertNil(store.load(testNote))
        let a = AttachmentIndexer.update(note: testNote, previous: nil, source: vault, current: nil, now: t0)
        let b = AttachmentIndexer.update(note: otherNote, previous: nil, source: vault, current: nil, now: t0)
        try store.save(a)
        try store.save(b)
        XCTAssertEqual(store.load(testNote), a)
        XCTAssertEqual(store.loadAll(), [testNote: a, otherNote: b])
        // One file per note; saving one note rewrites only its file.
        let files = try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()
        XCTAssertEqual(files.count, 2)
        let otherFile = store.folder.appendingPathComponent(store.fileName(otherNote))
        let before = try Data(contentsOf: otherFile)
        try store.save(a)
        XCTAssertEqual(try Data(contentsOf: otherFile), before)
        // Sealed: nothing readable on disk; a damaged or swapped file is a miss.
        let raw = try Data(contentsOf: store.folder.appendingPathComponent(store.fileName(testNote)))
        XCTAssertNil(String(data: raw, encoding: .utf8).flatMap { $0.contains("unusedSince") ? $0 : nil })
        try before.write(to: store.folder.appendingPathComponent(store.fileName(testNote)))
        XCTAssertNil(store.load(testNote), "another note's file under this name does not open")
        XCTAssertEqual(store.loadAll().keys.sorted { $0.uuidString < $1.uuidString }, [otherNote])
        store.remove(otherNote)
        XCTAssertEqual(store.loadAll(), [:])
        // Another vault (secret) uses another folder.
        let other = try AttachmentIndexStore(root: root, vault: try makeVault(pqIdentity(), name: "second"))
        XCTAssertNotEqual(other.folder, store.folder)
    }

    func testReadingAnUnreferencedBlobForAPreview() throws {
        let (vault, _, unused, _) = try setUpNotes()
        let name = try vault.blobFileName(for: unused)
        let (sha, content) = try vault.readBlobFile(note: testNote, fileName: name)
        XCTAssertEqual(sha, unused.sha256)
        XCTAssertEqual(content, Data("synthetic unused".utf8))
        XCTAssertThrowsError(try vault.readBlobFile(note: testNote, fileName: name, maxBytes: 3))
        XCTAssertThrowsError(try vault.readBlobFile(note: testNote, fileName: "../x"))
        XCTAssertThrowsError(try vault.readBlobFile(note: otherNote, fileName: name))
    }
}
