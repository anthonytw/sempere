import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// The key-change safety gate (docs/design/device-first-sync.md §6.4): one
/// test per failure F1 to F19 of §6.2, each asserting the invariant that
/// keeps data recoverable, over `MemoryRemote` and the WebDAV mock.
final class KeyChangeScenarioTests: TempDirTestCase {
    let n1 = UUID(uuidString: "6b000000-0000-4000-8000-000000000001")!
    let n2 = UUID(uuidString: "6b000000-0000-4000-8000-000000000002")!

    func world(webdav: Set<Int> = [], uses: [[Int]]? = nil, devices: Int = 3, kinds: [KCTarget.Kind]? = nil) throws -> KCWorld {
        try KCWorld(root: tmp.appendingPathComponent("w\(UUID().uuidString.prefix(6))"), deviceCount: devices,
                    webdav: webdav, uses: uses, kinds: kinds)
    }

    /// A world with a few notes on every side, in step.
    func seeded(webdav: Set<Int> = [], uses: [[Int]]? = nil, kinds: [KCTarget.Kind]? = nil) throws -> KCWorld {
        let w = try world(webdav: webdav, uses: uses, kinds: kinds)
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        try w.converge()
        return w
    }

    // MARK: The happy path

    func testARoutineRemovalReachesEveryDeviceAndTarget() throws {
        let kinds: [[KCTarget.Kind]] = [[.memory, .memory], [.memory, .webdav], [.folder, .evicting]]
        for k in kinds {
            let w = try seeded(kinds: k)
            let spare = try w.addSpare(on: w.a)
            try w.converge()
            w.assertConverged()
            try w.change(w.b) { try $0.prepareRemoveRecipient(spare.recipient) }
            try w.converge()
            w.assertConverged()
            w.assertRevoked([spare])
            w.assertNoLoss()
            XCTAssertFalse(w.b.coordinator.inProgress)
        }
    }

    // MARK: Helpers

    func path(_ note: UUID, _ n: RevisionName) -> [String] { [Vault.notesName, note.uuidString.lowercased(), n.filename] }

    /// A revision written by `d` under the current (soon old) list and taken out of its working copy:
    /// the bytes stand for a file that reaches a target only after a key change (written offline elsewhere).
    func offlineRevision(_ w: KCWorld, _ d: KCDevice, _ note: UUID, _ title: String) throws -> (path: [String], data: Data) {
        let n = try w.write(d, note, title)
        let p = path(note, n)
        let url = d.folder.appendingPathComponent(p.joined(separator: "/"))
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        return (p, data)
    }

    /// A removal of the spare key from `d` whose propagation stops after C5(a) on T0, so that `seers`
    /// take the step-2 vault.json and the journal (the policy) there; then it finishes everywhere.
    func removeSpareSeenBy(_ w: KCWorld, on d: KCDevice, policy: KeyChangePolicy, seers: [KCDevice]) throws {
        let spare = try XCTUnwrap(w.spare)
        try w.change(d) { try $0.prepareRemoveRecipient(spare.recipient, keyChange: policy) }
        w.tick()
        XCTAssertThrowsError(try d.sync("T0", now: w.now, faults: KeyChangeFaults(afterStep: ["T0": .manifest])))
        for s in seers {
            w.tick()
            let r = try s.sync("T0", now: w.now)
            XCTAssertTrue(r.downloaded.contains(Vault.journalName), "\(s.name) takes the journal: \(KCWorld.brief(r))")
        }
    }

    // MARK: F1 to F3: crashes on the device making the change

    /// F1: the claims written, then a crash before K1: they bind nothing; others hold them as in flight
    /// and never take them; the next launch takes them back.
    func testCrashAfterClaim() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let before = w.everyCopy().map { "\($0.0)/\($0.1)" }.sorted()
        let manifest = w.a.manifest()
        XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(afterClaims: true)) {
            try $0.prepareRemoveRecipient(spare.recipient)
        })
        for t in w.targets { XCTAssertNotNil(t.file([Vault.journalName]), "\(t.name): claimed") }
        XCTAssertEqual(w.a.manifest(), manifest, "no file changed")
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertTrue(r.rejected.isEmpty && !r.downloaded.contains(Vault.journalName), "held as in flight: \(KCWorld.brief(r))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.b.folder.appendingPathComponent(Vault.journalName).path))
        // The next launch: no local change behind the claims, so they are taken back.
        var v = try w.a.vault()
        XCTAssertFalse(try w.a.coordinator.recover(&v))
        for t in w.targets { XCTAssertNil(t.file([Vault.journalName]), "\(t.name): claim taken back") }
        try w.converge()
        XCTAssertEqual(w.everyCopy().map { "\($0.0)/\($0.1)" }.sorted(), before)
        w.assertConverged()
        w.assertNoLoss()
    }

    /// F2: a crash between K1 and K2 leaves an unbound journal, which this device refuses and so never
    /// uploads, even to a target its claim did not reach.
    func testCrashAfterJournal() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(rewrap: RewrapFaults(stop: .afterJournal))) {
            try $0.prepareRemoveRecipient(spare.recipient)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.a.folder.appendingPathComponent(Vault.journalName).path))
        XCTAssertTrue(try w.a.vault().journalRefused, "unbound: refused at open")
        // A target the claim never reached: a plain run does not upload the journal.
        w.targets[1].remove([Vault.journalName])
        w.tick()
        let plain = try SyncEngine(directory: w.a.folder, vault: try w.a.vault(), remote: w.targets[1].remote(),
                                   stateURL: w.a.stateURL("T1"), options: w.a.options(w.now)).run()
        XCTAssertFalse(plain.uploaded.contains(Vault.journalName), "\(KCWorld.brief(plain))")
        XCTAssertNil(w.targets[1].file([Vault.journalName]))
        try w.converge()
        XCTAssertFalse(w.a.coordinator.inProgress)
        w.assertConverged()
        w.assertNoLoss()
        XCTAssertNotNil(w.spare.map { s in w.a.manifest().map { String(decoding: $0, as: UTF8.self).contains(s.recipient.string) } })
    }

    /// F3: a crash after file n of K3, for n across revisions and blobs: files not yet rewrapped still
    /// verify (under the journal's outgoing secret, and from the keyring); the change resumes and propagates.
    func testCrashDuringRewrap() throws {
        for n in 0...3 {
            let w = try seeded()
            try w.a.attach(n1, Data("blob \(n)".utf8), now: w.now)
            try w.converge()
            let spare = try w.addSpare(on: w.a)
            try w.converge()
            XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(rewrap: RewrapFaults(stop: .afterFiles(n)))) {
                try $0.prepareRemoveRecipient(spare.recipient)
            }, "n = \(n)")
            let v = try w.a.vault()
            XCTAssertNotNil(v.previousSecret, "n = \(n): the journal is accepted")
            XCTAssertTrue(v.verify().files.allSatisfy { $0.status == .ok || $0.status == .staleRecipients }, "n = \(n): every file still verifies")
            XCTAssertNotNil(try w.a.keyring.load(vaultId: v.vaultId)?.lateFileDeadline(for: try XCTUnwrap(v.previousSecret)),
                            "n = \(n): the keyring holds the outgoing secret")
            try w.converge()
            w.assertConverged()
            w.assertRevoked([spare])
            w.assertNoLoss()
        }
    }

    // MARK: F4

    /// F4: the outgoing identity of a replace is kept while the replace is pending (the app guard's rule).
    func testReplaceKeepsOldKey() throws {
        let w = try seeded()
        let old = w.a.identity, new = pqIdentity()
        w.a.identities.insert(new, at: 0)
        XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(rewrap: RewrapFaults(stop: .afterFiles(1)))) {
            try $0.prepareReplaceRecipient(old.recipient, with: new.recipient)
        })
        let pending = try w.a.vault()
        XCTAssertTrue(pending.pendingRewrap)
        XCTAssertNotNil(OutgoingKeyGuard.refusal(recipient: old.recipient.string, vault: pending, targetsPending: false))
        XCTAssertNil(OutgoingKeyGuard.refusal(recipient: new.recipient.string, vault: pending, targetsPending: false))
        // Without the old key the files not yet rewrapped do not open: it must not be forgotten.
        let withoutOld = try Vault.open(at: w.a.folder, identities: [new], trust: w.a.trust)
        XCTAssertFalse(withoutOld.verify().isHealthy)
        try w.converge()
        XCTAssertNotNil(OutgoingKeyGuard.refusal(recipient: old.recipient.string, vault: try w.a.vault(), targetsPending: true),
                        "a target still pending keeps it too")
        XCTAssertNil(OutgoingKeyGuard.refusal(recipient: old.recipient.string, vault: try w.a.vault(), targetsPending: false))
        w.assertConverged()
        w.assertRevoked([old])
        w.assertNoLoss()
    }

    // MARK: F5, F6: partial propagation and order

    /// F5: A stops after C5(a): B takes the new vault.json and journal, finishes the rewrap itself and
    /// replaces the target's copies; A comes back later; both-current copies converge by the tie-break.
    func testPartialUploadThenOtherDeviceFinishes() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try removeSpareSeenBy(w, on: w.a, policy: .routine, seers: [w.b])
        var vb = try w.b.vault()
        XCTAssertNotNil(vb.previousSecret)
        XCTAssertTrue(try vb.resumeRewrap().isComplete)
        // A stays away: the others sync (T1 keeps A's claim, which they refuse and cannot remove).
        for _ in 0..<3 { for d in [w.b, w.c] { _ = d.syncAll(now: w.now); w.tick() } }
        XCTAssertEqual(w.targets[0].file([Vault.manifestName]), w.b.manifest(), "B's finished change is on T0")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// F6: the rewritten files reach a target before its vault.json: a device on the old list never
    /// pushes its copies over them, and they are never placed under a list it does not hold.
    func testFilesBeforeManifest() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let bBefore = w.b.noteFiles()
        try w.change(w.a, syncFirst: false) { try $0.prepareRemoveRecipient(spare.recipient) }
        // A transport that reorders: the files arrive, vault.json does not.
        for (p, data) in w.a.noteFiles() { w.targets[0].put(p.split(separator: "/").map(String.init), data) }
        let target = w.targets[0].noteFiles()
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertTrue(r.keyChange?.replaced.isEmpty ?? true, "\(KCWorld.brief(r))")
        XCTAssertEqual(w.b.noteFiles(), bBefore, "B keeps its copies")
        XCTAssertEqual(w.targets[0].noteFiles(), target, "and pushes none over the new ones")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    // MARK: F7: two changes at once

    func testConcurrentChangesWithOverride() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let t0 = w.targets[0], t1 = w.targets[1]
        // Without the override, an unreachable target refuses a routine change.
        t1.offline.value = true
        XCTAssertThrowsError(try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }) { e in
            guard case KeyChangeError.targetNotRecentlySynced = e else {
                guard case KeyChangeError.targetUnreachable = e else { return XCTFail("\(e)") }
                return
            }
        }
        // A removes the spare with T1 overridden; B, with T0 out of reach, replaces its own key.
        try w.change(w.a, overriding: ["T1"]) { try $0.prepareRemoveRecipient(spare.recipient) }
        t1.offline.value = false
        t0.offline.value = true
        let bOld = w.b.identity, bNew = pqIdentity()
        w.b.identities.insert(bNew, at: 0)
        try w.change(w.b, overriding: ["T0"]) { try $0.prepareReplaceRecipient(bOld.recipient, with: bNew.recipient) }
        t0.offline.value = false
        w.oracle.learn(w.b)
        // They meet: each records the other's change on a target, and nothing is replaced across lists.
        for _ in 0..<2 { for d in [w.a, w.b] { for t in ["T0", "T1"] { w.tick(); _ = try? d.sync(t, now: w.now) } } }
        XCTAssertFalse(w.a.coordinator.conflicts.isEmpty && w.b.coordinator.conflicts.isEmpty, "the changes met")
        w.assertNoLoss()
        // The user keeps B's change on A, then A redoes its own.
        var va = try w.a.vault()
        try w.a.coordinator.adoptOtherChange(from: "T1", vault: &va, now: w.now)
        w.oracle.learn(w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare, bOld])
        w.assertNoLoss()
    }

    // MARK: F8 to F10: devices that were away

    /// F8: a device away for the whole change returns: its keyring keeps its old secret before it takes
    /// the new vault.json, its own late file is rewrapped and uploaded, and its stale copies are replaced.
    func testStaleDeviceReturns() throws {
        for days in [1.0, 10.0] {
            let w = try seeded()
            let spare = try w.addSpare(on: w.a)
            try w.converge()
            let n3 = UUID()
            try w.write(w.c, n3, "written by C while away")
            try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
            try w.converge(skip: ["C"])
            XCTAssertNil(w.targets[0].file([Vault.journalName]), "the change finished everywhere else")
            w.tick(days * 86_400)
            try w.converge()
            let ring = try XCTUnwrap(try w.c.keyring.load(vaultId: try w.c.vault().vaultId))
            XCTAssertEqual(ring.entries.filter { $0.replaced != nil }.count, 1, "C kept its old secret (days \(days))")
            w.assertConverged()
            w.assertRevoked([spare])
            w.assertNoLoss()
        }
    }

    /// F9: another device's file under the old secret arrives after the change: taken in (rewrapped)
    /// within the window recorded in the journal, quarantined as a late file after it, never deleted;
    /// Adopt and Export take it out.
    func testLateFilesWithinWindow() throws {
        let w = try seeded()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.c, UUID(), "late")
        try removeSpareSeenBy(w, on: w.a, policy: try .routine(days: 7), seers: [w.b])
        try w.converge(skip: ["C"])
        w.tick(2 * 86_400)
        w.targets[0].put(late.path, late.data)
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.lateAccepted.count, 1, "\(KCWorld.brief(r))")
        let placed = try Data(contentsOf: w.b.folder.appendingPathComponent(late.path.joined(separator: "/")))
        XCTAssertNotEqual(placed, late.data, "placed rewrapped")
        XCTAssertTrue(try w.b.vault().classifyRevision(placed, note: UUID(uuidString: late.path[1])!,
                                                        name: RevisionName(late.path[2])!).isCurrent)
        try w.converge()
        w.assertConverged()
        w.assertNoLoss()
    }

    func testLateFilesAfterWindowQuarantined() throws {
        let w = try seeded()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.c, UUID(), "late")
        let other = try offlineRevision(w, w.c, UUID(), "late too")
        try removeSpareSeenBy(w, on: w.a, policy: try .routine(days: 7), seers: [w.b])
        try w.converge(skip: ["C"])
        w.tick(8 * 86_400)
        w.targets[0].put(late.path, late.data)
        w.targets[0].put(other.path, other.data)
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.lateQuarantined.count, 2, "\(KCWorld.brief(r))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.b.folder.appendingPathComponent(late.path.joined(separator: "/")).path))
        try w.converge(skip: ["C"])
        let items = w.b.lateFiles()
        XCTAssertEqual(Set(items.map(\.path)), [late.path.joined(separator: "/"), other.path.joined(separator: "/")])
        w.assertNoLoss()
        // Adopt one (rewrapped into the vault), export the other (as it is).
        var v = try w.b.vault()
        v = v.withOlderSecrets(from: try w.b.keyring.load(vaultId: v.vaultId))
        let adopt = try XCTUnwrap(items.first { $0.path == late.path.joined(separator: "/") })
        try LateFiles.adopt(adopt, into: v)
        let exported = try LateFiles.export(try XCTUnwrap(items.first { $0 != adopt }), to: tmp.appendingPathComponent("export"))
        XCTAssertEqual(try Data(contentsOf: exported), other.data)
        XCTAssertTrue(w.b.lateFiles().isEmpty)
        XCTAssertEqual(try w.b.notes()[UUID(uuidString: late.path[1])!], "late")
    }

    /// F10: a removed device keeps its notes and is told; what it uploads under the old secret never
    /// enters the vault silently (quarantined after the window).
    func testRemovedDeviceWrites() throws {
        let w = try seeded()
        let removed = w.c
        try w.change(w.a) { try $0.prepareRemoveRecipient(removed.identity.recipient, keyChange: try .routine(days: 1)) }
        try w.converge(skip: ["C"])
        removed.removed = true
        let n3 = UUID()
        _ = try removed.write(n3, "after removal", now: w.now)
        w.tick(2 * 86_400)
        let r = try removed.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.removedFromVault, true, "\(KCWorld.brief(r))")
        XCTAssertEqual(try removed.notes()[n3], "after removal", "its own notes stay readable to it")
        w.tick()
        let rb = try w.b.sync("T0", now: w.now)
        XCTAssertFalse((rb.keyChange?.lateAccepted ?? []).contains { $0.path.contains(n3.uuidString.lowercased()) })
        XCTAssertEqual(rb.keyChange?.lateQuarantined.count, 1, "\(KCWorld.brief(rb))")
        XCTAssertNil(try w.b.notes()[n3])
        try w.converge()
        // What the removed device uploaded stays on the target (never deleted), outside every working copy.
        let theirs = Set(w.targets[0].noteFiles().keys.filter { $0.contains(n3.uuidString.lowercased()) })
        XCTAssertEqual(theirs.count, 1)
        w.assertConverged(ignoring: theirs)
        w.assertRevoked([removed.identity], ignoring: theirs)
        w.assertNoLoss()
    }

    // MARK: F11 to F14: interrupted writes, locked receivers

    /// F11: a cut connection while replacing copies on a target: every copy there is the old one or
    /// the new one, complete; the next runs settle.
    func testCutDuringReplace() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        w.a.faults["T0"] = MemoryFaults(seed: 11, rates: MemoryFaults.Rates([.cutBody: 0.5, .dropBefore: 0.2, .loseAnswer: 0.2]))
        let oracle = w.oracle
        for _ in 0..<12 {
            w.tick()
            _ = try? w.a.sync("T0", now: w.now)
            for (p, data) in w.targets[0].noteFiles() where p.split(separator: "/").count == 3 {
                oracle.learn(w.a)
                XCTAssertNotNil(oracle.body(data, path: p), "\(p): a partial copy on the target")
            }
        }
        w.a.faults = [:]
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// F12: a crash while replacing a local file: the old or the new complete file stays, judged again next run.
    func testCrashDuringLocalReplace() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        try w.converge(skip: ["B", "C"])
        // B's R3 is off (its own copies stay stale), so the sweep replaces them locally.
        w.tick()
        _ = try w.b.sync("T0", now: w.now) { $0.lateRewrap = false }
        w.tick()
        let crashed = try w.b.sync("T0", now: w.now) { o in
            o.beforeLocalReplace = { _ in throw VaultError.interrupted }
            o.lateRewrap = false
        }
        XCTAssertTrue(crashed.errors.contains { $0.message.contains("interrupted") }, "\(KCWorld.brief(crashed))")
        XCTAssertFalse(crashed.keyChange?.replaced.contains { $0.side == "local" } ?? false)
        for (p, data) in w.b.noteFiles() where p.split(separator: "/").count == 3 {
            XCTAssertNotNil(w.oracle.body(data, path: p), "\(p): complete")
        }
        try w.converge()
        w.assertConverged()
        w.assertNoLoss()
    }

    /// F13: a locked receiver replaces nothing and stages nothing unverified; unlocked, it catches up.
    func testLockedReceiver() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        try w.converge(skip: ["B", "C"])
        let before = w.b.noteFiles(), manifest = w.b.manifest()
        w.tick()
        var o = w.b.options(w.now)
        o.keyring = w.b.keyring
        o.rewrapReplace = true
        let r = try SyncEngine(directory: w.b.folder, vault: try Vault.open(at: w.b.folder), remote: w.targets[0].remote(),
                               stateURL: w.b.stateURL("T0"), options: o).run()
        XCTAssertTrue(r.keyChange?.replaced.isEmpty ?? true, "\(KCWorld.brief(r))")
        XCTAssertEqual(w.b.noteFiles(), before)
        XCTAssertEqual(w.b.manifest(), manifest, "a changed list waits for an unlocked run")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// F14: a blob rename interrupted on removal: both names exist, lookups find it; the old name is
    /// collected only once no journal is left and the retention passed.
    func testBlobRenameInterrupted() throws {
        let w = try seeded()
        let blob = try w.a.attach(n1, Data("picture".utf8), now: w.now)
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        XCTAssertThrowsError(try w.change(w.a) { v in
            v.crashAfterBlobPlace = true
            return try v.prepareRemoveRecipient(spare.recipient)
        })
        let att = w.a.folder.appendingPathComponent("notes/\(n1.uuidString.lowercased())/att")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: att.path).filter { !$0.hasPrefix(".") }.count, 2,
                       "both names")
        let health = try w.a.vault().verify()
        XCTAssertTrue(health.files.allSatisfy { $0.status == .ok || $0.status == .staleRecipients }, "\(health)")
        let oldName = [Vault.notesName, n1.uuidString.lowercased(), Vault.attachmentsName, blob]
        for d in w.devices { for t in d.targets { w.tick(); _ = try? d.sync(t.name, now: w.now) { $0.blobRetention = 86_400 } } }
        XCTAssertNotNil(w.targets[0].file(oldName), "kept on the target within the retention")
        w.tick(2 * 86_400)
        try w.converge()
        XCTAssertNil(w.targets[0].file(oldName), "collected after it")
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    // MARK: F15, F16: hostile targets and provider forks

    /// F15: a target serving an older copy (an old list's wrap, or a removed stanza added back) never
    /// has it taken; it is replaced by the current copy.
    func testHostileDowngrade() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let old = w.targets[0].noteFiles()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        try w.converge()
        let current = w.b.noteFiles()
        for (p, data) in old { w.targets[0].put(p.split(separator: "/").map(String.init), data) }
        for d in w.devices { w.tick(); _ = try d.sync("T0", now: w.now) }
        XCTAssertEqual(w.b.noteFiles(), current, "never taken")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    func testHostileStanzaReadd() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        try w.converge()
        let v = try w.a.vault()
        let (p, data) = try XCTUnwrap(w.a.noteFiles().first { $0.key.split(separator: "/").count == 3 })
        let plain = try AgeFile.decrypt(data, with: w.a.identities)
        let readd = try Vault.encrypt(plain, to: try v.ageRecipients() + [spare.recipient])
        w.targets[0].put(p.split(separator: "/").map(String.init), readd)
        for d in w.devices { w.tick(); _ = try d.sync("T0", now: w.now) }
        for d in w.devices { XCTAssertEqual(d.noteFiles()[p], data, "\(d.name) never takes it") }
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
    }

    /// F16: a provider forks vault.json during a change (iCloud conflict versions: the other version
    /// becomes the current one under this device): a list fork is a conflict, never a blind pick, and
    /// replaces no file; a fork that differs only in label is the same vault.
    func testProviderForksManifest() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        // Label only: the same vault.
        var va = try w.a.vault()
        try va.setLabel("Mine")
        var vb = try w.b.vault()
        try vb.setLabel("Theirs")
        w.tick()
        _ = try w.b.sync("T0", now: w.now)
        w.tick()
        let label = try w.a.sync("T0", now: w.now)
        XCTAssertTrue(label.conflicts.isEmpty, "\(KCWorld.brief(label))")
        try w.converge()
        // A list fork: A's change on T0, and the pre-change list put back under it as the provider's pick.
        let pre = try XCTUnwrap(w.targets[0].file([Vault.manifestName]))
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient) }
        w.tick()
        _ = try w.a.sync("T0", now: w.now)
        let files = w.targets[0].noteFiles()
        let bBefore = w.b.noteFiles()
        try w.change(w.b) { try $0.prepareAddRecipient(pqIdentity().recipient, label: "x") }
        w.targets[0].put([Vault.manifestName], pre)
        w.tick()
        let fork = try w.a.sync("T0", now: w.now)
        XCTAssertTrue(fork.keyChange?.replaced.isEmpty ?? true, "\(KCWorld.brief(fork))")
        XCTAssertNotEqual(w.a.manifest(), pre, "never a blind pick")
        XCTAssertTrue(!fork.conflicts.isEmpty || !w.a.coordinator.conflicts.isEmpty || !fork.rejected.isEmpty,
                      "reported: \(KCWorld.brief(fork))")
        XCTAssertEqual(w.targets[0].noteFiles(), files, "no file replaced on the forked target")
        XCTAssertEqual(w.b.noteFiles().count, bBefore.count)
        w.assertNoLoss()
    }

    // MARK: F17: compromised mode

    func testCompromisedQuarantinesAtOnce() throws {
        let w = try seeded()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.c, UUID(), "late")
        try removeSpareSeenBy(w, on: w.a, policy: .compromised, seers: [w.b])
        // Even while the change is still pending (the journal accepted on B), a file under the old secret is late.
        w.targets[0].put(late.path, late.data)
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.lateQuarantined.count, 1, "\(KCWorld.brief(r))")
        XCTAssertTrue(r.keyChange?.lateAccepted.isEmpty ?? true)
        try w.converge(skip: ["C"])
        XCTAssertEqual(w.b.lateFiles().count, 1, "kept")
        w.assertNoLoss()
    }

    func testCompromisedPushesFirst() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a, syncFirst: false) { try $0.prepareRemoveRecipient(spare.recipient, keyChange: .compromised) }
        try w.write(w.a, UUID(), "written after the change")
        let faults = MemoryFaults(seed: 1)
        w.a.faults["T0"] = faults
        w.tick()
        _ = try w.a.sync("T0", now: w.now)
        let writes = faults.log.filter { $0.verb == .write }.map { $0.path.joined(separator: "/") }
        let firstNote = writes.firstIndex { $0.hasPrefix(Vault.notesName) } ?? writes.count
        let manifest = writes.firstIndex(of: Vault.manifestName) ?? Int.max
        XCTAssertLessThan(manifest, firstNote, "vault.json goes ahead of every note: \(writes.prefix(6))")
        w.a.faults = [:]
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
    }

    func testCompromisedWithTargetOffline() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        w.targets[1].offline.value = true
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, keyChange: .compromised) }
        XCTAssertNil(w.targets[1].file([Vault.journalName]), "not claimed while out of reach")
        try w.converge()
        XCTAssertTrue(w.a.coordinator.inProgress, "T1 is still to be done")
        w.targets[1].offline.value = false
        try w.converge()
        XCTAssertFalse(w.a.coordinator.inProgress)
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    // MARK: F18, F19: the late-file window across devices

    /// F18: a device that never saw the journal applies 0 days to others' late files; its own are rewrapped.
    func testPolicyUnknownDefaultsStrict() throws {
        let w = try seeded()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.b, UUID(), "B's, never synced")
        let own = UUID()
        try w.write(w.c, own, "C's own, while away")
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, keyChange: try .routine(days: 30)) }
        try w.converge(skip: ["C"])
        w.targets[0].put(late.path, late.data)
        w.tick()
        let r = try w.c.sync("T0", now: w.now)
        let ring = try XCTUnwrap(try w.c.keyring.load(vaultId: try w.c.vault().vaultId))
        XCTAssertTrue(ring.entries.contains { $0.replaced != nil && $0.policy == nil }, "C never saw the policy")
        XCTAssertEqual(r.keyChange?.lateQuarantined.count, 1, "\(KCWorld.brief(r))")
        try w.converge()
        XCTAssertEqual(try w.b.notes()[own], "C's own, while away", "C's own late file was rewrapped and uploaded")
        w.assertConverged()
        w.assertNoLoss()
    }

    /// F19: devices start their windows at different times: one accepts a late file, another
    /// quarantines it; the accepted (current) copy reaches everyone, and the quarantined original stays.
    func testWindowDecisionsConverge() throws {
        let w = try seeded()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.b, UUID(), "late")
        try removeSpareSeenBy(w, on: w.a, policy: try .routine(days: 3), seers: [w.c])
        // B sees the change (the journal still on T0: A is away) only four days later: its window starts then.
        w.tick(4 * 86_400)
        let seen = try w.b.sync("T0", now: w.now)
        XCTAssertTrue(seen.downloaded.contains(Vault.journalName), "\(KCWorld.brief(seen))")
        w.targets[0].put(late.path, late.data)
        w.tick()
        let rc = try w.c.sync("T0", now: w.now)
        XCTAssertEqual(rc.keyChange?.lateQuarantined.count, 1, "C's window is over: \(KCWorld.brief(rc))")
        w.tick()
        let rb = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(rb.keyChange?.lateAccepted.count, 1, "B's is open: \(KCWorld.brief(rb))")
        try w.converge()
        XCTAssertEqual(try w.c.notes()[UUID(uuidString: late.path[1])!], "late", "C takes the current copy")
        XCTAssertEqual(w.c.lateFiles().count, 1, "and keeps the quarantined original")
        w.assertConverged()
        w.assertNoLoss()
    }

    // MARK: Over folder targets (P3's `FolderRemote`, the design's `EvictingFolderRemote`)

    /// F3, F9 and F12 over a plain folder and a provider folder (both targets folders).
    func testCrashesAndLateFilesOverFolderTargets() throws {
        let w = try seeded(kinds: [.folder, .evicting])
        try w.a.attach(n1, Data("folder blob".utf8), now: w.now)
        try w.converge()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let late = try offlineRevision(w, w.c, UUID(), "late")
        let spare = try XCTUnwrap(w.spare)
        XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(rewrap: RewrapFaults(stop: .afterFiles(2)))) {
            try $0.prepareRemoveRecipient(spare.recipient, keyChange: try .routine(days: 7))
        })
        w.tick()
        XCTAssertThrowsError(try w.a.sync("T0", now: w.now, faults: KeyChangeFaults(afterStep: ["T0": .manifest])))
        w.tick()
        XCTAssertTrue(try w.b.sync("T0", now: w.now).downloaded.contains(Vault.journalName))
        try w.converge(skip: ["C"])
        w.tick(86_400)
        w.targets[1].put(late.path, late.data)
        w.tick()
        let r = try w.b.sync("T1", now: w.now) { $0.beforeLocalReplace = nil }
        XCTAssertEqual(r.keyChange?.lateAccepted.count, 1, "\(KCWorld.brief(r))")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// F16 over the design's `EvictingFolderRemote`: the provider forks `vault.json` during a change (a
    /// conflict version of another device's list beside this change's): never a blind pick, no file
    /// replaced across lists, the fork reported; a fork that differs only in label is the same vault.
    func testProviderForksManifestOverEvictingFolder() throws {
        let w = try seeded(kinds: [.evicting, .memory])
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        let provider = try XCTUnwrap(w.targets[0].provider)
        // A label-only fork: merged as the same vault.
        var labelled = try XCTUnwrap(w.targets[0].file([Vault.manifestName]))
        var obj = try JSONSerialization.jsonObject(with: labelled) as! [String: Any]
        obj["label"] = "Forked"
        labelled = try JSONSerialization.data(withJSONObject: obj)
        _ = try provider.addConflict(Vault.manifestName, labelled)
        w.tick()
        let label = try w.a.sync("T0", now: w.now)
        XCTAssertTrue(label.conflicts.isEmpty, "\(KCWorld.brief(label))")
        try w.converge()
        // A list fork: B's addition as a conflict version beside A's removal.
        try w.change(w.b, syncFirst: true) { try $0.prepareAddRecipient(pqIdentity().recipient, label: "x") }
        let bList = try XCTUnwrap(w.b.manifest())
        try w.converge(skip: ["A", "C"])
        try w.change(w.a, overriding: ["T0", "T1"], syncFirst: false) { try $0.prepareRemoveRecipient(spare.recipient) }
        _ = try provider.addConflict(Vault.manifestName, bList)
        let before = w.targets[0].noteFiles()
        w.tick()
        let fork = try? w.a.sync("T0", now: w.now)
        XCTAssertNotEqual(w.a.manifest(), bList, "never a blind pick")
        XCTAssertEqual(w.targets[0].noteFiles().filter { before[$0.key] != nil && before[$0.key] != $0.value }
            .keys.filter { _ in w.targets[0].file([Vault.manifestName]).map { !Vault.sameList($0, w.a.manifest() ?? Data()) } ?? true }
            .count, 0, "no file replaced across lists: \(fork.map(KCWorld.brief) ?? "threw")")
        w.assertNoLoss()
    }
}
