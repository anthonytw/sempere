import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// Any capable device does Insights work (D21, which replaced D13's designated work device): a device with the model
/// makes the summaries and keywords no device has, one that supports the pin embeds the vectors no device has and rebuilds
/// the map, any titles voice notes. Two devices of one vault, A (home) and B, each with its own updater: per-device
/// files, skipping what exists, a deterministic map, settled races, OS majors, topics, and what a pass that makes nothing
/// says (`InsightsPassOutcome`).
final class InsightsEveryDeviceTests: TempDirTestCase {
    var a: Vault!
    var b: Vault!
    var ib: NativeIdentity!
    var stateA: URL { tmp.appendingPathComponent("a.json") }
    var stateB: URL { tmp.appendingPathComponent("b.json") }
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(postQuantumAvailable, "X-Wing and ML-DSA need Apple OS 26 (always on Linux)")
        let ia = try NativeIdentity.generate(.postQuantum)
        ib = try NativeIdentity.generate(.postQuantum)
        let v = try TestVaults.create(at: tmp.appendingPathComponent("V.sempere"), identities: [ia, ib], names: ["mac", "iphone"])
        a = try TestVaults.open(at: v.url, identity: ia)
        b = try TestVaults.open(at: v.url, identity: ib)
        try DeviceState(device: try XCTUnwrap(a.writerDevice)).save(to: stateA)
        try DeviceState(device: try XCTUnwrap(b.writerDevice)).save(to: stateB)
        try a.updateSharedSettings { s in
            try s.write(SharedSettingsCatalog.spec(named: "insights.enabled")!, .bool(true), block: nil, type: nil, now: now)
        }
    }

    var meA: DeviceID { a.writerDevice! }
    var meB: DeviceID { b.writerDevice! }

    @discardableResult
    func note(_ title: String, _ text: String, notebook: String? = nil, modified: Date? = nil) throws -> UUID {
        let id = UUID(), page = UUID()
        var ops = NoteOps.newNote(title: title, paper: .ruled, notebook: notebook, pageId: page)
        ops.append(.setPageRecognition(pageId: page, recognition: Recognition(engine: "test", text: text)))
        try a.apply(ops, to: id, deviceState: stateA, app: "test/1", wall: modified ?? now.addingTimeInterval(-7200))
        return id
    }

    func inputs() throws -> [InsightsNoteInput] { InsightsNotes.inputs(a, summaries: try a.summaries()) }

    func model(os: String = "27.2") -> FakeModelProvider {
        var s = FakeModelProvider.Script()
        s.identity = GenerationIdentity(model: "fake-model", os: os, prompt: InsightsGenerator.promptRevision)
        return FakeModelProvider(s)
    }

    func run(_ vault: Vault, model: FakeModelProvider?, embedder: FakeEmbeddingProvider? = FakeEmbeddingProvider(), at: Date? = nil,
             _ edit: (inout InsightsUpdateOptions) -> Void = { _ in }) async throws -> InsightsUpdateReport {
        var o = InsightsUpdateOptions()
        o.now = at ?? now
        let isA = vault.writerDevice == a.writerDevice
        o.platform = .init(platform: isA ? "mac" : "ios", os: "27.2")
        edit(&o)
        var u = InsightsUpdater(vault: vault, model: model, embedder: embedder, deviceState: isA ? stateA : stateB, app: "test/1")
        u.writerDevice = vault.writerDevice
        return try await u.run(o, notes: try inputs())
    }

    static let physics = InsightsUpdaterTests.physics
    static let bread = InsightsUpdaterTests.bread

    // MARK: Policy

    func generates(_ plan: [WorkItem]) -> [UUID] { plan.compactMap { if case .generate(let id) = $0 { return id } else { return nil } } }
    func embeds(_ plan: [WorkItem]) -> Bool { plan.contains { if case .embed = $0 { return true } else { return false } } }

    func testAnyCapableDeviceGeneratesEmbedsAndMapsWhatNoDeviceHas() {
        let me = DeviceID("11111111")!, other = DeviceID("22222222")!
        let note = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-3600), deleted: false,
                              hasText: true)
        let settings = InsightsSettings(enabled: true)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let model = GenerationIdentity(model: "m", os: "27.2", prompt: 2)
        let plan = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                       capabilities: .init(model: model, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                       deviceRecordChanged: false)
        XCTAssertEqual(generates(plan), [note.id])
        XCTAssertTrue(embeds(plan), "no role to hold: any device that supports the pin embeds")
        XCTAssertTrue(plan.contains(.rebuildMap))
        // Embed-only (no model): embeds and maps, never generates.
        let embedOnly = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                            capabilities: .init(model: nil, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                            deviceRecordChanged: false)
        XCTAssertEqual(generates(embedOnly), [])
        XCTAssertTrue(embeds(embedOnly))
        // Model only (no embedder at the pin): generates, never embeds or maps.
        let modelOnly = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                            capabilities: .init(model: model, embedRevision: nil, powerWindow: true), pinKey: nil, now: now,
                                            deviceRecordChanged: false)
        XCTAssertEqual(generates(modelOnly), [note.id])
        XCTAssertFalse(embeds(modelOnly))
        XCTAssertFalse(modelOnly.contains(.rebuildMap))
        // Off power: nothing generated.
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: .init(model: model, embedRevision: nil, powerWindow: false), pinKey: nil,
                                                     now: now, deviceRecordChanged: false)), [])
        // A note whose summary and vector exist on another device is neither generated nor embedded again.
        var snap = InsightsSnapshot()
        let gen = InsightsNoteFile.Gen(hash: note.hash, identity: model, summary: "s", keywords: [], concepts: [], dropped: 0)
        let emb = InsightsNoteFile.Emb(hash: note.hash, key: key, vector: [0.5, 0.5])
        snap.notes[note.id] = [other: InsightsNoteFile(noteId: note.id, device: other, written: 1, gen: gen, emb: emb)]
        let skipped = InsightsPolicy.plan(notes: [note], snapshot: snap, me: me, settings: settings,
                                          capabilities: .init(model: model, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                          deviceRecordChanged: false)
        XCTAssertEqual(generates(skipped), [])
        XCTAssertFalse(embeds(skipped))
        // `force` redoes both.
        let forced = InsightsPolicy.plan(notes: [note], snapshot: snap, me: me, settings: settings,
                                         capabilities: .init(model: model, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                         force: true, deviceRecordChanged: false)
        XCTAssertEqual(generates(forced), [note.id])
        XCTAssertTrue(embeds(forced))
    }

    // MARK: The canary gate (D21)

    /// An incompatible device neither embeds nor maps, and its vectors never suppress a compatible device's embedding.
    func testAnIncompatibleDeviceWritesNothingSharedAndDoesNotSuppressOthers() {
        let me = DeviceID("11111111")!, bad = DeviceID("22222222")!
        let note = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-3600), deleted: false,
                              hasText: true)
        let settings = InsightsSettings(enabled: true)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let caps = PolicyCapabilities(model: nil, embedRevision: 1, powerWindow: true)
        let incompatiblePlan = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                   capabilities: caps, pinKey: key, now: now, deviceRecordChanged: false,
                                                   standing: .incompatible)
        XCTAssertFalse(embeds(incompatiblePlan))
        XCTAssertFalse(incompatiblePlan.contains(.rebuildMap))
        for standing in [MapCompatibility.compatible, .noMap] {
            XCTAssertTrue(embeds(InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: caps, pinKey: key, now: now, deviceRecordChanged: false,
                                                     standing: standing)))
        }
        // `bad`'s record says incompatible and its file holds a vector: it does not count as one.
        var snap = InsightsSnapshot()
        let record = InsightsDeviceRecord(device: bad, written: Int64(now.timeIntervalSince1970 * 1000), os: "27.2", platform: "ios",
                                          model: .init(available: false, reason: nil, identity: nil), supported: ["en": [1]],
                                          canaries: [], compatibility: "incompatible", against: nil)
        snap.devices[bad] = record
        snap.notes[note.id] = [bad: InsightsNoteFile(noteId: note.id, device: bad, written: 1,
                                                     emb: .init(hash: note.hash, key: key, vector: [0.5, 0.5]))]
        XCTAssertFalse(snap.hasCurrentEmb(for: note.id, hash: note.hash, key: key))
        XCTAssertNil(snap.emb(for: note.id, key: key, hash: note.hash))
        XCTAssertNotNil(snap.emb(for: note.id, from: bad), "its own file is still its own")
        XCTAssertTrue(embeds(InsightsPolicy.plan(notes: [note], snapshot: snap, me: me, settings: settings, capabilities: caps,
                                                 pinKey: key, now: now, deviceRecordChanged: false)),
                      "a compatible device embeds although the incompatible one holds a vector")
        // Once the device is compatible its vector counts.
        snap.devices[bad]?.compatibility = "compatible"
        XCTAssertTrue(snap.hasCurrentEmb(for: note.id, hash: note.hash, key: key))
    }

    /// End to end: a device whose embedder drifts is incompatible with A's map, writes no vector and builds no map, and
    /// A's map holds only A's vectors.
    func testADriftingDeviceKeepsItsVectorsLocal() async throws {
        let id1 = try note("P0", Self.physics[0]), id2 = try note("P1", Self.physics[1]), id3 = try note("P2", Self.physics[2])
        _ = try await run(a, model: nil)
        let drift = FakeEmbeddingProvider(perturbation: 0.05)
        let later = now.addingTimeInterval(3600)
        let rb = try await run(b, model: nil, embedder: drift, at: later) { $0.force = false }
        XCTAssertEqual(rb.embedded, [])
        XCTAssertFalse(rb.mapBuilt)
        let snap = InsightsStore(vault: a).snapshot()
        XCTAssertEqual(snap.devices[meB]?.compatibility, "incompatible")
        for id in [id1, id2, id3] {
            XCTAssertNil(snap.notes[id]?[meB]?.emb, "no shared vector from the incompatible device")
            XCTAssertNotNil(snap.notes[id]?[meA]?.emb)
        }
        XCTAssertNil(snap.map(of: meB))
        let built = try XCTUnwrap(snap.map(of: meA))
        XCTAssertEqual(built.built?.notes, 3)
    }

    /// A device that turns incompatible has its record say so after its very next pass (not up to a day later), so readers
    /// stop counting its vectors at once.
    func testADeviceThatTurnsIncompatibleRewritesItsRecordAtOnce() async throws {
        try note("P0", Self.physics[0]); try note("P1", Self.physics[1]); try note("P2", Self.physics[2])
        _ = try await run(a, model: nil)
        _ = try await run(b, model: nil, at: now.addingTimeInterval(60))
        XCTAssertEqual(InsightsStore(vault: a).snapshot().devices[meB]?.compatibility, "compatible")
        // B's embedder drifts; the pass is well inside the daily record interval.
        _ = try await run(b, model: nil, embedder: FakeEmbeddingProvider(perturbation: 0.05), at: now.addingTimeInterval(120))
        let snap = InsightsStore(vault: a).snapshot()
        XCTAssertEqual(snap.devices[meB]?.compatibility, "incompatible")
        XCTAssertTrue(snap.incompatibleDevices.contains(meB))
    }

    /// A map at another language's key does not make a device at the pinned key see "no map" (it would rebuild every pass).
    func testBestMapByKeyIgnoresAMapOfAnotherKey() {
        var snap = InsightsSnapshot()
        let en = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let es = EmbeddingKey(model: "nl-sentence", lang: "es", rev: 1, input: 1)
        let other = DeviceID("22222222")!
        snap.maps[other] = InsightsMapFile(device: other, written: 5, key: es, dim: 2, canaries: nil, mean: [0, 0], clusters: [],
                                           layout: [:], built: nil)
        XCTAssertNil(snap.bestMap(key: en), "no map at the key")
        XCTAssertEqual(snap.bestMap(rev: 1)?.device, other, "readers fall back by revision")
        XCTAssertEqual(snap.bestMap(rev: 1, language: "en")?.device, other, "and then to any map")
        let me = DeviceID("11111111")!
        snap.maps[me] = InsightsMapFile(device: me, written: 1, key: en, dim: 2, canaries: nil, mean: [0, 0], clusters: [],
                                        layout: [:], built: nil)
        XCTAssertEqual(snap.bestMap(rev: 1, language: "en")?.device, me, "the language's map first, though older")
        XCTAssertEqual(snap.bestMap(key: en)?.device, me)
        let note = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-3600), deleted: false,
                              hasText: true)
        snap.notes[note.id] = [me: InsightsNoteFile(noteId: note.id, device: me, written: 1,
                                                    emb: .init(hash: note.hash, key: en, vector: [0.5, 0.5]))]
        let plan = InsightsPolicy.plan(notes: [note], snapshot: snap, me: me, settings: InsightsSettings(enabled: true),
                                       capabilities: .init(model: nil, embedRevision: 1, powerWindow: true), pinKey: en, now: now,
                                       deviceRecordChanged: false)
        XCTAssertTrue(plan.contains(.rebuildMap), "a new note is not in the map at this key")
    }

    func testIgnoreSettleSkipsTheSettleTimeButNotOpenNotes() {
        let me = DeviceID("11111111")!
        let fresh = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-60), deleted: false,
                               hasText: true)
        var open = fresh; open.id = UUID(); open.open = true
        let caps = PolicyCapabilities(model: .init(model: "m", os: "27.2", prompt: 2), embedRevision: nil, powerWindow: true)
        let settings = InsightsSettings(enabled: true)
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [fresh, open], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: caps, pinKey: nil, now: now, deviceRecordChanged: false)), [])
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [fresh, open], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: caps, pinKey: nil, now: now, ignoreSettle: true,
                                                     deviceRecordChanged: false)), [fresh.id])
    }

    // MARK: Two updaters on one vault

    func testTwoDevicesGenerateTheSameNoteAndEachKeepsItsFile() async throws {
        let id = try note("Springs", Self.physics[0])
        // B works on its own copy of the vault (the sync delay: neither has seen the other's file yet).
        let copy = tmp.appendingPathComponent("B.sempere")
        try FileManager.default.copyItem(at: a.url, to: copy)
        let bCopy = try TestVaults.open(at: copy, identity: ib)
        let ins = try inputs()
        var o = InsightsUpdateOptions(); o.now = now; o.platform = .init(platform: "ios", os: "27.2")
        let repA = try await InsightsUpdater(vault: a, model: model(), embedder: FakeEmbeddingProvider(), deviceState: stateA,
                                             app: "test/1").run(o, notes: ins)
        let repB = try await InsightsUpdater(vault: bCopy, model: model(), embedder: FakeEmbeddingProvider(), deviceState: stateB,
                                             app: "test/1").run(o, notes: ins)
        XCTAssertEqual(repA.generated, [id.uuidString.lowercased()])
        XCTAssertEqual(repB.generated, [id.uuidString.lowercased()])
        XCTAssertEqual(repA.embedded, [id.uuidString.lowercased()])
        XCTAssertEqual(repB.embedded, [id.uuidString.lowercased()], "B has not seen A's vector: it makes the same one")
        // B's files arrive (a sync places them as they are).
        for name in InsightsStore.names(in: bCopy.insightsURL) where name.fileName.contains(meB.rawValue) {
            let to = a.insightsURL.appendingPathComponent(name.fileName)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: bCopy.insightsURL.appendingPathComponent(name.fileName), to: to)
        }
        let snap = InsightsStore(vault: a).snapshot()
        XCTAssertNotNil(snap.notes[id]?[meA]?.gen, "A's file survives")
        XCTAssertNotNil(snap.notes[id]?[meB]?.gen, "B's file survives")
        XCTAssertEqual(snap.notes[id]?[meA]?.emb, snap.notes[id]?[meB]?.emb, "bit-identical vectors on every device")
        let status = InsightsReader(vault: a).status(inputs: try inputs(), me: meA, embedder: nil, now: now)
        XCTAssertEqual(status.processed, 1, "counted once")
        XCTAssertEqual(status.notes, 1)
    }

    func testOnceAnotherDevicesSummaryIsVisibleNoneIsMade() async throws {
        let id = try note("Springs", Self.physics[0])
        let first = try await run(a, model: model())
        XCTAssertEqual(first.generated, [id.uuidString.lowercased()])
        let second = try await run(b, model: model())
        XCTAssertEqual(second.generated, [], "current on A")
        XCTAssertEqual(second.embedded, [])
        XCTAssertFalse(second.mapBuilt, "A's map is current")
        XCTAssertNil(InsightsStore(vault: a).snapshot().notes[id]?[meB]?.gen)
    }

    func testASecondDeviceDoesNotRedoWhatTheFirstDid() async throws {
        for (i, t) in Self.physics.enumerated() { try note("P\(i)", t, notebook: "Physics") }
        let r = try await run(b, model: model())
        XCTAssertEqual(r.generated.count, 3)
        XCTAssertEqual(r.embedded.count, 3, "any device with the embedder embeds")
        XCTAssertTrue(r.mapBuilt)
        XCTAssertEqual(r.pinSet, ["en": 1])
        XCTAssertEqual(r.topics, ["notebook:Physics"], "any device with the model makes topics")
        XCTAssertNotNil(InsightsStore(vault: a).snapshot().map(of: meB))
        // A makes nothing again: summaries, vectors and the map of B are current, and so is B's topic.
        let w = try await run(a, model: model())
        XCTAssertEqual(w.generated, [])
        XCTAssertEqual(w.embedded, [])
        XCTAssertFalse(w.mapBuilt)
        XCTAssertEqual(w.topics, [], "B's topic is current")
        let reader = InsightsReader(vault: a)
        XCTAssertEqual(reader.snapshot.bestMap()?.device, meB)
        let ins = try inputs()
        let status = reader.status(inputs: ins, me: meA, embedder: FakeEmbeddingProvider(), now: now)
        XCTAssertEqual(status.map?.device, meB.rawValue)
        XCTAssertEqual(status.compatibility, "compatible", "A reads B's map; no role either way")
        XCTAssertEqual(reader.related(try XCTUnwrap(ins.first), inputs: ins, me: meA, embedder: FakeEmbeddingProvider()).basis, "vectors")
    }

    func testMixedOSMajorsRegenerateOnceThenStop() async throws {
        let id = try note("Springs", Self.physics[0])
        let a1 = try await run(a, model: model(os: "27.2"))
        XCTAssertEqual(a1.generated, [id.uuidString.lowercased()])
        let b1 = try await run(b, model: model(os: "28.0"))
        XCTAssertEqual(b1.generated, [id.uuidString.lowercased()], "A's summary is of another OS major: B makes its own")
        let a2 = try await run(a, model: model(os: "27.2"), at: now.addingTimeInterval(3600))
        XCTAssertEqual(a2.generated, [])
        let b2 = try await run(b, model: model(os: "28.0"), at: now.addingTimeInterval(3600))
        XCTAssertEqual(b2.generated, [])
        let snap = InsightsStore(vault: a).snapshot()
        XCTAssertNotNil(snap.notes[id]?[meA]?.gen)
        XCTAssertNotNil(snap.notes[id]?[meB]?.gen)
    }

    func testTopicsAreJudgedAgainstEveryDevicesLatest() async throws {
        for (i, t) in Self.bread.enumerated() { try note("B\(i)", t, notebook: "Kitchen") }
        let ra = try await run(a, model: model())
        XCTAssertEqual(ra.topics, ["notebook:Kitchen"])
        let rb = try await run(b, model: model(), at: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(rb.topics, [], "A's topic is current for these members, however old")
        XCTAssertNil(InsightsStore(vault: a).snapshot().topics[meB])
        // Of another OS major, a day old: B makes one once, and A does not answer with another.
        let r28 = try await run(b, model: model(os: "28.0"), at: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(r28.topics, ["notebook:Kitchen"])
        let again = try await run(a, model: model(), at: now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(again.topics, [], "A's own topic is still current for A")
    }

    // MARK: Races settle (D21)

    /// Copies every insights file and note revision `from` has and `to` lacks (a sync that delivers all of them).
    func deliver(from: Vault, to: Vault) throws {
        let fm = FileManager.default
        func copy(_ src: URL, _ dst: URL, replace: Bool) throws {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where !name.hasPrefix(".") {
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: src.appendingPathComponent(name).path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                let target = dst.appendingPathComponent(name)
                // Insights files are replaced whole by their writer; revisions are write-once.
                if fm.fileExists(atPath: target.path) { if !replace { continue }; try fm.removeItem(at: target) }
                try fm.copyItem(at: src.appendingPathComponent(name), to: target)
            }
        }
        try copy(from.insightsURL, to.insightsURL, replace: true)
        let notes = from.url.appendingPathComponent("notes")
        for id in (try? fm.contentsOfDirectory(atPath: notes.path)) ?? [] where !id.hasPrefix(".") {
            try copy(notes.appendingPathComponent(id), to.url.appendingPathComponent("notes/\(id)"), replace: false)
        }
    }

    /// Two devices that rebuild the map at once from the same vectors, summaries and previous map write the same map
    /// (apart from who and when), so which one readers take changes nothing they show.
    func testConcurrentMapRebuildsAreIdenticalAndEveryReaderPicksTheSameOne() async throws {
        for (i, t) in (Self.physics + Self.bread).enumerated() { try note("N\(i)", t, notebook: i < 3 ? "Physics" : "Kitchen") }
        let copy = tmp.appendingPathComponent("B.sempere")
        try FileManager.default.copyItem(at: a.url, to: copy)
        let bCopy = try TestVaults.open(at: copy, identity: ib)
        let ins = try inputs()
        var o = InsightsUpdateOptions(); o.now = now; o.platform = .init(platform: "ios", os: "27.2")
        let repA = try await InsightsUpdater(vault: a, model: model(), embedder: FakeEmbeddingProvider(), deviceState: stateA,
                                             app: "test/1").run(o, notes: ins)
        o.now = now.addingTimeInterval(5)   // B's clock differs: the map content must not
        let repB = try await InsightsUpdater(vault: bCopy, model: model(), embedder: FakeEmbeddingProvider(), deviceState: stateB,
                                             app: "test/1").run(o, notes: ins)
        XCTAssertTrue(repA.mapBuilt)
        XCTAssertTrue(repB.mapBuilt)
        let mapA = try XCTUnwrap(InsightsStore(vault: a).snapshot().maps[meA])
        let mapB = try XCTUnwrap(InsightsStore(vault: bCopy).snapshot().maps[meB])
        func content(_ m: InsightsMapFile) -> InsightsMapFile {
            var c = m; c.device = "00000000"; c.written = 0
            return c
        }
        XCTAssertEqual(content(mapA), content(mapB), "same inputs, same map")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(content(mapA)), try encoder.encode(content(mapB)), "byte for byte")
        // Both maps reach both devices: every reader takes the same one, and nobody rebuilds.
        try deliver(from: bCopy, to: a)
        try deliver(from: a, to: bCopy)
        let pickA = InsightsStore(vault: a).snapshot().bestMap()
        let pickB = InsightsStore(vault: bCopy).snapshot().bestMap()
        XCTAssertEqual(pickA?.device, pickB?.device)
        XCTAssertEqual(pickA?.device, meB, "the later written wins")
        let showA = InsightsReader(vault: a).mapView(inputs: try inputs(), me: meA, embedder: FakeEmbeddingProvider())
        let showB = InsightsReader(vault: bCopy).mapView(inputs: try inputs(), me: meB, embedder: FakeEmbeddingProvider())
        XCTAssertEqual(showA.nodes, showB.nodes)
        XCTAssertEqual(showA.clusters, showB.clusters)
        o.now = now.addingTimeInterval(3600)
        let againA = try await InsightsUpdater(vault: a, model: model(), embedder: FakeEmbeddingProvider(), deviceState: stateA,
                                               app: "test/1").run(o, notes: ins)
        XCTAssertFalse(againA.mapBuilt)
        XCTAssertEqual(againA.generated, [])
        XCTAssertEqual(againA.embedded, [])
    }

    /// Two devices that summarize one note before they see each other's file: every reader takes the same one by the
    /// fixed order (later `written`, then device id), and neither device summarizes again.
    func testARaceOnASummarySettlesTheSameOnEveryReader() async throws {
        let id = try note("Springs", Self.physics[0])
        let copy = tmp.appendingPathComponent("B.sempere")
        try FileManager.default.copyItem(at: a.url, to: copy)
        let bCopy = try TestVaults.open(at: copy, identity: ib)
        let ins = try inputs()
        var o = InsightsUpdateOptions(); o.now = now; o.platform = .init(platform: "ios", os: "27.2")
        _ = try await InsightsUpdater(vault: a, model: model(), embedder: nil, deviceState: stateA, app: "test/1").run(o, notes: ins)
        _ = try await InsightsUpdater(vault: bCopy, model: model(), embedder: nil, deviceState: stateB, app: "test/1").run(o, notes: ins)
        try deliver(from: bCopy, to: a)
        try deliver(from: a, to: bCopy)
        let hash = try XCTUnwrap(ins.first { $0.id == id }?.hash)
        let bestA = try XCTUnwrap(InsightsStore(vault: a).snapshot().bestGen(for: id, hash: hash, now: now))
        let bestB = try XCTUnwrap(InsightsStore(vault: bCopy).snapshot().bestGen(for: id, hash: hash, now: now))
        XCTAssertEqual(bestA.device, bestB.device)
        XCTAssertTrue(bestA.current)
        for round in 1...2 {
            o.now = now.addingTimeInterval(Double(round) * 3600)
            let ra = try await InsightsUpdater(vault: a, model: model(), embedder: nil, deviceState: stateA, app: "test/1").run(o, notes: ins)
            let rb = try await InsightsUpdater(vault: bCopy, model: model(), embedder: nil, deviceState: stateB, app: "test/1").run(o, notes: ins)
            XCTAssertEqual(ra.generated + rb.generated, [], "settled: nobody summarizes again")
            XCTAssertEqual(InsightsStore(vault: a).snapshot().bestGen(for: id, hash: hash, now: now)?.device, bestA.device, "never flips")
        }
    }

    // MARK: Voice-note titles (D21)

    func capture(transcript text: String) throws -> UUID {
        let w = try CaptureWriter(profile: try a.captureProfile(device: meA))
        let id = UUID()
        let audio = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let started = Date(timeIntervalSince1970: 1_789_990_000)
        try CaptureWriter.store(try w.seal(audio: audio, started: started, title: "Voice note 2026-09-21 10:46", id: id), in: a.inboxURL)
        let t = TranscriptBuilder.transcript(recording: CaptureAdoption.ids(for: id).recording, engine: "e", language: "en-US",
                                             created: started, segments: [.init(start: 0, end: 4, text: text)])
        try CaptureWriter.store(try w.seal(transcript: t, capture: id, audio: BlobRef(content: audio, type: "audio/mp4")), in: a.inboxURL)
        XCTAssertNil(try a.adoptCapture(id, deviceState: stateA, app: "test/1", now: now).error)
        return CaptureAdoption.ids(for: id).note
    }

    func title(_ id: UUID, in vault: Vault) throws -> String { try vault.reconstruct(noteId: id).meta.title }

    /// A device without the embedder titles a voice note: no role to hold.
    func testAnyDeviceTitlesAVoiceNoteOnceAndTheOtherLeavesItAlone() async throws {
        let base = Date()   // the adoption's revision is stamped with the real clock: titles must come after it
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        let first = try await run(b, model: model(), embedder: nil, at: base.addingTimeInterval(60)) { $0.force = true }
        XCTAssertEqual(first.titled, [id.uuidString.lowercased()])
        let titled = try title(id, in: a)
        XCTAssertEqual(titled, "2026-09-21 10.46 Spring Lab Results Show")
        let second = try await run(a, model: model()) { $0.force = true }
        XCTAssertEqual(second.titled + second.restoredTitles, [], "applied at most once: no longer the capture default")
        XCTAssertEqual(try title(id, in: a), titled)
    }

    /// Two devices title one voice note before they see each other's title (their summaries differ): the register's last
    /// writer stays, and neither device takes the other's automatic title for a user's rename and flips it.
    func testTwoDevicesTitlingOneNoteSettleOnTheLastWriter() async throws {
        let base = Date()   // the adoption's revision is stamped with the real clock: titles must come after it
        let id = try capture(transcript: "Spring lab results show the damping ratio near critical damping.")
        let copy = tmp.appendingPathComponent("B.sempere")
        try FileManager.default.copyItem(at: a.url, to: copy)
        let bCopy = try TestVaults.open(at: copy, identity: ib)
        var wordsA = FakeModelProvider.Script(); wordsA.titleWords = 4
        var wordsB = FakeModelProvider.Script(); wordsB.titleWords = 3
        var o = InsightsUpdateOptions(); o.now = base; o.platform = .init(platform: "ios", os: "27.2"); o.force = true
        let ins = try inputs()
        let ra = try await InsightsUpdater(vault: a, model: FakeModelProvider(wordsA), embedder: nil, deviceState: stateA, app: "test/1")
            .run(o, notes: ins)
        o.now = base.addingTimeInterval(10)
        let rb = try await InsightsUpdater(vault: bCopy, model: FakeModelProvider(wordsB), embedder: nil, deviceState: stateB, app: "test/1")
            .run(o, notes: ins)
        XCTAssertEqual(ra.titled, [id.uuidString.lowercased()])
        XCTAssertEqual(rb.titled, [id.uuidString.lowercased()])
        XCTAssertNotEqual(try title(id, in: a), try title(id, in: bCopy), "each saw only its own title")
        try deliver(from: bCopy, to: a)
        try deliver(from: a, to: bCopy)
        let settled = try title(id, in: a)
        XCTAssertEqual(try title(id, in: bCopy), settled, "one register, one winner on every reader")
        for round in 1...2 {
            o.now = base.addingTimeInterval(Double(round) * 3600)
            let xa = try await InsightsUpdater(vault: a, model: FakeModelProvider(wordsA), embedder: nil, deviceState: stateA,
                                               app: "test/1").run(o, notes: ins)
            let xb = try await InsightsUpdater(vault: bCopy, model: FakeModelProvider(wordsB), embedder: nil, deviceState: stateB,
                                               app: "test/1").run(o, notes: ins)
            XCTAssertEqual(xa.titled + xa.restoredTitles + xb.titled + xb.restoredTitles, [], "no flip-flop")
            XCTAssertEqual(try title(id, in: a), settled)
        }
    }

    // MARK: Process Now

    func testAForcedPassSkipsTheSettleTimeAndEarlierBackOff() async throws {
        let fresh = try note("Fresh", Self.physics[0], modified: now.addingTimeInterval(-60))
        let failed = try note("Failed", Self.bread[0])
        let memoURL = try TestTemp.directory("forced-memo").appendingPathComponent("failures")
        var memo = InsightsFailureMemo()
        let m = model()
        let hash = try XCTUnwrap(try inputs().first { $0.id == failed }?.hash)
        memo.record(note: failed, hash: hash, identity: m.identity, error: InsightsProviderError.failed("the model said no"),
                    now: now.addingTimeInterval(-300))
        try memo.save(to: memoURL, vault: b)
        let plain = try await run(b, model: m) { $0.failureMemo = memoURL }
        XCTAssertEqual(plain.generated, [])
        XCTAssertEqual(plain.backedOff, 1)
        XCTAssertEqual(plain.backedOffReason, "the model failed: the model said no")
        XCTAssertEqual(plain.waitingToSettle, 1)
        XCTAssertEqual(InsightsPassOutcome.of([plain], availability: .available),
                       .backedOff(count: 1, reason: "the model failed: the model said no"))
        // An open note still waits under Process Now.
        let forced = try await run(b, model: m) {
            $0.failureMemo = memoURL; $0.ignoreSettle = true; $0.ignoreBackoffBefore = self.now; $0.openNotes = [fresh]
        }
        XCTAssertEqual(forced.generated, [failed.uuidString.lowercased()])
        XCTAssertEqual(forced.waitingOpen, 1)
        XCTAssertNil(InsightsPassOutcome.of([forced], availability: .available), "it made something")
        let closed = try await run(b, model: m) { $0.failureMemo = memoURL; $0.ignoreSettle = true; $0.ignoreBackoffBefore = self.now }
        XCTAssertEqual(closed.generated, [fresh.uuidString.lowercased()])
        let done = try await run(b, model: m) { $0.failureMemo = memoURL; $0.ignoreSettle = true; $0.ignoreBackoffBefore = self.now }
        XCTAssertEqual(InsightsPassOutcome.of([done], availability: .available), .nothingToDo)
    }

    func testAFailureDuringTheForcedPassWaitsAndIsReported() async throws {
        try note("Springs", Self.physics[0])
        let memoURL = try TestTemp.directory("forced-fail").appendingPathComponent("failures")
        var s = FakeModelProvider.Script(); s.failures = 100
        let failing = FakeModelProvider(s)
        let start = now
        let first = try await run(b, model: failing) { $0.failureMemo = memoURL; $0.ignoreSettle = true; $0.ignoreBackoffBefore = start }
        XCTAssertEqual(first.failures.count, 1)
        let second = try await run(b, model: failing, at: now.addingTimeInterval(1)) {
            $0.failureMemo = memoURL; $0.ignoreSettle = true; $0.ignoreBackoffBefore = start
        }
        XCTAssertEqual(second.failures, [:], "failed during this pass: not asked again in its next run")
        XCTAssertEqual(second.backedOff, 1)
        guard case .failed(let count, let reason)? = InsightsPassOutcome.of([first, second], availability: .available) else {
            return XCTFail("a failed outcome")
        }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(reason.contains("scripted failure"), reason)
        XCTAssertEqual(InsightsFailureMemo.load(from: memoURL, vault: b).reason(note: try inputs()[0].id), reason, "the first error is kept")
    }

    func testOutcomes() {
        XCTAssertEqual(InsightsPassOutcome.of([], availability: .available), nil)
        var r = InsightsUpdateReport()
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .disabled), .modelUnavailable(.disabled))
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: nil), .modelUnavailable(nil))
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .available), .nothingToDo)
        r.waitingOpen = 2
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .available), .noteOpen(2))
        r.waitingToSettle = 1
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .available), .waitingToSettle(1))
        r.cancelled = true
        XCTAssertNil(InsightsPassOutcome.of([r], availability: .available), "cut off: says nothing")
        r.cancelled = false
        r.waitingOpen = 0; r.waitingToSettle = 0
        r.failures = ["notebook:Kitchen": "nothing survived the fact check"]
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .available), .nothingToDo, "a topic's failure is no note's")
        let note = UUID().uuidString.lowercased()
        r.failures[note] = "boom"
        XCTAssertEqual(InsightsPassOutcome.of([r], availability: .available), .failed(count: 1, reason: "boom"))
        r.topics = ["tag:x"]
        XCTAssertNil(InsightsPassOutcome.of([r], availability: .available))
    }

    func testTheMemosReasonIsCappedInBytes() {
        var memo = InsightsFailureMemo()
        let id = UUID()
        let long = String(repeating: "é", count: 200)   // two bytes each
        memo.record(note: id, hash: "h", identity: GenerationIdentity(model: "m", os: "1", prompt: 2),
                    error: InsightsProviderError.failed(long), now: now)
        let reason = try? XCTUnwrap(memo.reason(note: id))
        XCTAssertLessThanOrEqual(reason?.utf8.count ?? 999, 120)
        XCTAssertGreaterThan(reason?.utf8.count ?? 0, 100)
    }
}
