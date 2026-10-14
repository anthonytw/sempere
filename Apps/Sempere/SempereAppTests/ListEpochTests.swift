import Foundation
import Sempere
import Testing
@testable import SempereApp

/// GA-54: the throttled note list (`listUpdateInterval`, `queueListUpdate`),
/// the lists derived from it once per change (`DerivedLists`) and the
/// per-note `summaryEpochs` that keep an older listing batch from overwriting
/// an edit's newer summary. Synthetic summaries only.
@MainActor
struct ListEpochTests {
    static let lecture = AppModelTests.lecture

    static func note(_ title: String, tags: [String] = [], id: UUID = UUID()) -> NoteSummary {
        NoteSummary(id: id, title: title, tags: tags, notebook: nil, deleted: false, pages: 1, strokes: 0,
                    modified: Date(timeIntervalSince1970: 1_000), problem: nil)
    }

    // MARK: - listUpdateInterval

    @Test func theDefaultIntervalIsAQuarterSecond() {
        #expect(AppModel(deviceStateURL: TS.deviceStateURL()).listUpdateInterval == .milliseconds(250))
    }

    @Test func updatesInsideTheIntervalWaitAndAreAppliedTogether() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        model.listUpdateInterval = .seconds(600)
        model.lastListApply = .now   // a list application just happened
        let a = Self.note("Throttled A"), b = Self.note("Throttled B")

        model.queueListUpdate(upserts: [a])
        #expect(!model.notes.contains { $0.id == a.id }, "inside the interval: not applied")
        #expect(model.listUpserts[a.id] != nil)
        let task = try #require(model.listFlushTask, "a flush is scheduled")
        model.queueListUpdate(upserts: [b])
        #expect(model.listFlushTask == task, "one flush task however many updates arrive")
        #expect(model.listUpserts.count == 2)

        model.flushListUpdates()
        #expect(model.notes.contains { $0.id == a.id } && model.notes.contains { $0.id == b.id })
        #expect(model.listUpserts.isEmpty && model.listRemovals.isEmpty)
        #expect(model.listFlushTask == nil)
        #expect(model.notes.map { $0.title.lowercased() } == model.notes.map { $0.title.lowercased() }.sorted(),
                "kept in title order")
    }

    @Test func aPastIntervalAppliesAtOnce() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        model.listUpdateInterval = .seconds(600)
        model.lastListApply = ContinuousClock.now.advanced(by: .seconds(-601))
        let a = Self.note("Immediate")
        model.queueListUpdate(upserts: [a])
        #expect(model.notes.contains { $0.id == a.id })
        #expect(model.listFlushTask == nil)

        model.listUpdateInterval = .zero
        let b = Self.note("Immediate too")
        model.queueListUpdate(upserts: [b])
        #expect(model.notes.contains { $0.id == b.id })
    }

    @Test func aDeferredFlushFiresOnceTheIntervalHasPassed() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        model.listUpdateInterval = .milliseconds(80)
        model.lastListApply = .now
        let a = Self.note("Later")
        model.queueListUpdate(upserts: [a])
        #expect(!model.notes.contains { $0.id == a.id })
        #expect(await TS.waitUntil { model.notes.contains { $0.id == a.id } })
        #expect(model.listFlushTask == nil)
        #expect(model.listUpserts.isEmpty)
    }

    @Test func aRemovalAndALaterUpsertOfOneNoteSupersedeEachOther() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        let a = Self.note("Flip")
        model.listUpdateInterval = .zero
        model.queueListUpdate(upserts: [a])
        #expect(model.notes.contains { $0.id == a.id })

        model.listUpdateInterval = .seconds(600)
        model.lastListApply = .now
        model.queueListUpdate(removals: [a.id])
        #expect(model.notes.contains { $0.id == a.id }, "still shown until the flush")
        #expect(model.listRemovals == [a.id])
        model.queueListUpdate(upserts: [a])
        #expect(model.listRemovals.isEmpty, "the later upsert wins")
        model.queueListUpdate(removals: [a.id])
        #expect(model.listUpserts[a.id] == nil, "the later removal wins")

        model.flushListUpdates()
        #expect(!model.notes.contains { $0.id == a.id })
    }

    @Test func anUnchangedSummaryDoesNotTouchTheListOrItsVersion() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        model.listUpdateInterval = .zero
        let same = try #require(model.notes.first)
        let version = model.listVersion
        model.queueListUpdate(upserts: [same])
        #expect(model.listVersion == version, "nothing differs: `notes` is not assigned")

        var changed = same
        changed.title = same.title + " edited"
        model.queueListUpdate(upserts: [changed])
        #expect(model.listVersion != version)
        #expect(model.notes.first { $0.id == same.id }?.title == changed.title)
    }

    @Test func closingTheVaultDiscardsQueuedUpdates() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        model.listUpdateInterval = .seconds(600)
        model.lastListApply = .now
        model.queueListUpdate(upserts: [Self.note("Never shown")], removals: [UUID()])
        #expect(model.listFlushTask != nil)
        model.close()
        #expect(model.listUpserts.isEmpty && model.listRemovals.isEmpty)
        #expect(model.listFlushTask == nil)
        #expect(model.lastListApply == nil)
    }

    // MARK: - DerivedLists

    @Test func visibleNotesAreComputedOncePerChangeOfListOrFilters() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        let first = model.visibleNotes
        let cached = try #require(model.derived.visible)
        #expect(cached.key.version == model.listVersion)
        #expect(cached.value == first)

        // Same version and filters: the cached value is returned, not recomputed.
        model.derived.visible = (cached.key, [])
        #expect(model.visibleNotes.isEmpty)

        // A different filter changes the key.
        model.sortOrder = model.sortOrder == .title ? .modified : .title
        #expect(Set(model.visibleNotes.map(\.id)) == Set(first.map(\.id)))
        #expect(model.derived.visible?.key.sort == model.sortOrder)

        // A change of the list changes the version.
        model.derived.visible = (try #require(model.derived.visible).key, [])
        let added = Self.note("Derived addition")
        model.merge([added])
        #expect(model.visibleNotes.contains { $0.id == added.id })
        #expect(model.derived.visible?.key.version == model.listVersion)
    }

    @Test func tagsAndTheNotebookTreeFollowTheListVersion() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        _ = model.tags
        _ = model.notebookTree
        #expect(model.derived.tags?.version == model.listVersion)
        #expect(model.derived.tree?.version == model.listVersion)

        model.derived.tags = (model.listVersion, ["sentinel"])
        model.derived.tree = (model.listVersion, [])
        #expect(model.tags == ["sentinel"], "cached while the list is unchanged")
        #expect(model.notebookTree.isEmpty)

        var tagged = Self.note("Tagged", tags: ["zeta-derived"])
        tagged.notebook = "Derived/Nested"
        model.merge([tagged])
        #expect(model.tags.contains("zeta-derived") && !model.tags.contains("sentinel"))
        #expect(model.notebooks.contains("Derived/Nested"))
        #expect(model.derived.tags?.version == model.listVersion)
        #expect(model.derived.tree?.version == model.listVersion)
    }

    // MARK: - summaryEpochs

    @Test func anEditsRereadBumpsTheNotesEpoch() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        defer { model.close() }
        #expect(model.summaryEpochs[Self.lecture] == nil)
        try await model.refresh([Self.lecture])
        #expect(model.summaryEpochs[Self.lecture] == 1)
        try await model.refresh([Self.lecture])
        #expect(model.summaryEpochs[Self.lecture] == 2)
        #expect(model.summaryEpochs[AppModelTests.deleted] == nil, "other notes keep theirs")
        model.close()
        #expect(model.summaryEpochs.isEmpty, "forgotten with the vault")
    }

    /// A listing batch read before an edit's own re-read must not put its
    /// older summary over the newer one.
    @Test func aBatchReadBeforeAnEditsRereadIsDropped() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        defer { model.close() }
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.listUpdateInterval = .zero
        let oldTitle = try #require(model.notes.first { $0.id == Self.lecture }).title
        try TS.writeAsAnotherDevice([.setMeta(.title("Renamed by a listing"))], to: Self.lecture, vault: url, key: key)

        // An edit re-reads the note while the batch is being read (the hook runs between the two).
        model.onSummaryRead = { _ in
            MainActor.assumeIsolated { model.summaryEpochs[Self.lecture, default: 0] += 1 }
        }
        try await model.readSummaries([Self.lecture])
        model.flushListUpdates()
        #expect(model.notes.first { $0.id == Self.lecture }?.title == oldTitle, "the stale batch was dropped")

        // Without a re-read in between, the same batch is applied.
        model.onSummaryRead = nil
        try await model.readSummaries([Self.lecture])
        model.flushListUpdates()
        #expect(model.notes.first { $0.id == Self.lecture }?.title == "Renamed by a listing")
    }
}
