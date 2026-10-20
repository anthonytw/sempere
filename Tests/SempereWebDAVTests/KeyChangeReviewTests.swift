import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Regression tests for the independent review of the key-change gate (PR #57): each reproduces a
/// probe that broke an invariant before its fix (docs/design/device-first-sync.md §6.6).
final class KeyChangeReviewTests: TempDirTestCase {
    let n1 = UUID(uuidString: "6b000000-0000-4000-8000-000000000001")!
    let n2 = UUID(uuidString: "6b000000-0000-4000-8000-000000000002")!

    func world(_ name: String, devices: Int = 3, uses: [[Int]]? = nil, kinds: [KCTarget.Kind]? = nil) throws -> KCWorld {
        try KCWorld(root: tmp.appendingPathComponent(name), deviceCount: devices, uses: uses, kinds: kinds)
    }

    // MARK: Finding 1: the window ends at the change time, however late a device sees the change

    /// A removed device writes 30 days after a 7-day removal; a target replays the finished change's
    /// authentic step-2 vault.json and journal to a device that was away. Before: that device's window
    /// started then, it took the file in, rewrapped it and spread it as current to everyone.
    func testLateInjectionThroughStaleDevice() throws {
        let w = try world("w1", devices: 4, uses: [[0, 1], [0, 1], [0, 1], [1]])
        let d = w.devices[3], c = w.c
        try w.write(w.a, n1, "one")
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(c.identity.recipient, keyChange: try .routine(days: 7), now: w.now) }
        c.removed = true
        w.tick()
        XCTAssertThrowsError(try w.a.sync("T1", now: w.now, faults: KeyChangeFaults(afterStep: ["T1": .manifest])))
        let step2 = try XCTUnwrap(w.targets[1].file([Vault.manifestName]))
        let journal = try XCTUnwrap(w.targets[1].file([Vault.journalName]))
        try w.converge(skip: ["D"])
        w.tick(30 * 86_400)
        let n3 = UUID()
        _ = try c.write(n3, "injected 30 days later", now: w.now)
        w.tick()
        _ = try? c.sync("T1", now: w.now)
        let final = try XCTUnwrap(w.targets[1].file([Vault.manifestName]))
        w.targets[1].put([Vault.manifestName], step2)
        w.targets[1].put([Vault.journalName], journal)
        for _ in 0..<2 {
            w.tick()
            let r = try d.sync("T1", now: w.now)
            XCTAssertTrue(r.keyChange?.lateAccepted.isEmpty ?? true, "\(KCWorld.brief(r))")
        }
        XCTAssertNil(try d.notes()[n3], "never taken in after changedAt + 7 days")
        w.targets[1].put([Vault.manifestName], final)
        w.targets[1].remove([Vault.journalName])
        try? w.converge(rounds: 8)
        for x in [w.a, w.b, d] { XCTAssertNil(try x.notes()[n3], "\(x.name) never reads it") }
        XCTAssertTrue(d.lateFiles().contains { $0.path.contains(n3.uuidString.lowercased()) }, "kept as a late file")
    }

    // MARK: Finding 2: R3 rewraps only this device's files

    /// A compromised-mode removal; the removed device writes to a target the change has not reached; a
    /// device that syncs only there takes it as ordinary. Before: R3 then rewrapped it to current there.
    func testCompromisedInjectionLaunderedByR3() throws {
        let w = try world("w2", uses: [[0, 1], [1], [0, 1]])
        try w.write(w.a, n1, "one")
        try w.converge()
        let c = w.c
        w.targets[1].offline.value = true
        try w.change(w.a) { try $0.prepareRemoveRecipient(c.identity.recipient, keyChange: .compromised, now: w.now) }
        c.removed = true
        w.tick(); _ = try? w.a.sync("T0", now: w.now)
        w.targets[1].offline.value = false
        let n3 = UUID()
        _ = try c.write(n3, "injected after a compromised removal", now: w.now)
        w.tick(); _ = try? c.sync("T1", now: w.now)
        w.tick(); _ = try w.b.sync("T1", now: w.now)
        try? w.converge(rounds: 10)
        for x in [w.a, w.b] { XCTAssertNil(try x.notes()[n3], "\(x.name) never makes it current") }
        let vb = try w.b.vault()
        let p = "notes/\(n3.uuidString.lowercased())"
        for (path, data) in w.b.noteFiles() where path.hasPrefix(p) {
            XCTAssertFalse(vb.classifyRevision(data, note: n3, name: RevisionName(String(path.split(separator: "/").last!))!).isCurrent)
        }
        XCTAssertTrue((w.a.lateFiles() + w.b.lateFiles()).contains { $0.path.hasPrefix(p) }, "set aside as a late file")
    }

    // MARK: Finding 3: a same-secret adoption owes a rotation, made by the coordinator itself

    func testConcurrentAdditionsWithoutRedo() throws {
        let w = try world("w3")
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        try w.attach(w.a, n1, Data("pic".utf8))
        try w.converge()
        let t0 = w.targets[0], t1 = w.targets[1]
        let x = pqIdentity(), y = pqIdentity()
        w.oracle.identities += [x, y]
        t1.offline.value = true
        try w.change(w.a, overriding: ["T1"]) { try $0.prepareAddRecipient(x.recipient, label: "X", now: w.now) }
        try w.write(w.a, n1, "A wrote under L+X")
        for _ in 0..<2 { w.tick(); _ = try? w.a.sync("T0", now: w.now) }
        t1.offline.value = false; t0.offline.value = true
        try w.change(w.b, overriding: ["T0"]) { try $0.prepareAddRecipient(y.recipient, label: "Y", now: w.now) }
        for _ in 0..<2 { w.tick(); _ = try? w.b.sync("T1", now: w.now) }
        t0.offline.value = false
        for _ in 0..<2 { for d in [w.a, w.b] { for t in ["T0", "T1"] { w.tick(); _ = try? d.sync(t, now: w.now) } } }
        XCTAssertFalse(w.a.coordinator.conflicts.isEmpty, "the two additions met")
        var va = try w.a.vault()
        let dropped = try w.a.coordinator.adoptOtherChange(from: "T1", vault: &va, now: w.now)
        XCTAssertEqual(dropped, [x.recipient.string])
        XCTAssertEqual(w.a.coordinator.rotationOwed, [x.recipient.string])
        XCTAssertThrowsError(try w.change(w.a) { try $0.prepareAddRecipient(pqIdentity().recipient, label: "z", now: w.now) }) {
            XCTAssertEqual($0 as? KeyChangeError, .rotationOwed)
        }
        // Nobody redoes anything: the coordinator rotates by itself at the next runs.
        try w.converge(rounds: 12)
        XCTAssertTrue(w.a.coordinator.rotationOwed.isEmpty)
        let listed = try VaultManifest.decode(try XCTUnwrap(w.a.manifest())).recipients.map(\.key)
        XCTAssertFalse(listed.contains(x.recipient.string))
        for (loc, p, data) in w.everyCopy() {
            XCTAssertNil(try? AgeFile.decrypt(data, with: [x]), "\(loc) \(p): the dropped key opens it")
            XCTAssertNotNil(try? AgeFile.decrypt(data, with: [y]), "\(loc) \(p): the listed key cannot open it")
        }
        w.assertConverged()
        w.assertNoLoss()
    }

    // MARK: Finding 6: the ledger fails closed; leftover claims do not block for ever

    func testCorruptLedgerMidPropagation() throws {
        let w = try world("w4")
        try w.write(w.a, n1, "one")
        try w.attach(w.a, n1, Data("pic".utf8))
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        w.tick()
        XCTAssertThrowsError(try w.a.sync("T0", now: w.now, faults: KeyChangeFaults(afterStep: ["T0": .manifest])))
        try Data("{garbage".utf8).write(to: w.a.root.appendingPathComponent("keychange.json"))
        XCTAssertTrue(w.a.coordinator.inProgress, "an unreadable record is never taken as nothing in progress")
        XCTAssertNotNil(w.a.coordinator.ledgerProblem)
        XCTAssertThrowsError(try w.change(w.a) { try $0.prepareRotation(now: w.now) }) {
            guard case KeyChangeError.ledgerUnreadable? = $0 as? KeyChangeError else { return XCTFail("\($0)") }
        }
        w.tick()
        var va = try w.a.vault()
        let r = try w.a.coordinator.sync(target: "T1", vault: &va, options: w.a.options(w.now))
        XCTAssertNotNil(r.propagation?.ledgerProblem, "reported")
        XCTAssertNotNil(try w.a.coordinator.repairLedger())
        // A day later every leftover claim is gone (any device removes a refused journal past the in-flight day).
        for _ in 0..<3 { try? w.converge(rounds: 6); w.tick(Vault.inFlightJournalWindow + 3600) }
        for t in w.targets { XCTAssertNil(t.file([Vault.journalName]), "\(t.name): a journal is left") }
        try w.change(w.b) { try $0.prepareRotation(now: w.now) }
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// The record is written before any claim; a crash right after a claim is written (before the record
    /// names it) still takes it back at the next launch.
    func testCrashBetweenClaimWriteAndRecord() throws {
        let w = try world("w5")
        try w.write(w.a, n1, "one")
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        XCTAssertThrowsError(try w.change(w.a, faults: KeyChangeFaults(afterFirstClaimWrite: true)) {
            try $0.prepareRemoveRecipient(spare.recipient, now: w.now)
        })
        XCTAssertNotNil(w.targets[0].file([Vault.journalName]), "the claim was written")
        XCTAssertTrue(w.a.coordinator.inProgress, "and the record knows the change")
        var v = try w.a.vault()
        XCTAssertFalse(try w.a.coordinator.recover(&v))
        for t in w.targets { XCTAssertNil(t.file([Vault.journalName]), "\(t.name): taken back") }
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
    }

    /// A refused journal nobody owns (a device lost with its claim on a target) stops blocking clean runs
    /// and blob collection once the in-flight day passed: any device removes it.
    func testAnOrphanClaimIsRemovedAfterTheInFlightDay() throws {
        let w = try world("w6")
        try w.write(w.a, n1, "one")
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        // A claim of a change from the current secret, whose device is gone: unbound, "in flight".
        var v = try w.c.vault()
        let p = try v.prepareRemoveRecipient(spare.recipient, now: w.now)
        w.targets[0].put([Vault.journalName], p.journal)
        for d in [w.a, w.b] { w.tick(); _ = try d.sync("T0", now: w.now) }
        XCTAssertNotNil(w.targets[0].file([Vault.journalName]), "held as in flight for a day")
        w.tick(Vault.inFlightJournalWindow + 3600)
        try w.converge()
        XCTAssertNil(w.targets[0].file([Vault.journalName]), "removed after the day")
        try w.change(w.b) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try w.converge()
        w.assertConverged()
    }

    // MARK: Finding 4: blobs in I1, late blobs, no collection across lists

    /// F9 with an attachment: a late revision and its blob arrive within the window; both are taken in
    /// (the blob under its current name), and every device resolves the reference.
    func testLateAttachmentWithinWindow() throws {
        let w = try world("w7")
        try w.write(w.a, n1, "one")
        try w.converge()
        _ = try w.addSpare(on: w.a)
        try w.converge()
        let note = UUID()
        try w.attach(w.c, note, Data("a late picture".utf8))
        let folder = w.c.folder.appendingPathComponent("notes/\(note.uuidString.lowercased())")
        let files = try Self.files(under: folder)
        try FileManager.default.removeItem(at: folder)
        let spare = try XCTUnwrap(w.spare)
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, keyChange: try .routine(days: 7), now: w.now) }
        // B sees the change's journal (its policy) while it is on T0.
        w.tick()
        XCTAssertThrowsError(try w.a.sync("T0", now: w.now, faults: KeyChangeFaults(afterStep: ["T0": .manifest])))
        w.tick()
        XCTAssertTrue(try w.b.sync("T0", now: w.now).downloaded.contains(Vault.journalName))
        try w.converge(skip: ["C"])
        w.tick(86_400)
        for (rel, data) in files { w.targets[0].put(["notes", note.uuidString.lowercased()] + rel.split(separator: "/").map(String.init), data) }
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.lateAccepted.count, 2, "the revision and the blob: \(KCWorld.brief(r))")
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// F8 with an attachment: a device away for the whole change attached a picture; when it comes back
    /// its revision and blob are rewrapped (R3) and uploaded, and every device resolves the reference.
    func testStaleDeviceReturnsWithAnAttachment() throws {
        let w = try world("w8")
        try w.write(w.a, n1, "one")
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.attach(w.c, UUID(), Data("written while away".utf8))
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try w.converge(skip: ["C"])
        w.tick(10 * 86_400)
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }

    /// No blob is collected while the two sides hold different lists: a name keyed under the other list's
    /// secret looks unreferenced from here (found by the property test; the review's mutation 1).
    func testNoBlobIsCollectedWhileTheListsDiffer() throws {
        let w = try world("w9")
        try w.write(w.a, n1, "one")
        let name = try w.attach(w.a, n1, Data("pic".utf8))
        try w.converge()
        let v = try w.a.vault()
        let engine = SyncEngine(directory: w.a.folder, vault: v, remote: w.targets[0].remote(),
                                stateURL: w.a.stateURL("T0"), options: w.a.options(w.now))
        engine.kc.startManifest = try? engine.localMutable(Vault.manifestName)
        let id = n1.uuidString.lowercased()
        let unreferenced = BlobName.fileName(name: String(repeating: "0", count: 64), kind: BlobName.parse(name)!.kind)
        guard case .judged(let allowed) = engine.collectable(id, remoteRevisions: []) else { return XCTFail("not judged") }
        XCTAssertTrue(allowed(unreferenced), "the same list: an unreferenced name is collectable")
        XCTAssertFalse(allowed(name))
        engine.kc.listsDiffer = true
        guard case .judged(let none) = engine.collectable(id, remoteRevisions: []) else { return XCTFail("not judged") }
        XCTAssertFalse(none(unreferenced), "different lists: nothing is collected")
    }

    // MARK: Finding 7: a target without strong version tokens

    func testWeakStampsAreReportedAndNothingIsReplaced() throws {
        let w = try world("w10")
        try w.write(w.a, n1, "one")
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        // T0 holds the change's step-2 vault.json (the same list), its files are still the old ones.
        w.tick()
        XCTAssertThrowsError(try w.a.sync("T0", now: w.now, faults: KeyChangeFaults(afterStep: ["T0": .manifest])))
        let weak = WeakStampRemote(inner: w.targets[0].remote())
        var o = w.a.options(w.now)
        o.keyring = w.a.keyring
        o.rewrapReplace = true
        o.holdMutableFiles = true
        let before = w.targets[0].noteFiles()
        let r = try SyncEngine(directory: w.a.folder, vault: try w.a.vault(), remote: weak,
                               stateURL: w.a.root.appendingPathComponent("weak.json"), options: o).run()
        XCTAssertEqual(r.keyChange?.weakStamps, true, "\(KCWorld.brief(r))")
        XCTAssertFalse(r.keyChange?.settled ?? false)
        XCTAssertEqual(w.targets[0].noteFiles(), before, "never replaced without If-Match")
    }

    // MARK: Finding 10: adopting with a pending journal and no keyring entry

    func testAdoptWithPendingJournalNotInKeyring() throws {
        let w = try world("w11")
        try w.write(w.a, n1, "one")
        try w.write(w.a, n2, "two")
        try w.attach(w.a, n1, Data("pic".utf8))
        try w.converge()
        let spare = try w.addSpare(on: w.b)
        try w.converge()
        w.targets[1].offline.value = true
        try w.change(w.b, overriding: ["T1"]) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        for _ in 0..<2 { w.tick(); _ = try? w.b.sync("T0", now: w.now) }
        let theirs = try XCTUnwrap(w.targets[0].file([Vault.manifestName]))
        // A changes C's key without the coordinator or keyring (as the CLI does) and stops after a file.
        var va = try w.a.vault()
        let cOld = w.c.identity, cNew = pqIdentity()
        w.c.identities.insert(cNew, at: 0)
        _ = try? va.replaceRecipient(cOld.recipient, with: cNew.recipient, label: nil, added: w.now, stopAfter: 1)
        va = try w.a.vault()
        let previous = try XCTUnwrap(va.previousSecret)
        let journal = try Data(contentsOf: w.a.folder.appendingPathComponent(Vault.journalName))
        try Data("an older refused journal".utf8).write(to: w.a.folder.appendingPathComponent(Vault.refusedJournalName))
        try va.adoptConcurrentChange(theirs, keyring: w.a.keyring, now: w.now)
        let ring = try XCTUnwrap(try w.a.keyring.load(vaultId: va.vaultId))
        XCTAssertNotNil(ring.entry(for: previous), "the journal's outgoing secret is kept in the keyring")
        XCTAssertEqual(try Data(contentsOf: w.a.folder.appendingPathComponent(Vault.refusedJournalName)),
                       Data("an older refused journal".utf8), "an earlier refused journal is not replaced")
        let aside = try FileManager.default.contentsOfDirectory(atPath: w.a.folder.path).filter { $0.hasPrefix("rewrap-journal.refused-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: w.a.folder.appendingPathComponent(aside[0])), journal)
        let v2 = try w.a.vault().withOlderSecrets(from: ring)
        XCTAssertTrue(v2.verify().files.filter { $0.path.hasPrefix("notes/") }.allSatisfy { $0.status == .ok })
    }

    static func files(under dir: URL) throws -> [(String, Data)] {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        var out: [(String, Data)] = []
        for case let rel as String in e {
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out.append((rel, try Data(contentsOf: url)))
            }
        }
        return out
    }

    // MARK: Found by the long property run: a stale file of an earlier change never holds a change back

    /// A blob under a secret two changes old, which no revision here references (another device's
    /// leftover, kept stale on both sides), sits in this device's copy when its next change stops in K3.
    /// Before: resuming without the keyring failed on it (tag mismatch), so the change never finished
    /// (property seed 74). Now the resume handles it as R3 does: left as it is, reported, not blocking.
    func testAnOlderStaleBlobDoesNotHoldAChangeBack() throws {
        let w = try world("stale-blob")
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        _ = try w.attach(w.b, n2, Data("pic".utf8))
        try w.converge()
        let first = try w.addSpare(on: w.a)
        let second = try w.addSpare(on: w.a)
        try w.converge()
        let att = w.b.folder.appendingPathComponent("notes/\(n2.uuidString.lowercased())/att")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: att.path).first { $0.hasSuffix(".age") })
        let stale = try Data(contentsOf: att.appendingPathComponent(name))
        _ = try w.change(w.a) { try $0.prepareRemoveRecipient(first.recipient, now: w.now) }
        try w.converge()
        // The old-named copy, unreferenced in note one.
        let planted = w.a.folder.appendingPathComponent("notes/\(n1.uuidString.lowercased())/att/\(name)")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stale.write(to: planted)
        XCTAssertThrowsError(try w.change(w.a, syncFirst: false,
                                          faults: KeyChangeFaults(rewrap: RewrapFaults(stop: .afterFiles(0)))) {
            try $0.prepareRemoveRecipient(second.recipient, now: w.now)
        })
        XCTAssertTrue(try w.a.vault().pendingRewrap)
        w.tick()
        _ = try? w.a.sync("T0", now: w.now)
        XCTAssertFalse(try w.a.vault().pendingRewrap, "the change finished locally")
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path), "the stale copy is left as it is")
        try? w.converge()
        XCTAssertFalse(w.a.coordinator.inProgress, "and propagated")
    }
}

/// A remote whose version tokens are all weak (`W/"…"`): nothing can be replaced under `If-Match`.
struct WeakStampRemote: SyncRemote {
    var inner: any SyncRemote
    var location: String { inner.location }
    var capabilities: RemoteCapabilities { inner.capabilities }
    var interrupt: (@Sendable () -> (any Error)?)? {
        get { inner.interrupt }
        set { inner.interrupt = newValue }
    }
    func weak(_ e: RemoteEntry) -> RemoteEntry {
        var e = e
        e.etag = e.etag.map { "W/\($0)" }
        return e
    }
    func list(_ path: [String]) throws -> [RemoteEntry]? { try inner.list(path)?.map(weak) }
    func listTree(_ path: [String], maxBytes: Int) throws -> RemoteTree? { .refused }
    func stat(_ path: [String]) throws -> RemoteEntry? { try inner.stat(path).map(weak) }
    func read(_ path: [String], maxBytes: Int) throws -> (data: Data, etag: String?) {
        let r = try inner.read(path, maxBytes: maxBytes)
        return (r.data, r.etag.map { "W/\($0)" })
    }
    func download(_ path: [String], to file: URL, resumeFrom: Int, ifETag: String?, maxBytes: Int, segmentBytes: Int,
                  progress: ((Int) throws -> Void)?) throws -> DownloadResult {
        var r = try inner.download(path, to: file, resumeFrom: 0, ifETag: nil, maxBytes: maxBytes, segmentBytes: segmentBytes,
                                   progress: progress)
        r.etag = r.etag.map { "W/\($0)" }
        return r
    }
    func write(_ path: [String], _ body: RemoteBody, condition: PutCondition) throws -> Bool {
        if case .replace = condition { return false }
        return try inner.write(path, body, condition: condition)
    }
    func moveNoOverwrite(_ path: [String], to destination: [String]) throws -> Bool { try inner.moveNoOverwrite(path, to: destination) }
    func makeCollection(_ path: [String]) throws -> CollectionResult { try inner.makeCollection(path) }
    func createBase() throws { try inner.createBase() }
    func delete(_ path: [String], ifETag: String?) throws -> Bool { try inner.delete(path, ifETag: ifETag.map { _ in "x" }) }
    func missingCollectionError(_ path: [String]) -> any Error { inner.missingCollectionError(path) }
}

/// F11 over real HTTP: wsgidav behind `scripts/dav-fault-proxy.py` (review 11). Skipped unless
/// `SEMPERE_WEBDAV_PROXY_URL` is set (`scripts/test-webdav.sh`, `scripts/sync-stress.sh`); the proxy's
/// configuration is global, so this must not run in parallel with `SyncFaultProxyTests`.
final class KeyChangeOverFaultProxyTests: TempDirTestCase {
    /// A connection reset in the middle of uploads (request bodies cut, answers lost) and random 5xx
    /// while a removal replaces copies on the server: every copy there is complete, old or new, after
    /// every run; the change then settles.
    func testCutDuringReplaceOverWsgidav() throws {
        let proxy = try FaultProxy.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        guard let direct = env["SEMPERE_WEBDAV_TEST_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("SEMPERE_WEBDAV_TEST_URL not set")
        }
        let path = "kc-\(UUID().uuidString.lowercased())"
        let creds = env["SEMPERE_WEBDAV_TEST_USER"].map { WebDAVCredentials(user: $0, password: env["SEMPERE_WEBDAV_TEST_PASSWORD"] ?? "") }
        try proxy.configure()
        defer { try? proxy.configure() }
        let server = WebDAVSyncRemote(try WebDAVClient(baseURL: direct.appendingPathComponent(path, isDirectory: true),
                                                       credentials: creds))
        let t0 = KCTarget(name: "T0", devices: WebDAVSyncRemote(try proxy.client(path)), direct: server)
        let t1 = KCTarget(name: "T1")
        let w = try KCWorld(root: tmp.appendingPathComponent("w"), targets: [t0, t1])
        let n1 = UUID(), n2 = UUID()
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        _ = try w.attach(w.a, n1, Data(repeating: 9, count: 200_000))
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try proxy.configure(errorRate: 0.1, seed: 11, rules: [
            .init(method: "PUT", path: "/\(path)/notes/", action: "reset", direction: "request", afterBytes: 600,
                  times: -1, probability: 0.4),
            .init(method: "PUT", path: "/\(path)/notes/", action: "reset", direction: "response", times: -1, probability: 0.2),
        ])
        for _ in 0..<12 {
            w.tick()
            _ = try? w.a.sync("T0", now: w.now)
            w.oracle.learn(w.a)
            for (p, data) in t0.noteFiles() where p.split(separator: "/").count == 3 {
                XCTAssertNotNil(w.oracle.body(data, path: p), "\(p): a partial copy on the server")
            }
        }
        let hits = try proxy.requests().filter { $0.path.hasPrefix("/\(path)/") && $0.fault != nil }
        XCTAssertFalse(hits.isEmpty, "the proxy cut something")
        try proxy.configure()
        try w.converge()
        w.assertConverged()
        w.assertRevoked([spare])
        w.assertNoLoss()
    }
}
