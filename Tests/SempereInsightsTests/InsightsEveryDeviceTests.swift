import Age
import Foundation
import Sempere
import TempDirSupport
import VaultTestSupport
import XCTest
@testable import SempereInsights

/// Every device with Apple's model makes summaries and keywords (D13 as changed for 1.2: the owner's iPhone pressed
/// "Process Now" and got "0 of 10"); embeddings, the map and voice-note titles stay with the work device. Two devices
/// of one vault, A (home) and B, each with its own updater: per-device files, `currentElsewhere`, OS majors, topics, the
/// self-healing claim of a work device not seen for 14 days, and what a pass that makes nothing says (`InsightsPassOutcome`).
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

    func setWorkDevice(_ d: DeviceID?) throws { try InsightsSettingsWrite.setWorkDevice(d, vault: a, now: now) }

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

    func testANonWorkDeviceWithTheModelGeneratesButNeverEmbedsOrMaps() {
        let me = DeviceID("11111111")!, work = DeviceID("22222222")!
        let note = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-3600), deleted: false,
                              hasText: true)
        let settings = InsightsSettings(enabled: true, workDevice: work)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        let model = GenerationIdentity(model: "m", os: "27.2", prompt: 2)
        let plan = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                       capabilities: .init(model: model, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                       deviceRecordChanged: false)
        XCTAssertEqual(generates(plan), [note.id])
        XCTAssertFalse(embeds(plan))
        XCTAssertFalse(plan.contains(.rebuildMap))
        XCTAssertFalse(plan.contains(.claimWorkDevice))
        // Embed-only (no model) and not the work device: nothing to do but its record.
        let embedOnly = InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                            capabilities: .init(model: nil, embedRevision: 1, powerWindow: true), pinKey: key, now: now,
                                            deviceRecordChanged: false)
        XCTAssertEqual(embedOnly.filter { $0 != .writeDeviceRecord }, [])
        // Off power: nothing generated.
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [note], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: .init(model: model, embedRevision: nil, powerWindow: false), pinKey: nil,
                                                     now: now, deviceRecordChanged: false)), [])
        // A note current on another device is not generated again.
        var snap = InsightsSnapshot()
        let gen = InsightsNoteFile.Gen(hash: note.hash, identity: model, summary: "s", keywords: [], concepts: [], dropped: 0)
        snap.notes[note.id] = [work: InsightsNoteFile(noteId: note.id, device: work, written: 1, gen: gen)]
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [note], snapshot: snap, me: me, settings: settings,
                                                     capabilities: .init(model: model, embedRevision: nil, powerWindow: true), pinKey: nil,
                                                     now: now, deviceRecordChanged: false)), [])
    }

    func testIgnoreSettleSkipsTheSettleTimeButNotOpenNotes() {
        let me = DeviceID("11111111")!
        let fresh = PolicyNote(id: UUID(), hash: String(repeating: "a", count: 32), modified: now.addingTimeInterval(-60), deleted: false,
                               hasText: true)
        var open = fresh; open.id = UUID(); open.open = true
        let caps = PolicyCapabilities(model: .init(model: "m", os: "27.2", prompt: 2), embedRevision: nil, powerWindow: true)
        let settings = InsightsSettings(enabled: true, workDevice: DeviceID("22222222")!)
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [fresh, open], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: caps, pinKey: nil, now: now, deviceRecordChanged: false)), [])
        XCTAssertEqual(generates(InsightsPolicy.plan(notes: [fresh, open], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                                     capabilities: caps, pinKey: nil, now: now, ignoreSettle: true,
                                                     deviceRecordChanged: false)), [fresh.id])
    }

    func testAMissingWorkDeviceIsClaimed() {
        let me = DeviceID("11111111")!, work = DeviceID("22222222")!
        let settings = InsightsSettings(enabled: true, workDevice: work)
        let caps = PolicyCapabilities(model: nil, embedRevision: 1, powerWindow: true)
        let key = EmbeddingKey(model: "nl-sentence", lang: "en", rev: 1, input: 1)
        XCTAssertFalse(InsightsPolicy.plan(notes: [], snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                           pinKey: key, now: now, deviceRecordChanged: false).contains(.claimWorkDevice))
        XCTAssertTrue(InsightsPolicy.plan(notes: [], snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: caps,
                                          pinKey: key, now: now, workDeviceMissing: true, deviceRecordChanged: false).contains(.claimWorkDevice))
        XCTAssertFalse(InsightsPolicy.plan(notes: [], snapshot: InsightsSnapshot(), me: me, settings: settings,
                                           capabilities: .init(model: nil, embedRevision: nil, powerWindow: true), pinKey: nil, now: now,
                                           workDeviceMissing: true, deviceRecordChanged: false).contains(.claimWorkDevice),
                       "a device that can do none of the work does not claim it")
        // A device with the model but no embedder at the pin never takes the map and titles role, missing holder or none.
        let modelOnly = PolicyCapabilities(model: .init(model: "m", os: "27.2", prompt: 2), embedRevision: nil, powerWindow: true)
        XCTAssertFalse(InsightsPolicy.plan(notes: [], snapshot: InsightsSnapshot(), me: me, settings: settings, capabilities: modelOnly,
                                           pinKey: nil, now: now, workDeviceMissing: true, deviceRecordChanged: false).contains(.claimWorkDevice))
        XCTAssertFalse(InsightsPolicy.plan(notes: [], snapshot: InsightsSnapshot(), me: me, settings: InsightsSettings(enabled: true),
                                           capabilities: modelOnly, pinKey: nil, now: now, deviceRecordChanged: false).contains(.claimWorkDevice))
    }

    func testAWorkDeviceNoLongerListedIsMissingAtOnce() {
        let w = DeviceID("22222222")!
        let settings = InsightsSettings(enabled: true, workDevice: w, workDeviceSetAt: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertFalse(WorkDeviceStatus(settings: settings, snapshot: InsightsSnapshot(), listed: [w], language: "en", now: now).notSeen)
        XCTAssertTrue(WorkDeviceStatus(settings: settings, snapshot: InsightsSnapshot(), listed: [], language: "en", now: now).notSeen,
                      "removed from the list: missing the same day it was designated")
    }

    // MARK: Two updaters on one vault

    func testTwoDevicesGenerateTheSameNoteAndEachKeepsItsFile() async throws {
        let id = try note("Springs", Self.physics[0])
        try setWorkDevice(meA)
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
        XCTAssertTrue(repB.embedded.isEmpty, "B is not the work device: no vectors")
        XCTAssertFalse(repB.mapBuilt)
        // B's files arrive (a sync places them as they are).
        for name in InsightsStore.names(in: bCopy.insightsURL) where name.fileName.contains(meB.rawValue) {
            let to = a.insightsURL.appendingPathComponent(name.fileName)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: bCopy.insightsURL.appendingPathComponent(name.fileName), to: to)
        }
        let snap = InsightsStore(vault: a).snapshot()
        XCTAssertNotNil(snap.notes[id]?[meA]?.gen, "A's file survives")
        XCTAssertNotNil(snap.notes[id]?[meB]?.gen, "B's file survives")
        XCTAssertNil(snap.notes[id]?[meB]?.emb)
        let status = InsightsReader(vault: a).status(inputs: try inputs(), me: meA, embedder: nil, now: now)
        XCTAssertEqual(status.processed, 1, "counted once")
        XCTAssertEqual(status.notes, 1)
    }

    func testOnceAnotherDevicesSummaryIsVisibleNoneIsMade() async throws {
        let id = try note("Springs", Self.physics[0])
        try setWorkDevice(meA)
        let first = try await run(a, model: model())
        XCTAssertEqual(first.generated, [id.uuidString.lowercased()])
        let second = try await run(b, model: model())
        XCTAssertEqual(second.generated, [], "current on A")
        XCTAssertEqual(second.embedded, [])
        XCTAssertNil(InsightsStore(vault: a).snapshot().notes[id]?[meB]?.gen)
    }

    func testANonWorkDeviceGeneratesWithoutAMapAndWorkDeviceThingsStayPut() async throws {
        for (i, t) in Self.physics.enumerated() { try note("P\(i)", t, notebook: "Physics") }
        try setWorkDevice(meA)
        let r = try await run(b, model: model())
        XCTAssertEqual(r.generated.count, 3)
        XCTAssertEqual(r.embedded, [])
        XCTAssertFalse(r.mapBuilt)
        XCTAssertFalse(r.claimedWorkDevice)
        XCTAssertEqual(r.pinSet, [:])
        XCTAssertEqual(r.topics, ["notebook:Physics"], "any device with the model makes topics")
        XCTAssertEqual(InsightsSettings.read(a).workDevice, meA)
        XCTAssertNil(InsightsStore(vault: a).snapshot().map(of: meB))
        // A, the work device, embeds and maps but makes no summary again, and no topic while B's is current.
        let w = try await run(a, model: model())
        XCTAssertEqual(w.generated, [])
        XCTAssertEqual(w.embedded.count, 3)
        XCTAssertTrue(w.mapBuilt)
        XCTAssertEqual(w.topics, [], "B's topic is current")
    }

    func testMixedOSMajorsRegenerateOnceThenStop() async throws {
        let id = try note("Springs", Self.physics[0])
        try setWorkDevice(meA)
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
        try setWorkDevice(meA)
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

    // MARK: Self-healing

    func testACapableDeviceTakesOverAWorkDeviceNotSeenFor14Days() async throws {
        try note("Springs", Self.physics[0])
        try setWorkDevice(meA)
        _ = try await run(a, model: model())
        // Thirteen days on: A is still the work device.
        let early = try await run(b, model: model(), at: now.addingTimeInterval(13 * 86_400))
        XCTAssertFalse(early.claimedWorkDevice)
        XCTAssertEqual(InsightsSettings.read(a).workDevice, meA)
        // Fifteen days on: B claims it through the settings merge, and embeds and maps in that pass.
        let late = try await run(b, model: model(), at: now.addingTimeInterval(15 * 86_400))
        XCTAssertTrue(late.claimedWorkDevice)
        XCTAssertEqual(InsightsSettings.read(a).workDevice, meB)
        XCTAssertEqual(late.embedded.count, 1)
        XCTAssertTrue(late.mapBuilt)
    }

    func testAModelOnlyDeviceNeverTakesOverAMissingWorkDevice() async throws {
        try note("Springs", Self.physics[0])
        try setWorkDevice(meA)
        _ = try await run(a, model: model())
        let late = try await run(b, model: model(), embedder: nil, at: now.addingTimeInterval(15 * 86_400)) { $0.force = true }
        XCTAssertFalse(late.claimedWorkDevice)
        XCTAssertEqual(InsightsSettings.read(a).workDevice, meA)
        XCTAssertEqual(late.generated.count, 1, "it still summarizes")
        XCTAssertFalse(late.mapBuilt)
    }

    func testARemovedWorkDeviceIsTakenOverAtOnce() async throws {
        try note("Springs", Self.physics[0])
        try setWorkDevice(DeviceID("0000beef")!)   // not in the device list
        let r = try await run(b, model: model())
        XCTAssertTrue(r.claimedWorkDevice)
        XCTAssertEqual(InsightsSettings.read(a).workDevice, meB)
        XCTAssertTrue(r.mapBuilt)
    }

    // MARK: Process Now

    func testAForcedPassSkipsTheSettleTimeAndEarlierBackOff() async throws {
        let fresh = try note("Fresh", Self.physics[0], modified: now.addingTimeInterval(-60))
        let failed = try note("Failed", Self.bread[0])
        try setWorkDevice(meA)
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
        try setWorkDevice(meA)
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
