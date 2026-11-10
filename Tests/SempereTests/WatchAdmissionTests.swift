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
        let w = try EpochWorld(in: tmp, names: ["A", "P", "X"])
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
