import Foundation
import XCTest
@testable import Sempere

final class MergeTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

    // MARK: Scenarios

    func testConcurrentAddsOnTwoDevicesBothAppear() throws {
        var log = LogBuilder()
        let s1 = stroke(), s2 = stroke(), s3 = stroke()
        let base = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let a = log.delta(devA, 100, [.addStroke(page: p1, stroke: s1), .addStroke(page: p1, stroke: s3)])
        let b = log.delta(devB, 100, [.addStroke(page: p1, stroke: s2)])
        let state = try NoteReducer.reconstruct([b, a, base])
        // Insertion order by add stamp: (100, aaaaaaaa) before (100, bbbbbbbb).
        XCTAssertEqual(state.strokeIds, [[s1.id, s3.id, s2.id]])
        XCTAssertEqual(try NoteReducer.reconstruct([a, base, b]), state)
    }

    func testRemoveWinsOverConcurrentReAdd() throws {
        var log = LogBuilder()
        let s = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: s)])
        let rmA = log.delta(devA, 200, [.removeStroke(page: p1, strokeId: s.id)])
        // B, not having seen the remove, re-adds the same stroke later (e.g. undo).
        let reB = log.delta(devB, 300, [.addStroke(page: p1, stroke: s)])
        XCTAssertEqual(try NoteReducer.reconstruct([d1, rmA, reB]).allStrokeIds, [])
        XCTAssertEqual(try NoteReducer.reconstruct([reB, rmA, d1]).allStrokeIds, [])
        // Still removed when a snapshot saw all three.
        let snapAll = try log.snapshot(devC, 400, from: [d1, rmA, reB])
        XCTAssertEqual(try NoteReducer.reconstruct([snapAll, reB, d1]).allStrokeIds, [])
    }

    /// Writer obligation (format.md §5.2, §5.6): a removed stroke id is never
    /// added again; undo mints a new id. Whenever the remove and a re-add are
    /// both visible, the reducer ignores the re-add. The case where the re-add
    /// arrives after a snapshot that covered both add and remove (and dropped
    /// the tombstone) cannot arise from a conforming writer, so it is not tested.
    func testRemovedStrokeIdIsNeverReAdded() throws {
        var log = LogBuilder()
        let s = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let rm = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: s.id)])
        let snap = try log.snapshot(devB, 150, from: [d1, rm])
        guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(state.tombstones?.strokes, [s.id])

        // A re-add of a tombstoned id is ignored.
        let reAdd = log.delta(devA, 200, [.addStroke(page: p1, stroke: s)])
        XCTAssertEqual(try NoteReducer.apply([reAdd], to: state, stamp: snap.stamp).allStrokeIds, [])
        // A remove and a later re-add in the same run: the re-add is ignored.
        let s2 = stroke()
        let add2 = log.delta(devA, 300, [.addStroke(page: p1, stroke: s2)])
        let rm2 = log.delta(devA, 400, [.removeStroke(page: p1, strokeId: s2.id)])
        let reAdd2 = log.delta(devB, 500, [.addStroke(page: p1, stroke: s2)])
        XCTAssertEqual(try NoteReducer.apply([reAdd2, rm2, add2], to: state, stamp: snap.stamp).allStrokeIds, [])
        // The conforming way to undo an erase: a new id with `parent` set.
        let restored = stroke(parent: s2.id)
        let undo = log.delta(devA, 600, [.addStroke(page: p1, stroke: restored)])
        let after = try NoteReducer.apply([add2, rm2, undo], to: state, stamp: snap.stamp)
        XCTAssertEqual(after.allStrokeIds, [restored.id])
        XCTAssertEqual(after.pages[0].strokes[0].parent, s2.id)
    }

    func testMergeHonoursRemovalSeenByAnotherSnapshot() throws {
        // A removes X and snapshots; B, which never saw the removal, later
        // writes a newer snapshot that still holds X. The remove delta is
        // compacted, so only the two snapshots remain.
        var log = LogBuilder()
        let x = stroke(), y = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x),
                                     .addStroke(page: p1, stroke: y)])
        let rm = log.delta(devA, 200, [.removeStroke(page: p1, strokeId: x.id)])
        let snapA = try log.snapshot(devA, 250, from: [d1, rm])              // saw add and remove: no x, no tombstone
        let snapB = try log.snapshot(devB, 1000, from: [d1])                 // holds x and y
        guard case .snapshot(_, let stA) = snapA.body else { return XCTFail("not a snapshot") }
        XCTAssertNil(stA.tombstones)
        XCTAssertLessThan(snapA.name, snapB.name, "the stale snapshot is the newer one")
        // Only the snapshots survive; x stays removed because A's snapshot covers its origin.
        for order in [[snapA, snapB], [snapB, snapA]] {
            XCTAssertEqual(try NoteReducer.reconstruct(order).allStrokeIds, [y.id])
        }
        let origin = try XCTUnwrap(try NoteReducer.reconstruct([snapB]).pages[0].strokes.first { $0.id == x.id }?.origin)
        XCTAssertEqual(Origin(origin), Origin(d1.name, op: 1))
    }

    func testCompactedDeltaSurvivesOfflineSnapshot() throws {
        // A writes d1 and snapshots it, then compacts d1. B was offline the
        // whole time and later snapshots with a greater HLC without ever
        // seeing d1 or A's snapshot. d1's content must survive.
        var log = LogBuilder()
        let x = stroke()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x),
                                     .setMeta(.title("From A"))])
        let snapA = try log.snapshot(devA, 10, from: [d1])
        let day: TimeInterval = 86_400
        let now = wallAt(baseMillis).addingTimeInterval(60 * day)
        let coverage = [try XCTUnwrap(SnapshotCoverage(snapA))]
        XCTAssertEqual(CompactionPlanner.deletable(names: [d1.name, snapA.name], wall: [d1.name: d1.wall],
                                                   snapshots: coverage, now: now), [d1.name])

        let dB = log.delta(devB, 5_000_000, [.addPage(Page(id: p2, order: "W")), .setMeta(.favorite(true))])
        let snapB = try log.snapshot(devB, 5_000_100, from: [dB])
        XCTAssertGreaterThan(snapB.hlc, snapA.hlc)
        // d1 is gone from disk; the vault now holds snapA, dB and snapB.
        let state = try NoteReducer.reconstruct([snapB, dB, snapA])
        XCTAssertEqual(state.pages.map(\.id), [p1, p2])
        XCTAssertEqual(state.allStrokeIds, [x.id])
        XCTAssertEqual(state.meta.title, "From A")
        XCTAssertTrue(state.meta.favorite)

        // Neither snapshot subsumes the other, so neither may be deleted ...
        let both = [snapA, snapB].compactMap(SnapshotCoverage.init)
        XCTAssertEqual(CompactionPlanner.deletable(names: [snapA.name, dB.name, snapB.name], wall: [dB.name: dB.wall],
                                                   snapshots: both, now: now.addingTimeInterval(day * 100)), [dB.name])
        // ... until a snapshot that merged both exists.
        let merged = try log.snapshot(devB, 5_000_200, from: [snapA, dB, snapB])
        let all = [snapA, snapB, merged].compactMap(SnapshotCoverage.init)
        XCTAssertEqual(CompactionPlanner.deletable(names: [], wall: [:], snapshots: all,
                                                   now: now.addingTimeInterval(day * 100)), [snapA.name, snapB.name])
        XCTAssertEqual(try NoteReducer.reconstruct([merged]).pages, state.pages)
    }

    func testOrphanAddStrokeIsAppliedOnceItsPageArrives() throws {
        var log = LogBuilder()
        let x = stroke()
        let addPage = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])            // A seq 1
        let draw = log.delta(devA, 100, [.addStroke(page: p1, stroke: x), .setMeta(.title("t"))])  // A seq 2
        // C received A's seq 2 but not seq 1.
        let snap = try log.snapshot(devC, 200, from: [draw])
        guard case .snapshot(let included, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(included.covers(device: devA, seq: 2), "an orphan delta is left out of included")
        XCTAssertEqual(state.meta.title, "t", "its other ops are still applied")
        XCTAssertEqual(state.allStrokeIds, [])
        // The page arrives; the stroke appears.
        let later = try NoteReducer.reconstruct([snap, draw, addPage])
        XCTAssertEqual(later.strokeIds, [[x.id]])
        // And a snapshot taken now includes both.
        let snap2 = try log.snapshot(devC, 300, from: [snap, draw, addPage])
        guard case .snapshot(let inc2, _) = snap2.body else { return XCTFail("not a snapshot") }
        XCTAssertTrue(inc2.covers(device: devA, seq: 1) && inc2.covers(device: devA, seq: 2))
        XCTAssertEqual(try NoteReducer.reconstruct([snap2]).strokeIds, [[x.id]])
    }

    /// Review finding: a tombstone may be dropped only when the revision that
    /// added the stroke is covered by the new `included`, not because an
    /// input snapshot held the stroke (it may hold an orphan's stroke).
    func testTombstoneKeptWhileAddingRevisionIsAnOrphan() throws {
        var log = LogBuilder()
        let q = UUID(uuidString: "00000000-0000-4000-8000-0000000000a9")!
        let s = stroke(), t = stroke()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let a2 = log.delta(devA, 100, [.addStroke(page: p1, stroke: s), .addStroke(page: q, stroke: t)])  // q unseen
        let c1 = try log.snapshot(devC, 200, from: [a1, a2])
        guard case .snapshot(let inc1, let st1) = c1.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(inc1.covers(device: devA, seq: 2), "a2 is an orphan")
        XCTAssertEqual(st1.allStrokeIds, [s.id], "but its stroke on a known page is held")
        let b1 = log.delta(devB, 300, [.removeStroke(page: p1, strokeId: s.id)])
        let c2 = try log.snapshot(devC, 400, from: [c1, a2, b1])
        guard case .snapshot(let inc2, let st2) = c2.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(inc2.covers(device: devA, seq: 2))
        XCTAssertEqual(st2.tombstones?.strokes, [s.id], "a2 is not covered, so the tombstone stays")

        // Compact everything the planner allows; a2 must survive and S must stay removed.
        let all = [a1, a2, c1, b1, c2]
        let wall = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.wall) })
        let doomed = Set(CompactionPlanner.deletable(names: all.map(\.name), wall: wall,
                                                     snapshots: [c1, c2].compactMap(SnapshotCoverage.init),
                                                     retention: 0, now: wallAt(baseMillis + 10_000_000)))
        let kept = all.filter { !doomed.contains($0.name) }
        XCTAssertEqual(Set(kept.map(\.name)), [a2.name, c2.name])
        XCTAssertEqual(try NoteReducer.reconstruct(kept).allStrokeIds, [])

        // Once q arrives, a2 is applied in full: T appears, S stays removed,
        // and the next snapshot may drop the tombstone.
        let addQ = log.delta(devB, 500, [.addPage(Page(id: q, order: "W"))])
        let now = try NoteReducer.reconstruct(kept + [addQ])
        XCTAssertEqual(now.allStrokeIds, [t.id])
        let c3 = try log.snapshot(devC, 600, from: kept + [addQ])
        guard case .snapshot(let inc3, let st3) = c3.body else { return XCTFail("not a snapshot") }
        XCTAssertTrue(inc3.covers(device: devA, seq: 2))
        XCTAssertNil(st3.tombstones?.strokes.first)
        XCTAssertEqual(try NoteReducer.reconstruct([c3, a2]).allStrokeIds, [t.id])
    }

    /// Page tombstones are permanent (§5.4): a late addStroke on a page whose
    /// add and remove were both compacted is a covered no-op, not an orphan,
    /// so `included` stays contiguous.
    func testLateAddStrokeOnRemovedPageIsACoveredNoOp() throws {
        var log = LogBuilder()
        let addP = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let rmP = log.delta(devB, 100, [.removePage(pageId: p1)])
        let s1 = try log.snapshot(devB, 200, from: [addP, rmP])
        guard case .snapshot(_, let st1) = s1.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(st1.tombstones?.pages, [p1], "kept although the add was seen")
        // addP and rmP are compacted; a late stroke from C arrives.
        var lateLog = log
        let late = lateLog.delta(devC, 50, [.addStroke(page: p1, stroke: stroke())])
        var current = [s1, late]
        for i in 0..<3 {
            let snap = try lateLog.snapshot(devB, 300 + Int64(i) * 100, from: current)
            guard case .snapshot(let inc, let st) = snap.body else { return XCTFail("not a snapshot") }
            XCTAssertEqual(inc.entries[devC], Included.Entry(upTo: 1, extra: []))
            XCTAssertEqual(st.pages, [])
            XCTAssertEqual(st.tombstones?.pages, [p1])
            current = [snap]
        }
    }

    func testApplyDoesNotInventOrigins() throws {
        var log = LogBuilder()
        let held = stroke()
        let state = NoteState(meta: NoteMeta(created: wallAt(baseMillis)),
                              pages: [Page(id: p1, order: "V", strokes: [held])])
        let added = stroke()
        let d = log.delta(devA, 100, [.addStroke(page: p1, stroke: added)])
        let out = try NoteReducer.apply([d], to: state, stamp: Stamp(hlc: HLC(millis: baseMillis, counter: 0)!, device: devB))
        XCTAssertEqual(out.pages[0].strokes.map(\.id), [held.id, added.id])
        XCTAssertNil(out.pages[0].strokes[0].origin, "no real revision added it here")
        XCTAssertNil(out.pages[0].origin)
        XCTAssertEqual(out.pages[0].strokes[1].origin, Origin(d.name, op: 0).description)
    }

    /// format.md §5.6.1; more cases in `ConcurrentSliceTests`.
    func testConcurrentSlicingKeepsOnePieceSet() throws {
        var log = LogBuilder()
        let x = stroke()
        let a1 = stroke(parent: x.id), a2 = stroke(parent: x.id)
        let b1 = stroke(parent: x.id), b2 = stroke(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        let state = try NoteReducer.reconstruct([sliceB, d0, sliceA])
        // Same hlc: B's greater device id wins; A's pieces are superseded.
        XCTAssertEqual(state.strokeIds, [[b1.id, b2.id]])
        XCTAssertTrue(state.pages[0].strokes.allSatisfy { $0.parent == x.id && $0.replaces })
        XCTAssertEqual(state.tombstones.map { Set($0.superseded) }, [a1.id, a2.id])
        XCTAssertEqual(state.tombstones?.strokes, [])
    }

    func testTombstonePreventsResurrectionAfterOutOfOrderArrival() throws {
        var log = LogBuilder()
        let s = stroke()
        let page = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V"))])
        let add = log.delta(devA, 100, [.addStroke(page: p1, stroke: s)])        // A seq 2
        let remove = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: s.id)])
        // C has received the page and the remove, but not yet the add.
        let snap = try log.snapshot(devC, 300, from: [page, remove])
        guard case .snapshot(let included, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(included.covers(device: devA, seq: 2))
        XCTAssertEqual(state.tombstones, Tombstones(strokes: [s.id]))
        // The add arrives late; the old remove still wins.
        XCTAssertEqual(try NoteReducer.reconstruct([snap, add]).allStrokeIds, [])
        XCTAssertEqual(try NoteReducer.reconstruct([add, page, snap, remove]).allStrokeIds, [])
        // Without the tombstone, the snapshot would resurrect it (guards the test itself).
        var bare = state
        bare.tombstones = nil
        let unsafe = Revision(noteId: testNote, device: devC, seq: snap.seq, hlc: snap.hlc, wall: snap.wall, app: "x",
                              body: .snapshot(included: included, state: bare))
        XCTAssertEqual(try NoteReducer.reconstruct([unsafe, add]).allStrokeIds, [s.id])
        // Once a later snapshot sees the add, the tombstone is dropped and the stroke stays gone.
        let snap2 = try log.snapshot(devA, 400, from: [snap, add])
        guard case .snapshot(let inc2, let state2) = snap2.body else { return XCTFail("not a snapshot") }
        XCTAssertTrue(inc2.covers(device: devA, seq: 2))
        XCTAssertNil(state2.tombstones)
        XCTAssertEqual(try NoteReducer.reconstruct([snap2, snap, add, page, remove]).allStrokeIds, [])
    }

    func testRemovedPageTombstone() throws {
        var log = LogBuilder()
        let addP = log.delta(devA, 0, [.addPage(Page(id: p2, order: "V")), .addStroke(page: p2, stroke: stroke())])
        let rmP = log.delta(devB, 100, [.removePage(pageId: p2)])
        let snap = try log.snapshot(devC, 200, from: [rmP])
        guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(state.tombstones?.pages, [p2])
        XCTAssertEqual(try NoteReducer.reconstruct([addP, snap]).pages, [])
    }

    func testLateDeltaVersusSnapshotClock() throws {
        // The snapshot recorded title set at t=300; a late delta at t=200 loses.
        var log = LogBuilder()
        let t1 = log.delta(devA, 100, [.setMeta(.title("One"))])
        let t3 = log.delta(devA, 300, [.setMeta(.title("Three"))])
        let snap = try log.snapshot(devB, 400, from: [t1, t3])
        guard case .snapshot(_, let st) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(st.clocks?["title"], Stamp(hlc: t3.hlc, device: devA).description)
        let lateOlder = log.delta(devC, 200, [.setMeta(.title("Two"))])
        XCTAssertEqual(try NoteReducer.reconstruct([lateOlder, snap]).meta.title, "Three")

        // The snapshot recorded title set at t=100; a late delta at t=200 (older
        // than the snapshot itself) wins.
        var log2 = LogBuilder()
        let u1 = log2.delta(devA, 100, [.setMeta(.title("One"))])
        let snapB = try log2.snapshot(devB, 400, from: [u1])
        let late = log2.delta(devC, 200, [.setMeta(.title("Two"))])
        XCTAssertEqual(try NoteReducer.reconstruct([snapB, late]).meta.title, "Two")
        XCTAssertEqual(try NoteReducer.reconstruct([late, u1, snapB]).meta.title, "Two")

        // A snapshot without clocks stamps registers with its own (hlc, device).
        guard case .snapshot(let inc, var bare) = snapB.body else { return XCTFail("not a snapshot") }
        bare.clocks = nil
        let unclocked = Revision(noteId: testNote, device: devB, seq: snapB.seq, hlc: snapB.hlc, wall: snapB.wall,
                              app: "x", body: .snapshot(included: inc, state: bare))
        XCTAssertEqual(try NoteReducer.reconstruct([unclocked, late]).meta.title, "One")
        let newer = log2.delta(devC, 500, [.setMeta(.title("Five"))])
        XCTAssertEqual(try NoteReducer.reconstruct([unclocked, late, newer]).meta.title, "Five")
    }

    func testPageReorderLWW() throws {
        var log = LogBuilder()
        let add = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addPage(Page(id: p2, order: "b"))])
        let moveA = log.delta(devA, 100, [.setPageOrder(pageId: p1, order: "c")])   // p1 after p2
        let moveB = log.delta(devB, 150, [.setPageOrder(pageId: p2, order: "0")])   // p2 first
        let moveC = log.delta(devC, 120, [.setPageOrder(pageId: p1, order: "Z")])   // loses to nothing on p1? 120 > 100
        let state = try NoteReducer.reconstruct([moveA, moveB, moveC, add])
        XCTAssertEqual(state.pages.map(\.id), [p2, p1])
        XCTAssertEqual(state.pages.map(\.order), ["0", "Z"])
        XCTAssertEqual(state.pages[1].orderClock, Stamp(hlc: moveC.hlc, device: devC).description)

        // Equal order keys tie-break on id.
        let tie = log.delta(devA, 200, [.setPageOrder(pageId: p2, order: "Z")])
        XCTAssertEqual(try NoteReducer.reconstruct([add, moveC, tie]).pages.map(\.id), [p1, p2])

        // The recorded orderClock survives a snapshot: a late older move loses, a late newer one wins.
        let snap = try log.snapshot(devB, 300, from: [add, moveA])
        let lateOld = log.delta(devC, 50, [.setPageOrder(pageId: p1, order: "0")])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateOld]).pages.first { $0.id == p1 }?.order, "c")
        let lateNew = log.delta(devC, 250, [.setPageOrder(pageId: p1, order: "0")])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateNew]).pages.first { $0.id == p1 }?.order, "0")
    }

    func testPageRecognitionLWW() throws {
        func rec(_ text: String) -> Recognition {
            Recognition(engine: "test-1", text: text, words: [.init(text: text, box: .init(x: 1, y: 2, w: 3, h: 4))])
        }
        var log = LogBuilder()
        let add = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addPage(Page(id: p2, order: "b"))])
        // Never set: no recognition and no clock.
        let plain = try NoteReducer.reconstruct([add])
        XCTAssertNil(plain.pages[0].recognition)
        XCTAssertNil(plain.pages[0].recognitionClock)

        let setA = log.delta(devA, 100, [.setPageRecognition(pageId: p1, recognition: rec("one"))])
        let setB = log.delta(devB, 150, [.setPageRecognition(pageId: p1, recognition: rec("two"))])
        let setC = log.delta(devC, 120, [.setPageRecognition(pageId: p1, recognition: rec("three"))])
        let state = try NoteReducer.reconstruct([setC, setB, add, setA])
        XCTAssertEqual(state.pages[0].recognition?.text, "two")
        XCTAssertEqual(state.pages[0].recognitionClock, Stamp(hlc: setB.hlc, device: devB).description)
        XCTAssertNil(state.pages[1].recognition)
        XCTAssertEqual(try NoteReducer.reconstruct([add, setA, setB, setC]), state)

        // Clearing is an ordinary LWW write.
        let clear = log.delta(devA, 200, [.setPageRecognition(pageId: p1, recognition: nil)])
        let cleared = try NoteReducer.reconstruct([add, setA, setB, clear])
        XCTAssertNil(cleared.pages[0].recognition)
        XCTAssertEqual(cleared.pages[0].recognitionClock, Stamp(hlc: clear.hlc, device: devA).description)

        // The recorded clock survives a snapshot: a late older write loses, a late newer one wins.
        let snap = try log.snapshot(devB, 300, from: [add, setA, setB])
        guard case .snapshot(_, let snapState) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(snapState.pages.first { $0.id == p1 }?.recognition?.text, "two")
        XCTAssertNil(snapState.pages.first { $0.id == p2 }?.recognitionClock)
        let lateOld = log.delta(devC, 50, [.setPageRecognition(pageId: p1, recognition: rec("old"))])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateOld]).pages[0].recognition?.text, "two")
        let lateNew = log.delta(devC, 250, [.setPageRecognition(pageId: p1, recognition: rec("new"))])
        XCTAssertEqual(try NoteReducer.reconstruct([lateNew, snap]).pages[0].recognition?.text, "new")
        // A page the snapshot never saw recognized does not compete: an older uncovered write still lands.
        let lateP2 = log.delta(devC, 60, [.setPageRecognition(pageId: p2, recognition: rec("p2"))])
        XCTAssertEqual(try NoteReducer.reconstruct([snap, lateP2]).pages[1].recognition?.text, "p2")
        // A cleared register in a snapshot does compete.
        let snapCleared = try log.snapshot(devB, 400, from: [add, setA, setB, clear])
        XCTAssertNil(try NoteReducer.reconstruct([snapCleared, lateOld]).pages[0].recognition)

        // `apply` honors the same register.
        let applied = try NoteReducer.apply([lateNew], to: snapState, stamp: snap.stamp)
        XCTAssertEqual(applied.pages[0].recognition?.text, "new")
        XCTAssertEqual(try NoteReducer.apply([lateOld], to: snapState, stamp: snap.stamp).pages[0].recognition?.text,
                       "two")

        // An op naming a page nobody has seen is an orphan, applied again once the page arrives.
        let p3 = UUID()
        let early = log.delta(devA, 500, [.setPageRecognition(pageId: p3, recognition: rec("early"))])
        let s2 = try log.snapshot(devB, 510, from: [add, early])
        guard case .snapshot(let inc, _) = s2.body else { return XCTFail("not a snapshot") }
        XCTAssertFalse(inc.covers(device: devA, seq: early.seq))
        let page3 = log.delta(devC, 520, [.addPage(Page(id: p3, order: "c"))])
        XCTAssertEqual(try NoteReducer.reconstruct([s2, early, page3]).pages.first { $0.id == p3 }?.recognition?.text,
                       "early")
    }

    func testDeleteAndRestoreNote() throws {
        var log = LogBuilder()
        let d0 = log.delta(devA, 0, [.setMeta(.title("x"))])
        let del = log.delta(devA, 100, [.deleteNote])
        XCTAssertTrue(try NoteReducer.reconstruct([d0, del]).deleted)
        let restore = log.delta(devB, 200, [.restoreNote])
        XCTAssertFalse(try NoteReducer.reconstruct([restore, d0, del]).deleted)
        let delAgain = log.delta(devC, 150, [.deleteNote])    // concurrent, older than the restore
        XCTAssertFalse(try NoteReducer.reconstruct([delAgain, restore, d0, del]).deleted)
        let snap = try log.snapshot(devA, 300, from: [d0, del, restore])
        XCTAssertFalse(try NoteReducer.reconstruct([snap, delAgain]).deleted)
        let delLater = log.delta(devC, 400, [.deleteNote])
        XCTAssertTrue(try NoteReducer.reconstruct([snap, delAgain, delLater]).deleted)
    }

    func testCreatedIsEarliestWall() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 500, [.setMeta(.title("x"))])
        let d2 = log.delta(devB, 100, [.setMeta(.favorite(true))])
        XCTAssertEqual(try NoteReducer.reconstruct([d1, d2]).meta.created, d2.wall)
    }

    func testErrors() throws {
        var log = LogBuilder()
        let d = log.delta(devA, 0, [])
        XCTAssertThrowsError(try NoteReducer.reconstruct([])) { XCTAssertEqual($0 as? NoteLogError, .noRevisions) }
        var other = d
        other.noteId = UUID()
        XCTAssertThrowsError(try NoteReducer.reconstruct([d, other]))
        var clash = d
        clash.body = .delta(ops: [.deleteNote])
        XCTAssertThrowsError(try NoteReducer.reconstruct([d, clash])) {
            XCTAssertEqual($0 as? NoteLogError, .conflictingRevisions(device: devA, seq: 1))
        }
        XCTAssertNoThrow(try NoteReducer.reconstruct([d, d]))   // exact duplicates are fine
    }

    func testIncrementalApplyMatchesReconstruct() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: stroke())])
        let d2 = log.delta(devA, 100, [.addStroke(page: p1, stroke: stroke()), .setMeta(.title("t"))])
        let d3 = log.delta(devB, 200, [.setPageOrder(pageId: p1, order: "W")])
        var state = try NoteReducer.reconstruct([d1])
        state = try NoteReducer.apply([d2], to: state, stamp: .zero)
        state = try NoteReducer.apply([d3], to: state, stamp: .zero)
        XCTAssertEqual(state, try NoteReducer.reconstruct([d3, d1, d2]))
        let snap = try log.snapshot(devA, 300, from: [d1])
        XCTAssertThrowsError(try NoteReducer.apply([snap], to: state, stamp: .zero))
    }

    // MARK: Property: order independence (format.md §5.3)

    func testReconstructIsOrderIndependent() throws {
        try checkOrderIndependence(attachments: false)
    }

    /// The same property with placed items and recordings (format.md §8.2,
    /// §8.3): adds, removes, register sets, orphans, moves between pages.
    func testReconstructWithAttachmentsIsOrderIndependent() throws {
        try checkOrderIndependence(attachments: true)
    }

    func checkOrderIndependence(attachments: Bool) throws {
        for seed in UInt64(1)...4 {
            var rng = SplitMix64(seed: attachments ? seed + 100 : seed)
            let revisions = try Self.randomLog(rng: &rng, attachments: attachments)
            XCTAssertEqual(revisions.filter { $0.kind == .snapshot }.count, 2)
            let reference = try NoteReducer.reconstruct(revisions)
            XCTAssertFalse(reference.pages.isEmpty, "seed \(seed): generator produced an empty note")
            if !attachments { XCTAssertFalse(reference.tagSet.removed.isEmpty, "seed \(seed): no tag was removed") }
            if attachments {
                XCTAssertFalse(reference.pages.allSatisfy(\.items.isEmpty), "seed \(seed): no item")
                XCTAssertFalse(reference.recordings.isEmpty, "seed \(seed): no recording")
                XCTAssertFalse(reference.tombstones?.items.isEmpty ?? true, "seed \(seed): no item removed")
                XCTAssertFalse(reference.tombstones?.recordings.isEmpty ?? true, "seed \(seed): no recording removed")
                XCTAssertTrue(reference.pages.flatMap(\.items).contains { $0.clocks?["frame"] != nil })
            }
            let refJSON = try InkJSON.encoder().encode(reference)
            for i in 0..<50 {
                let shuffled = revisions.shuffled(using: &rng)
                let state = try NoteReducer.reconstruct(shuffled)
                XCTAssertEqual(state, reference, "seed \(seed) permutation \(i)")
                XCTAssertEqual(try InkJSON.encoder().encode(state), refJSON, "seed \(seed) permutation \(i)")
            }

            // Compaction (everything past retention) never changes the visible note.
            let snaps = revisions.compactMap(SnapshotCoverage.init)
            let wall = Dictionary(uniqueKeysWithValues: revisions.map { ($0.name, $0.wall) })
            let doomed = Set(CompactionPlanner.deletable(names: revisions.map(\.name), wall: wall, snapshots: snaps,
                                                         retention: 0, now: wallAt(baseMillis + 10_000_000)))
            XCTAssertFalse(doomed.isEmpty)
            let compacted = try NoteReducer.reconstruct(revisions.filter { !doomed.contains($0.name) })
            XCTAssertEqual(compacted.pages, reference.pages, "seed \(seed)")
            XCTAssertEqual(compacted.meta, reference.meta, "seed \(seed)")
            XCTAssertEqual(compacted.deleted, reference.deleted, "seed \(seed)")
            XCTAssertEqual(compacted.clocks, reference.clocks, "seed \(seed)")
            XCTAssertEqual(compacted.tagSet, reference.tagSet, "seed \(seed)")
            XCTAssertEqual(compacted.recordings, reference.recordings, "seed \(seed)")
            XCTAssertEqual(compacted.tombstones?.items, reference.tombstones?.items, "seed \(seed)")
            XCTAssertEqual(compacted.tombstones?.recordings, reference.tombstones?.recordings, "seed \(seed)")

            // A snapshot of everything reconstructs to the same note, and its JSON round-trips.
            var clock = HybridClock()
            let all = try SnapshotBuilder.makeSnapshot(from: revisions, device: devC, seq: 1_000, clock: &clock,
                                                       wall: wallAt(baseMillis + 20_000_000), app: "test/0")
            let fromSnapshot = try NoteReducer.reconstruct([all])
            XCTAssertEqual(fromSnapshot.pages, reference.pages, "seed \(seed)")
            XCTAssertEqual(fromSnapshot.recordings, reference.recordings, "seed \(seed)")
            let json = try InkJSON.encoder().encode(all)
            XCTAssertEqual(try InkJSON.encoder().encode(InkJSON.decoder().decode(Revision.self, from: json)), json)
        }
    }

    /// 3 devices, 200 ops (adds, removes incl. of never-added ids, slices,
    /// meta incl. per-tag adds and removes, page moves,
    /// page removes, delete/restore), 2 snapshots from
    /// partial views. Writers follow §5.2: no removed id is re-added.
    ///
    /// With `attachments`, about a third of the ops are item and recording
    /// ops: adds of every kind (an unknown one included), removes (some of
    /// ids nobody adds), `setItem` / `setRecording` of typed and unknown
    /// fields (some on ids nobody adds: permanent orphans), moves to another
    /// page (remove + add with `parent`).
    static func randomLog(rng: inout SplitMix64, attachments: Bool = false) throws -> [Revision] {
        let devices = [devA, devB, devC]
        var clocks = [HybridClock(), HybridClock(), HybridClock()]
        var seqs = [0, 0, 0]
        var log: [Revision] = []
        var pages: [UUID] = []
        var strokes: [(page: UUID, stroke: Stroke)] = []
        var tagInstances: [(tag: String, origin: Origin)] = []
        var items: [(page: UUID, item: Item)] = []
        var recordings: [UUID] = []
        var opCount = 0
        let snapshotAt = [Int.random(in: 30..<100, using: &rng), Int.random(in: 100..<190, using: &rng)]
        var snapshotsDone = 0
        var step: Int64 = 0

        while opCount < 200 {
            step += 1
            let di = Int.random(in: 0..<3, using: &rng)
            let wall = wallAt(baseMillis + step * 1000 + Int64.random(in: -5000...5000, using: &rng))
            let hlc = clocks[di].tick(wall: wall)
            var ops: [Op] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) where opCount < 200 {
                opCount += 1
                if attachments, !pages.isEmpty, Double.random(in: 0..<1, using: &rng) < 0.35 {
                    ops += Self.randomAttachmentOps(rng: &rng, pages: pages, items: &items, recordings: &recordings)
                    continue
                }
                let r = Double.random(in: 0..<1, using: &rng)
                if pages.isEmpty || r < 0.10 {
                    let p = Page(id: UUID.random(using: &rng), order: ["a", "b", "V", "c0"].randomElement(using: &rng) ?? "a")
                    pages.append(p.id)
                    ops.append(.addPage(p))
                } else if r < 0.40 || strokes.isEmpty {
                    let page = pages.randomElement(using: &rng) ?? pages[0]
                    let s = stroke(UUID.random(using: &rng))
                    strokes.append((page, s))
                    ops.append(.addStroke(page: page, stroke: s))
                } else if r < 0.50 {
                    if Double.random(in: 0..<1, using: &rng) < 0.15 {
                        // Removal of an id whose add nobody ever writes.
                        ops.append(.removeStroke(page: pages[0], strokeId: UUID.random(using: &rng)))
                    } else if let victim = strokes.randomElement(using: &rng) {
                        ops.append(.removeStroke(page: victim.page, strokeId: victim.stroke.id))
                    }
                } else if r < 0.58, let victim = strokes.randomElement(using: &rng) {
                    // Slice: remove + two pieces.
                    ops.append(.removeStroke(page: victim.page, strokeId: victim.stroke.id))
                    for _ in 0..<2 {
                        let piece = stroke(UUID.random(using: &rng), parent: victim.stroke.id)
                        strokes.append((victim.page, piece))
                        ops.append(.addStroke(page: victim.page, stroke: piece))
                    }
                } else if r < 0.78 {
                    let change: MetaChange
                    switch Int.random(in: 0..<6, using: &rng) {
                    case 0: change = .title("t\(Int.random(in: 0..<100, using: &rng))")
                    case 1:
                        // Per-tag ops (§5.4.1).
                        let pick = Int.random(in: 0..<5, using: &rng)
                        if pick <= 1 || tagInstances.isEmpty {
                            let tag = ["x0", "X0", "x1", "y", "Y", "Fall Term"].randomElement(using: &rng) ?? "y"
                            tagInstances.append((tag, Origin(hlc: hlc, device: devices[di], seq: seqs[di] + 1,
                                                             op: ops.count)))
                            ops.append(.addTag(tag))
                            continue
                        } else {
                            let victim = tagInstances.randomElement(using: &rng) ?? tagInstances[0]
                            let key = NoteOps.tagKey(victim.tag)
                            // A partial view of the key's instances, sometimes an unknown one.
                            var observed = tagInstances.filter { NoteOps.tagKey($0.tag) == key && Bool.random(using: &rng) }
                                .map(\.origin)
                            if Double.random(in: 0..<1, using: &rng) < 0.2 {
                                observed.append(Origin(hlc: hlc, device: devA, seq: 999, op: 0))
                            }
                            ops.append(.removeTag(victim.tag.uppercased(), observed: observed + [victim.origin]))
                            continue
                        }
                    case 2: change = .notebook(Bool.random(using: &rng) ? nil : "nb")
                    case 3: change = .favorite(Bool.random(using: &rng))
                    case 4: change = .paper(Bool.random(using: &rng) ? .ruled : .blank)
                    default: change = .pageSize(Bool.random(using: &rng) ? .a4 : .letter)
                    }
                    ops.append(.setMeta(change))
                } else if r < 0.84, let p = pages.randomElement(using: &rng) {
                    ops.append(.setPageOrder(pageId: p, order: PageOrder.between(nil, ["a", "b", "c"].randomElement(using: &rng))))
                } else if r < 0.88, let p = pages.randomElement(using: &rng) {
                    let text = "r\(Int.random(in: 0..<100, using: &rng))"
                    ops.append(.setPageRecognition(pageId: p, recognition: Bool.random(using: &rng) ? nil
                        : Recognition(engine: "test-1", text: text)))
                } else if r < 0.92, pages.count > 2, let p = pages.randomElement(using: &rng) {
                    ops.append(.removePage(pageId: p))
                } else {
                    ops.append(Bool.random(using: &rng) ? .deleteNote : .restoreNote)
                }
            }
            seqs[di] += 1
            log.append(Revision(noteId: testNote, device: devices[di], seq: seqs[di], hlc: hlc,
                                wall: wall, app: "test/0", body: .delta(ops: ops)))

            if snapshotsDone < 2, opCount >= snapshotAt[snapshotsDone] {
                snapshotsDone += 1
                let si = Int.random(in: 0..<3, using: &rng)
                // A partial view: the writer has received ~70% of the log so far.
                let view = log.filter { _ in Double.random(in: 0..<1, using: &rng) < 0.7 }
                guard !view.isEmpty else { continue }
                seqs[si] += 1
                log.append(try SnapshotBuilder.makeSnapshot(from: view, device: devices[si], seq: seqs[si],
                                                            clock: &clocks[si], wall: wall, app: "test/0"))
            }
        }
        return log
    }

    static func randomAttachmentOps(rng: inout SplitMix64, pages: [UUID], items: inout [(page: UUID, item: Item)],
                             recordings: inout [UUID]) -> [Op] {
        func rect() -> Rect {
            Rect(x: Double(Int.random(in: 0..<500, using: &rng)), y: Double(Int.random(in: 0..<700, using: &rng)),
                 w: Double(Int.random(in: 1..<300, using: &rng)), h: Double(Int.random(in: 1..<300, using: &rng)))
        }
        let blob = BlobRef(sha256: String(repeating: "ab", count: 32), size: 10, type: "image/png")
        func newItem(parent: UUID? = nil, like old: Item? = nil) -> Item {
            if var c = old { c.id = UUID.random(using: &rng); c.parent = parent; return c }
            let z = ["a", "b", "a0", "c"].randomElement(using: &rng) ?? "a"
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                return .text(id: UUID.random(using: &rng), TextContent(size: 12, color: .black,
                                                                    runs: [TextRun("t\(Int.random(in: 0..<9, using: &rng))")]),
                             frame: rect(), z: z)
            case 1:
                return .image(id: UUID.random(using: &rng), blob: blob, pixelSize: Size(w: 10, h: 10), frame: rect(), z: z)
            case 2:
                return .pdfPage(id: UUID.random(using: &rng), blob: BlobRef(sha256: String(repeating: "cd", count: 32),
                                                                           size: 99, type: "application/pdf"),
                                pageIndex: Int.random(in: 0..<3, using: &rng), pageSize: Size(w: 612, h: 792),
                                frame: rect(), z: z)
            default:
                return Item(id: UUID.random(using: &rng), kind: ItemKind(rawValue: "sticker"), layer: ItemLayer(rawValue: 50),
                            frame: rect(), z: z, extra: ["glyph": .string("star"), "points": .array([.number(1)])])
            }
        }
        let r = Double.random(in: 0..<1, using: &rng)
        if items.isEmpty || r < 0.22 {
            let page = pages.randomElement(using: &rng) ?? pages[0]
            let item = newItem()
            items.append((page, item))
            return [.addItem(page: page, item: item)]
        } else if r < 0.30 {
            if Double.random(in: 0..<1, using: &rng) < 0.2 {
                return [.removeItem(page: pages[0], itemId: UUID.random(using: &rng))]
            }
            let victim = items.randomElement(using: &rng) ?? items[0]
            return [.removeItem(page: victim.page, itemId: victim.item.id)]
        } else if r < 0.35 {
            // Move to another page: remove + add of a copy naming it.
            let victim = items.randomElement(using: &rng) ?? items[0]
            let page = pages.randomElement(using: &rng) ?? pages[0]
            let copy = newItem(parent: victim.item.id, like: victim.item)
            items.append((page, copy))
            return [.removeItem(page: victim.page, itemId: victim.item.id), .addItem(page: page, item: copy)]
        } else if r < 0.62 {
            let target = items.randomElement(using: &rng) ?? items[0]
            var id = target.item.id
            if Double.random(in: 0..<1, using: &rng) < 0.05 { id = UUID.random(using: &rng) }   // never added
            let change: ItemChange
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: change = .frame(rect())
            case 1: change = .rotation(Bool.random(using: &rng) ? nil : Double(Int.random(in: 0..<360, using: &rng)))
            case 2: change = .z(["a", "b", "z"].randomElement(using: &rng) ?? "a")
            case 3: change = .crop(Bool.random(using: &rng) ? nil : rect())
            case 4: change = .text(TextContent(size: 14, color: .black, runs: [TextRun("e\(Int.random(in: 0..<9, using: &rng))")]))
            default: change = .other(field: "note", value: Bool.random(using: &rng) ? .null : .string("n\(Int.random(in: 0..<9, using: &rng))"))
            }
            return [.setItem(page: target.page, itemId: id, change: change)]
        } else if r < 0.75 || recordings.isEmpty {
            let rec = Recording(id: UUID.random(using: &rng),
                                blob: BlobRef(sha256: String(repeating: "ef", count: 32), size: 7, type: "audio/mp4"),
                                started: wallAt(baseMillis + Int64(Int.random(in: 0..<4, using: &rng)) * 1000),
                                title: Bool.random(using: &rng) ? nil : "r")
            recordings.append(rec.id)
            return [.addRecording(rec)]
        } else if r < 0.82 {
            let id = Double.random(in: 0..<1, using: &rng) < 0.2 ? UUID.random(using: &rng)
                : (recordings.randomElement(using: &rng) ?? recordings[0])
            return [.removeRecording(recordingId: id)]
        } else {
            var id = recordings.randomElement(using: &rng) ?? recordings[0]
            if Double.random(in: 0..<1, using: &rng) < 0.05 { id = UUID.random(using: &rng) }
            let change: RecordingChange
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: change = .title(Bool.random(using: &rng) ? nil : "title \(Int.random(in: 0..<9, using: &rng))")
            case 1: change = .transcript(Bool.random(using: &rng) ? nil
                : BlobRef(sha256: String(repeating: "12", count: 32), size: 3, type: BlobRef.transcriptType))
            default: change = .other(field: "speaker", value: .string("s\(Int.random(in: 0..<3, using: &rng))"))
            }
            return [.setRecording(recordingId: id, change: change)]
        }
    }
}
