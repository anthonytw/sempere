import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// What the app (Insights PR 2) needs from the core: titles written through the caller's clock (`titleWriter`, never a
/// second clock on the app's state file), open notes left alone, the settings writes Settings ▸ Note Insights and the
/// CLI share (under the vault's write lock), and the whole related graph at once, bounded (review of #50, L7).
extension InsightsUpdaterTests {
    func testTitlesGoThroughTheCallersWriter() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let calls = Calls()
        var o = InsightsUpdateOptions()
        o.now = now; o.force = true
        o.platform = .init(platform: "ios", os: "iOS 27.2")
        var updater = InsightsUpdater(vault: vault, model: FakeModelProvider(), embedder: FakeEmbeddingProvider(),
                                      deviceState: tmp.appendingPathComponent("missing.json"), app: "test/1")
        let vault = self.vault!, state = self.state
        updater.titleWriter = { note, ops, wall in
            calls.add(note)
            // The caller's own clock (here: the test's state file) writes the delta.
            let rev = try vault.apply(ops, to: note, deviceState: state, app: "app/1", wall: wall)
            return RevisionName(hlc: rev.hlc, device: rev.device, seq: rev.seq, kind: .delta)
        }
        updater.writerDevice = try DeviceState.loadOrCreate(at: state).device
        let r = try await updater.run(o, notes: try inputs())
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(calls.ids, [id])
        XCTAssertEqual(try title(id), "2026-09-21 10.46 Spring Lab Results Show")
        // The `titleOp` names the writer's revision, so the next pass keeps the title.
        let again = try await updater.run(o, notes: try inputs())
        XCTAssertEqual(again.titled, [])
        XCTAssertEqual(again.restoredTitles, [])
        XCTAssertEqual(calls.ids, [id])
    }

    func testOpenNotesWaitUntilClosed() async throws {
        let a = try note("A", Self.physics[0])
        try note("B", Self.physics[1])
        try enable()
        let r = try await run { $0.openNotes = [a] }
        XCTAssertFalse(r.generated.contains(a.uuidString.lowercased()))
        XCTAssertEqual(r.generated.count, 1)
        XCTAssertFalse(r.embedded.contains(a.uuidString.lowercased()), "an open note is not eligible yet (policy)")
        let later = try await run()
        XCTAssertEqual(later.generated, [a.uuidString.lowercased()], "closed again: generated")
    }

    func testSettingsWrites() throws {
        let me = try XCTUnwrap(vault.writerDevice)
        try InsightsSettingsWrite.setEnabled(true, vault: vault, now: now)
        XCTAssertTrue(InsightsSettings.read(vault).enabled)
        XCTAssertEqual(vault.insightsMode(), .on)
        try InsightsSettingsWrite.setWorkDevice(me, vault: vault, now: now)
        XCTAssertEqual(InsightsSettings.read(vault).workDevice, me)
        try InsightsSettingsWrite.setVoiceNoteTitle("{slug} ({date})", vault: vault, now: now)
        XCTAssertEqual(InsightsSettings.read(vault).voiceNoteTitle, "{slug} ({date})")
        XCTAssertThrowsError(try InsightsSettingsWrite.setVoiceNoteTitle("{nope}", vault: vault, now: now))
        XCTAssertEqual(InsightsSettings.read(vault).voiceNoteTitle, "{slug} ({date})", "a refused format writes nothing")
        try InsightsSettingsWrite.setVoiceNoteTitle(nil, vault: vault, now: now)
        XCTAssertEqual(InsightsSettings.read(vault).voiceNoteTitle, VoiceNoteTitleFormat.defaultFormat)
        try InsightsSettingsWrite.setCompute(auto: true, type: .iphone, vault: vault, now: now)
        XCTAssertTrue(InsightsSettings.read(vault, type: .iphone).computeAuto)
        XCTAssertFalse(InsightsSettings.read(vault, type: .mac).computeAuto, "a type block only")
        try InsightsSettingsWrite.setWorkDevice(nil, vault: vault, now: now)
        XCTAssertNil(InsightsSettings.read(vault).workDevice)
        // Off: the explicit false, and this copy's files go.
        try note("A", Self.physics[0])
        try InsightsStore(vault: vault).write(.note(InsightsNoteFile(noteId: UUID(), device: me, written: 0)), now: now)
        let deleted = try InsightsSettingsWrite.setEnabled(false, vault: vault, now: now)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(vault.insightsMode(), .off)
    }

    func testThePinMovePlanAndApply() async throws {
        for t in Self.physics + Self.bread { try note(String(t.prefix(8)), t) }
        try enable()
        _ = try await run(embedder: FakeEmbeddingProvider(revisions: [1, 2])) { $0.embeddingsOnly = true }
        let settings = InsightsSettings.read(vault)
        let me = try XCTUnwrap(vault.writerDevice)
        XCTAssertEqual(settings.workDevice, me)
        let snapshot = InsightsStore(vault: vault).snapshot()
        let away = InsightsSettingsWrite.planPinMove(to: 3, language: "en", vault: vault, snapshot: snapshot, settings: settings, now: now)
        XCTAssertEqual(away.leftOut, [me])
        XCTAssertTrue(away.movesWorkDevice)
        XCTAssertNil(away.workDevice, "no recently seen device supports 3")
        let move = InsightsSettingsWrite.planPinMove(to: 2, language: "en", vault: vault, snapshot: snapshot, settings: settings, now: now)
        XCTAssertEqual(move.revision, 2)
        XCTAssertEqual(move.leftOut, [], "this device supports revision 2")
        XCTAssertFalse(move.movesWorkDevice)
        try InsightsSettingsWrite.apply(move, vault: vault, now: now)
        XCTAssertEqual(InsightsSettings.read(vault).pins["en"], 2)
    }

    func testTheWholeGraphMatchesPerNoteRelatedAndIsBounded() async throws {
        for t in Self.physics + Self.bread { try note(String(t.prefix(8)), t) }
        try enable()
        _ = try await run()
        let inputs = try inputs()
        let reader = InsightsReader(vault: vault)
        let embedder = FakeEmbeddingProvider()
        let graph = reader.relatedGraph(inputs: inputs, me: vault.writerDevice, embedder: embedder)
        let titles = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.title) })
        for n in inputs {
            XCTAssertEqual(InsightsReader.related(n.id, in: graph, titles: titles),
                           reader.related(n, inputs: inputs, me: vault.writerDevice, embedder: embedder), n.title)
        }
        XCTAssertFalse(graph.edges.isEmpty)
        let bounded = reader.relatedGraph(inputs: inputs, me: vault.writerDevice, embedder: embedder, maxNotes: 3)
        XCTAssertEqual(bounded.leftOut, inputs.count - 3)
        XCTAssertLessThanOrEqual(Set(bounded.edges.keys).count, 3)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [UUID] = []
    func add(_ id: UUID) { lock.withLock { list.append(id) } }
    var ids: [UUID] { lock.withLock { list } }
}
