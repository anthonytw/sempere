import Age
import Foundation
import TempDirSupport
import XCTest
@testable import Sempere
@testable import SempereSync
@testable import SempereWebDAV

/// Regression tests for the second independent review of the key-change gate (PR #57) and for the
/// owner's decision of 2026-10-20 (every key change takes effect at once; docs/design/device-first-sync.md
/// §6.5): each reproduces a probe that broke an invariant before its fix, or a catch-up path the decision
/// makes essential.
final class KeyChangeRound2Tests: TempDirTestCase {
    let n1 = UUID(uuidString: "6b000000-0000-4000-8000-000000000001")!
    let n2 = UUID(uuidString: "6b000000-0000-4000-8000-000000000002")!

    func world(_ name: String, devices: Int = 3, uses: [[Int]]? = nil) throws -> KCWorld {
        try KCWorld(root: tmp.appendingPathComponent(name), deviceCount: devices, uses: uses)
    }

    func reads(_ d: KCDevice, _ n: UUID) -> String? { (try? d.notes()[n]) ?? nil }

    // MARK: Item 1: "own" from provenance, never from a name

    /// The removed device writes a note under B's device id onto a target the change has not reached; B
    /// takes it there as an ordinary file before it learns of the change. Before: once B learned of it,
    /// R3 took the file for B's own (its name says so) and made it current for everyone. Now B recorded
    /// that the name came from elsewhere: it is set aside, never current.
    func testASpoofedDeviceIdIsNeverTakenForOwn() throws {
        let w = try world("spoof", uses: [[0, 1], [1], [0, 1]])
        try w.write(w.a, n1, "one")
        try w.converge()
        let c = w.c
        w.targets[1].offline.value = true
        try w.change(w.a) { try $0.prepareRemoveRecipient(c.identity.recipient, now: w.now) }
        c.removed = true
        w.tick(); _ = try? w.a.sync("T0", now: w.now)
        w.targets[1].offline.value = false
        // The attacker writes as B and puts it on T1, which the change has not reached.
        let state = c.root.appendingPathComponent("spoof-device.json")
        try DeviceState(device: w.b.device).save(to: state)
        let n3 = UUID()
        w.tick()
        let r = try c.vault().apply([.setMeta(.title("INJECTED as B"))], to: n3, deviceState: state, app: "evil", wall: w.now)
        let path = [Vault.notesName, n3.uuidString.lowercased(), r.name.filename]
        w.targets[1].put(path, try Data(contentsOf: c.folder.appendingPathComponent(path.joined(separator: "/"))))
        w.tick()
        let first = try w.b.sync("T1", now: w.now)
        XCTAssertTrue(first.keyChange?.receivedOwn.contains(path.joined(separator: "/")) ?? false,
                      "a file with B's id that B did not write is recorded and reported: \(KCWorld.brief(first))")
        try? w.converge(rounds: 10)
        for x in [w.a, w.b] { XCTAssertNil(reads(x, n3), "\(x.name) never reads it") }
        XCTAssertTrue(w.b.lateFiles().contains { $0.path == path.joined(separator: "/") }, "set aside on B")
    }

    // MARK: Item 2: the owed rotation is durable

    func twoAdditions(_ name: String) throws -> (KCWorld, NativeIdentity, NativeIdentity) {
        let w = try world(name)
        try w.write(w.a, n1, "one")
        try w.write(w.b, n2, "two")
        try w.converge()
        let t0 = w.targets[0], t1 = w.targets[1]
        let x = pqIdentity(), y = pqIdentity()
        w.oracle.identities += [x, y]
        t1.offline.value = true
        try w.change(w.a) { try $0.prepareAddRecipient(x.recipient, label: "X", now: w.now) }
        try w.write(w.a, n1, "A wrote under L+X")
        for _ in 0..<2 { w.tick(); _ = try? w.a.sync("T0", now: w.now) }
        t1.offline.value = false; t0.offline.value = true
        try w.change(w.b) { try $0.prepareAddRecipient(y.recipient, label: "Y", now: w.now) }
        for _ in 0..<2 { w.tick(); _ = try? w.b.sync("T1", now: w.now) }
        t0.offline.value = false
        for _ in 0..<2 { for d in [w.a, w.b] { for t in ["T0", "T1"] { w.tick(); _ = try? d.sync(t, now: w.now) } } }
        return (w, x, y)
    }

    func assertOnlyListedKeysOpen(_ w: KCWorld, dropped x: NativeIdentity, listed y: NativeIdentity,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for (loc, p, data) in w.everyCopy() {
            XCTAssertNil(try? AgeFile.decrypt(data, with: [x]), "\(loc) \(p): the dropped key opens it", file: file, line: line)
            XCTAssertNotNil(try? AgeFile.decrypt(data, with: [y]), "\(loc) \(p): the listed key cannot", file: file, line: line)
        }
    }

    /// "Keep the other change" made through the vault API alone (as if the process stopped right after it):
    /// the owed rotation is recorded with the adopted vault.json, not after it. Before: nothing was owed,
    /// and the dropped key kept access for good.
    func testTheOwedRotationIsRecordedWithTheAdoption() throws {
        let (w, x, y) = try twoAdditions("owed")
        var va = try w.a.vault()
        let theirs = try XCTUnwrap(w.targets[1].file([Vault.manifestName]))
        try va.adoptConcurrentChange(theirs, keyring: w.a.keyring, now: w.now)
        XCTAssertEqual(w.a.coordinator.rotationOwed, [x.recipient.string])
        try w.converge(rounds: 12)
        XCTAssertTrue(w.a.coordinator.rotationOwed.isEmpty, "made by the coordinator itself")
        assertOnlyListedKeysOpen(w, dropped: x, listed: y)
        w.assertConverged()
        w.assertNoLoss()
    }

    /// The owed rotation survives a ledger that does not open and is repaired. Before: the repair set the
    /// record aside with the owed rotation in it.
    func testRepairingTheLedgerKeepsTheOwedRotation() throws {
        let (w, x, y) = try twoAdditions("owed-repair")
        var va = try w.a.vault()
        _ = try w.a.coordinator.adoptOtherChange(from: "T1", vault: &va, now: w.now)
        XCTAssertEqual(w.a.coordinator.rotationOwed, [x.recipient.string])
        try Data("{garbage".utf8).write(to: w.a.root.appendingPathComponent("keychange.json"))
        XCTAssertNotNil(try w.a.coordinator.repairLedger())
        XCTAssertEqual(w.a.coordinator.rotationOwed, [x.recipient.string], "kept in the keyring")
        try w.converge(rounds: 12)
        XCTAssertTrue(w.a.coordinator.rotationOwed.isEmpty)
        assertOnlyListedKeysOpen(w, dropped: x, listed: y)
        w.assertConverged()
        w.assertNoLoss()
    }

    /// A target that keeps a fresh journal planted (new bytes every time, so it always looks in flight)
    /// never holds an owed rotation back: the rotation goes on and reaches that target once it is clear.
    func testAPlantedClaimNeverHoldsAnOwedRotationBack() throws {
        let (w, x, y) = try twoAdditions("owed-planted")
        var va = try w.a.vault()
        _ = try w.a.coordinator.adoptOtherChange(from: "T1", vault: &va, now: w.now)
        let before = try XCTUnwrap(try w.a.vault().currentSecret)
        for i in 0..<4 {
            w.targets[0].put([Vault.journalName], Data(#"{"format":"sempere/1","rekeyBlobs":true,"n":\#(i)}"#.utf8))
            w.tick()
            _ = try? w.a.sync("T0", now: w.now)
            w.tick()
            _ = try? w.a.sync("T1", now: w.now)
        }
        XCTAssertNotEqual(try w.a.vault().currentSecret, before, "the rotation went on")
        XCTAssertTrue(w.a.coordinator.rotationOwed.isEmpty)
        w.targets[0].remove([Vault.journalName])
        try w.converge(rounds: 14)
        assertOnlyListedKeysOpen(w, dropped: x, listed: y)
        w.assertConverged()
        w.assertNoLoss()
    }

    // MARK: Item 4: a failed keep is never followed by a delete

    /// B holds a late file it must set aside, but the quarantine cannot keep it (a plain file where `late/`
    /// goes: a full disk, permissions). Before: the keep failed silently and the file was deleted: lost.
    /// Now it stays where it is, reported, until a keep succeeds.
    func testASetAsideThatCannotBeKeptLeavesTheFile() throws {
        let w = try world("keep-fails", uses: [[0, 1], [1], [0, 1]])
        try w.write(w.a, n1, "one")
        try w.converge()
        let c = w.c
        w.targets[1].offline.value = true
        try w.change(w.a) { try $0.prepareRemoveRecipient(c.identity.recipient, now: w.now) }
        c.removed = true
        w.tick(); _ = try? w.a.sync("T0", now: w.now)
        w.targets[1].offline.value = false
        let n3 = UUID()
        let r = try c.write(n3, "from C", now: w.now)
        let path = [Vault.notesName, n3.uuidString.lowercased(), r.filename]
        let bytes = try Data(contentsOf: c.folder.appendingPathComponent(path.joined(separator: "/")))
        w.targets[1].put(path, bytes)
        w.tick(); _ = try w.b.sync("T1", now: w.now)
        let local = w.b.folder.appendingPathComponent(path.joined(separator: "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "B took it before it learned of the change")
        let q = w.b.quarantine("T1")
        try FileManager.default.createDirectory(at: q, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: q.appendingPathComponent(LateFiles.folder))
        w.tick(); _ = try? w.a.sync("T1", now: w.now)
        for _ in 0..<3 { w.tick(); _ = try w.b.sync("T1", now: w.now) }
        XCTAssertEqual(try? Data(contentsOf: local), bytes, "not deleted while the quarantine cannot keep it")
        XCTAssertNil(reads(w.b, n3), "and never current")
        // The quarantine works again: set aside, kept.
        try FileManager.default.removeItem(at: q.appendingPathComponent(LateFiles.folder))
        w.tick(); _ = try w.b.sync("T1", now: w.now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertTrue(w.b.lateFiles().contains { $0.path == path.joined(separator: "/") })
    }

    // MARK: Item 5: two installs with one device id

    /// Another install with this device's id (a restored backup) wrote a revision this device did not:
    /// recorded and reported when it arrives, never treated as this device's own afterwards.
    func testAFileFromAnotherInstallWithThisDeviceIdIsRecorded() throws {
        let w = try world("same-id")
        try w.write(w.a, n1, "one")
        try w.converge()
        // The other install: A's device id, A's key, its own folder (a restored copy of A).
        let twin = w.a.root.appendingPathComponent("twin")
        try FileManager.default.copyItem(at: w.a.folder, to: twin)
        let twinState = w.a.root.appendingPathComponent("twin-device.json")
        try DeviceState(device: w.a.device).save(to: twinState)
        var tv = try Vault.open(at: twin, identities: w.a.identities, trust: w.a.trust)
        let n3 = UUID()
        w.tick()
        let r = try tv.apply([.setMeta(.title("written by the twin"))], to: n3, deviceState: twinState, app: "twin", wall: w.now)
        _ = tv
        let path = [Vault.notesName, n3.uuidString.lowercased(), r.name.filename]
        w.targets[0].put(path, try Data(contentsOf: twin.appendingPathComponent(path.joined(separator: "/"))))
        w.tick()
        let rep = try w.a.sync("T0", now: w.now)
        XCTAssertEqual(rep.keyChange?.receivedOwn, [path.joined(separator: "/")], "\(KCWorld.brief(rep))")
        let ring = try XCTUnwrap(try w.a.keyring.load(vaultId: try w.a.vault().vaultId))
        XCTAssertTrue(ring.receivedAsOwn("\(n3.uuidString.lowercased())/\(r.name.filename)"))
        XCTAssertEqual(reads(w.a, n3), "written by the twin", "a current file is taken as usual")
    }

    // MARK: Catch-up of a still-listed device

    /// C is away while the others make several changes in a row: a rotation (a spare key removed), the
    /// removal of another device (D), and an addition. C keeps writing (notes and an attachment). When it
    /// comes back it confirms the list it missed rotations of (the user's check), rewraps and uploads what
    /// it wrote (by provenance), and nothing is lost: everything it wrote is current everywhere, and no
    /// late copy is left aside anywhere.
    func testAStillListedDeviceAwayForSeveralChangesLosesNothing() throws {
        let w = try world("catch-up", devices: 4)
        let c = w.c, d = w.devices[3]
        try w.write(w.a, n1, "one")
        try w.write(c, n2, "C's before")
        try w.converge()
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        // C goes away.
        let away: Set<String> = ["C"]
        let c1 = UUID(), c2 = UUID()
        try w.write(c, c1, "C wrote while away, 1")
        try w.write(c, n2, "C edited while away")
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try w.converge(skip: away)
        try w.write(c, c2, "C wrote while away, 2")
        _ = try w.attach(c, c2, Data("C's picture while away".utf8))
        try w.change(w.b) { try $0.prepareRemoveRecipient(d.identity.recipient, now: w.now) }
        d.removed = true
        try w.converge(skip: away.union(["D"]))
        let extra = pqIdentity()
        w.oracle.identities.append(extra)
        try w.change(w.a) { try $0.prepareAddRecipient(extra.recipient, label: "extra", now: w.now) }
        try w.converge(skip: away.union(["D"]))
        // C comes back: its list missed two rotations, which it cannot link: the user confirms the list.
        for t in ["T0", "T1"] { w.tick(); _ = try? c.sync(t, now: w.now) }
        var vc = try c.vault()
        if c.manifest() != w.a.manifest() {
            _ = try c.coordinator.adoptOtherChange(from: "T0", vault: &vc, now: w.now, confirmed: true)
        }
        try w.converge(skip: ["D"])
        for x in [w.a, w.b] {
            XCTAssertEqual(reads(x, c1), "C wrote while away, 1", x.name)
            XCTAssertEqual(reads(x, c2), "C wrote while away, 2", x.name)
            XCTAssertTrue(x.lateFiles().isEmpty, "\(x.name): nothing left aside: \(x.lateFiles().map(\.path))")
            let inventory = try x.vault().blobInventory(note: c2)
            XCTAssertTrue(inventory.missing.isEmpty, "\(x.name): C's attachment is there")
        }
        w.assertConverged()
        w.assertRevoked([spare, d.identity])
        w.assertNoLoss()
    }

    // MARK: A late blob that a held revision references

    /// B holds a revision that references a blob whose only copy left is under its old name (seed 88: the
    /// revision went up, its blob did not, then a rotation). Taken in under its current name whatever the
    /// change: a blob is inert and content-addressed. Before (review mutation M4): treated as a leftover,
    /// never placed, the attachment missing for good.
    func testALateBlobAHeldRevisionReferencesIsTakenIn() throws {
        let w = try world("late-blob")
        try w.write(w.a, n1, "one")
        let oldName = try w.attach(w.a, n1, Data("the only picture".utf8))
        try w.converge()
        let oldBytes = try XCTUnwrap(w.targets[0].file([Vault.notesName, n1.uuidString.lowercased(), Vault.attachmentsName, oldName]))
        let spare = try w.addSpare(on: w.a)
        try w.converge()
        try w.change(w.a) { try $0.prepareRemoveRecipient(spare.recipient, now: w.now) }
        try w.converge()
        // Every current copy of the blob is lost; only its old-named copy comes back, on T0.
        let att = [Vault.notesName, n1.uuidString.lowercased(), Vault.attachmentsName]
        for x in w.devices {
            let dir = x.folder.appendingPathComponent(att.joined(separator: "/"))
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        for t in w.targets { for (p, _) in t.noteFiles() where p.contains("/att/") { t.remove(p.split(separator: "/").map(String.init)) } }
        w.targets[0].put(att + [oldName], oldBytes)
        w.tick()
        let r = try w.b.sync("T0", now: w.now)
        XCTAssertEqual(r.keyChange?.lateAccepted.count, 1, "\(KCWorld.brief(r))")
        XCTAssertTrue(try w.b.vault().blobInventory(note: n1).missing.isEmpty, "the attachment is back")
    }
}
