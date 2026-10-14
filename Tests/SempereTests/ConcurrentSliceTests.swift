import Foundation
import XCTest
@testable import Sempere

/// Concurrent replacements of one stroke (format.md §5.6.1): two devices
/// slice, move or recolor the same stroke without seeing each other's edit.
final class ConcurrentSliceTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!

    /// A stroke with distinct points, so overlapping copies are easy to tell apart.
    func ink(_ id: UUID = UUID(), parent: UUID? = nil, x: Double = 0, transform: Transform? = nil,
             color: Color = .black) -> Stroke {
        Stroke(id: id, ink: Ink(tool: .pen, color: color, width: 2),
               points: [StrokePoint(x: x, y: 2, w: 2, h: 2), StrokePoint(x: x + 10, y: 2, w: 2, h: 2)],
               transform: transform, parent: parent)
    }

    /// Every order of `revs` reconstructs to the same note; returns it.
    func reconstructAll(_ revs: [Revision], file: StaticString = #filePath, line: UInt = #line) throws -> NoteState {
        let reference = try NoteReducer.reconstruct(revs)
        var rng = SplitMix64(seed: 7)
        for _ in 0..<24 {
            XCTAssertEqual(try NoteReducer.reconstruct(revs.shuffled(using: &rng)), reference, file: file, line: line)
        }
        return reference
    }

    // MARK: Reproductions

    func testConcurrentSlicesKeepOneSetOfPieces() throws {
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id, x: 0), a2 = ink(parent: x.id, x: 6)
        let b1 = ink(parent: x.id, x: 3)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1)])
        // B's slice is the later replacement: A's pieces would overlap it and
        // bring back what B erased, and B's piece what A erased.
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB]).allStrokeIds, [b1.id])
        // The other way round, A's pieces stay.
        var log2 = LogBuilder()
        let e0 = log2.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let lateA = log2.delta(devA, 300, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let earlyB = log2.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id),
                                            .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([e0, lateA, earlyB]).allStrokeIds, [a1.id, a2.id])
    }

    func testConcurrentSlicesWithEqualClocksResolveByDevice() throws {
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), b1 = ink(parent: x.id), b2 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let sliceB = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        // Same hlc: the greater device id wins, as for every LWW register.
        let state = try reconstructAll([sliceB, d0, sliceA])
        XCTAssertEqual(state.strokeIds, [[b1.id, b2.id]])
        // A snapshot remembers what lost, nothing else: x's tombstone is covered.
        XCTAssertEqual(state.tombstones, Tombstones(superseded: [a1.id]))
    }

    func testConcurrentSliceAndMove() throws {
        var log = LogBuilder()
        let x = ink()
        let piece = ink(parent: x.id)
        let moved = ink(parent: x.id, transform: Transform(a: 1, b: 0, c: 0, d: 1, tx: 40, ty: 0))
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let slice = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: piece)])
        let move = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: moved)])
        // Not the moved stroke plus the sliced piece left where it was: the later edit.
        XCTAssertEqual(try reconstructAll([d0, slice, move]).allStrokeIds, [moved.id])
    }

    func testConcurrentSliceAndRecolour() throws {
        var log = LogBuilder()
        let x = ink()
        let piece = ink(parent: x.id)
        let red = ink(parent: x.id, color: Color(r: 255, g: 0, b: 0))
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let recolour = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: red)])
        let slice = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: piece)])
        XCTAssertEqual(try reconstructAll([d0, recolour, slice]).allStrokeIds, [piece.id])
    }

    func testSliceOfASlicedStroke() throws {
        // Sequential: B saw A's slice and slices one of its pieces. Nothing competes.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a2 = ink(parent: x.id)
        let b1 = ink(parent: a1.id), b2 = ink(parent: a1.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: a1.id),
                                           .addStroke(page: p1, stroke: b1), .addStroke(page: p1, stroke: b2)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB]).allStrokeIds, [a2.id, b1.id, b2.id])

        // Concurrent: both slice the same piece.
        let c1 = ink(parent: a1.id)
        let sliceC = log.delta(devC, 300, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: c1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, sliceB, sliceC]).allStrokeIds, [a2.id, c1.id])
    }

    func testTheLosingSideLosesWhatItDidToItsPiecesLater() throws {
        // A slices x, then (still without B's edit) slices one of its pieces
        // again; B's concurrent slice of x is later and wins: A's whole line
        // of pieces goes, not only the first set.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a2 = ink(parent: x.id), a11 = ink(parent: a1.id)
        let b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                           .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let againA = log.delta(devA, 150, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: a11)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, againA, sliceB]).allStrokeIds, [b1.id])
    }

    // MARK: Re-creations

    func testReCreationsAreNotReplacements() throws {
        // A erases x and undoes it (a re-creation: new id, `parent` = x, x
        // already removed); B concurrently slices x. Both stay (format.md
        // §5.6.1 "Not covered"), and the report finds the duplicate.
        var log = LogBuilder()
        let x = ink()
        let back = ink(parent: x.id), b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let erase = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id)])
        let undo = log.delta(devA, 300, [.addStroke(page: p1, stroke: back)])
        let slice = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        let revs = [d0, erase, undo, slice]
        XCTAssertEqual(try reconstructAll(revs).allStrokeIds, [back.id, b1.id])
        let conflicts = try NoteReducer.strokeConflicts(revs)
        XCTAssertEqual(conflicts.superseded, [])
        XCTAssertEqual(conflicts.duplicates, [StrokeRef(page: p1, stroke: b1.id)])
        let fix = log.delta(devC, 400, conflicts.ops)
        XCTAssertEqual(try reconstructAll(revs + [fix]).allStrokeIds, [back.id])
        XCTAssertTrue(try NoteReducer.strokeConflicts(revs + [fix]).isEmpty)
    }

    func testUndoAndRedoOfASliceOnOneDevice() throws {
        // Slice, undo (x comes back as a re-creation), redo (the pieces come
        // back as re-creations of the pieces): nothing competes.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a2 = ink(parent: x.id)
        let x2 = ink(parent: x.id)
        let a1b = ink(parent: a1.id), a2b = ink(parent: a2.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let slice = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id),
                                          .addStroke(page: p1, stroke: a1), .addStroke(page: p1, stroke: a2)])
        let undo = log.delta(devA, 200, [.removeStroke(page: p1, strokeId: a1.id), .removeStroke(page: p1, strokeId: a2.id),
                                         .addStroke(page: p1, stroke: x2)])
        let redo = log.delta(devA, 300, [.removeStroke(page: p1, strokeId: x2.id),
                                         .addStroke(page: p1, stroke: a1b), .addStroke(page: p1, stroke: a2b)])
        XCTAssertEqual(try reconstructAll([d0, slice, undo]).allStrokeIds, [x2.id])
        XCTAssertEqual(try reconstructAll([d0, slice, undo, redo]).allStrokeIds, [a1b.id, a2b.id])
        XCTAssertTrue(try NoteReducer.strokeConflicts([d0, slice, undo, redo]).isEmpty)
    }

    func testSplitRacingASlice() throws {
        // A switches the pageless note to pages: x, on the second sheet,
        // moves to a new page (a replacement); B slices x on the old page.
        var log = LogBuilder()
        let size = PageSize(width: 600, height: 800, infinite: true, breakHeight: 800)
        let x = Stroke(ink: Ink(tool: .pen, color: .black, width: 2),
                       points: [StrokePoint(x: 10, y: 900, w: 2, h: 2), StrokePoint(x: 20, y: 910, w: 2, h: 2)])
        let page = Page(id: p1, order: "V", strokes: [x])
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x),
                                     .setMeta(.pageSize(size))])
        let split = NoteOps.makePaged(pages: [page], pageSize: size)
        let moved = try XCTUnwrap(split.pages.last?.strokes.first)
        XCTAssertEqual(moved.parent, x.id)
        let piece = Stroke(ink: x.ink, points: [x.points[0]], parent: x.id)
        let slice = log.delta(devB, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: piece)])
        let splitRev = log.delta(devA, 200, split.ops)
        XCTAssertEqual(try reconstructAll([d0, slice, splitRev]).allStrokeIds, [moved.id])
    }

    // MARK: Snapshots and compaction

    func testSnapshotsKeepWhatTheRuleNeeds() throws {
        // A slices x and later erases its pieces; a snapshot covers that and the
        // deltas are compacted. B's concurrent, earlier slice arrives after:
        // A's replacement still wins, though none of its strokes is left.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 300, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let eraseA = log.delta(devA, 400, [.removeStroke(page: p1, strokeId: a1.id)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, eraseA, sliceB]).allStrokeIds, [])
        let snap = try log.snapshot(devA, 500, from: [d0, sliceA, eraseA])
        guard case .snapshot(_, let held) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(held.tombstones?.lineage,
                       [Tombstones.Lineage(stroke: a1.id, parent: x.id, by: "\(sliceA.hlc)-\(devA)-\(sliceA.seq)")])
        XCTAssertEqual(try reconstructAll([snap, sliceB]).allStrokeIds, [])

        // The winner's live pieces carry `replaces` instead of a record.
        let snap2 = try log.snapshot(devA, 600, from: [d0, sliceA])
        guard case .snapshot(_, let held2) = snap2.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(held2.pages[0].strokes.map(\.replaces), [true])
        XCTAssertNil(held2.tombstones)
        XCTAssertEqual(try reconstructAll([snap2, sliceB]).allStrokeIds, [a1.id])
        let json = try InkJSON.encoder().encode(snap2)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"replaces\":true"))
        XCTAssertEqual(try InkJSON.encoder().encode(InkJSON.decoder().decode(Revision.self, from: json)), json)
    }

    func testSupersededStrokesStaySupersededAfterCompaction() throws {
        // B's slice wins over A's; a snapshot of both is all that is left
        // when A's later slice of its own (losing) piece arrives.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a11 = ink(parent: a1.id), b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let againA = log.delta(devA, 150, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: a11)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        let snap = try log.snapshot(devC, 300, from: [d0, sliceA, sliceB])
        guard case .snapshot(_, let held) = snap.body else { return XCTFail("not a snapshot") }
        XCTAssertEqual(held.tombstones?.superseded, [a1.id])
        XCTAssertEqual(try reconstructAll([snap, againA]).allStrokeIds, [b1.id])
        XCTAssertEqual(try reconstructAll([d0, sliceA, againA, sliceB]).allStrokeIds, [b1.id])
    }

    func testCompactedIntermediatePieceStillLinksItsDescendants() throws {
        // A slices x, then slices its piece a1; a snapshot covers both and the
        // deltas go. B's concurrent, later slice of x arrives after: a1 is no
        // longer held, yet a11 must go with A's lost replacement.
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), a11 = ink(parent: a1.id), b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let againA = log.delta(devA, 150, [.removeStroke(page: p1, strokeId: a1.id), .addStroke(page: p1, stroke: a11)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        XCTAssertEqual(try reconstructAll([d0, sliceA, againA, sliceB]).allStrokeIds, [b1.id])
        let snap = try log.snapshot(devA, 160, from: [d0, sliceA, againA])
        XCTAssertEqual(try reconstructAll([snap, sliceB]).allStrokeIds, [b1.id])
    }

    func testReportListsSupersededStrokes() throws {
        var log = LogBuilder()
        let x = ink()
        let a1 = ink(parent: x.id), b1 = ink(parent: x.id)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: x)])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: a1)])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: x.id), .addStroke(page: p1, stroke: b1)])
        let conflicts = try NoteReducer.strokeConflicts([d0, sliceA, sliceB])
        XCTAssertEqual(conflicts.superseded, [StrokeRef(page: p1, stroke: a1.id)])
        XCTAssertEqual(conflicts.duplicates, [])
        let fix = log.delta(devC, 300, conflicts.ops)
        let after = [d0, sliceA, sliceB, fix]
        XCTAssertEqual(try reconstructAll(after).allStrokeIds, [b1.id])
        // Once removed, a1 is no longer live anywhere: nothing left to report.
        XCTAssertTrue(try NoteReducer.strokeConflicts(after).isEmpty)
    }

    // MARK: Hostile input

    func testParentCyclesAndBadRecordsDoNotTrap() throws {
        var log = LogBuilder()
        let u = UUID(), v = UUID()
        let su = ink(u, parent: v), sv = ink(v, parent: u)
        let d0 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "V")), .addStroke(page: p1, stroke: su),
                                     .removeStroke(page: p1, strokeId: v), .addStroke(page: p1, stroke: sv),
                                     .removeStroke(page: p1, strokeId: u)])
        let d1 = log.delta(devB, 0, [.addStroke(page: p1, stroke: ink(parent: u)), .removeStroke(page: p1, strokeId: u)])
        _ = try reconstructAll([d0, d1])
        _ = try NoteReducer.strokeConflicts([d0, d1])
        let bad = NoteState(meta: NoteMeta(created: wallAt(baseMillis)), pages: [Page(id: p1, order: "V")],
                            tombstones: Tombstones(lineage: [Tombstones.Lineage(stroke: u, parent: v, by: "nonsense")],
                                                   superseded: [u]))
        let snap = Revision(noteId: testNote, device: devC, seq: 1, hlc: HLC(millis: baseMillis + 9, counter: 0)!,
                            wall: wallAt(baseMillis + 9), app: "x/1", body: .snapshot(included: Included(), state: bad))
        _ = try reconstructAll([snap, d0, d1])
    }

    func withOrigin(_ s: Stroke, _ origin: String) -> Stroke {
        var s = s
        s.origin = origin
        return s
    }

    // MARK: Property: conforming writers, partial views, any order

    /// Three devices edit from their own partial views of the log (draw,
    /// slice, move, erase and, with `recreations`, bring back an erased
    /// stroke under a new id), receive each other's revisions at random and
    /// write snapshots of what they have. Every order of the final log gives
    /// the same note; compaction and a snapshot of everything change nothing;
    /// without re-creations no duplicate is left; the report's removals
    /// leave nothing to report.
    func testRandomConcurrentEditsConverge() throws {
        for seed in UInt64(1)...10 {
            for recreations in [false, true] { try checkRandomEdits(seed: seed, recreations: recreations) }
        }
    }

    func checkRandomEdits(seed: UInt64, recreations: Bool) throws {
        var rng = SplitMix64(seed: seed &* 31 &+ (recreations ? 1 : 0))
        let all = try randomEditLog(rng: &rng, recreations: recreations, steps: 120)
        let tag = "seed \(seed) recreations \(recreations)"
        let reference = try NoteReducer.reconstruct(all)
        let refJSON = try InkJSON.encoder().encode(reference)
        for i in 0..<30 {
            let state = try NoteReducer.reconstruct(all.shuffled(using: &rng))
            XCTAssertEqual(try InkJSON.encoder().encode(state), refJSON, "\(tag) permutation \(i)")
        }
        try checkInvariants(all, reference: reference, recreations: recreations, seed: seed, rng: &rng)
    }

    /// A log of conforming writers with partial views (see `testRandomConcurrentEditsConverge`).
    func randomEditLog(rng: inout SplitMix64, recreations: Bool, steps: Int) throws -> [Revision] {
        let devices = [devA, devB, devC]
        var clocks = [HybridClock(), HybridClock(), HybridClock()]
        var seqs = [0, 0, 0]
        var all: [Revision] = []
        var seen: [Set<RevisionName>] = [[], [], []]
        let skew = [Int64(0), Int64.random(in: -4000...4000, using: &rng), Int64.random(in: -4000...4000, using: &rng)]
        var step: Int64 = 0
        func wall(_ di: Int) -> Date { wallAt(baseMillis + step * 1000 + skew[di]) }
        func write(_ di: Int, _ ops: [Op]) {
            let hlc = clocks[di].tick(wall: wall(di))
            seqs[di] += 1
            let r = Revision(noteId: testNote, device: devices[di], seq: seqs[di], hlc: hlc, wall: wall(di),
                             app: "test/0", body: .delta(ops: ops))
            all.append(r)
            seen[di].insert(r.name)
        }
        func newInk(parent: UUID? = nil, from base: Stroke? = nil, dx: Double = 0) -> Stroke {
            let x = Double.random(in: 0..<500, using: &rng)
            var s = ink(UUID.random(using: &rng), parent: parent, x: x)
            if let base { s.points = base.points; s.ink = base.ink; s.transform = base.transform }
            if dx != 0 { s.transform = Transform(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: 0) }
            return s
        }
        write(0, [.addPage(Page(id: p1, order: "V")), .addPage(Page(id: p2, order: "W"))]
                 + (0..<4).map { i in .addStroke(page: i < 2 ? p1 : p2, stroke: newInk()) })

        for _ in 0..<steps {
            step += 1
            let di = Int.random(in: 0..<3, using: &rng)
            if seen[di].isEmpty || Double.random(in: 0..<1, using: &rng) < 0.15 {
                for r in all where !seen[di].contains(r.name) && Bool.random(using: &rng) {
                    seen[di].insert(r.name)
                    clocks[di].observe(r.hlc, wall: wall(di))
                }
                continue
            }
            let view = all.filter { seen[di].contains($0.name) }
            let state = try NoteReducer.reconstruct(view)
            let live = state.pages.flatMap { p in p.strokes.map { (page: p.id, stroke: $0) } }
            let r = Double.random(in: 0..<1, using: &rng)
            if r < 0.12 {
                seqs[di] += 1
                all.append(try SnapshotBuilder.makeSnapshot(from: view, device: devices[di], seq: seqs[di],
                                                            clock: &clocks[di], wall: wall(di), app: "test/0"))
                seen[di].insert(all[all.count - 1].name)
            } else if r < 0.27 || live.isEmpty {
                write(di, [.addStroke(page: Bool.random(using: &rng) ? p1 : p2, stroke: newInk())])
            } else if r < 0.62, let v = live.randomElement(using: &rng) {
                let pieces = (0..<Int.random(in: 1...3, using: &rng)).map { _ in newInk(parent: v.stroke.id) }
                write(di, [.removeStroke(page: v.page, strokeId: v.stroke.id)]
                          + pieces.map { .addStroke(page: v.page, stroke: $0) })
            } else if r < 0.77, let v = live.randomElement(using: &rng) {
                let moved = newInk(parent: v.stroke.id, from: v.stroke, dx: Double.random(in: 1..<50, using: &rng))
                // A move to the other page, sometimes (as a split does).
                let to = Double.random(in: 0..<1, using: &rng) < 0.3 ? (v.page == p1 ? p2 : p1) : v.page
                write(di, [.removeStroke(page: v.page, strokeId: v.stroke.id), .addStroke(page: to, stroke: moved)])
            } else if r < 0.90, let v = live.randomElement(using: &rng) {
                write(di, [.removeStroke(page: v.page, strokeId: v.stroke.id)])
            } else if recreations {
                // Undo of an erase: a stroke this device knows, no longer live, under a new id.
                let liveIDs = Set(live.map(\.stroke.id))
                var gone: [(page: UUID, stroke: Stroke)] = []
                for rev in view { for case .addStroke(let page, let st) in rev.ops where !liveIDs.contains(st.id) {
                    gone.append((page, st))
                } }
                if let g = gone.randomElement(using: &rng) {
                    write(di, [.addStroke(page: g.page, stroke: newInk(parent: g.stroke.id, from: g.stroke))])
                }
            }
        }

        return all
    }

    func checkInvariants(_ all: [Revision], reference: NoteState, recreations: Bool, seed: UInt64,
                         rng: inout SplitMix64) throws {
        let tag = "seed \(seed) recreations \(recreations)"
        let conflicts = try NoteReducer.strokeConflicts(all)
        if !recreations { XCTAssertEqual(conflicts.duplicates, [], tag) }
        // Something actually raced, or the test proves nothing.
        if seed == 1 { XCTAssertFalse(conflicts.superseded.isEmpty && (reference.tombstones?.superseded ?? []).isEmpty, tag) }

        // Compaction (everything a snapshot covers) changes nothing.
        let snaps = all.compactMap(SnapshotCoverage.init)
        let walls = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.wall) })
        let doomed = Set(CompactionPlanner.deletable(names: all.map(\.name), wall: walls, snapshots: snaps,
                                                     retention: 0, now: wallAt(baseMillis + 10_000_000)))
        let compacted = try NoteReducer.reconstruct(all.filter { !doomed.contains($0.name) })
        XCTAssertEqual(compacted.pages, reference.pages, tag)

        // So does deleting the deltas any one snapshot covers.
        for snap in all where snap.kind == .snapshot {
            guard case .snapshot(let included, _) = snap.body else { continue }
            let rest = all.filter { $0.kind == .snapshot || !included.covers(device: $0.device, seq: $0.seq) }
            XCTAssertEqual(try NoteReducer.reconstruct(rest).pages, reference.pages, "\(tag) without \(snap.name)")
        }

        // A snapshot of everything holds the same note, alone or with any revision.
        var clock = HybridClock()
        let everything = try SnapshotBuilder.makeSnapshot(from: all, device: devC, seq: 10_000, clock: &clock,
                                                          wall: wallAt(baseMillis + 20_000_000), app: "test/0")
        XCTAssertEqual(try NoteReducer.reconstruct([everything]).pages, reference.pages, tag)
        if let late = all.randomElement(using: &rng) {
            XCTAssertEqual(try NoteReducer.reconstruct([everything, late]).pages, reference.pages, tag)
        }

        // The report's removals settle everything it reported.
        if !conflicts.isEmpty {
            var log = LogBuilder()
            let fix = log.delta(DeviceID("dddddddd")!, 30_000_000, conflicts.ops)
            let fixed = try NoteReducer.reconstruct(all + [fix])
            XCTAssertTrue(try NoteReducer.strokeConflicts(all + [fix]).isEmpty, tag)
            let removed = Set(conflicts.duplicates.map(\.stroke))
            XCTAssertEqual(fixed.allStrokeIds, reference.allStrokeIds.subtracting(removed), tag)
        }
    }

    // MARK: Shared vectors (web/test/lineage.test.ts)

    struct Vectors: Codable {
        struct Case: Codable {
            var name: String
            var revisions: [Revision]
            var state: NoteState
        }
        var cases: [Case]
    }

    /// Random logs of conforming writers, some with the deltas a snapshot
    /// covers deleted, and the note each reconstructs to. The web viewer must
    /// reconstruct the same JSON. `SEMPERE_WRITE_MERGE_VECTORS=1` rewrites
    /// the file when the generator or the rule changes.
    func makeVectors() throws -> Vectors {
        var cases: [Vectors.Case] = []
        for seed in UInt64(101)...104 {
            var rng = SplitMix64(seed: seed)
            let recreations = seed % 2 == 0
            let all = try randomEditLog(rng: &rng, recreations: recreations, steps: 30)
            cases.append(.init(name: "seed \(seed)\(recreations ? " re-creations" : "")", revisions: all,
                               state: try NoteReducer.reconstruct(all)))
            if let snap = all.last(where: { $0.kind == .snapshot }), case .snapshot(let included, _) = snap.body {
                let rest = all.filter { $0.kind == .snapshot || !included.covers(device: $0.device, seq: $0.seq) }
                cases.append(.init(name: "seed \(seed) compacted", revisions: rest,
                                   state: try NoteReducer.reconstruct(rest)))
            }
        }
        return Vectors(cases: cases)
    }

    func testSharedVectors() throws {
        let made = try makeVectors()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/concurrent-replacement-vectors.json")
        if ProcessInfo.processInfo.environment["SEMPERE_WRITE_MERGE_VECTORS"] == "1" {
            try (InkJSON.encoder().encode(made) + Data("\n".utf8)).write(to: source)
        }
        let url = try FixtureTests.bundled("concurrent-replacement-vectors.json")
        let stored = try InkJSON.decoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.cases.count, made.cases.count)
        XCTAssertTrue(stored.cases.contains { $0.state.tombstones?.superseded.isEmpty == false })
        XCTAssertTrue(stored.cases.contains { $0.state.tombstones?.lineage.isEmpty == false })
        for (a, b) in zip(stored.cases, made.cases) {
            XCTAssertEqual(try InkJSON.encoder().encode(a.revisions), try InkJSON.encoder().encode(b.revisions),
                           "\(a.name): regenerate with SEMPERE_WRITE_MERGE_VECTORS=1")
            XCTAssertEqual(try InkJSON.encoder().encode(NoteReducer.reconstruct(a.revisions)),
                           try InkJSON.encoder().encode(a.state), a.name)
        }
    }
}
