import Age
import Foundation
import VaultTestSupport
import XCTest
@testable import Sempere
import SempereCapture

/// Which Watch files the phone admits (docs/design/1.1-watch.md §3.4 "Admission"), against real epochs and a real write ledger:
/// a copy of the phone's capture profile that is still on a lost watch can add nothing after the owner replaced the key,
/// however the file reaches the phone, and an epoch the phone never held never reaches the ledger.
final class WatchAdmissionTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26")
    }

    /// The phone's adapter over a shared vault: the stored profile's epoch is what `profile` says, the ledger is the
    /// phone's own, placement is ledger first and then the inbox.
    final class Phone: WatchDelivery, @unchecked Sendable {
        let vault: UUID
        let url: URL
        let inbox: URL
        let ledger: any WriteLedgerStore
        var profile: CaptureProfile
        var enabled = true

        init(vault: Vault, ledger: any WriteLedgerStore, profile: CaptureProfile) {
            self.vault = vault.vaultId
            url = vault.url
            inbox = vault.inboxURL
            self.ledger = ledger
            self.profile = profile
        }

        var currentVault: UUID? { vault }
        var linkEnabled: Bool { enabled }
        func knownEpoch(of vault: UUID) throws -> (epoch: Int, id: Data)? {
            guard vault == self.vault, let id = Hex.decode(profile.epochId) else { return nil }
            return (profile.epoch, id)
        }
        func holdsKey(of epochId: Data, vault: UUID) throws -> Bool {
            try ledger.epochKeys().contains { $0.key.epochId == epochId }
        }
        func folderEpoch(of vault: UUID) -> Int? { try? Vault.open(at: url).manifest.epoch }
        func inboxHolds(id: UUID, vault: UUID) -> Bool {
            FileManager.default.fileExists(atPath: inbox.appendingPathComponent(CaptureFile.name(id, .capture)).path)
        }
        func deliverToCurrent(_ sealed: SealedCapture) throws -> WatchPlacement {
            try WatchLedger.record(sealed, in: ledger)
            try CaptureWriter.store(sealed, in: inbox)
            return .vault
        }
        func holds(vault: UUID) -> Bool { vault == self.vault }
        func recordAndPlace(_ sealed: SealedCapture, in vault: UUID) throws -> Bool { false }
        func queue(_ sealed: SealedCapture, for vault: UUID) throws { XCTFail("not expected") }
    }

    let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })

    func intake(_ phone: Phone) -> WatchIntake {
        WatchIntake(received: WatchReceivedSet(url: nil), delivery: phone,
                    held: WatchHeldStore(root: tmp.appendingPathComponent("held-\(UUID().uuidString)")))
    }

    func send(_ sealed: SealedCapture, vault: UUID, meta overrides: ((inout WatchTransferMeta) -> Void)? = nil,
              intake: WatchIntake) throws -> WatchIntakeResult {
        var meta = try WatchTransferMeta(sealed: sealed, vault: vault)
        overrides?(&meta)
        let f = tmp.appendingPathComponent(UUID().uuidString)
        try sealed.data.write(to: f)
        return try intake.receive(file: f, meta: meta)
    }

    /// A lost watch's note, sealed with its epoch-1 copy after the owner started a new epoch, is held: it never gets a
    /// ledger entry, so no catch-up re-seals it as the phone's own note. Adding it is the owner's decision.
    func testALostWatchCannotPlantANoteAfterANewEpoch() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X"])   // A home, P the iPhone, X any other device
        let watchCopy = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        XCTAssertEqual(watchCopy.epoch, 1)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])                          // a new epoch: P's capture key is replaced
        // The phone unlocks, refreshes its stored profile and writes (caught up).
        let phoneNow = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        XCTAssertEqual(phoneNow.epoch, 2)
        try w["P"].newNote(try w.open("P"), "after the new epoch")
        let phone = Phone(vault: try w.open("P"), ledger: w["P"].ledger, profile: phoneNow)
        let intake = intake(phone)

        let id = UUID()
        let sealed = try CaptureWriter(profile: watchCopy).seal(audio: audio, started: Date(), title: "planted", id: id)
        let result = try send(sealed, vault: a.vaultId, intake: intake)
        XCTAssertEqual(result.outcome, .held(.oldEpoch))
        XCTAssertTrue(result.acknowledged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.inbox.appendingPathComponent(sealed.name).path))
        XCTAssertTrue(try w["P"].ledger.entries().filter { $0.path.hasPrefix("inbox/") }.isEmpty, "no ledger entry for it")
        // The phone's next ordinary write catches up; the file is not in the vault, so nothing was re-sealed.
        try w["P"].newNote(try w.open("P"), "next write on the phone")
        XCTAssertNil(try w.open("A").readCapture(id).audio, "nothing to adopt")

        // The owner adds it: the normal path, and catch-up re-seals it under the current key.
        let held = try XCTUnwrap(intake.held?.list().first)
        XCTAssertTrue(held.canAdd)
        XCTAssertEqual(try intake.addHeld(held), .vault)
        try w["P"].newNote(try w.open("P"), "after add")
        XCTAssertEqual(try w.open("A").readCapture(id).audio, audio, "re-sealed under the current key")
    }

    /// The phone has not unlocked since another device changed the epoch (its stored profile is still epoch 1): the
    /// plaintext `vault.json` epoch is ahead, so the file is held rather than admitted.
    func testAFolderAheadOfThePhonesProfileHoldsTheFile() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X"])
        let watchCopy = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        let phone = Phone(vault: try w.open("P"), ledger: w["P"].ledger, profile: watchCopy)   // still epoch 1
        let sealed = try CaptureWriter(profile: watchCopy).seal(audio: audio, started: Date(), id: UUID())
        XCTAssertEqual(try send(sealed, vault: a.vaultId, intake: intake(phone)).outcome, .held(.newerEpoch))
        XCTAssertTrue(try w["P"].ledger.entries().isEmpty)
    }

    /// Metadata that names an epoch the phone never held: held, delete only, never in the ledger, so catch-up has nothing
    /// to retry. A file that lies about its epoch as the current one is admitted but is not re-sealed (its tag does not
    /// verify under the claimed epoch's key).
    func testAnEpochThePhoneNeverHeldIsHeldAndALiarIsNotCaughtUp() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X", "Y"])
        let profile1 = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        let p2 = try w.open("P")
        let current = try p2.captureProfile(device: DeviceID("0c0c0c0c")!)
        let phone = Phone(vault: p2, ledger: w["P"].ledger, profile: current)
        let intake = intake(phone)

        let s1 = try CaptureWriter(profile: current).seal(audio: audio, started: Date(), id: UUID())
        let r1 = try send(s1, vault: a.vaultId, meta: { $0.epoch = 77; $0.epochId = String(repeating: "ab", count: 32) }, intake: intake)
        XCTAssertEqual(r1.outcome, .held(.unknownEpoch))
        XCTAssertFalse(try XCTUnwrap(intake.held?.list().first).canAdd)
        XCTAssertTrue(try w["P"].ledger.entries().isEmpty)
        let report = try w.open("P").catchUp()
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(try w["P"].ledger.caughtUp(), try w.open("P").requireSecret().epochId, "caught up, nothing to retry")

        let id2 = UUID()
        let s2 = try CaptureWriter(profile: profile1).seal(audio: audio, started: Date(), id: id2)
        let curId = Hex.encode(try XCTUnwrap(try w.open("P").requireSecret().epochId))
        let r2 = try send(s2, vault: a.vaultId, meta: { $0.epoch = current.epoch; $0.epochId = curId }, intake: intake)
        XCTAssertEqual(r2.outcome, .placed(.vault))
        _ = try w.open("P").catchUp()
        XCTAssertThrowsError(try w.open("A").readCapture(id2), "a mislabelled old-epoch note is not caught up")
        // Nor after a further epoch change, when its label has become an earlier epoch too (review of the 1.1.0 repair:
        // catch-up's fallback tries only epochs after the labeled one).
        a = try w.open("A")
        try a.removeDevices([w["Y"].id])
        let later = try w.open("P").catchUp()
        XCTAssertFalse(later.reencrypted.contains("inbox/\(s2.name)"), "\(later)")
        XCTAssertFalse(later.relabeled.contains("inbox/\(s2.name)"), "\(later)")
        XCTAssertThrowsError(try w.open("A").readCapture(id2), "still not laundered")
    }

    /// 1.1.0's quick-capture refresh gave the stored profile the new epoch's key and recipient but kept the old epoch's number
    /// and id. The phone's Lock Screen notes and the Watch's were then sealed under the current key and labeled with the epoch
    /// before; the Watch's were held as "newer key", and an added one was recorded under the old label. Adoption reads such a
    /// file (it is sealed under the current key); catch-up corrects its ledger entry instead of failing to re-seal it under
    /// the labeled key on every write.
    func testAStaleEpochLabelOnTheCurrentKeyIsAdoptedAndRelabeled() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X", "Y"])
        let profile1 = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        var stale = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        XCTAssertEqual(stale.epoch, 2)
        stale.epoch = profile1.epoch
        stale.epochId = profile1.epochId   // what 1.1.0's refresh left
        let phone = Phone(vault: try w.open("P"), ledger: w["P"].ledger, profile: stale)
        let intake = intake(phone)

        // A Watch note: held (the folder's epoch is above the label), added by the owner.
        let watchId = UUID()
        let watchNote = try CaptureWriter(profile: stale).seal(audio: audio, started: Date(), id: watchId)
        XCTAssertEqual(try send(watchNote, vault: a.vaultId, intake: intake).outcome, .held(.newerEpoch))
        let held = try XCTUnwrap(intake.held?.list().first)
        XCTAssertEqual(try intake.addHeld(held), .vault)
        // A Lock Screen note of the phone: recorded under the label, placed.
        let lockId = UUID()
        let writer = try CaptureWriter(profile: stale)
        let lockNote = try writer.seal(audio: audio, started: Date(), id: lockId)
        try writer.record(lockNote, in: w["P"].ledger)
        try CaptureWriter.store(lockNote, in: phone.inbox)
        XCTAssertEqual(Set(try w["P"].ledger.entries().filter { $0.path.hasPrefix("inbox/") }.map(\.epoch)), [1])

        let report = try w.open("P").catchUp()
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems)")
        XCTAssertEqual(Set(report.relabeled), ["inbox/\(watchNote.name)", "inbox/\(lockNote.name)"])
        XCTAssertTrue(report.reencrypted.isEmpty, "nothing to re-seal")
        XCTAssertEqual(Set(try w["P"].ledger.entries().filter { $0.path.hasPrefix("inbox/") }.map(\.epoch)), [2])
        XCTAssertEqual(try w["P"].ledger.caughtUp(), try w.open("P").requireSecret().epochId, "caught up, nothing to retry")
        XCTAssertTrue(try w.open("P").setAsideScan().isEmpty, "nothing set aside")
        XCTAssertEqual(try w.open("A").readCapture(watchId).audio, audio)
        XCTAssertEqual(try w.open("A").readCapture(lockId).audio, audio)

        // Another epoch before adoption: the file is re-sealed from the epoch it opens under, not the one its entry named.
        let laterId = UUID()
        let later = try writer.seal(audio: audio, started: Date(), id: laterId)
        try writer.record(later, in: w["P"].ledger)        // labeled epoch 1, sealed under epoch 2
        try CaptureWriter.store(later, in: phone.inbox)
        a = try w.open("A")
        try a.removeDevices([w["Y"].id])                   // epoch 3
        let third = try w.open("P").catchUp()
        XCTAssertTrue(third.problems.isEmpty, "\(third.problems)")
        XCTAssertEqual(third.reencrypted, ["inbox/\(later.name)"])
        XCTAssertEqual(try w.open("A").readCapture(laterId).audio, audio, "re-sealed under epoch 3")
    }

    /// After a takeover from below the frontier, the ledger keeps the key of the epoch the takeover dropped, whose number
    /// can be above an epoch on the chain. Catch-up's fallback goes by place on the verified chain, so a file sealed under
    /// the dropped epoch's key and labeled with an earlier epoch is not re-sealed under the new one.
    func testAFallbackNeverReachesAnEpochATakeoverDropped() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X", "T"])   // T stays pinned at epoch 1
        let profile1 = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])                                // epoch 2, which P follows
        var dropped = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        XCTAssertEqual(dropped.epoch, 2)
        dropped.epoch = profile1.epoch
        dropped.epochId = profile1.epochId                               // sealed under epoch 2, labeled epoch 1
        let id = UUID()
        let writer = try CaptureWriter(profile: dropped)
        let sealed = try writer.seal(audio: audio, started: Date(), id: id)
        try writer.record(sealed, in: w["P"].ledger)
        try CaptureWriter.store(sealed, in: try w.open("P").inboxURL)

        // T, with the kit, takes over from its frontier (epoch 1): its epoch 2' drops epoch 2, and P follows it.
        let (taken, _) = try Vault.takeover(at: w.url, device: w["T"].keys, recovery: w.recovery,
                                            keep: [w["P"].fingerprint], trust: w["T"].trust, root: nil)
        XCTAssertEqual(taken.manifest.epoch, 2)
        let p = try w.open("P")
        XCTAssertEqual(p.manifest.epochId, taken.manifest.epochId, "P follows the takeover")
        XCTAssertTrue(try w["P"].ledger.epochKeys().contains { $0.epoch == 2 && $0.key.epochId != taken.manifest.epochId },
                      "the dropped epoch's key is still in P's ledger, with the same number as the takeover's")
        let report = try p.catchUp()
        XCTAssertFalse(report.reencrypted.contains("inbox/\(sealed.name)"), "\(report)")
        XCTAssertFalse(report.relabeled.contains("inbox/\(sealed.name)"), "\(report)")
        XCTAssertThrowsError(try w.open("T").readCapture(id), "not laundered into the takeover's epoch")
    }

    /// Turning "Use on Apple Watch" off holds everything that arrives, whatever its epoch.
    func testTheToggleOffHoldsEvenTheCurrentEpoch() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "P"])
        let profile = try w.open("P").captureProfile(device: DeviceID("0c0c0c0c")!)
        let phone = Phone(vault: try w.open("P"), ledger: w["P"].ledger, profile: profile)
        phone.enabled = false
        let sealed = try CaptureWriter(profile: profile).seal(audio: audio, started: Date(), id: UUID())
        XCTAssertEqual(try send(sealed, vault: profile.vaultId, intake: intake(phone)).outcome, .held(.linkOff))
        XCTAssertTrue(try w["P"].ledger.entries().isEmpty)
    }
}
