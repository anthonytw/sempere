import Foundation
import Sempere
import Testing
@testable import SempereApp

/// The unlock sheet goes away as soon as the key is accepted, while the
/// notes are still being read.
@MainActor
struct UnlockLoadingTests {
    static func gatedModel() async throws -> (AppModel, Gate, key: String) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let gate = Gate()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), afterIO: { await gate.pass() })
        try await model.openVault(at: url)
        return (model, gate, try String(contentsOf: keyURL, encoding: .utf8))
    }

    @Test func deviceKeyUnlockReleasesTheSheetBeforeTheNotesAreRead() async throws {
        let (model, gate, key) = try await Self.gatedModel()
        let store = MemoryDeviceKeyStore()
        try await store.save(try DeviceKeys.parse(key), for: try #require(model.vault?.vaultId), vaultName: "sample")
        let keys = RememberedKeys(store: store)
        await gate.close()
        let start = await gate.arrivals
        let attempt = Task { await keys.unlockWithDeviceKey(model) }
        await gate.waitForArrivals(start + 1)   // the key check
        await gate.releaseOne()
        #expect(await attempt.value == .unlocked)
        // Unlocked, sheet released, the listing still waiting at the gate.
        #expect(model.phase == .unlocked)
        #expect(!keys.holdsUnlockSheet(model))
        await gate.waitForArrivals(start + 2)
        #expect(model.notes.isEmpty)
        guard case .loading = model.emptyListReason else {
            Issue.record("expected .loading, got \(String(describing: model.emptyListReason))")
            return
        }
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded && model.notes.count == 2 })
    }

    @Test func manualUnlockReleasesTheSheetBeforeTheNotesAreRead() async throws {
        let (model, gate, key) = try await Self.gatedModel()
        let keys = RememberedKeys(store: MemoryDeviceKeyStore())
        await gate.close()
        let start = await gate.arrivals
        let unlocking = Task { try await keys.unlock(model, identityText: key) }
        await gate.waitForArrivals(start + 1)
        await gate.releaseOne()
        try await unlocking.value
        #expect(model.phase == .unlocked)
        #expect(!keys.holdsUnlockSheet(model))
        #expect(!model.listLoaded)
        await gate.open()
        #expect(await TS.waitUntil { model.listLoaded && model.notes.count == 2 })
    }
}
