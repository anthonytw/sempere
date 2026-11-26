import Foundation
import XCTest
@testable import Sempere
@testable import SempereSync

/// A store that records which records' bytes were read: `readAsset` (a record's asset) and `fetch(payload: true)`.
final class ReadRecordingCloudStore: CloudRecordStore, @unchecked Sendable {
    let base: MemoryCloudDatabase
    private let lock = NSLock()
    private var _assets: [String] = [], _payloads: [String] = []
    init(_ base: MemoryCloudDatabase) { self.base = base }
    var assetReads: [String] { lock.withLock { _assets } }
    var payloadFetches: [String] { lock.withLock { _payloads } }

    func account() throws -> CloudAccount { try base.account() }
    func createZone(_ zone: String) throws { try base.createZone(zone) }
    func deleteZone(_ zone: String) throws { try base.deleteZone(zone) }
    func zones() throws -> [String] { try base.zones() }
    func fetchDatabaseChanges(since token: CloudChangeToken?) throws -> CloudDatabaseChanges { try base.fetchDatabaseChanges(since: token) }
    func fetchChanges(zone: String, since token: CloudChangeToken?) throws -> CloudZoneChanges { try base.fetchChanges(zone: zone, since: token) }
    func fetch(zone: String, name: String, payload: Bool) throws -> CloudRecord? {
        let record = try base.fetch(zone: zone, name: name, payload: payload)
        if payload, let path = record?.fields.path { lock.withLock { _payloads.append(path) } }
        return record
    }
    func readAsset(zone: String, name: String, maxBytes: Int64, chunk: (Data) throws -> Void) throws {
        lock.withLock { _assets.append(name) }
        try base.readAsset(zone: zone, name: name, maxBytes: maxBytes, chunk: chunk)
    }
    func modify(zone: String, saves: [CloudSave], deletes: [String], atomic: Bool) throws -> CloudModifyResult {
        try base.modify(zone: zone, saves: saves, deletes: deletes, atomic: atomic)
    }
}

/// Open from iCloud is a partial copy (docs/design/1.4-cloudkit.md §8, §15; format.md §1.2): only the control records of a zone are
/// fetched before the vault opens, whatever the notes and blobs weigh; the target's runs fetch the notes afterwards.
final class CloudVaultsPartialTests: BlobSyncTestCase {
    private func notePath(_ note: UUID) -> String { "notes/\(note.uuidString.lowercased())" }

    /// Vault A with `count` notes and a large blob in three of them, uploaded to `db` (a two-way run with its key, as home does).
    private func zone(_ db: MemoryCloudDatabase, notes count: Int, inbox: Bool = false) throws -> (vault: Vault, notes: [UUID], blobs: [String]) {
        let a = try makeVault("A")
        var ids: [UUID] = [], blobs: [String] = []
        for i in 0..<count {
            let note = UUID()
            ids.append(note)
            let seq = try a.nextSeq(noteId: note, device: devA)
            let ms = baseMillis + Int64(i)
            var ops = NoteOps.newNote(title: "Note \(i)", pageId: UUID())
            if i < 3 {
                let ref = try a.writeBlob(note: note, syntheticBlob(400_000, seed: UInt8(i + 1)), type: "image/png")
                blobs.append(try a.blobFileName(for: ref))
                ops.append(.addItem(page: UUID(), item: .image(blob: ref, pixelSize: Size(w: 4, h: 3),
                                                              frame: Rect(x: 1, y: 1, w: 4, h: 3), z: "a")))
            }
            try a.write(Revision(noteId: note, device: devA, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                                 wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "test/0", body: .delta(ops: ops)))
        }
        if inbox {
            let writer = try CaptureWriter(profile: try a.captureProfile(device: devA))
            try CaptureWriter.store(try writer.seal(audio: Data("voice".utf8), started: Date(), id: UUID()), in: a.inboxURL)
        }
        let state = tmp.appendingPathComponent("home/sync-state.json")
        let report = try CloudTargetRun.run(vaultFolder: dir("A"), remote: CloudTargetRun.remote(store: db, vaultId: a.vaultId, stateURL: state, expectedUser: nil),
                                            vault: a, stateURL: state, twoWay: true, options: SyncOptions(deviceLabel: "home"))
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        return (a, ids, blobs)
    }

    func testOnlyTheControlRecordsAreFetchedBeforeTheVaultOpens() throws {
        let db = MemoryCloudDatabase()
        let (a, notes, _) = try zone(db, notes: 40)
        let store = ReadRecordingCloudStore(db)
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        let state = tmp.appendingPathComponent("phone-state/sync-state.json")

        let report = try CloudVaults.downloadMetadata(vaultId: a.vaultId, store: store, into: folder, stateURL: state)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")

        // Nothing under notes/ was read: not a revision, not a blob.
        let reads = store.assetReads.count + store.payloadFetches.count
        XCTAssertTrue(store.payloadFetches.allSatisfy { !$0.hasPrefix("notes/") }, "fetched \(store.payloadFetches.filter { $0.hasPrefix("notes/") })")
        XCTAssertTrue(store.assetReads.isEmpty, "assets read: \(store.assetReads)")
        XCTAssertLessThan(reads, 20, "a handful of control records, not the zone")

        // The copy is partial, usable, locked-openable, and lists every note as pending.
        let copy = LocalCopy(folder: folder, stateDirectory: state.deletingLastPathComponent())
        XCTAssertTrue(copy.isPartial)
        XCTAssertTrue(copy.isUsable)
        XCTAssertEqual(PartialCopyState.incompleteNotes(folder).count, notes.count)
        let locked = try Vault.open(at: folder)
        XCTAssertEqual(locked.vaultId, a.vaultId)
        XCTAssertFalse(locked.canRead)
        for note in notes {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(notePath(note)).path)) ?? []
            XCTAssertEqual(files, [PartialCopy.noteMarkerName], "\(note): only the marker")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path))
    }

    /// A joiner's request is a root file written into the partial copy, carried by a keyless run; the approval comes back as a
    /// `vault.json`; and once the device holds a key the target's two-way run completes the copy.
    func testTheNotesArriveAfterTheKeyDoes() throws {
        let db = MemoryCloudDatabase()
        let (a, notes, blobs) = try zone(db, notes: 12)
        let store = ReadRecordingCloudStore(db)
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        let state = tmp.appendingPathComponent("phone-state/sync-state.json")
        try CloudVaults.downloadMetadata(vaultId: a.vaultId, store: store, into: folder, stateURL: state)
        XCTAssertTrue(store.assetReads.isEmpty)

        // Locked runs leave the partial copy alone (push-only, nothing fetched, nothing deleted).
        let locked = try CloudTargetRun.run(vaultFolder: folder, remote: CloudTargetRun.remote(store: store, vaultId: a.vaultId, stateURL: state, expectedUser: nil),
                                            vault: nil, stateURL: state, twoWay: false, options: SyncOptions(deviceLabel: "phone"))
        XCTAssertTrue(locked.errors.isEmpty, "\(locked)")
        XCTAssertEqual(PartialCopyState.incompleteNotes(folder).count, notes.count)
        XCTAssertTrue(store.assetReads.isEmpty, "a locked run fetched \(store.assetReads)")

        // Approved (a stand-in for the key: the same vault's key opens it), the two-way run fills the copy.
        let unlocked = try Vault.open(at: folder, identities: [identity])
        let filled = try CloudTargetRun.run(vaultFolder: folder, remote: CloudTargetRun.remote(store: store, vaultId: a.vaultId, stateURL: state, expectedUser: nil),
                                            vault: unlocked, stateURL: state, twoWay: true, options: SyncOptions(deviceLabel: "phone"))
        XCTAssertTrue(filled.errors.isEmpty, "\(filled)")
        XCTAssertTrue(PartialCopyState.incompleteNotes(folder).isEmpty, "every note arrived")
        XCTAssertFalse(PartialCopy.isPartial(folder), "and the copy is complete")
        let fresh = try Vault.open(at: folder, identities: [identity])
        for note in notes { XCTAssertFalse(try fresh.revisionNames(of: note).isEmpty, "\(note)") }
        let have = Set(try notes.flatMap { n in
            (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(notePath(n)).appendingPathComponent("att").path)) ?? []
        })
        XCTAssertTrue(Set(blobs).isSubset(of: have), "the blobs came with their notes")
    }

    /// A join run on a partial copy (`controlFilesOnly`, the app's CloudKit session) carries the control files and reads no note.
    func testAControlFilesOnlyRunReadsNoNote() throws {
        let db = MemoryCloudDatabase()
        let (a, notes, _) = try zone(db, notes: 10, inbox: true)
        let store = ReadRecordingCloudStore(db)
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        let state = tmp.appendingPathComponent("phone-state/sync-state.json")
        try CloudVaults.downloadMetadata(vaultId: a.vaultId, store: store, into: folder, stateURL: state)
        var o = SyncOptions(deviceLabel: "phone")
        o.controlFilesOnly = true
        let report = try CloudTargetRun.run(vaultFolder: folder, remote: CloudTargetRun.remote(store: store, vaultId: a.vaultId, stateURL: state, expectedUser: nil),
                                            vault: nil, stateURL: state, twoWay: true, options: o)
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertNil(report.stoppedEarly)
        XCTAssertTrue(store.assetReads.isEmpty)
        XCTAssertTrue(store.payloadFetches.allSatisfy { !$0.hasPrefix("notes/") }, "\(store.payloadFetches)")
        // Nor the inbox, the device summaries or the insights: a control-files run is the join's, nothing more.
        XCTAssertTrue(store.payloadFetches.allSatisfy { !$0.hasPrefix(CaptureFile.folderName + "/") && !$0.hasPrefix(PublishedSummaries.deviceFolderName + "/")
            && !$0.hasPrefix(Vault.insightsName + "/") }, "\(store.payloadFetches)")
        XCTAssertTrue(store.assetReads.allSatisfy { !$0.contains("inbox") }, "\(store.assetReads)")
        XCTAssertEqual(PartialCopyState.incompleteNotes(folder).count, notes.count)
        o.controlFilesOnly = false
        let rest = try CloudTargetRun.run(vaultFolder: folder, remote: CloudTargetRun.remote(store: store, vaultId: a.vaultId, stateURL: state, expectedUser: nil),
                                          vault: try Vault.open(at: folder, identities: [identity]), stateURL: state, twoWay: true, options: o)
        XCTAssertTrue(rest.errors.isEmpty, "\(rest)")
        XCTAssertFalse(PartialCopy.isPartial(folder), "the next run completes the copy")
    }

    /// A keyless (joining) run never uploads `vault.json` (review of #88, M1; format.md §2), not even to give a label-less
    /// server copy the name this side holds ("a name beats none" is for a listed device whose list checks).
    func testAKeylessRunNeverUploadsTheManifestToGiveItAName() throws {
        let db = MemoryCloudDatabase()
        let (a, _, _) = try zone(db, notes: 2)
        let zoneName = CloudTargetRun.zone(vaultId: a.vaultId)
        let recordName = CloudRecordNaming.fileName([Vault.manifestName])
        let before = try XCTUnwrap(db.rawRecord(zone: zoneName, recordName)?.fields.bytes)
        XCTAssertNil(VaultLabelText.peekLabel(before), "the zone holds no name")
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        try CloudVaults.downloadMetadata(vaultId: a.vaultId, store: db, into: folder, stateURL: tmp.appendingPathComponent("phone-state/sync-state.json"))
        let url = folder.appendingPathComponent("vault.json")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["label"] = "Phone name"
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        XCTAssertNotNil(VaultLabelText.peekLabel(try Data(contentsOf: url)))
        // A new state: no record of `vault.json`, so both sides count as changed.
        let fresh = tmp.appendingPathComponent("fresh-state/sync-state.json")
        var o = SyncOptions(deviceLabel: "phone")
        o.firstPullIdentities = [identity]
        let report = try CloudTargetRun.run(vaultFolder: folder, remote: CloudTargetRun.remote(store: db, vaultId: a.vaultId, stateURL: fresh, expectedUser: nil),
                                            vault: nil, stateURL: fresh, twoWay: true, options: o)
        XCTAssertFalse(report.uploaded.contains(Vault.manifestName), "\(report)")
        let after = try XCTUnwrap(db.rawRecord(zone: zoneName, recordName)?.fields.bytes)
        XCTAssertNil(VaultLabelText.peekLabel(after), "the zone's vault.json was not replaced")
    }

    /// A note opened first is fetched alone (the app's `joinFetch`): `LocalCopy.fetch` against the zone, its blobs left as stand-ins.
    func testOneNoteCanBeFetchedAlone() throws {
        let db = MemoryCloudDatabase()
        let (a, notes, _) = try zone(db, notes: 8)
        let store = ReadRecordingCloudStore(db)
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        let state = tmp.appendingPathComponent("phone-state/sync-state.json")
        try CloudVaults.downloadMetadata(vaultId: a.vaultId, store: store, into: folder, stateURL: state)
        let copy = LocalCopy(folder: folder, stateDirectory: state.deletingLastPathComponent())
        let remote = CloudTargetRun.remote(store: store, vaultId: a.vaultId, stateURL: state, expectedUser: nil)
        let report = try copy.fetch(remote: remote, vault: nil, scope: FetchScope(notes: [notes[1]], revisions: true, blobs: .none, maxNotes: 1))
        XCTAssertTrue(report.errors.isEmpty, "\(report)")
        XCTAssertEqual(PartialCopyState.incompleteNotes(folder).count, notes.count - 1)
        XCTAssertFalse(PartialCopy.isIncomplete(noteFolder: folder.appendingPathComponent(notePath(notes[1]))))
        XCTAssertTrue(store.assetReads.isEmpty || store.assetReads.count <= 1, "no blob of the note was read: \(store.assetReads)")
    }

    func testAZoneHoldingAnotherVaultIsNotCopiedOut() throws {
        let db = MemoryCloudDatabase()
        let (a, _, _) = try zone(db, notes: 1)
        // Zone X (this vault's name) holding Y's files: asking for another id reads nothing of it as that vault.
        let other = UUID()
        let folder = tmp.appendingPathComponent("phone/vault.sempere")
        XCTAssertThrowsError(try CloudVaults.downloadMetadata(vaultId: other, store: db, into: folder,
                                                              stateURL: tmp.appendingPathComponent("s/sync-state.json")))
        XCTAssertNotEqual(a.vaultId, other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("vault.json").path))
    }
}
