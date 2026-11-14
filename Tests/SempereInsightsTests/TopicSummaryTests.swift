import Foundation
import Sempere
import TempDirSupport
import XCTest
@testable import SempereInsights

/// Topic summaries as Insights PR 3 shows and makes them (docs/design/1.2-note-insights.md §4 step 9, §6 item 4, D8):
/// what every device shows (the latest stored paragraph, stale when the members changed, the "Check sources" members),
/// "Regenerate", and the background's rules: at most once a day per scope, failures backed off in the failure memo,
/// stopping between scopes when cancelled, and a write that keeps the scopes another writer made meanwhile.
extension InsightsUpdaterTests {
    /// A model whose topic summaries fail as scripted (notes are generated as by the fake).
    final class TopicModel: ModelProvider, @unchecked Sendable {
        let inner = FakeModelProvider()
        enum Mode { case ok, throwing, empty }
        var mode: Mode
        var summarizeCalls = 0
        /// Called before each topic summary (a test cancels its task here).
        var onSummarize: (() -> Void)?
        init(_ mode: Mode) { self.mode = mode }
        var identity: GenerationIdentity { inner.identity }
        var availability: ModelAvailability { .available }
        var contextTokens: Int { 8192 }
        func supports(language: String?) -> Bool { true }
        func extract(_ text: String, language: String?) async throws -> ModelExtraction { try await inner.extract(text, language: language) }
        func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
        func summarize(topic: String, summaries: [String], language: String?) async throws -> String {
            summarizeCalls += 1
            onSummarize?()
            switch mode {
            case .ok: return try await inner.summarize(topic: topic, summaries: summaries, language: language)
            case .throwing: throw InsightsProviderError.failed("busy")
            case .empty: return ""
            }
        }
        func title(transcript: String, language: String?) async throws -> String { try await inner.title(transcript: transcript, language: language) }
    }

    func physicsAndKitchen() throws {
        for (i, t) in Self.physics.enumerated() { try note("Physics \(i)", t, tags: ["physics"]) }
        for (i, t) in Self.bread.enumerated() { try note("Bread \(i)", t, notebook: "Kitchen") }
        try enable()
    }

    func runTopics(_ model: any ModelProvider, at when: Date, memo: URL?, force: Bool = false) async throws -> InsightsUpdateReport {
        var o = InsightsUpdateOptions()
        o.now = when; o.force = force; o.failureMemo = memo
        o.platform = .init(platform: "mac", os: "macOS 27.2")
        return try await InsightsUpdater(vault: vault, model: model, embedder: FakeEmbeddingProvider(), deviceState: state, app: "test/1")
            .run(o, notes: try inputs())
    }

    func testTopicsShowTheLatestParagraphAndGoStaleWhenMembersChange() async throws {
        try physicsAndKitchen()
        _ = try await run()
        let kitchen = InsightsTopicsFile.Scope(notebook: "Kitchen")
        var all = TopicSummaries.shownAll(inputs: try inputs(), snapshot: InsightsStore(vault: vault).snapshot())
        XCTAssertEqual(all.map { TopicScopes.name($0.scope) }, ["notebook:Kitchen", "tag:physics"])
        let shown = try XCTUnwrap(all.first { $0.scope == kitchen })
        XCTAssertTrue(shown.eligible)
        XCTAssertEqual(shown.members.count, 3)
        XCTAssertNotNil(shown.summary)
        XCTAssertFalse(shown.stale)
        XCTAssertEqual(shown.device, vault.writerDevice)
        // A fourth summarized member: the stored paragraph is stale until it is made again.
        try note("Bread 3", Self.bread[0] + " Bake at a high heat.", notebook: "Kitchen")
        _ = try await run { $0.topics = false }
        all = TopicSummaries.shownAll(inputs: try inputs(), snapshot: InsightsStore(vault: vault).snapshot())
        let after = try XCTUnwrap(all.first { $0.scope == kitchen })
        XCTAssertEqual(after.members.count, 4)
        XCTAssertTrue(after.stale)
        // The background makes it again at most once a day: not within the day...
        let soon = try await run { $0.now = self.now.addingTimeInterval(3600) }
        XCTAssertFalse(soon.topics.contains("notebook:Kitchen"))
        // ...but after it.
        let later = try await run { $0.now = self.now.addingTimeInterval(TopicSummaries.minInterval + 60) }
        XCTAssertTrue(later.topics.contains("notebook:Kitchen"))
        XCTAssertFalse(TopicSummaries.shownAll(inputs: try inputs(), snapshot: InsightsStore(vault: vault).snapshot())
            .first { $0.scope == kitchen }!.stale)
        // The latest paragraph of any device wins (by `at`).
        let snapshot = InsightsStore(vault: vault).snapshot()
        XCTAssertEqual(TopicSummaries.latest(kitchen, snapshot: snapshot)?.device, vault.writerDevice)
    }

    func testRegenerateRunsNowAndKeepsOtherScopes() async throws {
        try physicsAndKitchen()
        _ = try await run()
        let me = try XCTUnwrap(vault.writerDevice)
        let before = try XCTUnwrap(InsightsStore(vault: vault).snapshot().topics[me])
        let updater = InsightsUpdater(vault: vault, model: FakeModelProvider(), embedder: nil, deviceState: state, app: "test/1")
        let kitchen = InsightsTopicsFile.Scope(notebook: "Kitchen")
        // Within the day (the background would wait): Regenerate runs anyway.
        let shown = try await updater.regenerateTopic(kitchen, inputs: try inputs(), now: now.addingTimeInterval(60))
        XCTAssertNotNil(shown.summary)
        let after = try XCTUnwrap(InsightsStore(vault: vault).snapshot().topics[me])
        XCTAssertEqual(after.topics.count, 2, "the tag's summary stays")
        XCTAssertGreaterThan(after.topics.first { $0.scope == kitchen }!.gen.at, before.topics.first { $0.scope == kitchen }!.gen.at)
        XCTAssertEqual(after.topics.first { $0.scope.tag == "physics" }, before.topics.first { $0.scope.tag == "physics" })
        // Too few members, no model, nothing surviving the fact check: typed errors, nothing written.
        do { _ = try await updater.regenerateTopic(.init(tag: "nothing"), inputs: try inputs()); XCTFail() }
        catch let e as InsightsUpdater.TopicError { XCTAssertEqual(e, .tooFewMembers(0)) }
        let none = InsightsUpdater(vault: vault, model: nil, embedder: nil, deviceState: state, app: "test/1")
        do { _ = try await none.regenerateTopic(kitchen, inputs: try inputs()); XCTFail() }
        catch let e as InsightsUpdater.TopicError { if case .unavailable = e {} else { XCTFail("\(e)") } }
        let empty = InsightsUpdater(vault: vault, model: TopicModel(.empty), embedder: nil, deviceState: state, app: "test/1")
        do { _ = try await empty.regenerateTopic(kitchen, inputs: try inputs()); XCTFail() }
        catch let e as InsightsUpdater.TopicError { XCTAssertEqual(e, .factCheck) }
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().topics[me], after, "a failed regeneration writes nothing")
    }

    func testFailedTopicsBackOffInTheMemo() async throws {
        try physicsAndKitchen()
        let memo = try TestTemp.directory("topic-memo").appendingPathComponent("failures.json")
        for mode in [TopicModel.Mode.throwing, .empty] {
            try? FileManager.default.removeItem(at: memo)
            let model = TopicModel(mode)
            let first = try await runTopics(model, at: now, memo: memo)
            XCTAssertEqual(first.topics, [], "\(mode): nothing made")
            XCTAssertEqual(Set(first.failures.keys), ["notebook:Kitchen", "tag:physics"], "\(mode)")
            XCTAssertEqual(InsightsFailureMemo.load(from: memo).topics.count, 2)
            let calls = model.summarizeCalls
            let second = try await runTopics(model, at: now.addingTimeInterval(3600), memo: memo)
            XCTAssertEqual(model.summarizeCalls, calls, "\(mode): not asked again the next hour")
            XCTAssertTrue(second.failures.isEmpty)
            _ = try await runTopics(model, at: now.addingTimeInterval(InsightsFailureMemo.failedFor + 60), memo: memo)
            XCTAssertGreaterThan(model.summarizeCalls, calls, "\(mode): asked again after a day")
        }
        // A success clears the scope's entry.
        let ok = try await runTopics(FakeModelProvider(), at: now.addingTimeInterval(3 * InsightsFailureMemo.failedFor), memo: memo, force: true)
        XCTAssertEqual(ok.topics.sorted(), ["notebook:Kitchen", "tag:physics"])
        XCTAssertTrue(InsightsFailureMemo.load(from: memo).topics.isEmpty)
    }

    func testACancelledRunStopsBetweenTopicsAndKeepsWhatItMade() async throws {
        try physicsAndKitchen()
        _ = try await run { $0.topics = false }
        let model = TopicModel(.ok)
        // Cancelled while the first scope's summary is being made: it is not written, and the next is not asked.
        model.onSummarize = { withUnsafeCurrentTask { $0?.cancel() } }
        let ins = try inputs(), v: Vault = vault, st = state, when = now
        let task = Task { () -> InsightsUpdateReport in
            var o = InsightsUpdateOptions()
            o.now = when
            o.platform = .init(platform: "mac", os: "macOS 27.2")
            return try await InsightsUpdater(vault: v, model: model, embedder: FakeEmbeddingProvider(), deviceState: st, app: "test/1")
                .run(o, notes: ins)
        }
        let r = try await task.value
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(model.summarizeCalls, 1)
        XCTAssertLessThanOrEqual(r.topics.count, 1)
    }

    /// Review of #54, M1 and L6: the topics file is written only while Note Insights is on (checked under the lock), and
    /// an own file that is there but cannot be read is never replaced (that would drop its scopes); a missing one is
    /// made.
    func testTopicWritesNeedInsightsOnAndAReadableOwnFile() async throws {
        try physicsAndKitchen()
        _ = try await run()
        let me = try XCTUnwrap(vault.writerDevice)
        let store = InsightsStore(vault: vault)
        let file = vault.insightsURL.appendingPathComponent(InsightsFileName(.topics, device: me).fileName)
        let topic = try XCTUnwrap(store.snapshot().topics[me]?.topics.first)
        // Missing: made.
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try store.updateOwnTopics(now: now) { $0.append(topic); return true })
        XCTAssertEqual(store.snapshot().topics[me]?.topics.count, 1)
        // There but unreadable: refused, left as it is.
        let garbage = Data("not an age file".utf8)
        try garbage.write(to: file)
        XCTAssertThrowsError(try store.updateOwnTopics(now: now) { $0.append(topic); return true })
        XCTAssertEqual(try Data(contentsOf: file), garbage)
        let regenerate = InsightsUpdater(vault: vault, model: FakeModelProvider(), embedder: nil, deviceState: state, app: "test/1")
        do { _ = try await regenerate.regenerateTopic(.init(notebook: "Kitchen"), inputs: try inputs()); XCTFail("replaced an unreadable file") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: file), garbage)
        // Off: refused.
        try FileManager.default.removeItem(at: file)
        try vault.updateSharedSettings { s in
            try s.write(SharedSettingsCatalog.spec(named: "insights.enabled")!, .bool(false), block: nil, type: nil, now: now)
        }
        XCTAssertThrowsError(try store.updateOwnTopics(now: now) { $0.append(topic); return true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAMemoWithoutTopicsStillDecodes() throws {
        let url = try TestTemp.directory("old-memo").appendingPathComponent("failures.json")
        try Data(#"{"notes":{"x":{"hash":"h","identity":"m 1 2","refused":false,"at":1,"count":1}}}"#.utf8).write(to: url)
        let memo = InsightsFailureMemo.load(from: url)
        XCTAssertEqual(memo.notes.count, 1)
        XCTAssertTrue(memo.topics.isEmpty)
        var m = memo
        let id = GenerationIdentity(model: "m", os: "1", prompt: 2)
        m.recordTopic("tag:x", membersHash: "d1", identity: id, error: InsightsProviderError.refused("no"), now: now)
        XCTAssertEqual(m.topicBackoff("tag:x", membersHash: "d1", identity: id), now.addingTimeInterval(InsightsFailureMemo.refusedFor))
        XCTAssertNil(m.topicBackoff("tag:x", membersHash: "d2", identity: id), "other members: a new question")
        try m.save(to: url)
        XCTAssertEqual(InsightsFailureMemo.load(from: url), m)
    }
}
