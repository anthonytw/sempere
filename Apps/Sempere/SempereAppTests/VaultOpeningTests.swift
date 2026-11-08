import Age
import Foundation
import Sempere
import Testing
@testable import SempereApp
import SempereAppCore

/// Holds the first piece of off-main work after `arm()` until `release()`;
/// all other work passes.
actor HeldRead {
    private var armed = false
    private var holding = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func arm() { armed = true; released = false }

    func passIfArmed() async {
        guard armed else { return }
        armed = false
        holding = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilHolding() async {
        while !holding { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// Opening a vault: the note list loads in the background with progress,
/// fills in batch by batch, comes from the summary cache on a reopen, and
/// says why whenever it is empty.
@MainActor
struct VaultOpeningTests {
    static let lecture = AppModelTests.lecture
    static let other = AppModelTests.deleted

    static func tempDir() -> URL {
        TestTemp.root.appendingPathComponent("sempere-opening-\(UUID().uuidString)")
    }

    static func key(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// A locked model on a private copy of the fixture vault.
    static func lockedModel(cache: URL? = nil, gate: Gate? = nil) async throws -> (AppModel, key: String, vault: URL) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        var afterIO: (@Sendable () async -> Void)?
        if let gate { afterIO = { await gate.pass() } }
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cache, afterIO: afterIO)
        try await model.openVault(at: url)
        return (model, try key(keyURL), url)
    }

    /// Unlocks with `gate` closed: lets the key check (one piece of off-main
    /// work) through and returns how many arrivals the gate had before it.
    static func unlockGated(_ model: AppModel, key: String, gate: Gate) async throws -> Int {
        await gate.close()
        let start = await gate.arrivals
        let unlocking = Task { try await model.unlock(identityText: key, awaitNotes: false) }
        await gate.waitForArrivals(start + 1)
        await gate.releaseOne()
        try await unlocking.value
        return start
    }

    // MARK: - Edits while the list is loading

    /// A model whose I/O hook holds exactly one piece of off-main work, the
    /// first one after `hold.arm()`; everything else goes through.
    static func modelHoldingOneRead(cache: URL? = nil) throws -> (AppModel, HeldRead, key: String, vault: URL) {
        let (url, keyURL) = try AppModelTests.fixtureVault()
        let held = HeldRead()
        let model = AppModel(deviceStateURL: TS.deviceStateURL(), summaryCacheDirectory: cache,
                             afterIO: { await held.passIfArmed() })
        return (model, held, try key(keyURL), url)
    }

    @Test func loadingHeadlines() {
        #expect(NoteLoading(done: 3, total: 640).headline == "Opening vault: 3 of 640 notes")
        #expect(NoteLoading(done: 1, total: 1, refreshing: true).headline == "Updating 1 changed note: 1 done")
        #expect(NoteLoading(done: 120, total: 640, refreshing: true).headline == "Updating 640 changed notes: 120 done")
        #expect(NoteLoading(done: 0, total: 0).fractionCompleted == 1)
        #expect(NoteLoading(done: 5, total: 10).fractionCompleted == 0.5)
    }

}
