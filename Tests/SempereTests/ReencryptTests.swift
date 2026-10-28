import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Re-encrypt everything in core (key-hierarchy design §7, §11.1; phase KH6), with in-process devices sharing one
/// vault folder: the start (journal, epoch with no parent key), the pass (every accepted file under the new key, each
/// verified first), the finish (vault.json re-signed without the binding, the journal and the earlier records gone),
/// a crash at every `EpochFaults` point of the pass, a removal during the pass, and replayed or stripped bindings.
/// J7 (completeness) is checked by trying every age file of the vault folder with every earlier key.
final class ReencryptTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    override func tearDown() {
        Vault.epochMutations = []
        super.tearDown()
    }

    /// A vault of A (home), B and X at epoch 2 (X removed), with notes, a blob, a notebook record and settings
    /// under both epochs; the earlier keys (every vault identity so far and the first kit).
    private var staleX: Vault?

    private func world(_ sub: String = "w") throws -> (EpochWorld, notes: [UUID: String], blob: (UUID, BlobRef), old: [any AgeIdentity]) {
        let dir = tmp.appendingPathComponent(sub)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = try EpochWorld(in: dir, names: ["A", "B", "X"])
        var a = try w.open("A")
        var notes: [UUID: String] = [:]
        notes[try w["A"].newNote(a, "A one")] = "A one"
        let b = try w.open("B")
        let nb = try w["B"].newNote(b, "B one")
        notes[nb] = "B one"
        let ref = try b.writeBlob(note: nb, Data("attachment bytes".utf8), type: "image/png")
        _ = try b.createNotebook("Work/Projects")
        var s = SharedSettings()
        try s.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: .mac, now: Date())
        try b.writeSharedSettings(s)
        staleX = try w.open("X")
        try a.removeDevices([w["X"].id])
        a = try w.open("A")
        notes[try w["A"].newNote(a, "A two")] = "A two"
        let old: [any AgeIdentity] = a.identities + a.olderEpochs.map { $0.identity as any AgeIdentity }
            + [NativeIdentity.mlkem768x25519(w.recovery)]
        return (w, notes, (nb, ref), old)
    }

    /// J7 here: every age file of the vault folder that opens with one of `old`, and every wrap in vault.json.
    private func openWithOld(_ url: URL, _ old: [any AgeIdentity]) throws -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL {
            guard f.pathExtension == "age", let data = try? Data(contentsOf: f) else { continue }
            for k in old where (try? AgeFile.decrypt(data, with: [k])) != nil {
                out.append(String(f.path.dropFirst(url.path.count + 1)))
                break
            }
        }
        let m = try EpochManifest.parse(Data(contentsOf: url.appendingPathComponent("vault.json")))
        for k in m.keys {
            let wrap = Data(k.wrap.utf8)
            if old.contains(where: { (try? AgeFile.decrypt(wrap, with: [$0])) != nil }) { out.append("vault.json \(k.role)") }
        }
        return out
    }

    private func start(_ w: EpochWorld, keep: [String] = ["B"]) throws -> (Vault, MLKEM768X25519Identity) {
        var a = try w.open("A")
        let kit = try MLKEM768X25519Identity()
        let prep = try a.prepareReencryption(kit, keep: Set(keep.map { w[$0].id }), remove: [])
        try a.beginReencryption(prep)
        return (a, kit)
    }

    func testReencryptEverythingOnASharedFolder() throws {
        let (w, notes, blob, old) = try world()
        XCTAssertFalse(try openWithOld(w.url, old).isEmpty)
        var (a, kit) = try start(w)
        XCTAssertTrue(a.isReencryptPending)
        XCTAssertEqual(a.reencryptEpoch?.epoch, 3)
        // Written under the new key from the start; the old files still read through the journal.
        let b = try w.open("B")
        XCTAssertEqual(try w.titles(b), notes)
        XCTAssertEqual(try b.readBlob(note: blob.0, blob.1), Data("attachment bytes".utf8))
        let status = try a.reencryptStatus()
        XCTAssertTrue(status.pending && status.journalHere)
        XCTAssertGreaterThanOrEqual(status.remaining, 6, "\(status)")

        let pass = try a.reencryptPass()
        XCTAssertTrue(pass.problems.isEmpty && pass.left.isEmpty, "\(pass)")
        XCTAssertEqual(pass.reencrypted.count, 6, "\(pass.reencrypted)")
        XCTAssertEqual(pass.oldBlobsDeleted.count, 1)
        XCTAssertEqual(try a.reencryptStatus().remaining, 0)
        // Nothing to redo: the pass resumes where it stopped.
        XCTAssertTrue(try a.reencryptPass().reencrypted.isEmpty)
        // Before the finish the earlier records and the journal still open with the earlier keys.
        XCTAssertFalse(try openWithOld(w.url, old).isEmpty)

        try a.finishReencryption()
        XCTAssertFalse(a.isReencryptPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.url.appendingPathComponent(Vault.journalName).path))
        XCTAssertEqual(try openWithOld(w.url, old), [], "J7")
        XCTAssertEqual(try w["A"].trust.record(for: a.vaultId)?.reencryptFinished, a.manifest.epochId)
        for n in ["A", "B"] {
            let v = try w.open(n)
            XCTAssertEqual(try w.titles(v), notes, n)
            XCTAssertEqual(try v.readBlob(note: blob.0, blob.1), Data("attachment bytes".utf8), n)
            XCTAssertEqual(try v.readNotebookRecords().records.count, 1, n)
            XCTAssertNotNil(try v.readSharedSettingsFile(), n)
            XCTAssertTrue(v.verify().isHealthy, n)
            XCTAssertNoThrow(try v.requireWritable(), n)
        }
        // The new kit reads everything; the old one opens nothing in the vault.
        let byKit = try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(kit)], root: w.root)
        XCTAssertEqual(try w.titles(byKit), notes)
        XCTAssertThrowsError(try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(w.recovery)], root: w.root))
        // The kit's frozen script reads a re-encrypted note with the new key alone.
        XCTAssertEqual(try w.titles(try w.open("B")), notes)
    }

    /// Sync stress seeds 45 and 27: after a finish, the record of the re-encryption epoch still holds the sealed set of
    /// the epoch before it, but a copy under that epoch's key is from before the re-encryption: set aside, never
    /// accepted (or it is downloaded again and kept). And a second re-encryption, while pending, judges files below
    /// the first (finished) one the same way, so its pass is never left waiting on records the first one deleted.
    func testAfterAFinishTheEarlierKeysAcceptNothing() throws {
        let (w, _, blob, _) = try world()
        let before = try w.open("A")
        let att = w.url.appendingPathComponent("notes/\(blob.0.uuidString.lowercased())/att")
        let blobName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: att.path).first { BlobName.parse($0) != nil })
        let oldBlob = try Data(contentsOf: att.appendingPathComponent(blobName))
        let place = att.appendingPathComponent(blobName)
        XCTAssertEqual(before.blobStanding(place, note: blob.0), .old(epoch: 1, accepted: true))
        let paths = try before.noteDirectoryNames().flatMap { note -> [String] in
            guard let id = UUID(uuidString: note) else { return [] }
            return try before.revisionFileNames(in: before.noteURL(id)).map { Vault.notePath(id, $0) }
        }
        let p = try XCTUnwrap(paths.first)
        let oldBytes = try Data(contentsOf: w.url.appendingPathComponent(p))
        XCTAssertTrue(before.acceptance(of: oldBytes, path: p).isAccepted)
        var (a, _) = try start(w)
        _ = try a.reencryptPass()
        try a.finishReencryption()
        a = try w.open("A")
        XCTAssertEqual(a.acceptance(of: oldBytes, path: p), .setAside(.beforeReencryption))
        // The old blob arriving again under its old name (another device's upload): not accepted either.
        XCTAssertFalse(FileManager.default.fileExists(atPath: place.path), "the pass deleted the old name")
        try oldBlob.write(to: place)
        XCTAssertEqual(a.blobStanding(place, note: blob.0), .old(epoch: 1, accepted: false), "a blob too")
        try FileManager.default.removeItem(at: place)
        // A second re-encryption: the copy below the first still reads so while the second is pending, and the pass
        // has nothing it must wait for.
        var (a2, _) = try start(w)
        XCTAssertTrue(a2.isReencryptPending)
        XCTAssertEqual(a2.acceptance(of: oldBytes, path: p), .setAside(.beforeReencryption))
        XCTAssertFalse(a2.keyring?.isIncomplete ?? true)
        let pass = try a2.reencryptPass()
        XCTAssertTrue(pass.problems.isEmpty, "\(pass.problems)")
        try a2.finishReencryption()
        a2 = try w.open("A")
        XCTAssertFalse(a2.isReencryptPending)
    }

    /// Review of #89 re-check, R1: a value opened before another process began the re-encryption (the CLI, another
    /// window) never abandons its bound journal as "a start that stopped": it is judged against the disk's vault.json,
    /// under the write lock. Removals and the pass go on afterwards.
    func testAStaleValueNeverAbandonsABoundJournal() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        let stale = try w.open("A")
        var a = try w.open("A")
        let prep = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id, w["C"].id], remove: [])
        try a.beginReencryption(prep)
        let journalURL = w.url.appendingPathComponent(Vault.journalName)
        XCTAssertNil(try stale.abandonReencryptionStart(), "nothing to abandon: the disk binds it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path), "the bound journal is still here")
        var fresh = try w.open("A")
        XCTAssertNotNil(fresh.localBoundJournal())
        XCTAssertNoThrow(try fresh.removeDevices([w["C"].id]))
        fresh = try w.open("A")
        XCTAssertNoThrow(try fresh.reencryptPass())
        // A real leftover (prepared, never begun) still goes.
        let w2 = try EpochWorld(in: tmp.appendingPathComponent("leftover"), names: ["A", "B"])
        let b = try w2.open("A")
        let left = try b.prepareReencryption(try MLKEM768X25519Identity(), keep: [w2["B"].id], remove: [])
        XCTAssertEqual(try w2.open("A").abandonReencryptionStart(), left.journalFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w2.url.appendingPathComponent(Vault.journalName).path))
    }

    /// Re-check T1: the finish sweeps temporary files a crash left, but never a resumable blob download
    /// (`att/.sempere-tmp-part-…`), which the sync engine keeps.
    func testTheFinishSweepKeepsResumableDownloads() throws {
        let (w, _, blob, _) = try world()
        let att = w.url.appendingPathComponent("notes/\(blob.0.uuidString.lowercased())/att")
        let partial = att.appendingPathComponent(".sempere-tmp-part-0123")
        let leftover = att.deletingLastPathComponent().appendingPathComponent(".sempere-tmp-4567")
        try Data("partial".utf8).write(to: partial)
        try Data("leftover".utf8).write(to: leftover)
        var (a, _) = try start(w)
        _ = try a.reencryptPass()
        Vault.staleTemporaryAge = 0
        defer { Vault.staleTemporaryAge = 3600 }
        try a.finishReencryption()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "the resumable download stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "the crash leftover goes")
    }

    /// Review of #89, S4: a settings write that lands while the pass re-encrypts `settings.age` is never undone: the
    /// pass places its copy only under the write lock and only when the file still holds the bytes it read; the next
    /// pass re-encrypts the newer settings.
    func testASettingsWriteDuringThePassIsKept() throws {
        let (w, _, _, _) = try world()
        var (a, _) = try start(w)
        let b = try w.open("B")
        var newer = try XCTUnwrap(b.readSharedSettings())
        try newer.set(SettingSlotKey("photos.removeMetadata"), to: .bool(true), type: .mac, now: Date().addingTimeInterval(60))
        Vault.beforeSettingsPlaced = { try? b.writeSharedSettings(newer) }
        defer { Vault.beforeSettingsPlaced = nil }
        let first = try a.reencryptPass()
        XCTAssertNotNil(first.problems[SharedSettings.fileName], "\(first.problems)")
        Vault.beforeSettingsPlaced = nil
        a = try w.open("A")
        let second = try a.reencryptPass()
        XCTAssertTrue(second.problems.isEmpty, "\(second.problems)")
        let after = try XCTUnwrap(try w.open("A").readSharedSettings())
        XCTAssertEqual(after.value(SettingSlotKey("photos.removeMetadata")), .bool(true), "the newer write is kept")
    }

    /// §11.1 `EpochFaults`: a crash at every point of the pass, for the first, a middle and the last file; the
    /// pass then resumes, the finish completes, nothing is lost (J1) and no path holds two bodies (J8).
    func testACrashAtEveryPassPointResumes() throws {
        let points: [(Int) -> EpochFaults.Point] = [{ .reencryptWritten($0) }, { .reencryptVerified($0) },
                                                    { .reencryptRecorded($0) }, { .reencryptPlaced($0) },
                                                    { .beforeOldBlobDeleted($0) }]
        var fired = 0
        var leftBehind = 0
        var kinds = Set<String>()
        for make in points {
            for n in 1...8 {
                let (w, notes, blob, old) = try world("\(make(n))-\(n)")
                var (a, _) = try start(w)
                var bodies: [String: Data] = [:]
                func checkBodies(_ v: Vault, _ when: String) throws {
                    for p in SyncFiles.all(in: w.url) where Vault.framing(p) != nil {
                        guard let d = try? Data(contentsOf: w.url.appendingPathComponent(p)), let body = v.plainBody(of: d, path: p)
                        else { continue }
                        if let first = bodies[p] { XCTAssertEqual(first, body, "J8 \(p) \(when)") }
                        bodies[p] = bodies[p] ?? body
                    }
                }
                try checkBodies(a, "before")
                // A real crash: nothing cleaned up on the way out (review of #89, S9).
                a.faults = EpochFaults(stop: make(n), crash: true)
                do { _ = try a.reencryptPass(); continue } catch VaultError.interrupted { fired += 1; kinds.insert(String("\(make(n))".prefix { $0 != "(" })) }
                let leftovers = Self.temporaryFiles(w.url)
                leftBehind += leftovers.count
                a = try w.open("A")
                try checkBodies(a, "after the crash at \(make(n))")
                XCTAssertEqual(try w.titles(try w.open("B")), notes, "\(make(n)) J1")
                let again = try a.reencryptPass()
                XCTAssertTrue(again.problems.isEmpty, "\(make(n)): \(again.problems)")
                // The leftovers are ignored meanwhile, and the finish sweeps them once stale.
                Vault.staleTemporaryAge = 0
                defer { Vault.staleTemporaryAge = 3600 }
                try a.finishReencryption()
                XCTAssertEqual(Self.temporaryFiles(w.url), [], "\(make(n)) swept")
                try checkBodies(a, "finished")
                XCTAssertEqual(try openWithOld(w.url, old), [], "\(make(n)) J7")
                let b = try w.open("B")
                XCTAssertEqual(try w.titles(b), notes, "\(make(n))")
                XCTAssertEqual(try b.readBlob(note: blob.0, blob.1), Data("attachment bytes".utf8), "\(make(n))")
                XCTAssertTrue(b.verify().isHealthy, "\(make(n))")
            }
        }
        // Every point of a framed file, for most files (the blob's own point: `testACrashBeforeTheOldBlobNameGoes`).
        XCTAssertTrue(kinds.isSuperset(of: ["reencryptWritten", "reencryptVerified", "reencryptRecorded", "reencryptPlaced"]), "\(kinds)")
        XCTAssertGreaterThanOrEqual(fired, 20)
        XCTAssertGreaterThan(leftBehind, 0, "the crashes left temporary files behind, as a real crash does")
    }

    /// Temporary files (`.sempere-tmp-…`) anywhere in the vault folder.
    static func temporaryFiles(_ url: URL) -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL { if f.lastPathComponent.hasPrefix(".sempere-tmp-") { out.append(f.lastPathComponent) } }
        return out
    }

    /// The blob's own point: the new name is in place and verified, the old name not deleted yet. The pass resumes and
    /// deletes it; the attachment reads throughout.
    func testACrashBeforeTheOldBlobNameGoes() throws {
        // A fresh vault per try (a pass that does not stop does everything), until the blob's turn.
        var found: (EpochWorld, UUID, BlobRef, Vault)?
        for n in 1...4 where found == nil {
            let dir = tmp.appendingPathComponent("blob-\(n)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let w = try EpochWorld(in: dir, names: ["A", "B"])
            let b = try w.open("B")
            let note = try w["B"].newNote(b, "with a blob")
            let ref = try b.writeBlob(note: note, Data("blob only".utf8), type: "image/png")
            var a = try w.open("A")
            let prep = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: [])
            try a.beginReencryption(prep)
            a.faults = EpochFaults(stop: .beforeOldBlobDeleted(n))
            do { _ = try a.reencryptPass() } catch VaultError.interrupted { found = (w, note, ref, try w.open("A")) }
        }
        guard let (w, note, ref, a) = found else { return XCTFail("the blob's point was never reached") }
        let att = w.url.appendingPathComponent("notes/\(note.uuidString.lowercased())/att")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: att.path).filter { !$0.hasPrefix(".") }.count, 2, "both names")
        XCTAssertEqual(try w.open("B").readBlob(note: note, ref), Data("blob only".utf8))
        let again = try a.reencryptPass()
        XCTAssertEqual(again.oldBlobsDeleted.count, 1, "\(again)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: att.path).filter { !$0.hasPrefix(".") }.count, 1)
        var done = a
        try done.finishReencryption()
        XCTAssertEqual(try w.open("B").readBlob(note: note, ref), Data("blob only".utf8))
    }

    /// A start that stops after its journal (a refused claim, a crash): nothing binds it, no reader takes a key from
    /// it, and abandoning it gives the claim's bytes and leaves the vault as it was.
    func testAStartThatDoesNotReachItsEpochIsAbandoned() throws {
        let (w, notes, _, _) = try world()
        var a = try w.open("A")
        a.faults = EpochFaults(stop: .afterJournal)
        XCTAssertThrowsError(try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: []))
        a = try w.open("A")
        XCTAssertFalse(a.isReencryptPending)
        let journal = try Data(contentsOf: w.url.appendingPathComponent(Vault.journalName))
        XCTAssertNil(a.boundJournal(journal))
        XCTAssertEqual(try a.abandonReencryptionStart(), journal)
        XCTAssertNil(try a.abandonReencryptionStart())
        XCTAssertEqual(try w.titles(try w.open("B")), notes)
        // A fresh start works.
        _ = try start(w)
    }

    /// A finish that stops after its vault.json: the leftover journal is unbound (abandoned like a start's), the
    /// earlier records go the next time.
    func testAFinishThatStopsBeforeTheJournalGoes() throws {
        let (w, notes, _, old) = try world()
        var (a, _) = try start(w)
        _ = try a.reencryptPass()
        a.faults = EpochFaults(stop: .beforeJournalRemoved)
        XCTAssertThrowsError(try a.finishReencryption())
        a = try w.open("A")
        XCTAssertFalse(a.isReencryptPending)
        XCTAssertNotNil(try a.abandonReencryptionStart())
        a.removeRecordsBelowReencryption()
        XCTAssertEqual(try openWithOld(w.url, old), [])
        XCTAssertEqual(try w.titles(try w.open("B")), notes)
    }

    /// §7.2: a removal during the pass is an ordinary epoch whose vault.json keeps the journal bound (under its own
    /// key); the pass continues under it.
    func testARemovalDuringThePassKeepsTheJournalBound() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var a = try w.open("A")
        var notes: [UUID: String] = [:]
        for n in ["A", "B", "C"] {
            let v = try w.open(n)
            notes[try w[n].newNote(v, "\(n) note")] = "\(n) note"
        }
        let old: [any AgeIdentity] = a.identities + [NativeIdentity.mlkem768x25519(w.recovery)]
        let prep = try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id, w["C"].id], remove: [])
        try a.beginReencryption(prep)
        XCTAssertEqual(try a.reencryptPass(limit: 1).remaining, 2)
        try a.removeDevices([w["C"].id])
        a = try w.open("A")
        XCTAssertEqual(a.manifest.epoch, 3)
        XCTAssertTrue(a.isReencryptPending)
        XCTAssertNotNil(a.localBoundJournal())
        XCTAssertEqual(try a.reencryptPass().problems, [:])
        try a.finishReencryption()
        XCTAssertEqual(try openWithOld(w.url, old), [])
        XCTAssertEqual(try w.titles(try w.open("B")), notes)
        XCTAssertThrowsError(try w.open("C").requireWritable())
    }

    /// A removed device's write under an earlier key is never re-encrypted ("never launder"): it is set aside, and the
    /// finish takes it out of the working copy (J7), kept in the set-aside store.
    func testAnUnacceptedOldFileIsNeverLaundered() throws {
        let (w, notes, _, old) = try world()
        // X, removed at epoch 2, writes under the key it holds into the shared folder.
        let rogue = UUID()
        let stale = try XCTUnwrap(staleX)
        try stale.apply(NoteOps.newNote(title: "rogue", paper: .ruled, pageId: UUID()), to: rogue,
                        deviceState: tmp.appendingPathComponent("x-device.json"), app: "test/1")
        var (a, _) = try start(w)
        let pass = try a.reencryptPass()
        XCTAssertEqual(pass.left.count, 1, "\(pass.left)")
        try a.finishReencryption()
        XCTAssertEqual(try openWithOld(w.url, old), [])
        XCTAssertNil(try w.titles(a)[rogue])
        XCTAssertTrue(w["A"].setAside.items(vaultId: a.vaultId).contains { $0.path.contains(rogue.uuidString.lowercased()) })
        XCTAssertEqual(try w.titles(try w.open("B")), notes)
    }

    /// The binding is signed (authorSig): stripped by anyone but home, the list is tampered; put back after the
    /// finish (a replayed journal), it is refused by every device that saw the finish.
    func testAStrippedOrReplayedBindingIsRefused() throws {
        let (w, _, _, _) = try world()
        var (a, _) = try start(w)
        let manifestURL = w.url.appendingPathComponent(Vault.manifestName)
        let pendingBytes = try Data(contentsOf: manifestURL)
        let journal = try Data(contentsOf: w.url.appendingPathComponent(Vault.journalName))
        var stripped = try EpochManifest.parse(pendingBytes)
        stripped.reencryptPending = nil
        try stripped.encoded().write(to: manifestURL)
        XCTAssertEqual(try w.open("B").listStatus.problem?.reason, .authorSig)
        try pendingBytes.write(to: manifestURL)
        _ = try w.open("B").requireWritable()   // B pins the pending version
        _ = try a.reencryptPass()
        try a.finishReencryption()
        _ = try w.open("B").requireWritable()   // and sees the finish
        XCTAssertNotNil(try w["B"].trust.record(for: a.vaultId)?.reencryptFinished)
        // Storage puts the pending version and its journal back.
        try pendingBytes.write(to: manifestURL)
        try journal.write(to: w.url.appendingPathComponent(Vault.journalName))
        for n in ["A", "B"] {
            XCTAssertEqual(try w.open(n).listStatus.problem?.reason, .reencryptRolledBack, n)
        }
        // The later version (the finish) is home's later version of the same epoch, never the other way round.
        let v = try w.open("A")
        let pending = try EpochManifest.parse(pendingBytes)
        XCTAssertFalse(v.isLaterVersion(pending, of: v.manifest))
    }

    /// Only home re-encrypts; a review must name every device; a second start waits for the first's finish.
    func testPreconditions() throws {
        let (w, _, _, _) = try world()
        let b = try w.open("B")
        XCTAssertThrowsError(try b.prepareReencryption(try MLKEM768X25519Identity(), keep: [], remove: []))
        let a = try w.open("A")
        XCTAssertThrowsError(try a.prepareReencryption(try MLKEM768X25519Identity(), keep: [], remove: []))
        _ = try start(w)
        XCTAssertThrowsError(try w.open("A").prepareReencryption(try MLKEM768X25519Identity(), keep: [w["B"].id], remove: []))
        XCTAssertThrowsError(try w.open("B").reencryptPass())
        var a2 = try w.open("A")
        XCTAssertThrowsError(try a2.finishReencryption(), "the pass has work left")
    }
}

/// Paths of every regular file below a vault folder (relative), hidden ones left out.
enum SyncFiles {
    static func all(in url: URL) -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let f = e?.nextObject() as? URL {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(String(f.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1)))
            }
        }
        return out.sorted()
    }
}

/// A kit replacement (a re-encryption is one) above a takeover this device pinned: the takeover stays valid on the
/// pinned chain (found by the KH6 interleaving runs: the frontier kit rule re-judged it under the new kit).
final class TakeoverThenKitReplacementTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    func testAKitReplacementAboveAPinnedTakeoverKeepsTheVaultWritable() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let (b, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [w["A"].fingerprint],
                                        trust: w["B"].trust, root: w.root, ledger: w["B"].ledger, setAside: w["B"].setAside)
        var home = b
        try home.replaceRecoveryKit(try MLKEM768X25519Identity(), keep: [w["A"].id], remove: [])
        let again = try w.open("B")
        XCTAssertNil(again.listStatus.problem, "\(again.listStatus)")
        XCTAssertNoThrow(try again.requireWritable())
        var r = try w.open("B")
        let prep = try r.prepareReencryption(try MLKEM768X25519Identity(), keep: [w["A"].id], remove: [])
        try r.beginReencryption(prep)
        XCTAssertNil(try w.open("B").listStatus.problem)
        XCTAssertNil(try w.open("A").listStatus.problem)
    }
}
