import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// One receive reads the stored capture profile once (`WatchDelivery.snapshot`): a profile that changes while a watch
/// file is between its admission and its delivery (another quick-capture vault picked, a new epoch's profile saved)
/// never puts the note into the other vault's inbox or ledger, and never admits it under the wrong epoch.
struct WatchProfileSnapshotTests {
    /// Returns `first` for the first `switchAfter` loads, then `second`.
    final class SwitchingStore: CaptureProfileStore, @unchecked Sendable {
        let lock = NSLock()
        var loads = 0
        let first: StoredCaptureProfile
        let second: StoredCaptureProfile
        let switchAfter: Int
        init(_ a: StoredCaptureProfile, _ b: StoredCaptureProfile, after n: Int) { first = a; second = b; switchAfter = n }
        func load() throws -> StoredCaptureProfile? {
            lock.withLock { loads += 1; return loads <= switchAfter ? first : second }
        }
        func save(_ profile: StoredCaptureProfile) throws {}
        func delete() throws {}
    }

    @Test func aVaultSwitchMidReceiveNeverReachesTheOtherVault() throws {
        let rig = try WatchReceiverTests.rig()
        let other = try WatchReceiverTests.otherVault(rig, inStore: true)
        let otherURL = try #require(other.url)
        let a = rig.current.stored
        let b = StoredCaptureProfile(profile: other.profile, vaultName: "other", transcribe: false)
        for n in 0...12 {
            let store = SwitchingStore(a, b, after: n)
            let receiver = WatchReceiver(delivery: rig.delivery, store: store, received: WatchReceivedSet(url: nil),
                                         quarantine: rig.dir.appendingPathComponent("q\(n)"),
                                         held: WatchHeldStore(root: rig.dir.appendingPathComponent("held\(n)")),
                                         enabled: { true })
            let t = try WatchReceiverTests.transfer(a.profile, in: rig)   // a note of vault A
            let receipt = try? receiver.receive(file: t.file, metadata: t.metadata)
            #expect(!WatchReceiverTests.inbox(otherURL).contains(t.sealed.name), "n=\(n): placed in the other vault's inbox")
            if let receipt, case .placed(.vault) = receipt.result.outcome {
                #expect(WatchReceiverTests.inbox(rig.current.url).contains(t.sealed.name), "n=\(n): placed, in its own vault")
            }
        }
        let entries = try rig.ledgers.ledger(b.profile.vaultId).entries()
        #expect(entries.isEmpty, "nothing recorded in the other vault's ledger")
    }

    @Test func anEpochChangeMidReceiveIsNotAdmittedUnderTheOldOne() throws {
        let rig = try WatchReceiverTests.rig()
        let a = rig.current.stored
        var newer = a
        newer.profile.epoch = a.profile.epoch + 1
        newer.profile.epochId = String(repeating: "ab", count: 32)
        for n in 0...12 {
            let store = SwitchingStore(a, newer, after: n)
            let receiver = WatchReceiver(delivery: rig.delivery, store: store, received: WatchReceivedSet(url: nil),
                                         quarantine: rig.dir.appendingPathComponent("eq\(n)"),
                                         held: WatchHeldStore(root: rig.dir.appendingPathComponent("eheld\(n)")),
                                         enabled: { true })
            let t = try WatchReceiverTests.transfer(a.profile, in: rig)
            let receipt = try? receiver.receive(file: t.file, metadata: t.metadata)
            if let receipt, case .placed = receipt.result.outcome {
                // Placed only when every load of this receive saw the old profile: it never moved under it.
                #expect(store.loads <= n, "n=\(n): admitted after the epoch moved (\(store.loads) loads)")
            }
        }
    }
}
