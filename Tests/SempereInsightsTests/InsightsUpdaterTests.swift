import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// The updater end to end on a real vault with the fake providers (docs/design/1.2-note-insights.md §3.7, §3.8, D14,
/// D21): enabling, sidecars with `gen` and `emb`, the pin set by the
/// first map build, device records, deletion tombstones, transcripts in `text/1`, voice-note titles (applied only to the
/// capture default, never over a user's rename, restoring a concurrent rename that lost), and readers on top.
final class InsightsUpdaterTests: TempDirTestCase {
    var identity: NativeIdentity!
    var vault: Vault!
    var state: URL { tmp.appendingPathComponent("device.json") }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        identity = try NativeIdentity.generate(.postQuantum)
        let v = try TestVaults.create(at: tmp.appendingPathComponent("V.sempere"), identities: [identity], names: ["mac"])
        vault = try TestVaults.open(at: v.url, identity: identity)
        try DeviceState(device: DeviceID("abcdef01")!).save(to: state)
    }

    @discardableResult
    func note(_ title: String, _ text: String, notebook: String? = nil, tags: [String] = []) throws -> UUID {
        let id = UUID(), page = UUID()
        var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: notebook, pageId: page)
        ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
        for t in tags { ops.append(.addTag(t)) }
        try vault.apply(ops, to: id, deviceState: state, app: "test/1", wall: now.addingTimeInterval(-7200))
        return id
    }

    func enable() throws {
        try vault.updateSharedSettings { s in
            try s.write(SharedSettingsCatalog.spec(named: "insights.enabled")!, .bool(true), block: nil, type: nil, now: now)
        }
    }

    func inputs() throws -> [InsightsNoteInput] { InsightsNotes.inputs(vault, summaries: try vault.summaries()) }

    func run(_ model: FakeModelProvider = FakeModelProvider(), embedder: FakeEmbeddingProvider? = FakeEmbeddingProvider(),
             _ edit: (inout InsightsUpdateOptions) -> Void = { _ in }) async throws -> InsightsUpdateReport {
        var o = InsightsUpdateOptions()
        o.now = now
        o.platform = .init(platform: "mac", os: "macOS 27.2")
        edit(&o)
        return try await InsightsUpdater(vault: vault, model: model, embedder: embedder, deviceState: state, app: "test/1")
            .run(o, notes: try inputs())
    }

    static let physics = [
        "The damping ratio decides whether a spring mass system oscillates. Critical damping returns fastest without oscillation. Resonance amplifies the amplitude.",
        "Damped oscillation of a spring and mass: the amplitude decays with the damping ratio. Resonance happens near the natural frequency.",
        "Forced oscillation of a spring mass system near resonance: the amplitude peaks when damping is small.",
    ]
    static let bread = [
        "Sourdough starter needs flour and water fed daily. Knead the dough and let it rise in a warm oven.",
        "Knead sourdough dough for ten minutes, proof it overnight, bake it in a hot oven with steam.",
        "Feed the starter with flour, wait for bubbles, then mix the dough and knead it well.",
    ]

    func testDisabledByDefault() async throws {
        try note("A", Self.physics[0])
        do { _ = try await run(); XCTFail("ran while off") } catch let e as InsightsUpdateError { XCTAssertEqual(e, .disabled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.insightsURL.path))
    }

    func testUpdateMakesSidecarsTheMapAndTheRecord() async throws {
        for (i, t) in Self.physics.enumerated() { try note("Physics \(i)", t, tags: ["physics"]) }
        for (i, t) in Self.bread.enumerated() { try note("Bread \(i)", t, notebook: "Kitchen") }
        try enable()
        let r = try await run()
        let me = try XCTUnwrap(vault.writerDevice)
        XCTAssertEqual(r.generated.count, 6)
        XCTAssertEqual(r.embedded.count, 6)
        XCTAssertTrue(r.mapBuilt)
        XCTAssertEqual(r.pinSet, ["en": 1])
        XCTAssertEqual(InsightsSettings.read(vault).pins, ["en": 1], "the first map build writes the pin")
        XCTAssertTrue(r.deviceRecord)
        let snap = InsightsStore(vault: vault).snapshot()
        XCTAssertEqual(snap.notes.count, 6)
        XCTAssertEqual(snap.map(of: me)?.built?.notes, 6)
        XCTAssertEqual(snap.devices[me]?.supported, ["en": [1]])
        XCTAssertEqual(snap.devices[me]?.canaries.first?.canaries.v.count, Canaries.sentences.count)
        XCTAssertEqual(r.topics.sorted(), ["notebook:Kitchen", "tag:physics"])
        XCTAssertEqual(snap.topics[me]?.topics.count, 2)
        // A second pass has nothing to do.
        let again = try await run()
        XCTAssertEqual(again.generated, [])
        XCTAssertEqual(again.embedded, [])
        XCTAssertFalse(again.mapBuilt)
        // Readers.
        let ins = try inputs()
        let reader = InsightsReader(vault: vault)
        let physics0 = try XCTUnwrap(ins.first { $0.title == "Physics 0" })
        let shown = reader.show(physics0)
        XCTAssertEqual(shown.state, "current")
        XCTAssertTrue(shown.embedded)
        let related = reader.related(physics0, inputs: ins, me: me, embedder: FakeEmbeddingProvider())
        XCTAssertEqual(related.basis, "vectors")
        XCTAssertTrue(related.related.allSatisfy { $0.title.hasPrefix("Physics") }, "\(related.related.map(\.title))")
        XCTAssertFalse(reader.search("resonance", inputs: ins).isEmpty)
        let status = reader.status(inputs: ins, me: me, embedder: FakeEmbeddingProvider(), now: now)
        XCTAssertEqual(status.processed, 6)
        XCTAssertEqual(status.compatibility, "compatible", "the device that built the map holds its vectors")
        XCTAssertEqual(status.pin, 1)
        let map = reader.mapView(inputs: ins, me: me, embedder: nil)
        XCTAssertEqual(map.nodes.count, 6)
        XCTAssertTrue(InsightsReader.svg(map).hasPrefix("<svg"))
    }

    func testEditDeleteAndAnotherReader() async throws {
        let a = try note("Physics", Self.physics[0])
        let b = try note("Bread", Self.bread[0])
        try enable()
        _ = try await run()
        // An edit makes the sidecar stale; the next pass (forced past the settle time) regenerates it.
        try vault.apply([.setPageRecognition(pageId: try vault.reconstruct(noteId: a).pages[0].id,
                                             recognition: Recognition(engine: "test", text: Self.physics[1]))],
                        to: a, deviceState: state, app: "test/1", wall: now)
        XCTAssertEqual(InsightsReader(vault: vault).show(try inputs().first { $0.id == a }!).state, "stale")
        let r = try await run { $0.force = true }
        XCTAssertTrue(r.generated.contains(a.uuidString.lowercased()))
        // A deleted note: this device's sidecar becomes a tombstone.
        try vault.apply([.deleteNote], to: b, deviceState: state, app: "test/1", wall: now)
        let d = try await run()
        XCTAssertEqual(d.tombstoned, [b.uuidString.lowercased()])
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().notes[b]?[vault.writerDevice!]?.isTombstone, true)
    }

    func testModelFailuresAreReportedNotFatal() async throws {
        try note("Physics", Self.physics[0])
        try enable()
        var s = FakeModelProvider.Script()
        s.failures = 1
        let r = try await run(FakeModelProvider(s))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(r.generated, [])
        XCTAssertEqual(r.embedded.count, 1, "embedding still runs")
    }

    func testARefusedNoteWaitsInsteadOfCrowdingOutTheOthers() async throws {
        // D16: refusals were asked again on every run and, under --limit, came first every time.
        try note("Refused", Self.physics[0])
        try enable()
        let memoURL = try TestTemp.directory("d16-memo").appendingPathComponent("failures.json")
        final class Refusing: ModelProvider, @unchecked Sendable {
            let inner = FakeModelProvider()
            var calls = 0
            var identity: GenerationIdentity { inner.identity }
            var availability: ModelAvailability { .available }
            var contextTokens: Int { 8192 }
            func supports(language: String?) -> Bool { true }
            func extract(_ text: String, language: String?) async throws -> ModelExtraction {
                calls += 1; throw InsightsProviderError.refused("a guardrail")
            }
            func merge(_ parts: [ModelExtraction], language: String?) async throws -> ModelExtraction { try await inner.merge(parts, language: language) }
            func summarize(topic: String, summaries: [String], language: String?) async throws -> String { "" }
            func title(transcript: String, language: String?) async throws -> String { "" }
        }
        let refusing = Refusing()
        func runRefusing(at when: Date, force: Bool = false) async throws -> InsightsUpdateReport {
            var o = InsightsUpdateOptions()
            o.now = when; o.force = force; o.failureMemo = memoURL
            o.platform = .init(platform: "mac", os: "macOS 27.2")
            return try await InsightsUpdater(vault: vault, model: refusing, embedder: FakeEmbeddingProvider(), deviceState: state, app: "test/1")
                .run(o, notes: try inputs())
        }
        let first = try await runRefusing(at: now)
        XCTAssertEqual(first.failures.count, 1)
        XCTAssertEqual(InsightsFailureMemo.load(from: memoURL, vault: vault).notes.count, 1)
        let second = try await runRefusing(at: now.addingTimeInterval(3600))
        XCTAssertEqual(second.failures.count, 0, "not asked again the next hour")
        XCTAssertEqual(refusing.calls, 1)
        XCTAssertTrue(second.notes.contains("1 notes backed off (failed earlier; --force to retry)"), "\(second.notes)")
        _ = try await runRefusing(at: now.addingTimeInterval(InsightsFailureMemo.refusedFor + 60))
        XCTAssertEqual(refusing.calls, 2, "asked again after the back-off")
        _ = try await runRefusing(at: now.addingTimeInterval(InsightsFailureMemo.refusedFor + 120), force: true)
        XCTAssertEqual(refusing.calls, 3, "--force asks at once")
        // A changed text is a new question.
        var memo = InsightsFailureMemo()
        let id = UUID(), model = GenerationIdentity(model: "m", os: "1", prompt: 2)
        memo.record(note: id, hash: "h1", identity: model, error: InsightsProviderError.failed("x"), now: now)
        XCTAssertEqual(memo.backoff(notes: [(id, "h1")], identity: model)[id], now.addingTimeInterval(InsightsFailureMemo.failedFor))
        XCTAssertTrue(memo.backoff(notes: [(id, "h2")], identity: model).isEmpty)
        XCTAssertTrue(memo.backoff(notes: [(id, "h1")], identity: GenerationIdentity(model: "m", os: "1", prompt: 3)).isEmpty)
        memo.clear(note: id)
        XCTAssertTrue(memo.notes.isEmpty)
    }

    func testEmbeddingsOnlyWithoutAModel() async throws {
        for (i, t) in Self.physics.enumerated() { try note("P\(i)", t) }
        try enable()
        let r = try await run { $0.embeddingsOnly = true }
        XCTAssertEqual(r.generated, [])
        XCTAssertEqual(r.embedded.count, 3)
        XCTAssertTrue(r.mapBuilt)
    }

    // MARK: Voice notes (D14)

    /// A quick voice note as 1.3 stores it: no title, the capture's zone (UTC here) and source. `storedTitle` writes a
    /// title the way 1.0 through 1.2 did (their default, or a user's).
    func capture(transcript text: String, storedTitle: String? = nil) throws -> UUID {
        let me = try XCTUnwrap(vault.writerDevice)
        let w = try CaptureWriter(profile: try vault.captureProfile(device: me))
        let id = UUID()
        let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let started = Date(timeIntervalSince1970: 1_789_990_000)
        try CaptureWriter.store(try w.seal(audio: audio, started: started, title: storedTitle, source: "phone", timeZone: TimeZone(identifier: "UTC")!, id: id),
                                in: vault.inboxURL)
        let t = TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: id).recording, engine: "e", language: "en-US",
                                             created: started, segments: [.init(start: 0, end: 4, text: text)])
        try CaptureWriter.store(try w.seal(transcript: t, capture: id, audio: BlobRef(content: audio, type: "audio/mp4")), in: vault.inboxURL)
        let r = try vault.adoptCapture(id, deviceState: state, app: "test/1")
        XCTAssertNil(r.error)
        return CaptureAdoption.ids(for: id).note
    }

    func title(_ id: UUID) throws -> String { try vault.reconstruct(noteId: id).meta.title }

    func testVoiceNotesGetADerivedTitleFromTheirTranscript() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let inputs = try inputs()
        XCTAssertTrue(inputs.first { $0.id == id }?.text.contains("damping ratio") ?? false, "text/1 carries the transcript")
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(try title(id), "", "the stored title stays blank")
        let store = InsightsStore(vault: vault)
        XCTAssertEqual(store.snapshot().bestTitle(for: id, hash: nil), "2026-09-21 11.26 Spring Lab Results Show")
        // The generated title is bound to the text it was made for: current for that hash, none for another.
        let hash = try XCTUnwrap(inputs.first { $0.id == id }?.hash)
        XCTAssertNotNil(store.snapshot().bestTitle(for: id, hash: hash))
        XCTAssertNil(store.snapshot().bestTitle(for: id, hash: String(repeating: "0", count: 32)))
        // Once per text: the next pass keeps it.
        let again = try await run { $0.force = true }
        XCTAssertEqual(again.titled, [])
    }

    /// The title format decides when a derived title is current (format.md §16.2 `fmt`): a changed format derives again, the
    /// old title stays shown until then, and the new one wins once derived.
    func testChangingTheTitleFormatDerivesTheTitleAgain() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let first = try await run { $0.force = true }
        XCTAssertEqual(first.titled, [id.uuidString.lowercased()])
        let hash = try XCTUnwrap(try inputs().first { $0.id == id }?.hash)
        XCTAssertTrue(InsightsStore(vault: vault).snapshot().hasTitle(for: id, hash: hash, language: nil))
        XCTAssertFalse(InsightsStore(vault: vault).snapshot().hasTitle(for: id, hash: hash, language: nil, format: "{slug} ({date})"))
        try InsightsSettingsWrite.setVoiceNoteTitle("{slug} ({date})", vault: vault, now: now)
        // Until the new one is derived, the old title is shown.
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().bestTitle(for: id, hash: hash, format: "{slug} ({date})"),
                       "2026-09-21 11.26 Spring Lab Results Show")
        let again = try await run { $0.force = true; $0.now = self.now.addingTimeInterval(60) }
        XCTAssertEqual(again.titled, [id.uuidString.lowercased()])
        let snap = InsightsStore(vault: vault).snapshot()
        XCTAssertEqual(snap.bestTitle(for: id, hash: hash, format: "{slug} ({date})"), "Spring Lab Results Show (2026-09-21)")
        XCTAssertTrue(snap.hasTitle(for: id, hash: hash, language: nil, format: "{slug} ({date})"))
        // Back to the default: a device keeps one title per note, so it is derived again and wins again.
        try InsightsSettingsWrite.setVoiceNoteTitle(nil, vault: vault, now: now.addingTimeInterval(120))
        let back = try await run { $0.force = true; $0.now = self.now.addingTimeInterval(180) }
        XCTAssertEqual(back.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().bestTitle(for: id, hash: hash), "2026-09-21 11.26 Spring Lab Results Show")
    }

    /// A note of 1.0 through 1.2 holds its default as a stored title: it is still a default, and gets a derived title whose
    /// date and time come from that stored title (the capture kept no zone then).
    func testAStoredDefaultTitleOfAnOlderNoteStillGetsADerivedTitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.",
                             storedTitle: "Voice note 2026-09-21 11:26")
        try enable()
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(try title(id), "Voice note 2026-09-21 11:26", "the stored title is not rewritten")
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().bestTitle(for: id, hash: nil), "2026-09-21 11.26 Spring Lab Results Show")
    }

    func testAUserRenameWinsAndGetsNoDerivedTitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        try vault.apply([.setMeta(.title("My lab"))], to: id, deviceState: state, app: "test/1", wall: now)
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [])
        XCTAssertEqual(try title(id), "My lab")
        XCTAssertNil(InsightsStore(vault: vault).snapshot().bestTitle(for: id, hash: nil))
    }

    /// A user's title, then thinning drops the adoption delta: still the user's, never replaced.
    func testARenamedVoiceNoteWhoseHistoryWasThinnedKeepsItsTitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        try vault.apply([.setMeta(.title("My lab"))], to: id, deviceState: state, app: "test/1", wall: now)
        var clock = HybridClock(millis: Int64(now.timeIntervalSince1970 * 1000) + 60_000)
        let snap = try vault.snapshot(noteId: id, device: DeviceID("abcdef01")!, clock: &clock, wall: now, app: "test/1")
        let dir = vault.url.appendingPathComponent("notes/\(id.uuidString.lowercased())")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".delta.age") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(try vault.loadNote(id).revisions.map(\.name), [snap.name])
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [])
        XCTAssertEqual(try title(id), "My lab")
    }

    /// D21: a device without the embedder derives a voice note's title too; nothing designates who may.
    func testADeviceWithoutTheEmbedderDerivesATitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let r = try await run(embedder: nil) { $0.force = true }
        XCTAssertFalse(r.generated.isEmpty)
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().bestTitle(for: id, hash: nil), "2026-09-21 11.26 Spring Lab Results Show")
    }

    func testOrdinaryNotesAreNeverRetitled() async throws {
        let id = try note("Lecture", Self.physics[0])
        try enable()
        _ = try await run { $0.force = true }
        XCTAssertEqual(try title(id), "Lecture")
    }
}
