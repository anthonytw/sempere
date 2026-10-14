import Foundation
import Sempere
import Testing
@testable import SempereApp

/// Performance round 3: a vault where every note changed at once (a mass
/// re-import seen from another device) is brought up to date without
/// quadratic work.
@MainActor
@Suite(.serialized)
struct MassChangeTests {
    /// The fixture vault plus `extra` one-revision notes.
    static func vault(extra: Int) throws -> (url: URL, key: URL, ids: [UUID]) {
        let (url, key) = try AppModelTests.fixtureVault()
        let identity = try IdentityFile.parse(try String(contentsOf: key, encoding: .utf8))
        let vault = try Vault.open(at: url, identities: [identity])
        for i in 0..<extra {
            _ = try vault.apply([.setMeta(.title("Note \(i)")), .addPage(Page(order: "a0"))], to: UUID(),
                                deviceState: TS.deviceStateURL(), app: "t")
        }
        return (url, key, try vault.noteIDs())
    }

    /// Every note gets a new revision from another device and iCloud has not
    /// delivered any yet; then two notes arrive between passes. Each pass asks
    /// iCloud for the state of the newly reported notes and at most
    /// `cloudCheckLimit` of the others (in rotation), never of every arriving
    /// note, and every note is still read once it arrives.
    @Test func arrivingNotesAreCheckedInRotationNotAllEveryPass() async throws {
        let (url, key, ids) = try Self.vault(extra: 40)
        let cloud = FakeCloud(vault: url)
        let calls = Counter()
        var hooks = cloud.hooks
        let state = hooks.state
        hooks.state = { calls.add(1); return state($0) }
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = hooks
        model.cloudPollInterval = .seconds(3600)   // the loop runs its first pass, then waits: passes are the test's
        model.cloudIdleInterval = .seconds(3600)
        model.cloudCheckLimit = 5
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.notes.count == ids.count)
        // The simulator's file presenter would report the evictions and deliveries below on its own
        // schedule; the passes here count only the arrivals the test reports.
        model.stopWatchingNotes()
        for id in ids { try TS.writeAsAnotherDevice([.setMeta(.title("Changed \(id)"))], to: id, vault: url, key: key) }
        for id in ids { try cloud.evict(id) }

        // The first pass looks at every changed note once (it must learn which are local).
        try await model.reconcile()
        #expect(model.pendingNoteIDs == Set(ids))
        let files = try ids.reduce(0) { $0 + (try CloudScan.noteItems(inVault: url, id: $1).count) }
        let maxFiles = try ids.map { try CloudScan.noteItems(inVault: url, id: $0).count }.max() ?? 1

        var delivered: [UUID] = []
        var passes = 0
        while !model.pendingNoteIDs.isEmpty {
            passes += 1
            #expect(passes <= ids.count, "every arriving note is reached")
            if passes > ids.count { break }
            let next = Array(ids.dropFirst(delivered.count).prefix(2))
            for id in next { try cloud.deliver(id) }
            delivered += next
            model.dirtyNoteIDs = []
            model.dirtyAll = false
            model.reportedNoteIDs = []
            model.noteFoldersChanged(Set(next))   // what the file presenter reports
            _ = model.nextSyncScope(lastFullPass: .now)
            let before = calls.value
            try await model.reconcile(scope: model.pendingNoteIDs.union(next))
            let asked = calls.value - before
            #expect(asked <= (model.cloudCheckLimit + next.count) * maxFiles, "pass \(passes) asked about \(asked) files")
        }
        #expect(model.placeholderNoteIDs.isEmpty)
        for id in ids { #expect(model.notes.first { $0.id == id }?.title == "Changed \(id)") }
        // In all: about one look per file per pass at most `limit` notes, far below N per pass.
        #expect(calls.value < files * 3 + passes * (model.cloudCheckLimit + 2) * maxFiles)
        model.close()
    }

    @Test func rotationReachesEveryArrivingNote() {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        let ids = Set((0..<23).map { _ in UUID() })
        var seen = Set<UUID>()
        for _ in 0..<5 {
            let slice = model.nextPendingChecks(ids, limit: 5)
            #expect(slice.count == 5)
            seen.formUnion(slice)
        }
        #expect(seen == ids)
        #expect(model.nextPendingChecks(Set(ids.prefix(3)), limit: 5).count == 3)
    }

    /// Many changed notes are read in bigger batches (fewer list updates and
    /// thread barriers), and the status says how many changed.
    @Test func manyChangedNotesAreReadInBiggerBatches() async throws {
        let (url, key, ids) = try Self.vault(extra: 60)
        let reads = Counter()
        let batches = Counter()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        for id in ids { try TS.writeAsAnotherDevice([.setMeta(.title("Changed"))], to: id, vault: url, key: key) }
        model.onSummaryRead = { reads.add($0); batches.add(1) }
        try await model.reconcile()
        #expect(reads.value == ids.count)
        #expect(batches.value <= 8 + 1)
        #expect(model.notes.allSatisfy { $0.title == "Changed" })
        model.close()
    }
}
