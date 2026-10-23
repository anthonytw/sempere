import Age
import Foundation
import XCTest
import VaultTestSupport
@testable import Sempere

/// Ledger that runs `inject` once, at the first `remove` (catch-up calls it after reading the entries and
/// before `setCaughtUp`): stands in for another process appending meanwhile.
final class InjectingLedger: WriteLedgerStore, @unchecked Sendable {
    let base: MemoryWriteLedger
    var inject: (() throws -> Void)?
    init(_ base: MemoryWriteLedger) { self.base = base }
    func append(_ entries: [LedgerEntry]) throws { try base.append(entries) }
    func remove(_ entries: [LedgerEntry]) throws {
        try base.remove(entries)
        if let i = inject { inject = nil; try i() }
    }
    func entries() throws -> [LedgerEntry] { try base.entries() }
    func rememberKey(epoch: Int, key: VaultEpochKey) throws { try base.rememberKey(epoch: epoch, key: key) }
    func epochKeys() throws -> [(epoch: Int, key: VaultEpochKey)] { try base.epochKeys() }
    func caughtUp() throws -> Data? { try base.caughtUp() }
    func setCaughtUp(_ epochId: Data) throws { try base.setCaughtUp(epochId) }
}

/// The reviewer's re-check proof of concept for PR #81 (R1), kept as a regression test: failed on cb9bdc4.
final class ReviewRecheckPoCTests: VaultTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26")
    }

    /// A stale-profile capture recorded WHILE a catch-up runs: catch-up then sets the caught-up mark
    /// unconditionally, so the automatic path never re-seals the capture.
    func testPoC5_CaptureRecordedDuringACatchUpIsNeverCaughtUp() throws {
        let w = try EpochWorld(in: tmp, names: ["A", "C", "X"])
        let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
        let profileC = try w.open("C").captureProfile(device: DeviceID("0c0c0c0c")!)
        var a = try w.open("A")
        try a.removeDevices([w["X"].id])
        let ledger = InjectingLedger(w["C"].ledger)
        func openC() throws -> Vault {
            try Vault.open(at: w.url, identities: [w["C"].identity], signing: TestVaults.signing(w["C"].identity),
                           trust: w["C"].trust, ledger: ledger, setAside: w["C"].setAside)
        }
        let id = UUID()
        let inbox = a.inboxURL
        ledger.inject = {
            let writer = try CaptureWriter(profile: profileC)
            let sealed = try writer.seal(audio: audio, started: Date(), id: id)
            try writer.record(sealed, in: ledger)
            try CaptureWriter.store(sealed, in: inbox)
        }
        try w["C"].newNote(try openC(), "unlock: first write catches up")   // catch-up runs; the capture lands mid-way
        XCTAssertNil(ledger.inject, "the injection ran")
        try w["C"].newNote(try openC(), "a later write")
        XCTAssertNoThrow(try w.open("A").readCapture(id), "capture recorded during catch-up stays set aside")
        // Control (adapted after the fix): the automatic path re-sealed it already, so an explicit catch-up
        // finds nothing left to do.
        XCTAssertFalse(try openC().catchUp().reencrypted.contains { $0.hasPrefix("inbox/") }, "control")
        XCTAssertNoThrow(try w.open("A").readCapture(id), "control")
    }
}
