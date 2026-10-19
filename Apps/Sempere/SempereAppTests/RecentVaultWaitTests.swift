import Foundation
import Sempere
import Testing
@testable import SempereApp

/// iCloud Drive that is not ready yet: after a restart, a recent vault's bookmark does not resolve (or
/// its folder is not listed) for a while. The simulator has no iCloud, so the library's probe is faked
/// (`FakeVaultCloud`); the real probe runs once the fake "delivers" the vault.
final class FakeVaultCloud: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var probes = 0

    /// iCloud makes the vault available (or takes it away again).
    func setReady(_ value: Bool) { lock.withLock { ready = value } }

    /// How many times the library looked.
    var probeCount: Int { lock.withLock { probes } }

    /// The library's probe: the real one once ready, an unresolved bookmark before.
    var probe: @Sendable (Data) -> RecentVaultProbe {
        { [self] bookmark in
            let ready = lock.withLock { () -> Bool in
                probes += 1
                return self.ready
            }
            return ready ? RecentVaultCheck.probe(bookmark) : .unresolved
        }
    }
}

@MainActor
struct RecentVaultWaitTests {
    static let iCloudPath = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notes.sempere"

    /// A library holding one recent entry for a real copy of the fixture vault, recorded as living in
    /// iCloud Drive, with iCloud not ready.
    static func waitingLibrary() throws -> (library: VaultLibrary, cloud: FakeVaultCloud, entry: RecentVault, store: URL) {
        let (vault, _) = try AppModelTests.fixtureVault()
        let store = try BrowserTests.tempDir().appendingPathComponent("recents.json")
        let cloud = FakeVaultCloud()
        let library = VaultLibrary(storeURL: store, probe: cloud.probe)
        try library.remember(vault)
        library.recents[0].path = iCloudPath
        library.save()
        // A fresh launch: nothing checked yet.
        let relaunched = VaultLibrary(storeURL: store, probe: cloud.probe)
        relaunched.retryDelay = { _, _ in .milliseconds(20) }
        return (relaunched, cloud, relaunched.recents[0], store)
    }

    /// Waits (up to 5 s) for `condition`.
    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - The rules

    @Test func statesFollowWhatTheProbeFoundAndHowLongItWaited() {
        let here = URL(fileURLWithPath: Self.iCloudPath)
        let found = RecentVaultProbe(url: here, refreshed: nil, vaultPresent: true, parentPresent: true)
        let folderGone = RecentVaultProbe(url: here, refreshed: nil, vaultPresent: false, parentPresent: true)
        let patience = RecentVaultCheck.patience
        #expect(RecentVaultCheck.state(of: found, cloud: true, waited: 0) == .available)
        #expect(RecentVaultCheck.state(of: found, cloud: false, waited: 10_000) == .available)
        // In iCloud: waiting, then gone.
        #expect(RecentVaultCheck.state(of: .unresolved, cloud: true, waited: 0) == .waiting)
        #expect(RecentVaultCheck.state(of: .unresolved, cloud: true, waited: patience - 1) == .waiting)
        #expect(RecentVaultCheck.state(of: .unresolved, cloud: true, waited: patience) == .unreachable)
        #expect(RecentVaultCheck.state(of: folderGone, cloud: true, waited: patience - 1) == .waiting)
        #expect(RecentVaultCheck.state(of: folderGone, cloud: true, waited: patience) == .missing)
        // On this device: nothing to wait for.
        #expect(RecentVaultCheck.state(of: .unresolved, cloud: false, waited: 0) == .unreachable)
        #expect(RecentVaultCheck.state(of: folderGone, cloud: false, waited: 0) == .missing)
    }

    @Test func checksBackOffToThirtySecondsAndAMinuteForGoneVaults() {
        let delays = (0..<8).map { RecentVaultCheck.delay(attempt: $0, waiting: true) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(RecentVaultCheck.delay(attempt: 0, waiting: false) == .seconds(60))
        #expect(RecentVaultCheck.delay(attempt: 1000, waiting: true) == .seconds(30))
    }

    @Test func entriesWithoutAKnownPathMayBeInICloud() throws {
        let legacy = RecentVault(id: UUID(), name: "Old", bookmark: Data([1]), lastOpened: Date())
        #expect(RecentVaultCheck.mayBeCloud(legacy))
        #expect(RecentVaultCheck.mayBeICloud(legacy))
        var cloud = legacy
        cloud.path = Self.iCloudPath
        #expect(RecentVaultCheck.mayBeCloud(cloud) && RecentVaultCheck.mayBeICloud(cloud))
        var local = legacy
        local.path = NSHomeDirectory() + "/Documents/Notes.sempere"
        #expect(!RecentVaultCheck.mayBeCloud(local))
        // recents.json written before paths were kept still decodes.
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","bookmark":"AQ==","lastOpened":0}]"#
        let decoded = try JSONDecoder().decode([RecentVault].self, from: Data(json.utf8))
        #expect(decoded.first?.path == nil)
    }

    // MARK: - The list

    /// The owner's report: after a restart the vault was not listed at all. It is listed at once, as
    /// waiting, and becomes available when iCloud delivers it; it is never dropped.
    @Test func anICloudVaultUnavailableAtLaunchIsListedAsWaitingThenAvailable() async throws {
        let (library, cloud, entry, store) = try Self.waitingLibrary()
        #expect(library.recents.map(\.id) == [entry.id])
        #expect(library.state(of: entry) == .unknown)

        await library.checkRecents()
        #expect(library.state(of: entry) == .waiting)
        #expect(library.recents.map(\.id) == [entry.id])
        #expect(VaultLibrary(storeURL: store).recents.map(\.id) == [entry.id])

        cloud.setReady(true)
        // The scheduled re-check (backoff) finds it without anything else happening.
        #expect(await Self.eventually { library.state(of: entry) == .available })
        #expect(library.recents.map(\.id) == [entry.id])
    }

    @Test func keepsCheckingWhileWaiting() async throws {
        let (library, cloud, entry, _) = try Self.waitingLibrary()
        await library.checkRecents()
        let first = cloud.probeCount
        #expect(await Self.eventually { cloud.probeCount >= first + 3 })
        #expect(library.state(of: entry) == .waiting)
        library.forget(entry)
        #expect(library.state(of: entry) == .unknown)
    }

    @Test func aVaultWaitedForTooLongIsReportedUnreachableButKept() async throws {
        let (library, cloud, entry, _) = try Self.waitingLibrary()
        var now = Date()
        library.clock = { now }
        await library.checkRecents()
        #expect(library.state(of: entry) == .waiting)
        now += RecentVaultCheck.patience + 1
        await library.checkRecents()
        #expect(library.state(of: entry) == .unreachable)
        #expect(library.recents.map(\.id) == [entry.id])
        // iCloud signed back in: it comes back.
        cloud.setReady(true)
        library.refreshRecents()
        #expect(await Self.eventually { library.state(of: entry) == .available })
    }

    @Test func aDeletedVaultOnThisDeviceIsReportedMissingAtOnce() async throws {
        let dir = try BrowserTests.tempDir()
        let vault = dir.appendingPathComponent("Local.sempere")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: vault.appendingPathComponent("vault.json"))
        let library = VaultLibrary(storeURL: dir.appendingPathComponent("recents.json"))
        library.retryDelay = { _, _ in .seconds(600) }
        let entry = try library.remember(vault)
        await library.checkRecents()
        #expect(library.state(of: entry) == .available)
        try FileManager.default.removeItem(at: vault)
        await library.checkRecents()
        // Not in a cloud provider, so nothing to wait for. (A bookmark of a deleted folder may or may
        // not still resolve, depending on the file system: either way it is gone.)
        #expect(library.state(of: entry).isGone)
        #expect(library.recents.map(\.id) == [entry.id])
    }

    // MARK: - Opening

    /// The launch reopen (and a tap on the row) finds the vault waiting: no error, and it opens by
    /// itself once iCloud delivers it.
    @Test func reopenWaitsForICloudAndOpensWhenItArrives() async throws {
        let (library, cloud, entry, _) = try Self.waitingLibrary()
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))

        let pick = await LibraryCommands.reopen(entry, pickOnFailure: false, model: model, library: library)
        #expect(pick == nil)
        #expect(model.errorMessage == nil)
        #expect(model.phase == .noVault)
        #expect(library.pendingOpen == entry.id)
        #expect(library.state(of: entry) == .waiting)
        #expect(library.takeReadyPendingOpen() == nil)

        cloud.setReady(true)
        #expect(await Self.eventually { library.state(of: entry) == .available })
        let ready = try #require(library.takeReadyPendingOpen())
        #expect(ready.id == entry.id)
        #expect(library.takeReadyPendingOpen() == nil)   // used up
        #expect(await LibraryCommands.reopen(ready, pickOnFailure: false, model: model, library: library) == nil)
        #expect(model.errorMessage == nil)
        #expect(model.phase == .locked)
        #expect(model.vaultURL?.lastPathComponent == "sample.sempere")
    }

    @Test func openingAnotherVaultStopsWaiting() async throws {
        let (library, _, entry, _) = try Self.waitingLibrary()
        library.retryDelay = { _, _ in .seconds(600) }
        await library.checkRecents()
        library.openWhenAvailable(entry)
        #expect(library.pendingOpen == entry.id)
        library.cancelPendingOpen()
        #expect(library.pendingOpen == nil)
        library.openWhenAvailable(entry)
        library.forget(entry)
        #expect(library.pendingOpen == nil)
    }
}
