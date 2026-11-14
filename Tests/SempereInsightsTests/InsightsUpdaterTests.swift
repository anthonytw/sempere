import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// The updater end to end on a real vault with the fake providers (docs/design/1.2-note-insights.md §3.7, §3.8, D13,
/// D14): enabling, the work-device claim through the settings merge, sidecars with `gen` and `emb`, the pin set by the
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
        XCTAssertTrue(r.claimedWorkDevice)
        XCTAssertEqual(InsightsSettings.read(vault).workDevice, me, "claimed through the settings")
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
        XCTAssertEqual(status.compatibility, "workDevice")
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

    func testEmbeddingsOnlyWithoutAModel() async throws {
        for (i, t) in Self.physics.enumerated() { try note("P\(i)", t) }
        try enable()
        let r = try await run { $0.embeddingsOnly = true }
        XCTAssertEqual(r.generated, [])
        XCTAssertEqual(r.embedded.count, 3)
        XCTAssertTrue(r.mapBuilt)
    }

    // MARK: Voice notes (D14)

    func capture(transcript text: String) throws -> UUID {
        let me = try XCTUnwrap(vault.writerDevice)
        let w = try CaptureWriter(profile: try vault.captureProfile(device: me))
        let id = UUID()
        let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let started = Date(timeIntervalSince1970: 1_789_990_000)
        try CaptureWriter.store(try w.seal(audio: audio, started: started, title: "Voice note 2026-09-21 10:46", id: id), in: vault.inboxURL)
        let t = TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: id).recording, engine: "e", language: "en-US",
                                             created: started, segments: [.init(start: 0, end: 4, text: text)])
        try CaptureWriter.store(try w.seal(transcript: t, capture: id, audio: BlobRef(content: audio, type: "audio/mp4")), in: vault.inboxURL)
        let r = try vault.adoptCapture(id, deviceState: state, app: "test/1")
        XCTAssertNil(r.error)
        return CaptureAdoption.ids(for: id).note
    }

    func title(_ id: UUID) throws -> String { try vault.reconstruct(noteId: id).meta.title }

    func testVoiceNotesGetATitleFromTheirTranscript() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let inputs = try inputs()
        XCTAssertTrue(inputs.first { $0.id == id }?.text.contains("damping ratio") ?? false, "text/1 carries the transcript")
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(try title(id), "2026-09-21 10.46 Spring Lab Results Show")
        // Applied once: the next pass keeps it.
        let again = try await run { $0.force = true }
        XCTAssertEqual(again.titled, [])
        XCTAssertEqual(InsightsStore(vault: vault).snapshot().notes[id]?[vault.writerDevice!]?.titleOp?.title, try title(id))
    }

    func testAUserRenameWinsAndIsNeverOverwritten() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        try vault.apply([.setMeta(.title("My lab"))], to: id, deviceState: state, app: "test/1", wall: now)
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.titled, [])
        XCTAssertEqual(try title(id), "My lab")
    }

    /// A rename made on another device before it saw the automatic title, with a lower clock: the work device's title
    /// wins the register, so it writes the user's title back (D14 review fix).
    func testAConcurrentRenameWithALowerClockEndsWithTheUsersTitle() async throws {
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        try enable()
        let loaded = try vault.loadNote(id)
        let adoption = try XCTUnwrap(loaded.revisions.last)
        _ = try await run { $0.force = true }
        XCTAssertEqual(try title(id), "2026-09-21 10.46 Spring Lab Results Show")
        // Another device's rename, written before it saw the automatic title: a clock between the adoption and it.
        let ours = try XCTUnwrap(InsightsStore(vault: vault).snapshot().notes[id]?[vault.writerDevice!]?.titleOp.flatMap { Stamp($0.stamp) })
        XCTAssertGreaterThan(ours.hlc, adoption.hlc)
        // The same clock reading as the automatic title's revision, from a device whose id sorts first: a lower stamp.
        let other = DeviceID("0000beef")!
        XCTAssertLessThan(Stamp(hlc: ours.hlc, device: other), ours)
        try vault.write(Revision(noteId: id, device: other, seq: 1, hlc: ours.hlc, wall: now, app: "other/1",
                                 body: .delta(ops: [.setMeta(.title("Spring lab (mine)"))])))
        XCTAssertEqual(try title(id), "2026-09-21 10.46 Spring Lab Results Show", "the automatic title wins the register")
        let r = try await run { $0.force = true }
        XCTAssertEqual(r.restoredTitles, [id.uuidString.lowercased()])
        XCTAssertEqual(try title(id), "Spring lab (mine)")
        // And it stays.
        let again = try await run { $0.force = true }
        XCTAssertEqual(again.titled + again.restoredTitles, [])
        XCTAssertEqual(try title(id), "Spring lab (mine)")
    }

    func testOrdinaryNotesAreNeverRetitled() async throws {
        let id = try note("Lecture", Self.physics[0])
        try enable()
        _ = try await run { $0.force = true }
        XCTAssertEqual(try title(id), "Lecture")
    }
}
