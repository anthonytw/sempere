import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Epochs above 1 (key-hierarchy design §5, §6.3, §6.5, §11.1; phase KH3): removal, handoff, takeover and kit
/// replacement in core, the acceptance rule, catch-up from the write ledger, set-aside copies and unlisted
/// devices, with in-process devices sharing one vault folder (no sync: that is KH4). The invariants they
/// check are named as in design §11.2: J1 no loss, J2 revocation, J3 no injection, J5a immediacy (writes),
/// J6 set-aside monotone, J8 body integrity.
final class EpochScenarioTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
    }

    private func revisionData(_ vault: Vault, _ note: UUID) throws -> [Data] {
        try vault.revisionNames(of: note).map { try Data(contentsOf: fileURL(vault, note, $0)) }
    }

    // MARK: - Removal

    func testHomeRemovesADeviceAndEveryListedDeviceFollows() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        var a = try w.open("A")
        let b0 = try w.open("B"), x0 = try w.open("X")
        let na = try w["A"].newNote(a, "from A")
        let nb = try w["B"].newNote(b0, "from B")
        let nx = try w["X"].newNote(x0, "from X")
        let v1 = x0.identities

        let report = try a.removeDevices([w["X"].id])
        XCTAssertEqual(report.epoch, 2)
        XCTAssertEqual(report.reason, .remove)
        XCTAssertEqual(report.removed, [w["X"].fingerprint])
        XCTAssertGreaterThanOrEqual(report.sealed, 3)
        XCTAssertEqual(a.manifest.epoch, 2)
        XCTAssertTrue(a.isHome)
        XCTAssertFalse(a.manifest.keys.contains { $0.fingerprint == w["X"].fingerprint })
        // Files from before the change stay readable: the record seals them (design §5.3 rule 2).
        XCTAssertEqual(try w.titles(a), [na: "from A", nb: "from B", nx: "from X"])

        let b = try w.open("B")
        XCTAssertEqual(b.listStatus, .verified(.newEpoch))
        XCTAssertEqual(try w.titles(b), [na: "from A", nb: "from B", nx: "from X"])
        XCTAssertTrue(b.verify().isHealthy, "\(b.verify())")

        // J5a: B's next write is under the new key; J2: the removed device's key opens none of it.
        let nb2 = try w["B"].newNote(b, "after")
        for data in try revisionData(b, nb2) {
            XCTAssertThrowsError(try AgeFile.decrypt(data, with: v1), "written under the old key")
            XCTAssertNoThrow(try AgeFile.decrypt(data, with: b.identities))
        }
        // X verifies its own removal and writes nothing (design §5.5).
        XCTAssertThrowsError(try w.open("X")) {
            guard case VaultError.removedFromVault(let why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("A (\(w["A"].id))"), why)
        }
    }

    func testOnlyHomeRemovesAndNeverItself() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        var b = try w.open("B")
        XCTAssertThrowsError(try b.removeDevices([w["A"].id])) {
            guard case VaultError.notHome = $0 else { return XCTFail("\($0)") }
        }
        var a = try w.open("A")
        XCTAssertThrowsError(try a.removeDevices([w["A"].id])) {
            guard case VaultError.epochChangeRefused = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try a.removeDevices(["ffff0000"]))
        XCTAssertEqual(try Vault.open(at: w.url).manifest.epoch, 1, "nothing written")
    }

    /// J3 (no injection) and J2: a removed device that keeps writing under the key it held is never taken.
    func testARemovedDevicesLaterWritesAreSetAsideEverywhere() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        var a = try w.open("A")
        let stale = try w.open("X")   // X's value from before the change, as a device that never saw it
        try a.removeDevices([w["X"].id])
        let injected = try w["X"].newNote(stale, "planted")   // under K_1, after the change: not sealed

        let b = try w.open("B")
        XCTAssertNil(try w.titles(b)[injected], "J3: never placed")
        let loaded = try b.loadNote(injected)
        XCTAssertTrue(loaded.revisions.isEmpty)
        XCTAssertTrue(loaded.failures.values.allSatisfy { $0 == .setAside(.notSealed) }, "\(loaded.failures)")
        let report = b.verify()
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.counts[.setAside], 1)
        // A set-aside scan copies it into B's store; the original stays (never placed, never deleted).
        let scanned = try b.setAsideScan()
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(w["B"].setAside.items(vaultId: b.vaultId).map(\.reason), [.notSealed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(b, injected, try b.revisionNames(of: injected)[0]).path))
        // Keep, on the user's word, re-encrypts it under the current key (design §5.8).
        let item = try XCTUnwrap(b.setAsideReport().first)
        XCTAssertFalse(item.superseded)
        try b.keepSetAside(item.item)
        XCTAssertEqual(try w.titles(try w.open("B"))[injected], "planted")
        XCTAssertTrue(try w.open("B").setAsideReport().first?.superseded == true)
    }

    // MARK: - Catch-up (design §5.4)

    /// J1 (no loss) and J8 (body integrity): a still-listed device that wrote under the old key after the
    /// change re-encrypts its own files from its ledger; until then they are set aside elsewhere.
    func testAnOfflineListedDeviceCatchesUpFromItsLedger() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "written offline")
        let before = try revisionData(staleC, note)
        XCTAssertNil(try w.titles(try w.open("A"))[note], "set aside until C catches up")
        XCTAssertEqual(try w["C"].ledger.entries().map(\.epoch), [1])

        let c = try w.open("C")
        XCTAssertEqual(c.listStatus, .verified(.newEpoch))
        let report = try c.catchUp()
        XCTAssertEqual(report.reencrypted, [Vault.notePath(note, try c.revisionNames(of: note)[0].filename)])
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(try w["C"].ledger.entries().map(\.epoch), [2], "the entry follows the file")
        XCTAssertEqual(try w["C"].ledger.caughtUp(), c.manifest.epochId)
        // The same body under the new key (J8); the old bytes set aside first (J6).
        let after = try revisionData(c, note)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(try w.titles(try w.open("A"))[note], "written offline")
        XCTAssertEqual(w["C"].setAside.items(vaultId: c.vaultId).map(\.sha256), before.map { FileDigest.sha256($0) })
        // Idempotent.
        XCTAssertTrue(try c.catchUp().reencrypted.isEmpty)
    }

    /// The first write at a new epoch catches the device up by itself (design §5.4 step 1).
    func testTheFirstWriteAtANewEpochCatchesUp() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "offline")
        let c = try w.open("C")
        try w["C"].newNote(c, "online")
        XCTAssertEqual(try w.titles(try w.open("A"))[note], "offline")
    }

    func testCatchUpCoversBlobsNotebookRecordsAndSettings() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "with a blob")
        let ref = try staleC.writeBlob(note: note, Data("attachment".utf8), type: "image/png")
        _ = try staleC.createNotebook("Offline/Work")
        var settings = SharedSettings()
        try settings.set(SettingSlotKey("photos.removeMetadata"), to: .bool(false), type: .mac, now: Date())
        try staleC.writeSharedSettings(settings)

        let a2 = try w.open("A")
        XCTAssertThrowsError(try a2.readBlob(note: note, ref)) { XCTAssertEqual($0 as? BlobError, .setAside(.notSealed)) }
        XCTAssertTrue(try a2.readNotebookRecords().records.isEmpty)
        XCTAssertThrowsError(try a2.readSharedSettingsFile())

        let c = try w.open("C")
        let report = try c.catchUp()
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(report.reencrypted.count, 4, "\(report.reencrypted)")
        let a3 = try w.open("A")
        XCTAssertEqual(try a3.readBlob(note: note, ref), Data("attachment".utf8))
        XCTAssertEqual(try a3.readNotebookRecords().records.count, 1)
        XCTAssertNotNil(try a3.readSharedSettingsFile())
        XCTAssertTrue(a3.verify().isHealthy)
    }

    /// J6: nothing replaces an unaccepted file whose copy could not be set aside.
    func testASetAsideThatFailsStopsTheReplacement() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "offline")
        let before = try revisionData(staleC, note)
        // The store's folder is a file: no copy can be kept.
        try Data().write(to: w["C"].setAside.directory)
        let c = try w.open("C")
        let report = try c.catchUp()
        XCTAssertEqual(report.problems.count, 1, "\(report)")
        XCTAssertEqual(try revisionData(c, note), before, "the original stays")
        XCTAssertNotEqual(try w["C"].ledger.caughtUp(), c.manifest.epochId, "tried again later")
    }

    func testAnUnreadableLedgerFailsClosed() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var a = try w.open("A")
        let staleC = try w.open("C")
        try a.removeDevices([w["X"].id])
        let note = try w["C"].newNote(staleC, "offline")
        let before = try revisionData(staleC, note)
        w["C"].ledger.markUnreadable("damaged")
        let c = try w.open("C")
        XCTAssertThrowsError(try c.catchUp()) {
            guard case VaultError.ledgerUnreadable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try revisionData(c, note), before)
        XCTAssertTrue(w["C"].setAside.items(vaultId: c.vaultId).isEmpty, "nothing set aside on its account")
    }

    // MARK: - Handoff (design §5.6 rule 2)

    func testAHandoffMovesHomeAndTheOldHomeNoLongerSigns() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var a = try w.open("A")
        let n = try w["A"].newNote(a, "kept")
        let report = try a.handOff(to: w["B"].id)
        XCTAssertEqual(report.reason, .handoff)
        XCTAssertEqual(report.home, w["B"].fingerprint)
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertFalse(a.isHome)
        XCTAssertThrowsError(try a.removeDevices([w["C"].id])) {
            guard case VaultError.notHome = $0 else { return XCTFail("\($0)") }
        }
        var b = try w.open("B")
        XCTAssertTrue(b.isHome)
        XCTAssertEqual(try w.titles(b)[n], "kept")
        try b.removeDevices([w["A"].id])
        XCTAssertThrowsError(try w.open("A")) {
            guard case VaultError.removedFromVault = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try w.open("C").listStatus, .verified(.newEpoch))
    }

    /// A former home signing after its handoff (a copied or stolen key) is not followed: the chain check
    /// wants the parent's home (design §5.6, §11.1 "a handoff, then the old home signing").
    func testTheOldHomeSigningAfterAHandoffIsIgnored() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var a = try w.open("A")
        try a.handOff(to: w["B"].id)
        _ = try w.open("C").requireWritable()   // C pins epoch 2 (home B)
        // A signs an epoch under epoch 2, as if it were still home.
        try forgeEpoch(w, author: w["A"], removing: [])
        let c = try w.open("C")
        XCTAssertEqual(c.listStatus.problem?.reason, .epochSig, "\(c.listStatus)")
        XCTAssertThrowsError(try w["C"].newNote(c, "x"))
        XCTAssertEqual(try w.open("B").listStatus.problem?.reason, .epochSig)
    }

    /// A device that is not home signs an epoch (design §5.6 rule 4): nobody follows it, and a device it
    /// "removes" is not told it was removed (an epoch it cannot verify never counts as its removal).
    func testANonHomeSignerIsIgnored() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        _ = try w.open("C").requireWritable()
        try forgeEpoch(w, author: w["B"], removing: [])
        for d in ["A", "C"] {
            let v = try w.open(d)
            XCTAssertFalse(v.listStatus.allowsWriting, "\(d): \(v.listStatus)")
            XCTAssertThrowsError(try w[d].newNote(v, "x"))
        }
        let dir = tmp.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w2 = try EpochWorld(in: dir, names: ["A", "B", "C"])
        _ = try w2.open("C").requireWritable()
        try forgeEpoch(w2, author: w2["B"], removing: [w2["C"].fingerprint])
        XCTAssertThrowsError(try w2.open("C")) {
            guard case VaultError.keyNotListed = $0 else { return XCTFail("\($0)") }
        }
    }

    /// Writes an epoch over the folder's `vault.json` signed by `author` whatever the rules say (what a
    /// copied key or a removed device could do).
    private func forgeEpoch(_ w: EpochWorld, author: EpochDevice, removing: Set<Data>) throws {
        let v = try author.open(w.url)
        let entry = try XCTUnwrap(v.manifest.devices.first { $0.fingerprint == author.fingerprint })
        let plan = Vault.EpochPlan(
            reason: .remove, parentKey: try v.requireSecret(), parentChain: try v.currentChain(),
            parentList: v.manifest.keys.map(\.fingerprint), parentAdditions: v.currentAdditions(),
            devices: v.manifest.devices.filter { !removing.contains($0.fingerprint) }, recovery: try XCTUnwrap(v.manifest.recoveryEntry),
            home: author.fingerprint, author: entry, signing: author.keys.signing, recoverySigner: nil,
            sealed: try v.sealedSet(try v.currentSealView()), created: Date(), label: nil, features: [])
        _ = try v.writeEpoch(plan)
    }

    // MARK: - Takeover (design §5.6 rule 3, §6.3)

    /// The stolen home (design §11.1): the thief's home removes C; C is unlisted. The owner takes over on B
    /// with the recovery kit, re-admits C and drops A; C follows and writes again, A is out.
    func testAStolenHomeIsUndoneByATakeover() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        var thief = try w.open("A")
        let n = try w["C"].newNote(try w.open("C"), "C's note")
        try thief.removeDevices([w["C"].id])
        XCTAssertThrowsError(try w.open("C")) { guard case VaultError.removedFromVault = $0 else { return XCTFail("\($0)") } }
        // B pins the thief's epoch (it follows home linearly until the takeover reaches it).
        let b = try w.open("B")
        try w["B"].newNote(b, "B before")

        let plan = try Vault.takeoverPlan(at: w.url, device: w["B"].keys, recovery: w.recovery, trust: w["B"].trust, root: nil)
        XCTAssertEqual(plan.parentEpoch, 2)
        let cCand = try XCTUnwrap(plan.candidates.first { $0.fingerprint == w["C"].fingerprint })
        XCTAssertFalse(cCand.listed, "a device a later epoch removed is unchecked by default")
        XCTAssertTrue(try XCTUnwrap(plan.candidates.first { $0.fingerprint == w["A"].fingerprint }).listed)
        let (vb, report) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [w["C"].fingerprint],
                                              trust: w["B"].trust, root: nil, ledger: w["B"].ledger, setAside: w["B"].setAside)
        XCTAssertEqual(report.reason, .takeover)
        XCTAssertEqual(report.home, w["B"].fingerprint)
        XCTAssertTrue(vb.isHome)
        XCTAssertEqual(vb.manifest.epoch, 3)
        XCTAssertEqual(Set(report.removed), [w["A"].fingerprint])

        // C rejoins by itself (design §5.5) and reads everything; A is out.
        let c = try w.open("C")
        XCTAssertEqual(c.listStatus, .verified(.newEpoch))
        XCTAssertEqual(try w.titles(c)[n], "C's note")
        try w["C"].newNote(c, "C again")
        XCTAssertThrowsError(try w.open("A")) { guard case VaultError.removedFromVault = $0 else { return XCTFail("\($0)") } }
        // The thief's later approvals and removals count nowhere: only home (B) signs now.
        var thiefAgain = thief
        XCTAssertThrowsError(try thiefAgain.removeDevices([w["B"].id]))
    }

    /// A takeover beats the home epochs that are not its ancestors (design §5.6 rule 4): a device pinned on
    /// the stolen home's later epoch drops it, and catches up its own files from it (design §5.4).
    func testATakeoverDropsTheStolenHomesLaterEpochsAndTheirWritersCatchUp() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "D"])
        let nb = try w["B"].newNote(try w.open("B"), "B before")   // B pins epoch 1
        var thief = try w.open("A")
        try thief.removeDevices([w["B"].id])   // epoch 2 by the stolen home
        let d = try w.open("D")
        let nd = try w["D"].newNote(d, "D under the thief's key")   // D pins epoch 2 and writes under K_2
        // The owner takes over on B from B's pinned epoch 1, keeping D.
        let (vb, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [w["D"].fingerprint],
                                         trust: w["B"].trust, root: nil, ledger: w["B"].ledger, setAside: w["B"].setAside)
        XCTAssertEqual(vb.manifest.epoch, 2)
        let d2 = try w.open("D")
        XCTAssertEqual(d2.listStatus, .verified(.newEpoch))
        XCTAssertEqual(d2.droppedEpochs.count, 1, "the thief's epoch is dropped")
        // D's own file under the dropped key comes back from its ledger (round 7, H1).
        let report = try d2.catchUp()
        XCTAssertTrue(report.problems.isEmpty, "\(report)")
        XCTAssertEqual(try w.titles(try w.open("B"))[nd], "D under the thief's key")
        XCTAssertEqual(try w.titles(try w.open("B"))[nb], "B before")
    }

    /// A kit join is a takeover (design §6.3): a new device with only the kit and the root becomes home.
    func testAKitJoinTakesOverAsANewHome() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let n = try w["A"].newNote(try w.open("A"), "kept")
        let newcomer = EpochDevice("N", root: tmp)
        XCTAssertThrowsError(try Vault.takeover(at: w.url, device: newcomer.keys, recovery: w.recovery, keep: [],
                                                trust: newcomer.trust, root: nil)) {
            guard case VaultError.untrustedList(let p) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(p.reason, .rootUnconfirmed, "no root: refused")
        }
        let wrongRoot = Data(repeating: 7, count: 32)
        XCTAssertThrowsError(try Vault.takeover(at: w.url, device: newcomer.keys, recovery: w.recovery, keep: [],
                                                trust: newcomer.trust, root: wrongRoot))
        let (v, report) = try Vault.takeover(at: w.url, device: newcomer.keys, recovery: w.recovery,
                                             keep: [w["B"].fingerprint], name: "New iPad", kind: "ipad",
                                             trust: newcomer.trust, root: w.root, ledger: newcomer.ledger,
                                             setAside: newcomer.setAside)
        XCTAssertTrue(v.isHome)
        XCTAssertEqual(report.removed, [w["A"].fingerprint])
        let entry = try XCTUnwrap(v.deviceEntry)
        XCTAssertEqual(entry.addedBy, EntryClaim.recovery)
        XCTAssertEqual(entry.name, "New iPad")
        XCTAssertEqual(try w.titles(v)[n], "kept")
        XCTAssertEqual(try w.open("B").listStatus, .verified(.newEpoch))
        XCTAssertEqual(try w.open("B").manifest.home, newcomer.fingerprint)
    }

    /// Two takeovers that are not ancestors of each other: the smaller `epochId` wins, silently and the same
    /// way on every device (design §5.6 rule 4).
    func testOfTwoTakeoversTheSmallerEpochIdWins() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C", "D"])
        for d in ["B", "C", "D"] { try w[d].newNote(try w.open(d), d) }   // all pin epoch 1
        let all = Set(["A", "B", "C", "D"].map { w[$0].fingerprint })
        let (vb, _) = try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery,
                                         keep: all.subtracting([w["B"].fingerprint]), trust: w["B"].trust, root: nil)
        let t1 = vb.manifest.epochId
        _ = try w.open("D").requireWritable()   // D pins T1
        let (vc, _) = try Vault.takeover(at: w.url, device: w["C"].keys, recovery: w.recovery,
                                         keep: all.subtracting([w["C"].fingerprint]), trust: w["C"].trust, root: nil)
        let t2 = vc.manifest.epochId
        XCTAssertEqual(vc.manifest.parent, vb.manifest.parent, "both under epoch 1")
        // The folder now shows T2. D (pinned on T1) follows it only when T2's id is the smaller.
        let d = try w.open("D")
        let t2Wins = t2.lexicographicallyPrecedes(t1)
        XCTAssertEqual(d.listStatus.allowsWriting, t2Wins, "\(d.listStatus)")
        // A device that pinned neither (still on epoch 1) follows T2: it sees only it (order independence:
        // the rule is the same wherever the device stands).
        XCTAssertTrue(try w.open("A").listStatus.allowsWriting)
    }

    // MARK: - Recovery kit replacement (design §6.5)

    func testReplacingTheKitNeedsTheDeviceReviewAndRetiresTheOldKit() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"], passphrase: "correct horse battery staple orbit ninja")
        let staleB = try w.open("B")   // B has not seen the replacement yet
        var a = try w.open("A")
        let review = try a.kitReview()
        XCTAssertEqual(Set(review.map(\.device.fingerprint)), [w["B"].fingerprint, w["X"].fingerprint])
        let newKit = try MLKEM768X25519Identity()
        XCTAssertThrowsError(try a.replaceRecoveryKit(newKit, keep: [w["B"].id], remove: [])) {
            guard case VaultError.epochChangeRefused(let why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("X (\(w["X"].id))"), why)
        }
        let oldCopies = a.passphraseCopyNames()
        let report = try a.replaceRecoveryKit(newKit, keep: [w["B"].id], remove: [w["X"].id], oldRecovery: w.recovery,
                                              passphrase: "tangerine wombat quarry velvet mosaic lantern")
        XCTAssertEqual(report.reason, .recovery)
        XCTAssertEqual(report.removed.count, 2, "the old kit and X")
        XCTAssertEqual(a.manifest.recoveryEntry?.key, newKit.recipient.string)
        XCTAssertEqual(a.verifiedChain?.entries.last?.recoveryAuthor?.recoveryFingerprint,
                       try KeyFingerprint.recovery(identity: w.recovery), "the old kit's evidence signature")
        let copies = a.passphraseCopyNames()
        XCTAssertEqual(copies.count, 1)
        XCTAssertNotEqual(copies, oldCopies, "the superseded copy is deleted")
        XCTAssertEqual(try a.openPassphraseCopy(passphrase: "tangerine wombat quarry velvet mosaic lantern").identity.recipient,
                       newKit.recipient)

        // The old kit no longer opens the current epoch, and a device that pinned the replacement refuses
        // its takeover (design §5.6 rule 3).
        XCTAssertThrowsError(try Vault.open(at: w.url, identities: [NativeIdentity.mlkem768x25519(w.recovery)]))
        _ = try w.open("B").requireWritable()   // B pins epoch 2
        XCTAssertThrowsError(try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [],
                                                trust: w["B"].trust, root: nil))
        // The new kit takes over on a device that pinned it.
        XCTAssertNoThrow(try Vault.takeoverPlan(at: w.url, device: w["B"].keys, recovery: newKit, trust: w["B"].trust, root: nil))
        _ = staleB
    }

    /// A kit introduced above a device's pinned frontier signs nothing for it until it pins the replacement
    /// (round 8, C1-b): the takeover waits a run (`kitNotPinned`), then counts.
    func testANewKitsTakeoverWaitsUntilTheReplacementIsPinned() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "C"])
        _ = try w.open("C").requireWritable()   // C pins epoch 1
        var a = try w.open("A")
        let newKit = try MLKEM768X25519Identity()
        try a.replaceRecoveryKit(newKit, keep: [w["B"].id, w["C"].id], remove: [])
        _ = try w.open("B").requireWritable()   // B pins epoch 2 (the replacement)
        let all = Set(["A", "C"].map { w[$0].fingerprint })
        try Vault.takeover(at: w.url, device: w["B"].keys, recovery: newKit, keep: all, trust: w["B"].trust, root: nil)
        // C pinned epoch 1: the new kit is not its frontier's.
        let c = try w.open("C")
        XCTAssertEqual(c.listStatus.problem?.reason, .otherEpoch, "\(c.listStatus)")
        XCTAssertThrowsError(try c.requireWritable(), "this write is refused, the replacement is pinned meanwhile")
        let again = try w.open("C")
        XCTAssertEqual(again.listStatus, .verified(.newEpoch), "a run later the takeover counts")
    }

    // MARK: - EpochFaults (design §11.1, core points)

    func testACrashAfterTheRecordLeavesAnOrphanThatNothingReads() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        var a = try w.open("A")
        a.faults = EpochFaults(stop: .afterRecord)
        XCTAssertThrowsError(try a.removeDevices([w["X"].id])) { XCTAssertEqual($0 as? VaultError, .interrupted) }
        let records = try FileManager.default.contentsOfDirectory(atPath: w.url.appendingPathComponent("epochs").path)
        XCTAssertEqual(records.count, 2, "epoch 1's and the orphan")
        let b = try w.open("B")
        XCTAssertEqual(b.manifest.epoch, 1)
        XCTAssertEqual(b.listStatus, .verified(.unchanged))
        XCTAssertTrue(b.verify().isHealthy, "an orphan is an unknown file")
        // The next removal works.
        var a2 = try w.open("A")
        XCTAssertEqual(try a2.removeDevices([w["X"].id]).epoch, 2)
        XCTAssertEqual(try w.open("B").listStatus, .verified(.newEpoch))
    }

    func testACrashAfterVaultJsonIsAFinishedChange() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        var a = try w.open("A")
        let n = try w["A"].newNote(a, "one")
        a.faults = EpochFaults(stop: .afterManifest)
        XCTAssertThrowsError(try a.removeDevices([w["X"].id]))
        let again = try w.open("A")
        XCTAssertEqual(again.listStatus, .verified(.newEpoch))
        XCTAssertEqual(try w.titles(again)[n], "one")
        try w["A"].newNote(again, "two")
        XCTAssertThrowsError(try w.open("X"))
    }

    func testACrashAfterTheLedgerIntentLeavesAnEntryThatIsDropped() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        var c = try w.open("C")
        c.faults = EpochFaults(stop: .afterLedgerIntent)
        XCTAssertThrowsError(try w["C"].newNote(c, "never placed"))
        XCTAssertEqual(try w["C"].ledger.entries().count, 1)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        let report = try w.open("C").catchUp()
        XCTAssertEqual(report.dropped.count, 1)
        XCTAssertTrue(try w["C"].ledger.entries().isEmpty)
    }

    func testCatchUpResumesAfterACrashAtEachPoint() throws {
        for point: EpochFaults.Point in [.catchUpWritten(1), .catchUpVerified(1), .catchUpPlaced(1)] {
            let dir = tmp.appendingPathComponent("\(point)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let w = try EpochWorld(in: dir, names: ["A", "C", "X"])
            var a = try w.open("A")
            let staleC = try w.open("C")
            try a.removeDevices([w["X"].id])
            let note = try w["C"].newNote(staleC, "offline")
            var c = try w.open("C")
            c.faults = EpochFaults(stop: point)
            XCTAssertThrowsError(try c.catchUp(), "\(point)")
            // Whatever the point, the path holds one body and the next run finishes (J1, J8).
            let resumed = try w.open("C")
            let report = try resumed.catchUp()
            XCTAssertTrue(report.problems.isEmpty, "\(point): \(report)")
            XCTAssertEqual(try w.titles(try w.open("A"))[note], "offline", "\(point)")
            XCTAssertEqual(try w["C"].ledger.entries().map(\.epoch), [2], "\(point)")
        }
    }

    func testCrashesInAHandoffAndATakeover() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        var a = try w.open("A")
        a.faults = EpochFaults(stop: .afterRecord)
        XCTAssertThrowsError(try a.handOff(to: w["B"].id))
        XCTAssertEqual(try w.open("B").manifest.home, w["A"].fingerprint, "not handed off")
        XCTAssertThrowsError(try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [], name: "B",
                                                kind: "cli", trust: w["B"].trust, root: nil, ledger: nil, setAside: nil,
                                                now: Date(), faults: EpochFaults(stop: .afterRecord)))
        XCTAssertEqual(try w.open("A").listStatus, .verified(.unchanged))
        XCTAssertThrowsError(try Vault.takeover(at: w.url, device: w["B"].keys, recovery: w.recovery, keep: [], name: "B",
                                                kind: "cli", trust: w["B"].trust, root: nil, ledger: nil, setAside: nil,
                                                now: Date(), faults: EpochFaults(stop: .afterManifest)))
        let b = try w.open("B")
        XCTAssertEqual(b.listStatus, .verified(.newEpoch))
        XCTAssertTrue(b.isHome)
    }

    // MARK: - Blob collection (design §5.7)

    func testABlobOnlyASetAsideRevisionReferencesIsNotCollected() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B", "X"])
        var a = try w.open("A")
        let note = try w["A"].newNote(a, "note")
        let stale = try w.open("X")
        try a.removeDevices([w["X"].id])
        // X (removed, stale) writes a blob and a revision referencing it, both under K_1, unsealed.
        let ref = try stale.writeBlob(note: note, Data("x".utf8), type: "image/png")
        try stale.apply([.setMeta(.title("x"))], to: note, deviceState: w["X"].state, app: "t")
        _ = ref
        let b = try w.open("B")
        var records: [String: Date] = [:]
        let report = try b.collectBlobs(note: note, records: &records, now: Date().addingTimeInterval(400 * 86400), retention: 0)
        XCTAssertTrue(report.deleted.isEmpty)
        XCTAssertNotNil(report.blocked, "rule 1: a set-aside revision blocks collection")
    }

    // MARK: - Rules carried over from #57

    /// A received `vault.json` that lists fewer keys under the same epoch is not taken (§13.1).
    func testAnIncomingListWithFewerKeysUnderTheSameEpochIsRefused() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "B"])
        let full = try Data(contentsOf: w.url.appendingPathComponent("vault.json"))
        let a = try w.open("A")
        var shrunk = a.manifest
        shrunk.keys.removeAll { $0.fingerprint == w["B"].fingerprint }
        let resealed = try a.resealed(shrunk, home: w["A"].identity)
        let data = try resealed.encoded()
        XCTAssertNotNil(Vault.incomingManifestProblem(data, local: full, vault: a))
        XCTAssertNil(Vault.incomingManifestProblem(full, local: full, vault: a))
    }
}
