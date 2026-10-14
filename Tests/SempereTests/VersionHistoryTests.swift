import Foundation
import XCTest
@testable import Sempere

/// Checkpoints, editing sessions, positioned snapshots and thinning
/// (format.md §5.8).
final class VersionHistoryTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!

    private func decode(_ json: String) throws -> Revision {
        try InkJSON.decoder().decode(Revision.self, from: Data(json.utf8))
    }

    private func object(_ r: Revision) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: InkJSON.encoder().encode(r)) as? [String: Any])
    }

    // MARK: Format round trip (§5.1)

    func testDeltaFieldsRoundTrip() throws {
        var log = LogBuilder()
        var d = log.delta(devA, 0, [])
        d.session = "5f0c3e8a-2b7d-4c1e-9a3f-6d2b8e4f1a07"
        d.checkpoint = Checkpoint(name: "  Before the exam  ")
        let o = try object(d)
        XCTAssertEqual(o["session"] as? String, "5f0c3e8a-2b7d-4c1e-9a3f-6d2b8e4f1a07")
        XCTAssertEqual((o["checkpoint"] as? [String: Any])?["name"] as? String, "Before the exam")
        let back = try InkJSON.decoder().decode(Revision.self, from: InkJSON.encoder().encode(d))
        XCTAssertEqual(back, d)

        d.checkpoint = Checkpoint(name: "   ")
        XCTAssertNil(d.checkpoint?.name)
        let unnamed = try object(d)
        XCTAssertEqual((unnamed["checkpoint"] as? [String: Any])?.count, 0, "an unnamed checkpoint is {}")
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: InkJSON.encoder().encode(d)), d)
    }

    func testCheckpointNameIsCapped() {
        let long = String(repeating: "é", count: 500)
        XCTAssertEqual(Checkpoint(name: long).name?.count, Checkpoint.maxNameLength)
    }

    func testPlainRevisionsCarryNoNewFields() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let o = try object(d)
        XCTAssertNil(o["session"]); XCTAssertNil(o["checkpoint"]); XCTAssertNil(o["asOf"])
        let s = try log.snapshot(devB, 5, from: [d])
        XCTAssertNil(try object(s)["asOf"])
    }

    func testSnapshotAsOfRoundTrips() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        var s = try log.snapshot(devB, 5, from: [d])
        s.asOf = RevisionKey(d.name)
        XCTAssertEqual(try object(s)["asOf"] as? String, "\(d.hlc)-aaaaaaaa-1")
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: InkJSON.encoder().encode(s)), s)
    }

    /// A value of the wrong type or form is ignored, never fatal (§5.1).
    func testMalformedHistoryFieldsAreIgnored() throws {
        let head = #""noteId":"0d1c6a1e-9a44-4a6c-8a6b-0e2a0e9b1f3c","device":"aaaaaaaa","seq":1,"hlc":"17596320000000000","wall":"2025-10-05T02:40:00.000Z","app":"x""#
        for extra in [#""session":"UPPER""#, #""session":42"#, #""session":"\#(String(repeating: "a", count: 65))""#,
                      #""session":"""#, #""checkpoint":"yes""#, #""checkpoint":true"#, #""checkpoint":null"#,
                      #""checkpoint":[1]"#] {
            let r = try decode(#"{"type":"delta",\#(head),"ops":[],\#(extra)}"#)
            XCTAssertNil(r.session, extra)
            XCTAssertNil(r.checkpoint, extra)
        }
        let named = try decode(#"{"type":"delta",\#(head),"ops":[],"checkpoint":{"name":7,"future":1}}"#)
        XCTAssertEqual(named.checkpoint, Checkpoint(), "a non-string name is unnamed")
        let snap = #"{"type":"snapshot",\#(head),"included":{},"state":{"deleted":false,"meta":{"title":"","tags":[],"notebook":null,"favorite":false,"created":"2025-10-05T02:40:00.000Z","paper":{"kind":"plain"},"pageSize":{"width":612,"height":792,"infinite":false}},"pages":[],"tagSet":{"instances":[],"removed":[]}}"#
        for bad in ["\"nonsense\"", "\"17596320000000000-aaaaaaaa-0\"", "\"17596320000000000-aaaaaaaa-01\"",
                    "\"17596320000000000-AAAAAAAA-1\"", "\"17596320000000000-aaaaaaaa-9007199254740992\"", "12"] {
            XCTAssertNil(try decode(snap + #","asOf":\#(bad)}"#).asOf, bad)
        }
        // Fields on the wrong kind are ignored.
        let s = try decode(snap + #","session":"abc","checkpoint":{}}"#)
        XCTAssertNil(s.session); XCTAssertNil(s.checkpoint)
        let d = try decode(#"{"type":"delta",\#(head),"ops":[],"asOf":"17596320000000000-aaaaaaaa-1"}"#)
        XCTAssertNil(d.asOf)
    }

    // MARK: Sessions (§5.8.2)

    private func point(_ d: DeviceID, _ minutes: Double, session: String? = "s1", checkpoint: Checkpoint? = nil,
                       seq: Int) -> RestorePoint {
        let ms = baseMillis + Int64(minutes * 60_000)
        return RestorePoint(name: RevisionName(hlc: HLC(millis: ms, counter: 0)!, device: d, seq: seq, kind: .delta),
                            wall: wallAt(ms), app: "t", complete: true, checkpoint: checkpoint, session: session)
    }

    private func shape(_ groups: [HistoryGroup]) -> [String] {
        groups.map {
            switch $0 {
            case .checkpoint(let p): return "C\(p.name.seq)"
            case .session(let s): return s.points.map { "\($0.name.seq)" }.joined(separator: ",")
            }
        }
    }

    func testSessionRuleAClosedAndReopenedStartsNewSession() {
        let pts = [point(devA, 0, session: "s1", seq: 1), point(devA, 1, session: "s1", seq: 2),
                   point(devA, 2, session: "s2", seq: 3), point(devA, 3, session: "s2", seq: 4)]
        XCTAssertEqual(shape(NoteHistory.groups(pts)), ["1,2", "3,4"])
    }

    func testSessionRuleBGapOfTenMinutes() {
        let pts = [point(devA, 0, seq: 1), point(devA, 9.99, seq: 2), point(devA, 19.99, seq: 3),
                   point(devA, 25, seq: 4)]
        XCTAssertEqual(shape(NoteHistory.groups(pts)), ["1,2", "3,4"], "exactly 10 minutes starts a new session")
        // A wall clock going backwards is no gap.
        let back = [point(devA, 30, seq: 1), point(devA, 0, seq: 2)]
        XCTAssertEqual(shape(NoteHistory.groups(back)), ["1,2"])
    }

    func testSessionRuleCDifferentDevice() {
        let pts = [point(devA, 0, seq: 1), point(devB, 1, seq: 1), point(devA, 2, seq: 2)]
        XCTAssertEqual(shape(NoteHistory.groups(pts)), ["1", "1", "2"])
    }

    func testPointsWithoutSessionGroupByGapAndDevice() {
        let pts = [point(devA, 0, session: nil, seq: 1), point(devA, 5, session: nil, seq: 2),
                   point(devA, 6, session: "s1", seq: 3), point(devA, 20, session: nil, seq: 4)]
        XCTAssertEqual(shape(NoteHistory.groups(pts)), ["1,2", "3", "4"])
    }

    func testCheckpointsStandAloneAndSplitSessions() {
        let pts = [point(devA, 0, seq: 1), point(devA, 1, seq: 2),
                   point(devA, 2, checkpoint: Checkpoint(name: "v1"), seq: 3),
                   point(devA, 3, seq: 4), point(devA, 4, checkpoint: Checkpoint(), seq: 5),
                   point(devA, 4.5, checkpoint: Checkpoint(), seq: 6)]
        let groups = NoteHistory.groups(pts)
        XCTAssertEqual(shape(groups), ["1,2", "C3", "4", "C5", "C6"])
        guard case .session(let s) = groups[0] else { return XCTFail() }
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.device, devA)
        XCTAssertEqual(s.start, pts[0].wall)
        XCTAssertEqual(s.end, pts[1].wall)
        XCTAssertEqual(s.newest.name, pts[1].name)
    }

    func testRestorePointsCarryCheckpointAndSession() {
        var log = LogBuilder()
        var a = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        a.session = "s1"
        var c = log.delta(devA, 10, [])
        c.checkpoint = Checkpoint(name: "Draft")
        c.session = "s1"
        let pts = NoteHistory.restorePoints([a, c])
        XCTAssertEqual(pts.map(\.session), ["s1", "s1"])
        XCTAssertEqual(pts.map(\.checkpoint), [nil, Checkpoint(name: "Draft")])
    }

    // MARK: Positioned snapshots (§5.8.3)

    func testPositionedSnapshotMakesItsPointCompleteAndIsNoRestorePoint() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let s1 = stroke(), s2 = stroke()
        let a2 = log.delta(devA, 10, [.addStroke(page: p1, stroke: s1)])
        let a3 = log.delta(devA, 20, [.addStroke(page: p1, stroke: s2)])
        let a4 = log.delta(devA, 30, [.removeStroke(page: p1, strokeId: s1.id)])
        var pos = try log.snapshot(devB, 40, from: [a1, a2, a3])
        pos.asOf = RevisionKey(a3.name)
        let full = try log.snapshot(devB, 50, from: [a1, a2, a3, a4])
        // a1 and a2 compacted away: a3 is complete only thanks to `pos`.
        let left = [a3, a4, pos, full]
        XCTAssertEqual(NoteHistory.positions(left), [pos.name: RevisionKey(a3.name)])
        let pts = NoteHistory.restorePoints(left)
        XCTAssertEqual(pts.map(\.name), [a3.name, a4.name, full.name], "the positioned snapshot is not listed")
        XCTAssertEqual(pts.map(\.complete), [true, true, true])
        XCTAssertEqual(try NoteHistory.state(left, at: a3.name).allStrokeIds, [s1.id, s2.id])
        XCTAssertEqual(try NoteHistory.state(left, at: a4.name).allStrokeIds, [s2.id])
        XCTAssertThrowsError(try NoteHistory.state(left, at: pos.name))
        // Without asOf (an older reader) a3 is incomplete, never wrong.
        var plain = pos; plain.asOf = nil
        XCTAssertEqual(NoteHistory.restorePoints([a3, a4, plain, full]).first?.complete, false)
        // The current state is the same either way.
        XCTAssertEqual(try NoteReducer.reconstruct(left).comparable,
                       try NoteReducer.reconstruct([a1, a2, a3, a4]).comparable)
    }

    func testInvalidAsOfIsAnOrdinarySnapshot() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let a2 = log.delta(devA, 10, [.setMeta(.title("x"))])
        // Covers a2, which is ordered after its asOf: a leak.
        var leak = try log.snapshot(devB, 40, from: [a1, a2])
        leak.asOf = RevisionKey(a1.name)
        XCTAssertTrue(NoteHistory.positions([a1, a2, leak]).isEmpty)
        // asOf not before its own name.
        var late = try log.snapshot(devB, 50, from: [a1])
        late.asOf = RevisionKey(hlc: HLC(millis: baseMillis + 99_999, counter: 0)!, device: devA, seq: 9)
        XCTAssertTrue(NoteHistory.positions([a1, a2, late]).isEmpty)
        XCTAssertEqual(NoteHistory.restorePoints([a1, a2, late]).count, 3)
    }

    // MARK: Thinning: hand-made cases

    private func minutes(_ m: Double) -> Int64 { Int64(m * 60_000) }

    /// Applies a plan in memory.
    private func applied(_ revs: [Revision], _ plan: CompactionPlan) -> [Revision] {
        let gone = Set(plan.deletions)
        return revs.filter { !gone.contains($0.name) } + plan.snapshots
    }

    private func thin(_ revs: [Revision], olderThan age: TimeInterval, now: Date,
                      device: DeviceID = devC) throws -> CompactionPlan {
        var clock = HybridClock()
        return try CompactionPlanner.plan(revs, mode: .thin(olderThan: age), now: now, device: device, clock: &clock,
                                          wall: now, app: "test/0")
    }

    func testThinningKeepsCheckpointsAndSessionEnds() throws {
        var log = LogBuilder()
        var revs: [Revision] = []
        func add(_ d: DeviceID, _ m: Double, _ ops: [Op], session: String?, checkpoint: Checkpoint? = nil) -> Revision {
            var r = log.delta(d, minutes(m), ops)
            r.session = session; r.checkpoint = checkpoint
            revs.append(r)
            return r
        }
        _ = add(devA, 0, [.addPage(Page(id: p1, order: "a0"))], session: "s1")
        for i in 1...5 { _ = add(devA, Double(i), [.addStroke(page: p1, stroke: stroke())], session: "s1") }
        let end1 = add(devA, 6, [.setMeta(.title("one"))], session: "s1")
        let cp = add(devA, 7, [], session: "s1", checkpoint: Checkpoint(name: "v1"))
        for i in 0..<4 { _ = add(devA, 8 + Double(i), [.addStroke(page: p1, stroke: stroke())], session: "s2") }
        let end2 = revs.last!
        // A recent session (inside the window): untouched.
        let recent = (0..<3).map { i in add(devA, 60 * 24 * 40 + Double(i), [.addStroke(page: p1, stroke: stroke())], session: "s3") }
        let now = wallAt(baseMillis + minutes(60 * 24 * 41))
        let plan = try thin(revs, olderThan: 30 * 86_400, now: now)
        
        let after = applied(revs, plan)
        let names = Set(after.map(\.name))
        for keep in [end1, cp, end2] + recent { XCTAssertTrue(names.contains(keep.name), keep.name.filename) }
        XCTAssertEqual(plan.deletions.count, revs.count - 3 - recent.count)
        XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, try NoteReducer.reconstruct(revs).comparable)
        let pts = NoteHistory.restorePoints(after)
        XCTAssertEqual(pts.map(\.name), [end1, cp, end2].map(\.name) + recent.map(\.name))
        XCTAssertTrue(pts.allSatisfy(\.complete))
        for p in pts {
            XCTAssertEqual(try NoteHistory.state(after, at: p.name).comparable,
                           try NoteHistory.state(revs, at: p.name).comparable)
        }
        // Positioned snapshots at end1 (cp needs none: nothing deleted between) and end2.
        XCTAssertEqual(Set(plan.snapshots.compactMap(\.asOf)), [RevisionKey(end1.name), RevisionKey(end2.name)])
        XCTAssertTrue(try thin(after, olderThan: 30 * 86_400, now: now).isEmpty, "thinning again does nothing")
        // Never: same as nothing older than the window.
        XCTAssertTrue(try thin(revs, olderThan: 365 * 86_400, now: now).isEmpty)
    }

    func testWitnessKeepsAnotherDevicesOrder() throws {
        var log = LogBuilder()
        var revs: [Revision] = []
        func add(_ d: DeviceID, _ m: Double, _ ops: [Op], session: String) {
            var r = log.delta(d, minutes(m), ops); r.session = session; revs.append(r)
        }
        add(devA, 0, [.addPage(Page(id: p1, order: "a0"))], session: "a1")
        for i in 1...3 { add(devA, Double(i), [.addStroke(page: p1, stroke: stroke())], session: "a1") }
        for i in 0...3 { add(devB, 4 + Double(i), [.addStroke(page: p1, stroke: stroke())], session: "b1") }
        for i in 0...3 { add(devA, 8 + Double(i), [.addStroke(page: p1, stroke: stroke())], session: "a2") }
        let now = wallAt(baseMillis + minutes(60 * 24 * 60))
        let plan = try thin(revs, olderThan: 30 * 86_400, now: now)
        let after = applied(revs, plan)
        // Target a1's end (A seq 4): B's first revision after it is its witness;
        // target b1's end: A's first revision after it (seq 5).
        XCTAssertEqual(Set(plan.witnesses.map { "\($0.device)-\($0.seq)" }), ["bbbbbbbb-1", "aaaaaaaa-5"])
        let pts = NoteHistory.restorePoints(after)
        for t in plan.targets {
            XCTAssertTrue(pts.first { $0.name == t }?.complete ?? false, t.filename)
            XCTAssertEqual(try NoteHistory.state(after, at: t).comparable, try NoteHistory.state(revs, at: t).comparable)
        }
        XCTAssertTrue(try thin(after, olderThan: 30 * 86_400, now: now).isEmpty)
    }

    func testRetentionCompactionKeepsCheckpointsComplete() throws {
        var log = LogBuilder()
        var revs = [log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])]
        for i in 1...4 { revs.append(log.delta(devA, minutes(Double(i)), [.addStroke(page: p1, stroke: stroke())])) }
        var cp = log.delta(devA, minutes(5), [])
        cp.checkpoint = Checkpoint(name: "keep me")
        revs.append(cp)
        for i in 6...9 { revs.append(log.delta(devA, minutes(Double(i)), [.addStroke(page: p1, stroke: stroke())])) }
        let now = wallAt(baseMillis + minutes(60 * 24 * 60))
        var clock = HybridClock()
        let plan = try CompactionPlanner.plan(revs, mode: .retention(30 * 86_400), now: now, device: devC,
                                              clock: &clock, wall: now, app: "t")
        XCTAssertFalse(plan.deletions.contains(cp.name))
        let after = applied(revs, plan)
        XCTAssertEqual(after.filter { $0.kind == .delta }.map(\.name), [cp.name])
        XCTAssertTrue(NoteHistory.restorePoints(after).first { $0.name == cp.name }?.complete ?? false)
        XCTAssertEqual(try NoteHistory.state(after, at: cp.name).comparable, try NoteHistory.state(revs, at: cp.name).comparable)
        XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, try NoteReducer.reconstruct(revs).comparable)

        // Without a device (no positioned snapshots), nothing a checkpoint depends on goes.
        let deviceless = LoadedNote(revisions: revs, failures: [:]).compactionPlan(retention: 0, now: now, assumingSnapshot: true)
        XCTAssertFalse(deviceless.contains(cp.name))
        XCTAssertTrue(deviceless.allSatisfy { $0 > cp.name })
    }

    func testPlanRefusesNothingWhenNoteIsYoung() throws {
        var log = LogBuilder()
        let revs = [log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))]), log.delta(devA, 1000, [.setMeta(.title("t"))])]
        XCTAssertTrue(try thin(revs, olderThan: 86_400, now: wallAt(baseMillis + 5000)).isEmpty)
    }

    // MARK: Thinning: property test of the guarantees (§5.8.4 G1–G5)

    func testThinningGuaranteesOnRandomLogs() throws {
        let seeds: [UInt64] = (1...120).map { $0 }
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            let revs = try RandomHistory.make(using: &rng)
            let end = revs.map(\.wall).max()!
            let span = end.timeIntervalSince(revs.map(\.wall).min()!)
            let now = end.addingTimeInterval(Double.random(in: 0...(span / 2), using: &rng))
            let age = Double.random(in: 0...(span), using: &rng)
            let mode: CompactionMode = seed % 4 == 0 ? .retention(age) : .thin(olderThan: age)
            try checkGuarantees(revs, mode: mode, now: now, seed: seed, rng: &rng)
        }
    }

    /// Thinning again later, after new revisions, must work on the snapshots
    /// the first run wrote (a new snapshot built from them covers them, §5.8.3).
    func testThinningAgainAfterNewRevisions() throws {
        var log = LogBuilder()
        var revs: [Revision] = []
        func add(_ day: Double, _ minute: Double, _ ops: [Op], session: String) {
            var r = log.delta(devA, Int64((day * 86_400 + minute * 60) * 1000), ops)
            r.session = session
            revs.append(r)
        }
        add(0, 0, [.addPage(Page(id: p1, order: "a0"))], session: "s1")
        add(0, 1, [.addStroke(page: p1, stroke: stroke())], session: "s1")
        add(0, 2, [.addStroke(page: p1, stroke: stroke())], session: "s1")
        for i in 0..<3 { add(5, Double(i), [.addStroke(page: p1, stroke: stroke())], session: "s2") }
        let day: Double = 86_400
        let first = try thin(revs, olderThan: 30 * day, now: wallAt(baseMillis + Int64(31 * day * 1000)))
        XCTAssertFalse(first.isEmpty)
        var after = applied(revs, first)
        for i in 0..<3 { add(20, Double(i), [.addStroke(page: p1, stroke: stroke())], session: "s3") }
        after += revs.suffix(3)
        var rng = SplitMix64(seed: 7)
        try checkGuarantees(after, mode: .thin(olderThan: 30 * day), now: wallAt(baseMillis + Int64(36 * day * 1000)),
                            seed: 0, rng: &rng)
        try checkGuarantees(after, mode: .thin(olderThan: 30 * day), now: wallAt(baseMillis + Int64(60 * day * 1000)),
                            seed: 0, rng: &rng)
        try checkGuarantees(after, mode: .retention(30 * day), now: wallAt(baseMillis + Int64(60 * day * 1000)),
                            seed: 0, rng: &rng)
    }

    /// Two rounds on random logs: thin a prefix, add the rest, thin again later.
    func testThinningTwiceOnRandomLogs() throws {
        for seed: UInt64 in Array(1...80) + [128] {   // 128: a delta orphaned at its target is kept
            var rng = SplitMix64(seed: seed &* 7919)
            let all = try RandomHistory.make(using: &rng).sorted { $0.name < $1.name }
            guard all.count > 3 else { continue }
            let k = Int.random(in: 2..<all.count, using: &rng)
            let head = Array(all.prefix(k)), rest = all.dropFirst(k)
            let span = all.last!.wall.timeIntervalSince(all[0].wall)
            let age = Double.random(in: 0...max(span / 2, 1), using: &rng)
            let mode1: CompactionMode = seed % 3 == 0 ? .retention(age) : .thin(olderThan: age)
            var clock = HybridClock()
            let now1 = head.last!.wall.addingTimeInterval(age + 1)
            let plan = try CompactionPlanner.plan(head, mode: mode1, now: now1, device: DeviceID("dddddddd")!,
                                                  clock: &clock, wall: now1, app: "t")
            let gone = Set(plan.deletions)
            let round2 = head.filter { !gone.contains($0.name) } + plan.snapshots + rest
            let mode2: CompactionMode = seed % 2 == 0 ? .retention(age) : .thin(olderThan: age)
            try checkGuarantees(round2, mode: mode2, now: all.last!.wall.addingTimeInterval(age + 1),
                                seed: seed, rng: &rng)
        }
    }

    /// A snapshot ordered before a checkpoint can cover a revision ordered
    /// after it (that revision's device clock ran more than 24h fast, so its
    /// hlc was not adopted, format.md §5). A snapshot positioned at the
    /// checkpoint would cover it too, which §5.8.3 rejects; the plan keeps
    /// what the checkpoint needs instead of failing for good (B16).
    func testASnapshotCoveringASkewedLaterRevisionDoesNotBlockThePlan() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        var f = log.delta(devB, minutes(3 * 24 * 60), [.addStroke(page: p1, stroke: stroke())])
        f.wall = wallAt(baseMillis + 3)
        var snap = try log.snapshot(devA, 1, from: [d1, f])
        snap.hlc = HLC(millis: baseMillis + 1, counter: 0)!
        var cp = log.delta(devA, 2, [])
        cp.checkpoint = Checkpoint(name: "v1")
        let revs = [d1, snap, cp, f]
        XCTAssertTrue(snap.name < cp.name && cp.name < f.name)
        XCTAssertEqual(NoteHistory.restorePoints(revs).first { $0.name == cp.name }?.complete, true)
        let now = wallAt(baseMillis + minutes(60 * 24 * 60))
        for mode in [CompactionMode.thin(olderThan: 0), .retention(0)] {
            var clock = HybridClock()
            let plan = try CompactionPlanner.plan(revs, mode: mode, now: now, device: devC, clock: &clock, wall: now, app: "t")
            let after = applied(revs, plan)
            XCTAssertEqual(NoteHistory.restorePoints(after).first { $0.name == cp.name }?.complete, true, "\(mode)")
            XCTAssertEqual(try NoteHistory.state(after, at: cp.name).comparable,
                           try NoteHistory.state(revs, at: cp.name).comparable, "\(mode)")
            XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, try NoteReducer.reconstruct(revs).comparable)
        }
    }

    /// Device-less compaction keeps a positioned snapshot a complete checkpoint needs.
    func testDevicelessCompactionKeepsPositionedSnapshotOfCheckpoint() throws {
        var log = LogBuilder()
        var revs = [log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])]
        for i in 1...3 { revs.append(log.delta(devA, minutes(Double(i)), [.addStroke(page: p1, stroke: stroke())])) }
        var cp = log.delta(devA, minutes(4), [])
        cp.checkpoint = Checkpoint(name: "v")
        revs.append(cp)
        let now = wallAt(baseMillis + minutes(60 * 24 * 60))
        var clock = HybridClock()
        let plan = try CompactionPlanner.plan(revs, mode: .retention(30 * 86_400), now: now, device: devA, clock: &clock,
                                              wall: now, app: "t")
        var after = applied(revs, plan)
        XCTAssertTrue(after.contains { $0.asOf == RevisionKey(cp.name) })
        after.append(log.delta(devB, minutes(60 * 24 * 61), [.addStroke(page: p1, stroke: stroke())]))
        after.append(try log.snapshot(devB, minutes(60 * 24 * 62), from: after))
        let doomed = Set(LoadedNote(revisions: after, failures: [:]).compactionPlan(retention: 0, now: now.addingTimeInterval(86_400 * 90)))
        let left = after.filter { !doomed.contains($0.name) }
        XCTAssertEqual(NoteHistory.restorePoints(left).first { $0.name == cp.name }?.complete, true)
        XCTAssertEqual(try NoteHistory.state(left, at: cp.name).comparable, try NoteHistory.state(revs, at: cp.name).comparable)
    }

    /// Clocks that disagree (`RandomHistory.makeSkewed`). Seeds 64, 88 and 336
    /// moved the note's `created` before compaction kept its first revision
    /// (`CompactionPlanner.createdAnchor`).
    func testThinningGuaranteesWithSkewedClocks() throws {
        for seed in Array(UInt64(1)...60) + [64, 88, 336] {
            var rng = SplitMix64(seed: seed &* 7919)
            let revs = try RandomHistory.makeSkewed(using: &rng)
            let walls = revs.map(\.wall)
            let end = walls.max()!
            let span = max(end.timeIntervalSince(walls.min()!), 1)
            let now = end.addingTimeInterval(Double.random(in: 0...(span / 2), using: &rng))
            let age = Double.random(in: 0...span, using: &rng)
            let mode: CompactionMode = seed % 4 == 0 ? .retention(age) : .thin(olderThan: age)
            try checkGuarantees(revs, mode: mode, now: now, seed: seed, rng: &rng)
        }
    }

    /// The first revision has a later `wall` than one ordered after it (its
    /// device's clock is behind; its HLC moved ahead when it synced). Deleting
    /// the first revision would make that one first and move `created`.
    func testCompactionKeepsTheRevisionThatSetsCreated() throws {
        let hour: Int64 = 3_600_000
        func rev(_ d: DeviceID, _ seq: Int, hlcMs: Int64, wallMs: Int64, _ ops: [Op], session: String? = nil) -> Revision {
            var r = Revision(noteId: testNote, device: d, seq: seq, hlc: HLC(millis: baseMillis + hlcMs, counter: 0)!,
                             wall: wallAt(baseMillis + wallMs), app: "t", body: .delta(ops: ops))
            r.session = session
            return r
        }
        func stroke(_ x: Double) -> Op {
            .addStroke(page: p1, stroke: Stroke(id: UUID(), ink: Ink(tool: .pen, color: .black, width: 2),
                                                points: [StrokePoint(x: x, y: 1, w: 2, h: 2)]))
        }
        let revs = [
            rev(devA, 1, hlcMs: 2 * hour, wallMs: 2 * hour, [.addPage(Page(id: p1, order: "a0"))], session: "s1"),
            rev(devA, 2, hlcMs: 2 * hour + 1000, wallMs: 2 * hour + 1000, [stroke(1)], session: "s1"),
            // Device B's clock is two hours behind; it synced, so its HLC is ahead of A's.
            rev(devB, 1, hlcMs: 2 * hour + 2000, wallMs: 2000, [stroke(2)], session: "s2"),
            // A checkpoint is never deleted: once A's first revisions go, it would be first.
            {
                var r = rev(devB, 2, hlcMs: 2 * hour + 3000, wallMs: 3000, [], session: "s2")
                r.checkpoint = Checkpoint(name: "v1")
                return r
            }(),
            rev(devA, 3, hlcMs: 900 * hour, wallMs: 900 * hour, [stroke(4)], session: "s3"),
        ]
        let created = try NoteReducer.reconstruct(revs).meta.created
        XCTAssertEqual(created, wallAt(baseMillis + 2 * hour))
        XCTAssertEqual(CompactionPlanner.createdAnchor(revs), revs[0].name)
        let now = wallAt(baseMillis + 901 * hour)
        for mode in [CompactionMode.thin(olderThan: 86_400), .retention(86_400)] {
            var clock = HybridClock()
            let plan = try CompactionPlanner.plan(revs, mode: mode, now: now, device: devC, clock: &clock, wall: now, app: "t")
            XCTAssertFalse(plan.deletions.contains(revs[0].name), "\(mode)")
            let after = revs.filter { !plan.deletions.contains($0.name) } + plan.snapshots
            XCTAssertEqual(try NoteReducer.reconstruct(after).meta.created, created, "\(mode)")
            XCTAssertEqual(try NoteHistory.state(after, at: revs[3].name).meta.created, created, "\(mode)")
            if case .retention = mode { XCTAssertFalse(plan.deletions.isEmpty) }   // the others still go
        }
        XCTAssertFalse(LoadedNote(revisions: revs, failures: [:]).compactionPlan(retention: 0, now: now, assumingSnapshot: true)
            .contains(revs[0].name))
    }

    private func checkGuarantees(_ revs: [Revision], mode: CompactionMode, now: Date, seed: UInt64,
                                 rng: inout SplitMix64) throws {
        let ctx = "seed \(seed) \(mode)"
        var clock = HybridClock()
        let plan = try CompactionPlanner.plan(revs, mode: mode, now: now, device: DeviceID("dddddddd")!, clock: &clock,
                                              wall: now, app: "t")
        let before = NoteHistory.restorePoints(revs)
        let checkpoints = before.filter(\.isCheckpoint).map(\.name)
        let gone = Set(plan.deletions)
        // G2: no checkpoint deleted.
        XCTAssertTrue(gone.isDisjoint(with: checkpoints), ctx)
        // G3: thinning deletes only inside the thinned range.
        if case .thin(let age) = mode {
            let range = revs.sorted { $0.name < $1.name }.prefix { now.timeIntervalSince($0.wall) > age }
            XCTAssertTrue(gone.isSubset(of: Set(range.map(\.name))), ctx)
            // Every session's newest point stays.
            for case .session(let s) in NoteHistory.groups(before) where gone.contains(s.newest.name) {
                XCTFail("\(ctx): session end \(s.newest.name) deleted")
            }
            // Every kept version that was complete is a target: checkpoints, session ends, the newest
            // revision and everything after the range.
            var kept = Set(checkpoints)
            if let newest = revs.map(\.name).max() { kept.insert(newest) }
            for case .session(let s) in NoteHistory.groups(before) { kept.insert(s.newest.name) }
            kept.formUnion(before.map(\.name).filter { !Set(range.map(\.name)).contains($0) })
            XCTAssertTrue(kept.intersection(Set(before.filter(\.complete).map(\.name))).isSubset(of: Set(plan.targets)), ctx)
        }
        // Each deletion prefix: G1 (state) and G2 (targets complete, same as-of).
        let order = plan.deletions.shuffled(using: &rng)
        let cuts = Set([0, order.count, Int.random(in: 0...order.count, using: &rng)])
        let current = try NoteReducer.reconstruct(revs).comparable
        let completeBefore = Set(before.filter(\.complete).map(\.name))
        for cut in cuts.sorted() {
            let removed = Set(order.prefix(cut))
            let after = revs.filter { !removed.contains($0.name) } + plan.snapshots
            XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, current, "\(ctx) cut \(cut)")
            let pts = Dictionary(uniqueKeysWithValues: NoteHistory.restorePoints(after).map { ($0.name, $0) })
            for t in plan.targets {
                XCTAssertTrue(completeBefore.contains(t), ctx)
                XCTAssertEqual(pts[t]?.complete, true, "\(ctx) cut \(cut) target \(t)")
                XCTAssertEqual(try NoteHistory.state(after, at: t).comparable, try NoteHistory.state(revs, at: t).comparable,
                               "\(ctx) cut \(cut) target \(t)")
            }
        }
        // Checkpoints that were complete are targets.
        XCTAssertTrue(Set(checkpoints).intersection(completeBefore).isSubset(of: Set(plan.targets)), ctx)
        // G5: each deleted revision is covered (delta) or dominated (snapshot) by a survivor.
        let after = applied(revs, plan)
        let covers = after.compactMap { r -> (RevisionName, Included)? in
            if case .snapshot(let inc, _) = r.body { return (r.name, inc) } else { return nil }
        }
        for r in revs where gone.contains(r.name) {
            switch r.body {
            case .delta:
                XCTAssertTrue(covers.contains { $0.1.covers(device: r.device, seq: r.seq) }, ctx)
            case .snapshot(let inc, _):
                XCTAssertTrue(covers.contains { $0.1.isSuperset(of: inc) && (!inc.isSuperset(of: $0.1) || $0.0 > r.name) }, ctx)
            }
        }
        // Positioned snapshots written are valid.
        let positions = NoteHistory.positions(after)
        for s in plan.snapshots where s.asOf != nil { XCTAssertEqual(positions[s.name], s.asOf, ctx) }
        // G4: again with the same cutoff: nothing.
        if case .thin = mode, !plan.isEmpty {
            var c2 = clock
            let again = try CompactionPlanner.plan(after, mode: mode, now: now, device: DeviceID("dddddddd")!, clock: &c2,
                                                   wall: now, app: "t")
            XCTAssertTrue(again.isEmpty, "\(ctx): second pass deletes \(again.deletions) writes \(again.snapshots.count)")
        }
    }
}

/// Random multi-device logs with sessions, checkpoints, removals, tags,
/// page changes and the odd snapshot, spread over months.
enum RandomHistory {
    static func make(using rng: inout SplitMix64) throws -> [Revision] {
        let devices = [devA, devB, devC]
        var log = LogBuilder()
        var revs: [Revision] = []
        var t: Int64 = 0
        var pages: [UUID] = []
        var device = devA
        var sessions: [DeviceID: String] = [:]
        let count = Int.random(in: 8...40, using: &rng)
        for i in 0..<count {
            // Time: seconds apart, sometimes 10+ minutes, sometimes days.
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: t += Int64.random(in: 1...20, using: &rng) * 86_400_000
            case 1, 2: t += Int64.random(in: 10...120, using: &rng) * 60_000
            default: t += Int64.random(in: 1...300, using: &rng) * 1000
            }
            if Int.random(in: 0..<4, using: &rng) == 0 { device = devices.randomElement(using: &rng)! }
            if sessions[device] == nil || Int.random(in: 0..<6, using: &rng) == 0 {
                sessions[device] = Bool.random(using: &rng) ? "s\(i)" : nil
                if sessions[device] == nil { sessions[device] = "" }
            }
            if i > 2, Int.random(in: 0..<12, using: &rng) == 0 {
                revs.append(try log.snapshot(device, t, from: revs))
                continue
            }
            let state = revs.isEmpty ? nil : try NoteReducer.reconstruct(revs)
            var ops: [Op] = []
            var checkpoint: Checkpoint?
            if pages.isEmpty {
                let p = UUID.random(using: &rng)
                pages.append(p)
                ops.append(.addPage(Page(id: p, order: "a\(i)")))
            } else {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: checkpoint = Checkpoint(name: Bool.random(using: &rng) ? "v\(i)" : nil)
                case 1:
                    let p = UUID.random(using: &rng)
                    pages.append(p)
                    ops.append(.addPage(Page(id: p, order: "b\(i)")))
                case 2:
                    if let s = state?.pages.flatMap({ p in p.strokes.map { (p.id, $0.id) } }).randomElement(using: &rng) {
                        ops.append(.removeStroke(page: s.0, strokeId: s.1))
                    }
                case 3: ops.append(.setMeta(.title("t\(i)")))
                case 4: ops.append(.addTag("tag\(i % 3)"))
                case 5:
                    if let st = state, let op = NoteOps.removeTag("tag\(i % 3)", from: st) { ops.append(op) }
                default:
                    let p = pages.randomElement(using: &rng)!
                    ops.append(.addStroke(page: p, stroke: Stroke(id: UUID.random(using: &rng),
                                                                  ink: Ink(tool: .pen, color: .black, width: 2),
                                                                  points: [StrokePoint(x: Double(i), y: 2, w: 2, h: 2)])))
                }
            }
            var r = log.delta(device, t, ops)
            let s = sessions[device] ?? ""
            r.session = s.isEmpty ? nil : s
            r.checkpoint = checkpoint
            revs.append(r)
        }
        // Sometimes an earlier compaction already removed covered revisions.
        if Int.random(in: 0..<3, using: &rng) == 0, let end = revs.last?.wall {
            let gone = Set(LoadedNote(revisions: revs, failures: [:])
                .compactionPlan(retention: Double.random(in: 0...(30 * 86_400), using: &rng), now: end,
                                protectingCheckpoints: false))
            revs.removeAll { gone.contains($0.name) }
        }
        return revs
    }

    /// Like `make`, with device clocks as they are: each device's wall clock
    /// has its own offset (sometimes days), its HLC is the hybrid clock's
    /// max(wall, last + 1, everything seen + 1 when it has synced), and a
    /// device that has not synced edits only what it made itself. Walls are
    /// then not in HLC order, and snapshots miss what their writer had not seen.
    static func makeSkewed(using rng: inout SplitMix64) throws -> [Revision] {
        let devices = [DeviceID("aaaaaaaa")!, DeviceID("bbbbbbbb")!, DeviceID("cccccccc")!]
        // Each device's wall clock has an offset (sometimes days off). Its HLC is max(wall, last + 1,
        // and, when it has synced, everything it has seen + 1), as a hybrid logical clock is.
        var offset: [DeviceID: Int64] = [:]
        for d in devices {
            offset[d] = Int.random(in: 0..<3, using: &rng) == 0 ? Int64.random(in: -(4 * 86_400_000)...(4 * 86_400_000), using: &rng) : 0
        }
        var seqs: [DeviceID: Int] = [:]
        var lastHLC: [DeviceID: Int64] = [:]
        var known: [DeviceID: [DeviceID: Int]] = [:]       // per device: seen seq per other device
        var ownPages: [DeviceID: [UUID]] = [:]
        var revs: [Revision] = []
        var t: Int64 = 10 * 86_400_000
        var device = devices[0]
        var sessions: [DeviceID: String?] = [:]
        let base: Int64 = 1_700_000_000_000
        let count = Int.random(in: 8...40, using: &rng)
        for i in 0..<count {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: t += Int64.random(in: 1...20, using: &rng) * 86_400_000
            case 1, 2: t += Int64.random(in: 10...120, using: &rng) * 60_000
            default: t += Int64.random(in: 1...300, using: &rng) * 1000
            }
            if Int.random(in: 0..<4, using: &rng) == 0 { device = devices.randomElement(using: &rng)! }
            if sessions[device] == nil || Int.random(in: 0..<6, using: &rng) == 0 {
                sessions[device] = Bool.random(using: &rng) ? "s\(i)" : .some(nil)
            }
            let wallMs = base + t + offset[device]!
            let wall = Date(timeIntervalSince1970: Double(wallMs) / 1000)
            let synced = revs.isEmpty || Int.random(in: 0..<3, using: &rng) != 0
            var ms = max(wallMs, (lastHLC[device] ?? 0) + 1)
            if synced {
                ms = max(ms, (revs.map { $0.hlc.millis }.max() ?? 0) + 1)
                for d in devices where d != device { known[device, default: [:]][d] = seqs[d] ?? 0 }
            }
            lastHLC[device] = ms
            seqs[device, default: 0] += 1
            let seq = seqs[device]!
            let hlc = HLC(millis: ms, counter: 0)!
            // What this device has seen: its own revisions and the others' up to what it synced.
            let seen = revs.filter { $0.device == device || $0.seq <= (known[device]?[$0.device] ?? 0) }
            if i > 2, Int.random(in: 0..<10, using: &rng) == 0, !seen.isEmpty {
                var c = HybridClock()
                let snap = try SnapshotBuilder.makeSnapshot(from: seen, device: device, seq: seq, clock: &c, wall: wall, app: "t")
                revs.append(Revision(noteId: snap.noteId, device: device, seq: seq, hlc: hlc, wall: wall, app: "t", body: snap.body))
                continue
            }
            let state = seen.isEmpty ? nil : try? NoteReducer.reconstruct(seen)
            let pages = synced ? (state?.pages.map(\.id) ?? []) : (ownPages[device] ?? [])
            var ops: [Op] = []
            var checkpoint: Checkpoint?
            if pages.isEmpty {
                let p = UUID.random(using: &rng); ownPages[device, default: []].append(p)
                ops.append(.addPage(Page(id: p, order: "a\(i)")))
            } else {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0: checkpoint = Checkpoint(name: Bool.random(using: &rng) ? "v\(i)" : nil)
                case 1:
                    let p = UUID.random(using: &rng); ownPages[device, default: []].append(p)
                    ops.append(.addPage(Page(id: p, order: "b\(i)")))
                case 2:
                    if synced, let s = state?.pages.flatMap({ p in p.strokes.map { (p.id, $0.id) } }).randomElement(using: &rng) {
                        ops.append(.removeStroke(page: s.0, strokeId: s.1))
                    }
                case 3: ops.append(.setMeta(.title("t\(i)")))
                case 4: ops.append(.addTag("tag\(i % 3)"))
                case 5: if synced, let st = state, let op = NoteOps.removeTag("tag\(i % 3)", from: st) { ops.append(op) }
                default:
                    let p = pages.randomElement(using: &rng)!
                    ops.append(.addStroke(page: p, stroke: Stroke(id: UUID.random(using: &rng), ink: Ink(tool: .pen, color: .black, width: 2),
                                                                  points: [StrokePoint(x: Double(i), y: 2, w: 2, h: 2)])))
                }
            }
            var r = Revision(noteId: testNote, device: device, seq: seq, hlc: hlc, wall: wall, app: "t", body: .delta(ops: ops))
            r.session = sessions[device] ?? nil
            r.checkpoint = checkpoint
            revs.append(r)
        }
        if Int.random(in: 0..<3, using: &rng) == 0, let end = revs.map(\.wall).max() {
            let gone = Set(LoadedNote(revisions: revs, failures: [:])
                .compactionPlan(retention: Double.random(in: 0...(30 * 86_400), using: &rng), now: end, protectingCheckpoints: false))
            revs.removeAll { gone.contains($0.name) }
        }
        return revs
    }
}

// MARK: - Mass re-import and the metadata-only stage (performance round 3)

extension VersionHistoryTests {
    /// Two imports of a note dated by its creation date, without `session` or
    /// `checkpoint`, fall in the thinned range as ONE editing session (§5.8.2:
    /// same device, no session id, no wall gap), and the first import is not
    /// that session's last point. Deleting it is correct by §5.8.4: the state
    /// and the kept re-import are unchanged (G1, G2), the re-import (the
    /// session's newest point) stays, and a positioned snapshot keeps it
    /// complete. Importers write checkpoints, which thinning never deletes.
    func testReimportWithoutCheckpointsThinsOnlyTheFirstImportAndChangesNothing() throws {
        var rng = SeededRNG(3)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<40 {
            let plain = SyntheticVault.reimportedNote(index: i, strokes: 6, points: 5, rng: &rng, baseMillis: 1_600_000_000_000,
                                                       reimportMillis: 1_790_000_000_000, withoutCheckpoints: true)
            var clock = HybridClock()
            let plan = try CompactionPlanner.plan(plain, mode: .thin(olderThan: 30 * 86_400), now: now, device: devC,
                                                  clock: &clock, wall: now, app: "t")
            XCTAssertEqual(plan.deletions, [plain[0].name], "note \(i)")
            XCTAssertEqual(plan.targets, [plain[1].name])
            XCTAssertEqual(plan.snapshots.map(\.asOf), [RevisionKey(plain[1].name)])
            let after = applied(plain, plan)
            XCTAssertEqual(try NoteReducer.reconstruct(after).comparable, try NoteReducer.reconstruct(plain).comparable)
            XCTAssertEqual(try NoteHistory.state(after, at: plain[1].name).comparable,
                           try NoteHistory.state(plain, at: plain[1].name).comparable)
            var r2 = SplitMix64(seed: UInt64(i))
            try checkGuarantees(plain, mode: .thin(olderThan: 30 * 86_400), now: now, seed: UInt64(i), rng: &r2)

            // As the importer writes them: two checkpoints, nothing to thin, decided from metadata.
            let current = SyntheticVault.reimportedNote(index: i, strokes: 6, points: 5, rng: &rng, baseMillis: 1_600_000_000_000,
                                                        reimportMillis: 1_790_000_000_000, withoutCheckpoints: false)
            var c2 = HybridClock()
            for cutoff: TimeInterval in [0, 86_400, 30 * 86_400] {
                XCTAssertTrue(try CompactionPlanner.plan(current, mode: .thin(olderThan: cutoff), now: now, device: devC,
                                                         clock: &c2, wall: now, app: "t").isEmpty)
                XCTAssertFalse(CompactionPlanner.mayDelete(current.map(RevisionMeta.init), noteId: current[0].noteId,
                                                           mode: .thin(olderThan: cutoff), now: now))
            }
        }
    }

    /// The metadata-only stage decides exactly what the full stage does: `select` on
    /// hollow revisions (no ops, empty snapshot states) equals `select` on the real
    /// ones, and whenever it finds no candidate the full plan is empty. So skipping a
    /// note on its metadata never changes what thinning or compaction does.
    func testSelectionFromMetadataEqualsSelectionFromRevisions() throws {
        var nonEmpty = 0
        for seed in UInt64(1)...150 {
            var rng = SplitMix64(seed: seed &* 31)
            let revs = seed % 3 == 0 ? try RandomHistory.makeSkewed(using: &rng) : try RandomHistory.make(using: &rng)
            let walls = revs.map(\.wall)
            let end = walls.max()!
            let span = max(end.timeIntervalSince(walls.min()!), 1)
            let now = end.addingTimeInterval(Double.random(in: 0...(span / 2), using: &rng))
            let age = Double.random(in: 0...span, using: &rng)
            let mode: CompactionMode = seed % 4 == 0 ? .retention(age) : .thin(olderThan: age)
            let metas = revs.map(RevisionMeta.init)
            // The metadata survives the cache's encoding.
            let decoded = try JSONDecoder().decode([RevisionMeta].self, from: JSONEncoder().encode(metas))
            XCTAssertEqual(decoded, metas, "seed \(seed)")
            let hollow = decoded.map { $0.hollow(noteId: revs[0].noteId) }
            XCTAssertEqual(CompactionPlanner.select(hollow, mode: mode, now: now),
                           CompactionPlanner.select(revs, mode: mode, now: now), "seed \(seed) \(mode)")
            var clock = HybridClock()
            let plan = try CompactionPlanner.plan(revs, mode: mode, now: now, device: devC, clock: &clock, wall: now, app: "t")
            if !CompactionPlanner.mayDelete(decoded, noteId: revs[0].noteId, mode: mode, now: now) {
                XCTAssertTrue(plan.isEmpty, "seed \(seed) \(mode)")
            } else {
                nonEmpty += 1
            }
            XCTAssertTrue(Set(plan.deletions).isSubset(of: CompactionPlanner.select(revs, mode: mode, now: now).candidates))
        }
        XCTAssertGreaterThan(nonEmpty, 20)   // the property is not vacuous
    }
}

// MARK: - "Thin everything except checkpoints" (cutoff zero)

extension VersionHistoryTests {
    /// The random property tests draw the cutoff from a continuum, so they never
    /// try the explicit zero cutoff `ThinningRule.allButCheckpoints` uses, where
    /// every revision is in the thinned range. The same guarantees (G1–G5) hold,
    /// and the metadata-only stage still decides exactly what the full one does.
    func testThinEverythingExceptCheckpointsGuarantees() throws {
        let mode = ThinningRule.allButCheckpoints.mode
        XCTAssertEqual(mode, .thin(olderThan: 0))
        var deleted = 0
        for seed in UInt64(1)...120 {
            var rng = SplitMix64(seed: seed &* 6_151)
            let revs = seed % 2 == 0 ? try RandomHistory.makeSkewed(using: &rng) : try RandomHistory.make(using: &rng)
            let now = revs.map(\.wall).max()!.addingTimeInterval(Double.random(in: 1...86_400, using: &rng))
            try checkGuarantees(revs, mode: mode, now: now, seed: seed, rng: &rng)
            var clock = HybridClock()
            let plan = try CompactionPlanner.plan(revs, mode: mode, now: now, device: devC, clock: &clock, wall: now, app: "t")
            deleted += plan.deletions.count
            XCTAssertEqual(CompactionPlanner.mayDelete(revs.map(RevisionMeta.init), noteId: revs[0].noteId, mode: mode, now: now),
                           !CompactionPlanner.select(revs, mode: mode, now: now).candidates.isEmpty, "seed \(seed)")
            // What stays: every checkpoint, each session's newest point and the newest revision.
            let points = NoteHistory.restorePoints(revs)
            let gone = Set(plan.deletions)
            XCTAssertTrue(gone.isDisjoint(with: points.filter(\.isCheckpoint).map(\.name)), "seed \(seed)")
            XCTAssertFalse(gone.contains(revs.map(\.name).max()!), "seed \(seed)")
        }
        XCTAssertGreaterThan(deleted, 200)   // the property is not vacuous
    }
}
