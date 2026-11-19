import Foundation
import Sempere
@testable import SempereAppCore
import TempDirSupport
import Testing

/// An index that records what it was asked, and can fail removals.
final class FakeSpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: SpotlightItem] = [:]
    private var log: [String] = []
    private var failDomains = false

    var items: [String: SpotlightItem] { lock.withLock { held } }
    var calls: [String] { lock.withLock { log } }
    var failDomainDeletes: Bool {
        get { lock.withLock { failDomains } }
        set { lock.withLock { failDomains = newValue } }
    }
    func clearCalls() { lock.withLock { log = [] } }

    /// While closed, `index` waits inside the call (after noting that it started) until `openGate()`.
    private var gateClosed = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = 0
    func closeGate() { lock.withLock { gateClosed = true } }
    func openGate() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            gateClosed = false
            defer { gateWaiters = [] }
            return gateWaiters
        }
        for w in waiting { w.resume() }
    }
    var indexCallsStarted: Int { lock.withLock { started } }

    func index(_ items: [SpotlightItem]) async throws {
        lock.withLock { started += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                if gateClosed { gateWaiters.append(c); return true }
                return false
            }
            if !wait { c.resume() }
        }
        lock.withLock {
            log.append("index \(items.count)")
            for i in items { held[i.id] = i }
        }
    }
    func delete(ids: [String]) async throws {
        lock.withLock {
            log.append("delete \(ids.count)")
            for id in ids { held[id] = nil }
        }
    }
    func deleteDomain(vault: UUID) async throws {
        try lock.withLock {
            if failDomains { throw CancellationError() }
            log.append("deleteDomain")
            held = held.filter { $0.value.vaultId != vault }
        }
    }
    func deleteAll() async throws {
        lock.withLock {
            log.append("deleteAll")
            held = [:]
        }
    }
}

extension AppModelSuites {
    /// Opt-in Spotlight (docs/design/1.3-spotlight.md §3): the switches, the removal table and links, with a fake index.
    @MainActor
    struct SpotlightTests {
        struct Rig {
            var world: DeviceWorld
            var model: AppModel
            var index: FakeSpotlightIndex
            var settings: MemoryKeyValueStore
        }

        static func rig(others: [String] = [], noteTitles: [String] = ["Alpha", "Beta"]) async throws -> Rig {
            let world = try await DeviceWorld.make(others: others)
            let index = FakeSpotlightIndex()
            let settings = MemoryKeyValueStore()
            var services = AppModelServices.headless(settings: settings)
            services.spotlightIndex = index
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: world.homeTrust, services: services)
            model.spotlightRuntime.debounce = .zero
            try await model.openVault(at: world.url)
            try await model.unlock(device: world.home)
            for t in noteTitles { _ = try await model.createNote(title: t, paper: Paper(kind: .ruled), notebook: "Work") }
            return Rig(world: world, model: model, index: index, settings: settings)
        }

        @Test func offByDefaultAndNothingDonated() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            #expect(r.model.spotlightMode == .off)
            #expect(r.model.spotlightEligibility == .eligible)
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }   // let any stray task run
            #expect(r.index.items.isEmpty)
            #expect(r.index.calls.isEmpty)
        }

        @Test func turningItOnDonatesMetadataOnly() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            await r.model.setSpotlight(.metadata)
            let titles = Set(r.index.items.values.map(\.title))
            #expect(titles == ["Alpha", "Beta"])
            #expect(r.index.items.values.allSatisfy { $0.textContent == nil && $0.contentDescription.hasPrefix("Work") })
            #expect(r.index.items.values.allSatisfy { $0.vaultId == r.model.vault?.vaultId })
            // Recorded for this device only, in the device's own store.
            let id = try #require(r.model.vault?.vaultId)
            #expect(r.settings.string(forKey: "Sempere.spotlight.\(id.uuidString.lowercased())") == "metadata")
        }

        @Test func cancellingTheSheetIndexesNothing() async throws {
            // The sheet is the app's: Cancel never calls `setSpotlight`.
            let r = try await Self.rig()
            defer { r.model.close() }
            #expect(r.index.items.isEmpty && r.model.spotlightMode == .off)
        }

        @Test func includeNoteTextIsItsOwnSwitch() async throws {
            let r = try await Self.rig(noteTitles: ["Typed"])
            defer { r.model.close() }
            let id = try #require(r.model.notes.first?.id)
            // Text is whatever search sees: put some into the summary list.
            var s = try #require(r.model.notes.first)
            s.pageTexts = [PageText(pageId: UUID(), number: 1, text: "hello secret words")]
            r.model.merge([s])
            await r.model.setSpotlight(.metadata)
            #expect(r.index.items.values.first?.textContent == nil)
            await r.model.setSpotlight(.text)
            #expect(r.index.items.values.first?.textContent == "hello secret words")
            // Text off replaces the items without it; nothing is deleted.
            await r.model.setSpotlight(.metadata)
            #expect(r.index.items.values.first?.textContent == nil)
            #expect(r.index.items.count == 1 && r.index.items.keys.first?.hasSuffix(id.uuidString.lowercased()) == true)
        }

        @Test func turningItOffDeletesTheDomainAndTheIndexWhenItWasTheLast() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            await r.model.setSpotlight(.metadata)
            r.index.clearCalls()
            await r.model.setSpotlight(.off)
            #expect(r.index.items.isEmpty)
            #expect(r.index.calls == ["deleteDomain", "deleteAll"])
            #expect(r.model.spotlight.vaultsOn.isEmpty)
        }

        @Test func turningItOffWaitsForAPassInFlightSoNothingOutlivesIt() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            r.index.closeGate()
            let on = Task { await r.model.setSpotlight(.metadata) }
            #expect(await TS.waitUntil(timeout: .seconds(5)) { r.index.indexCallsStarted > 0 })
            // The pass is inside its upsert batch; the switch goes off now.
            let off = Task { await r.model.setSpotlight(.off) }
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }
            r.index.openGate()
            await on.value
            await off.value
            #expect(r.index.items.isEmpty)
            #expect(r.index.calls.last == "deleteAll")
            #expect(r.model.spotlightMode == .off)
        }

        @Test func offThenOnAgainWhileAPassRunsKeepsTheIndexFull() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            r.index.closeGate()
            let on = Task { await r.model.setSpotlight(.metadata) }
            #expect(await TS.waitUntil(timeout: .seconds(5)) { r.index.indexCallsStarted > 0 })
            let off = Task { await r.model.setSpotlight(.off) }
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }
            // Back on before the pass finishes: the waiting "off" must not empty the index afterward.
            let again = Task { await r.model.setSpotlight(.metadata) }
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }
            r.index.openGate()
            await on.value
            await off.value
            await again.value
            #expect(r.model.spotlightMode == .metadata)
            #expect(await TS.waitUntil(timeout: .seconds(5)) { r.index.items.count == 2 })
            _ = await TS.waitUntil(timeout: .milliseconds(300)) { false }
            #expect(r.index.items.count == 2, "nothing removed the items after the switch went back on")
        }

        @Test func aDeletedNoteLeavesAndARestoredOneComesBack() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            await r.model.setSpotlight(.metadata)
            let beta = try #require(r.model.notes.first { $0.title == "Beta" }?.id)
            try await r.model.deleteNote(beta)
            #expect(await TS.waitUntil { r.index.items.count == 1 })
            #expect(r.index.items.values.first?.title == "Alpha")
            try await r.model.restoreNote(beta)
            #expect(await TS.waitUntil { r.index.items.count == 2 })
        }

        @Test func closingTheVaultDeletesNothing() async throws {
            let r = try await Self.rig()
            await r.model.setSpotlight(.metadata)
            r.index.clearCalls()
            r.model.close()
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }
            #expect(r.index.items.count == 2)
            #expect(r.index.calls.isEmpty)
            #expect(r.model.spotlightMode == .off, "the open vault's mode is cleared, the record stays")
            #expect(r.model.spotlight.vaultsOn.count == 1)
        }

        @Test func reopeningRefreshesAndRemovesWhatWentWhileClosed() async throws {
            let r = try await Self.rig()
            await r.model.setSpotlight(.metadata)
            // An item of a note that no longer exists lingers in the index (deleted elsewhere while closed).
            let id = try #require(r.model.vault?.vaultId)
            try await r.index.index([SpotlightItem(vaultId: id, noteId: UUID(), title: "Ghost", contentDescription: "", keywords: [], modified: nil, textContent: nil)])
            r.model.close()
            try await r.model.openVault(at: r.world.url)
            try await r.model.unlock(device: r.world.home)
            #expect(await TS.waitUntil { r.index.items.count == 2 && !r.index.items.values.contains { $0.title == "Ghost" } })
            r.model.close()
        }

        @Test func aKeyChangeDeletesThenReindexesWhileListed() async throws {
            let r = try await Self.rig(others: ["Phone"])
            defer { r.model.close() }
            await r.model.setSpotlight(.metadata)
            r.index.clearCalls()
            let phone = try #require(r.world.others["Phone"]?.keys.id)
            _ = try await r.model.removeDevices([phone])
            #expect(await TS.waitUntil { r.index.calls.contains("deleteDomain") && r.index.items.count == 2 })
            let firstDelete = try #require(r.index.calls.firstIndex(of: "deleteDomain"))
            let firstIndex = try #require(r.index.calls.firstIndex { $0.hasPrefix("index") })
            #expect(firstDelete < firstIndex, "removed first, donated again after")
            #expect(r.model.spotlightMode == .metadata)
        }

        @Test func anApprovalIsNotAKeyChange() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            await r.model.setSpotlight(.metadata)
            r.index.clearCalls()
            r.model.adoptReopened(try #require(r.model.vault))   // the same keys, as a rename or approval reopen
            _ = await TS.waitUntil(timeout: .milliseconds(200)) { false }
            #expect(!r.index.calls.contains("deleteDomain"))
        }

        @Test func aRemovedDeviceForcesItOffWithANotice() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            await r.model.setSpotlight(.text)
            r.model.forceSpotlightOff(.deviceRemoved)
            #expect(await TS.waitUntil { r.index.items.isEmpty })
            #expect(r.model.spotlightMode == .off)
            #expect(r.model.spotlightNotice == .deviceRemoved)
            #expect(r.model.spotlight.mode(for: try #require(r.model.vault?.vaultId)) == .off)
        }

        @Test func aVaultOpenedWithTheRecoveryKeyIsNotEligible() async throws {
            let world = try await DeviceWorld.make(others: [])
            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: world.homeTrust)
            defer { model.close() }
            try await model.openVault(at: world.url)
            try await model.unlock(with: [world.recovery])
            #expect(model.spotlightEligibility == .noDeviceKeys)
            await model.setSpotlight(.metadata)
            #expect(model.spotlightMode == .off)
        }

        @Test func twoVaultsStayInSeparateDomains() async throws {
            let index = FakeSpotlightIndex()
            let settings = MemoryKeyValueStore()
            let manager = SpotlightManager(index: index, defaults: settings)
            let a = UUID(), b = UUID()
            manager.record(.metadata, for: a)
            manager.record(.text, for: b)
            try await index.index([SpotlightItem(vaultId: a, noteId: UUID(), title: "A", contentDescription: "", keywords: [], modified: nil, textContent: nil),
                                   SpotlightItem(vaultId: b, noteId: UUID(), title: "B", contentDescription: "", keywords: [], modified: nil, textContent: nil)])
            #expect(Set(manager.vaultsOn) == [a, b])
            await manager.vaultRemoved(a)
            #expect(index.items.values.map(\.title) == ["B"], "the other vault is untouched")
            #expect(!index.calls.contains("deleteAll"))
            #expect(manager.mode(for: b) == .text && manager.mode(for: a) == .off)
            await manager.vaultRemoved(b)
            #expect(index.items.isEmpty && index.calls.last == "deleteAll")
        }

        @Test func aFailedDeleteIsRetriedFromThePendingList() async throws {
            let index = FakeSpotlightIndex()
            let settings = MemoryKeyValueStore()
            let manager = SpotlightManager(index: index, defaults: settings)
            let v = UUID()
            manager.record(.metadata, for: v)
            try await index.index([SpotlightItem(vaultId: v, noteId: UUID(), title: "N", contentDescription: "", keywords: [], modified: nil, textContent: nil)])
            index.failDomainDeletes = true
            #expect(await manager.removeDomain(v) == false)
            #expect(manager.pendingDeletions == [v])
            #expect(index.items.count == 1)
            // A new manager (the next launch) retries from the stored list; it holds ids only.
            let next = SpotlightManager(index: index, defaults: settings)
            index.failDomainDeletes = false
            await next.retryPending()
            #expect(next.pendingDeletions.isEmpty && index.items.isEmpty)
        }

        // MARK: - Links

        @Test func aLinkOpensTheNoteAndAnUnknownOneIsReported() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            let vault = try #require(r.model.vault?.vaultId)
            let alpha = try #require(r.model.notes.first { $0.title == "Alpha" }?.id)
            #expect(r.model.open(NoteLink(vaultId: vault, noteId: alpha)) == .opened)
            #expect(r.model.selectedNoteID == alpha)

            let missing = NoteLink(vaultId: vault, noteId: UUID())
            try await r.index.index([SpotlightItem(vaultId: vault, noteId: missing.noteId, title: "Stale", contentDescription: "", keywords: [], modified: nil, textContent: nil)])
            #expect(r.model.open(missing) == .gone)
            #expect(r.model.noteLinkProblem == .notOnThisDevice)
            #expect(await TS.waitUntil { r.index.items.isEmpty }, "the stale item is deleted")
        }

        @Test func aLinkToAnotherVaultWaitsForIt() async throws {
            let r = try await Self.rig()
            defer { r.model.close() }
            let link = NoteLink(vaultId: UUID(), noteId: UUID())
            #expect(r.model.open(link) == .needsVault)
            #expect(r.model.pendingNoteLink == link)
        }

        @Test func aLinkHeldWhileTheVaultWasLockedFollowsTheUnlock() async throws {
            let world = try await DeviceWorld.make(others: [])
            let seed = AppModel(deviceStateURL: TS.deviceStateURL(), trust: world.homeTrust)
            try await seed.openVault(at: world.url)
            try await seed.unlock(device: world.home)
            let note = try await seed.createNote(title: "Held", paper: Paper(kind: .ruled), notebook: nil)
            let vault = try #require(seed.vault?.vaultId)
            seed.close()

            let model = AppModel(deviceStateURL: TS.deviceStateURL(), trust: world.homeTrust)
            defer { model.close() }
            try await model.openVault(at: world.url)   // locked
            #expect(model.open(NoteLink(vaultId: vault, noteId: note)) == .needsVault)
            try await model.unlock(device: world.home)
            #expect(model.pendingNoteLink == nil)
            #expect(model.selectedNoteID == note)
        }

        @Test func identifiersRoundTripThroughTheLink() {
            let link = NoteLink(vaultId: UUID(), noteId: UUID())
            #expect(NoteLink(spotlightIdentifier: link.spotlightIdentifier) == link)
            #expect(NoteLink(spotlightIdentifier: "x/y") == nil)
        }
    }
}
