import Foundation
import XCTest
@testable import Sempere

/// `ReducedNote.updated(with:)` (the open editor's merge, docs/io.md "Changes
/// from other devices while a note is open") must give exactly what
/// `NoteReducer.reconstruct` gives for the same revisions, whichever path it
/// takes, and name every page whose content changed.
final class ReducedNoteTests: XCTestCase {
    /// `reconstruct` as `ReducedNote.state` holds it (no tombstones).
    private func full(_ revisions: [Revision]) throws -> NoteState {
        var s = try NoteReducer.reconstruct(revisions)
        s.tombstones = nil
        return s
    }

    // MARK: Property: incremental == full read, over random interleavings

    func testIncrementalMatchesFullReadInOrderArrival() throws {
        try checkRandomInterleavings(jitter: 0, seeds: 1...12, minimumIncremental: 0.3)
    }

    func testIncrementalMatchesFullReadLateArrivals() throws {
        try checkRandomInterleavings(jitter: 0.1, seeds: 41...52, minimumIncremental: 0.2)
    }

    func testIncrementalMatchesFullReadShuffledArrival() throws {
        try checkRandomInterleavings(jitter: 1, seeds: 21...32, minimumIncremental: 0)
    }

    /// Several devices write deltas (and now and then a snapshot from a
    /// partial view); revisions arrive in batches of 1…3, in name order with
    /// a fraction `jitter` of them moved to a random later point (1: a full
    /// shuffle). After each batch the incremental result is compared to a
    /// full read of everything arrived, state and per-page diff.
    func checkRandomInterleavings(jitter: Double, seeds: ClosedRange<UInt64>, minimumIncremental: Double) throws {
        var incremental = 0, total = 0
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            let log = randomLog(rng: &rng)
            var arrival = log.sorted { $0.name < $1.name }
            if jitter >= 1 {
                arrival.shuffle(using: &rng)
            } else {
                for i in arrival.indices.reversed() where Double.random(in: 0..<1, using: &rng) < jitter {
                    let r = arrival.remove(at: i)
                    arrival.insert(r, at: Int.random(in: i...arrival.count, using: &rng))
                }
            }
            let firstCount = Int.random(in: 1...3, using: &rng)
            var arrived = Array(arrival.prefix(firstCount))
            var reduced = try ReducedNote(revisions: arrived)
            XCTAssertEqual(reduced.state, try full(arrived), "seed \(seed): initial")
            var rest = arrival.dropFirst(firstCount)
            while !rest.isEmpty {
                let n = min(Int.random(in: 1...3, using: &rng), rest.count)
                arrived += rest.prefix(n)
                rest = rest.dropFirst(n)
                let expected = try full(arrived)
                let update = try reduced.updated(with: arrived.shuffled(using: &rng))
                total += 1
                XCTAssertEqual(update.note.state, expected, "seed \(seed) after \(arrived.count) revisions")
                XCTAssertEqual(update.note.names, Set(arrived.map(\.name.filename)))
                if let changed = update.changedPages {
                    incremental += 1
                    XCTAssertEqual(update.reduced, n)
                    XCTAssertEqual(reduced.state.pages.map(\.id).sorted(), expected.pages.map(\.id).sorted(),
                                   "seed \(seed): incremental path changed the page list")
                    let before = Dictionary(uniqueKeysWithValues: reduced.state.pages.map { ($0.id, $0) })
                    for page in expected.pages where before[page.id] != page {
                        XCTAssertTrue(changed.contains(page.id), "seed \(seed): page changed but not reported")
                    }
                } else {
                    XCTAssertEqual(update.reduced, arrived.count)
                }
                reduced = update.note
            }
        }
        XCTAssertGreaterThanOrEqual(Double(incremental), minimumIncremental * Double(total),
                                    "incremental \(incremental) of \(total)")
        print("ReducedNote: \(incremental) of \(total) updates incremental (jitter \(jitter))")
    }

    /// 3 devices, ~120 revisions: stroke adds, removes (of live, removed and
    /// never-added ids), slices (two devices may slice one stroke: a
    /// concurrent replacement), a re-add of a removed id (hostile), meta,
    /// page order, recognition and paper, delete/restore; and rarer page
    /// adds and removes, tags, items and partial-view snapshots, which the
    /// incremental path leaves to the full read.
    func randomLog(rng: inout SplitMix64) -> [Revision] {
        let devices = [devA, devB, devC]
        var clocks = [HybridClock(), HybridClock(), HybridClock()]
        var seqs = [0, 0, 0]
        var log: [Revision] = []
        var pages: [UUID] = []
        var strokes: [(page: UUID, id: UUID)] = []
        var removed: [UUID] = []
        func write(_ di: Int, _ hlc: HLC, _ wall: Date, _ ops: [Op]) {
            seqs[di] += 1
            log.append(Revision(noteId: testNote, device: devices[di], seq: seqs[di], hlc: hlc, wall: wall, app: "test/0",
                                body: .delta(ops: ops)))
        }
        // The note as created on A.
        let wall0 = wallAt(baseMillis)
        var first: [Op] = []
        for i in 0..<5 {
            let p = Page(id: UUID.random(using: &rng), order: "p\(i)")
            pages.append(p.id)
            first.append(.addPage(p))
        }
        write(0, clocks[0].tick(wall: wall0), wall0, first)

        for step in Int64(1)...120 {
            let di = Int.random(in: 0..<3, using: &rng)
            let wall = wallAt(baseMillis + step * 1000 + Int64.random(in: -4000...4000, using: &rng))
            let hlc = clocks[di].tick(wall: wall)
            if Double.random(in: 0..<1, using: &rng) < 0.03 {
                let view = log.filter { _ in Double.random(in: 0..<1, using: &rng) < 0.7 }
                if !view.isEmpty, let snap = try? SnapshotBuilder.makeSnapshot(
                    from: view, device: devices[di], seq: seqs[di] + 1, clock: &clocks[di], wall: wall, app: "test/0") {
                    seqs[di] += 1
                    log.append(snap)
                }
                continue
            }
            var ops: [Op] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let r = Double.random(in: 0..<1, using: &rng)
                let page = pages.randomElement(using: &rng) ?? pages[0]
                if r < 0.40 || strokes.isEmpty {
                    let id = UUID.random(using: &rng)
                    strokes.append((page, id))
                    ops.append(.addStroke(page: page, stroke: stroke(id)))
                } else if r < 0.52 {
                    let roll = Double.random(in: 0..<1, using: &rng)
                    let id = roll < 0.1 ? UUID.random(using: &rng) : (strokes.randomElement(using: &rng)?.id ?? UUID())
                    removed.append(id)
                    ops.append(.removeStroke(page: page, strokeId: id))
                } else if r < 0.60, let victim = strokes.randomElement(using: &rng) {
                    ops.append(.removeStroke(page: victim.page, strokeId: victim.id))
                    removed.append(victim.id)
                    for _ in 0..<2 {
                        let id = UUID.random(using: &rng)
                        strokes.append((victim.page, id))
                        ops.append(.addStroke(page: victim.page, stroke: stroke(id, parent: victim.id)))
                    }
                } else if r < 0.61, let back = removed.randomElement(using: &rng) {
                    ops.append(.addStroke(page: page, stroke: stroke(back)))   // hostile: §5.2 forbids it
                } else if r < 0.70 {
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: ops.append(.setMeta(.title("t\(Int.random(in: 0..<50, using: &rng))")))
                    case 1: ops.append(.setMeta(.favorite(Bool.random(using: &rng))))
                    case 2: ops.append(.setMeta(.pageSize(Bool.random(using: &rng) ? .a4 : .letter)))
                    default: ops.append(.setMeta(.notebook(Bool.random(using: &rng) ? nil : "nb")))
                    }
                } else if r < 0.77 {
                    ops.append(.setPageRecognition(pageId: page, recognition: Bool.random(using: &rng) ? nil
                        : Recognition(engine: "test-1", text: "r\(Int.random(in: 0..<50, using: &rng))")))
                } else if r < 0.82 {
                    ops.append(.setPagePaper(pageId: page, paper: Bool.random(using: &rng) ? nil : .ruled))
                } else if r < 0.87 {
                    ops.append(.setPageOrder(pageId: page, order: "p\(Int.random(in: 0..<9, using: &rng))"))
                } else if r < 0.89 {
                    ops.append(Bool.random(using: &rng) ? .deleteNote : .restoreNote)
                } else if r < 0.92 {
                    let p = Page(id: UUID.random(using: &rng), order: "q\(Int.random(in: 0..<9, using: &rng))")
                    pages.append(p.id)
                    ops.append(.addPage(p))
                } else if r < 0.93, pages.count > 3 {
                    ops.append(.removePage(pageId: page))
                } else if r < 0.96 {
                    ops.append(.addTag("tag\(Int.random(in: 0..<3, using: &rng))"))
                } else {
                    let item = Item.text(id: UUID.random(using: &rng),
                                         TextContent(size: 12, color: .black, runs: [TextRun("x")]),
                                         frame: Rect(x: 1, y: 2, w: 3, h: 4), z: "a")
                    ops.append(.addItem(page: page, item: item))
                }
            }
            write(di, hlc, wall, ops)
        }
        return log
    }

    // MARK: Scenarios

    func testOneStrokeOnOnePageIsApplied() throws {
        var log = LogBuilder()
        let p1 = UUID(), p2 = UUID()
        let a = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addPage(Page(id: p2, order: "b")),
                                    .addStroke(page: p1, stroke: stroke()), .addStroke(page: p2, stroke: stroke())])
        let reduced = try ReducedNote(revisions: [a])
        let b = log.delta(devB, 100, [.addStroke(page: p2, stroke: stroke())])
        let update = try reduced.updated(with: [a, b])
        XCTAssertEqual(update.changedPages, [p2])
        XCTAssertEqual(update.reduced, 1)
        XCTAssertEqual(update.note.state, try full([a, b]))
    }

    func testOlderRevisionFallsBack() throws {
        var log = LogBuilder()
        let p1 = UUID()
        let a = log.delta(devA, 100, [.addPage(Page(id: p1, order: "a")), .addStroke(page: p1, stroke: stroke())])
        let late = log.delta(devB, 50, [.addStroke(page: p1, stroke: stroke())])
        let update = try ReducedNote(revisions: [a]).updated(with: [a, late])
        XCTAssertNil(update.changedPages)
        XCTAssertEqual(update.note.state, try full([a, late]))
    }

    func testSnapshotAndPageAddFallBack() throws {
        var log = LogBuilder()
        let p1 = UUID()
        let a = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addStroke(page: p1, stroke: stroke())])
        let reduced = try ReducedNote(revisions: [a])
        let snap = try log.snapshot(devB, 100, from: [a])
        XCTAssertNil(try reduced.updated(with: [a, snap]).changedPages)
        let add = log.delta(devB, 200, [.addPage(Page(id: UUID(), order: "b"))])
        XCTAssertNil(try reduced.updated(with: [a, add]).changedPages)
    }

    /// Two devices slice one stroke: the earlier replacement is superseded
    /// (format.md §5.6.1), which only the full read decides.
    func testSecondReplacementFallsBack() throws {
        var log = LogBuilder()
        let p1 = UUID(), victim = UUID()
        let a = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a")), .addStroke(page: p1, stroke: stroke(victim))])
        let sliceA = log.delta(devA, 100, [.removeStroke(page: p1, strokeId: victim),
                                           .addStroke(page: p1, stroke: stroke(UUID(), parent: victim))])
        let reduced = try ReducedNote(revisions: [a, sliceA])
        let sliceB = log.delta(devB, 200, [.removeStroke(page: p1, strokeId: victim),
                                           .addStroke(page: p1, stroke: stroke(UUID(), parent: victim))])
        let update = try reduced.updated(with: [a, sliceA, sliceB])
        XCTAssertNil(update.changedPages)
        XCTAssertEqual(update.note.state, try full([a, sliceA, sliceB]))
        XCTAssertEqual(update.note.state.pages[0].strokes.count, 1)
    }

    /// A revision the reduced note held is gone (compacted elsewhere): full read.
    func testMissingRevisionFallsBack() throws {
        var log = LogBuilder()
        let p1 = UUID()
        let a = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a"))])
        let b = log.delta(devA, 100, [.addStroke(page: p1, stroke: stroke())])
        let reduced = try ReducedNote(revisions: [a, b])
        let snap = try log.snapshot(devA, 200, from: [a, b])
        let update = try reduced.updated(with: [snap])
        XCTAssertNil(update.changedPages)
        XCTAssertEqual(update.note.state, try full([snap]))
    }

    // MARK: Cost

    /// A large note (500 revisions, 100 pages, 20 000 strokes) and one remote
    /// revision adding a stroke to one page: revisions reduced and time, full
    /// read vs incremental.
    func testOneRemoteStrokeOnALargeNote() throws {
        var rng = SplitMix64(seed: 7)
        var log = LogBuilder()
        var pages: [UUID] = []
        var first: [Op] = []
        for i in 0..<100 {
            let id = UUID.random(using: &rng)
            pages.append(id)
            first.append(.addPage(Page(id: id, order: String(format: "p%03d", i))))
        }
        var revisions = [log.delta(devA, 0, first)]
        for r in 1..<500 {
            let ops: [Op] = (0..<40).map { _ in
                .addStroke(page: pages.randomElement(using: &rng) ?? pages[0], stroke: stroke(UUID.random(using: &rng)))
            }
            revisions.append(log.delta(r % 2 == 0 ? devA : devC, Int64(r) * 1000, ops))
        }
        XCTAssertEqual(revisions.count, 500)
        let reduced = try ReducedNote(revisions: revisions)
        XCTAssertEqual(reduced.state.pages.reduce(0) { $0 + $1.strokes.count }, 19_960)
        let remote = log.delta(devB, 600_000, [.addStroke(page: pages[42], stroke: stroke(UUID.random(using: &rng)))])
        let all = revisions + [remote]

        var t = ContinuousClock.now
        let expected = try full(all)
        let fullTime = ContinuousClock.now - t
        t = ContinuousClock.now
        let update = try reduced.updated(with: all)
        let incrementalTime = ContinuousClock.now - t
        XCTAssertEqual(update.note.state, expected)
        XCTAssertEqual(update.changedPages, [pages[42]])
        XCTAssertEqual(update.reduced, 1)
        let strokesOnPage = expected.pages.first { $0.id == pages[42] }?.strokes.count ?? 0
        print("ReducedNote large note: full read reduces \(all.count) revisions in \(fullTime), "
              + "incremental reduces \(update.reduced) in \(incrementalTime) (page of \(strokesOnPage) strokes)")
    }
}
