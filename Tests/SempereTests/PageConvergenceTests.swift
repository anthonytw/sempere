import Foundation
import XCTest
@testable import Sempere

/// Property: page edits converge (format.md §5.3, §5.4.3). Four devices with
/// skewed clocks add, move, delete, undo deletes of, and duplicate pages,
/// draw, and switch the note between paged and pageless, each from its own
/// partial view; they exchange random subsets of what they hold and write
/// snapshots. Whatever the order, grouping, snapshots or compaction, every
/// reader gets the same pages as a replay of the deltas; a removed page never
/// comes back (delete wins over a concurrent move); every live page appears
/// once; and each gesture's predicted pages are what its writer then reads.
final class PageConvergenceTests: XCTestCase {
    private struct Device {
        var id: DeviceID
        var skew: Int64
        var clock = HybridClock()
        var seq = 0
        var view: [RevisionName: Revision] = [:]
        /// Pages this device deleted, for undo.
        var deleted: [Page] = []

        func state() throws -> NoteState { try NoteReducer.reconstruct(Array(view.values)) }
    }

    private struct Counts {
        var adds = 0, moves = 0, deletes = 0, undos = 0, duplicates = 0, switches = 0, snapshots = 0
        var moveOfDeleted = 0
    }

    /// What must agree between readers.
    private struct Shape: Equatable {
        var pages: [[String]]
        var size: PageSize
        init(_ s: NoteState) {
            pages = s.pages.map { [$0.id.uuidString, $0.order, $0.parent?.uuidString ?? "-"] + $0.strokes.map(\.id.uuidString) }
            size = s.meta.pageSize
        }
    }

    private func simulate(seed: UInt64, counts: inout Counts) throws -> (all: [Revision], devices: [Device]) {
        var rng = SplitMix64(seed: seed)
        func id() -> UUID { UUID.random(using: &rng) }
        var devices = [devA, devB, devC, DeviceID("dddddddd")!].map {
            Device(id: $0, skew: Int64.random(in: -40_000...40_000, using: &rng))
        }
        // The note: three pages, paged, created on A and seen by everyone.
        let first = Revision(noteId: testNote, device: devA, seq: 1, hlc: HLC(millis: baseMillis, counter: 0)!,
                             wall: wallAt(baseMillis), app: "test/0",
                             body: .delta(ops: NoteOps.newNote(title: "t", pageId: id())
                                          + [.addPage(Page(id: id(), order: "k")), .addPage(Page(id: id(), order: "s"))]))
        for i in devices.indices {
            devices[i].view[first.name] = first
            _ = devices[i].clock.observe(first.hlc, wall: wallAt(baseMillis))
        }
        devices[0].seq = 1
        var everDeleted = Set<UUID>()

        for step in Int64(1)...160 {
            let di = Int.random(in: 0..<devices.count, using: &rng)
            let wall = wallAt(baseMillis + step * 1000 + devices[di].skew)
            let state = try devices[di].state()
            let pages = state.pages
            let r = Double.random(in: 0..<1, using: &rng)
            var edit: PageEdit?
            var size: PageSize?
            if r < 0.12 {
                edit = NoteOps.addPage(at: Int.random(in: 0...pages.count, using: &rng), in: pages, id: id())
                counts.adds += 1
            } else if r < 0.30, let p = pages.randomElement(using: &rng) {
                edit = NoteOps.movePage(p.id, to: Int.random(in: 0..<pages.count, using: &rng), in: pages)
                if edit != nil { counts.moves += 1 }
                if everDeleted.contains(p.id) { counts.moveOfDeleted += 1 }   // deleted elsewhere, not seen yet
            } else if r < 0.40, pages.count > 1, let p = pages.randomElement(using: &rng) {
                edit = NoteOps.deletePage(p.id, in: pages)
                devices[di].deleted.append(p)
                everDeleted.insert(p.id)
                counts.deletes += 1
            } else if r < 0.46, let p = devices[di].deleted.popLast() {
                edit = NoteOps.restorePage(p, at: Int.random(in: 0...pages.count, using: &rng), in: pages, id: id(),
                                           newID: id)
                counts.undos += 1
            } else if r < 0.52, let p = pages.randomElement(using: &rng) {
                edit = NoteOps.duplicatePage(p.id, in: pages, newPageID: id(), newID: id)
                counts.duplicates += 1
            } else if r < 0.62, let p = pages.randomElement(using: &rng) {
                let s = Stroke(id: id(), ink: Ink(tool: .pen, color: .black, width: 2),
                               points: [StrokePoint(x: 10, y: Double.random(in: 0...2400, using: &rng), w: 2, h: 2)])
                var after = pages
                after[pages.firstIndex(of: p)!].strokes.append(s)
                edit = PageEdit(ops: [.addStroke(page: p.id, stroke: s)], pages: after)
            } else if r < 0.66 {
                let l = state.meta.pageSize.infinite
                    ? NoteOps.makePaged(pages: pages, pageSize: state.meta.pageSize, newID: id)
                    : NoteOps.makePageless(pages: pages, pageSize: state.meta.pageSize, newID: id)
                for case .removePage(let gone) in l.ops { everDeleted.insert(gone) }
                edit = PageEdit(ops: l.ops, pages: l.pages)
                size = l.pageSize
                counts.switches += 1
            } else if r < 0.88 {
                let from = Int.random(in: 0..<devices.count, using: &rng)
                guard from != di else { continue }
                for (name, rev) in devices[from].view.sorted(by: { $0.key < $1.key })
                where Double.random(in: 0..<1, using: &rng) < 0.6 {
                    devices[di].view[name] = rev
                    _ = devices[di].clock.observe(rev.hlc, wall: wall)
                }
                continue
            } else {
                devices[di].seq += 1
                let snap = try SnapshotBuilder.makeSnapshot(from: Array(devices[di].view.values), device: devices[di].id,
                                                            seq: devices[di].seq, clock: &devices[di].clock,
                                                            wall: wall, app: "test/0")
                devices[di].view[snap.name] = snap
                counts.snapshots += 1
                continue
            }
            guard let edit, !edit.ops.isEmpty else { continue }
            devices[di].seq += 1
            let hlc = devices[di].clock.tick(wall: wall)
            let rev = Revision(noteId: testNote, device: devices[di].id, seq: devices[di].seq, hlc: hlc,
                               wall: wall, app: "test/0", body: .delta(ops: edit.ops))
            devices[di].view[rev.name] = rev
            // The writer reads back what it predicted (its own delta is the newest it knows).
            let now = try devices[di].state()
            XCTAssertEqual(now.pages.map(\.id), edit.pages.map(\.id), "seed \(seed) step \(step)")
            XCTAssertEqual(now.strokeIds, edit.pages.map { $0.strokes.map(\.id) }, "seed \(seed) step \(step)")
            if let size { XCTAssertEqual(now.meta.pageSize, size) }
        }
        var all: [RevisionName: Revision] = [:]
        for d in devices { all.merge(d.view) { a, _ in a } }
        return (all.values.sorted { $0.name < $1.name }, devices)
    }

    func testPagesConvergeWhateverTheOrderSnapshotsAndCompaction() throws {
        var counts = Counts()
        for seed in UInt64(1)...20 {
            var rng = SplitMix64(seed: seed &* 104_729)
            let (all, devices) = try simulate(seed: seed, counts: &counts)
            let deltas = all.filter { $0.kind == .delta }
            let reference = try NoteReducer.reconstruct(deltas)
            let shape = Shape(reference)

            // Invariants of the replay.
            let ids = reference.pages.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "seed \(seed): a page appears twice")
            XCTAssertEqual(reference.pages, NoteOps.sortedPages(reference.pages))
            let strokeIds = reference.pages.flatMap { $0.strokes.map(\.id) }
            XCTAssertEqual(Set(strokeIds).count, strokeIds.count, "seed \(seed): a stroke on two pages")
            var removed = Set<UUID>()
            for d in deltas { for case .removePage(let id) in d.ops { removed.insert(id) } }
            XCTAssertTrue(removed.isDisjoint(with: ids), "seed \(seed): a removed page came back")

            for i in 0..<10 {
                var order = all.shuffled(using: &rng)
                if i % 3 == 0 { order += order.prefix(5) }
                XCTAssertEqual(Shape(try NoteReducer.reconstruct(order)), shape, "seed \(seed) order \(i)")
            }
            let snaps = all.compactMap { r -> Included? in
                if case .snapshot(let inc, _) = r.body { return inc } else { return nil }
            }
            let compacted = all.filter { r in r.kind == .snapshot || !snaps.contains { $0.covers(device: r.device, seq: r.seq) } }
            XCTAssertEqual(Shape(try NoteReducer.reconstruct(compacted.shuffled(using: &rng))), shape, "seed \(seed) compacted")
            var log = LogBuilder()
            for d in devices {
                let snap = try log.snapshot(DeviceID("eeeeeeee")!, 999_000, from: Array(d.view.values))
                // Every revision the snapshot does not cover stays readable, including orphans from
                // the view (a delta whose page the view lacked is not in `included`, §5.3).
                guard case .snapshot(let covered, _) = snap.body else { return XCTFail("not a snapshot") }
                let rest = all.filter { !covered.covers(device: $0.device, seq: $0.seq) }
                let merged = try NoteReducer.reconstruct([snap] + rest.shuffled(using: &rng))
                XCTAssertEqual(Shape(merged), shape, "seed \(seed) view of \(d.id)")
            }
        }
        // The generator exercises what it claims to.
        XCTAssertGreaterThan(counts.moves, 200)
        XCTAssertGreaterThan(counts.deletes, 100)
        XCTAssertGreaterThan(counts.undos, 30)
        XCTAssertGreaterThan(counts.duplicates, 50)
        XCTAssertGreaterThan(counts.switches, 30)
        XCTAssertGreaterThan(counts.snapshots, 100)
        XCTAssertGreaterThan(counts.moveOfDeleted, 5, "concurrent move of a page deleted elsewhere")
    }

    /// The two concurrent cases named in format.md §5.4.3, spelled out.
    func testConcurrentMoveAndDeleteOfOnePage() throws {
        var log = LogBuilder()
        let p = [Page(order: "V"), Page(order: "k"), Page(order: "s")]
        let base = log.delta(devA, 0, p.map { .addPage($0) })
        // A moves the last page first; B, concurrently and later by the clock, deletes it.
        let move = log.delta(devA, 100, NoteOps.movePage(p[2].id, to: 0, in: p)!.ops)
        let del = log.delta(devB, 50, NoteOps.deletePage(p[2].id, in: p)!.ops)
        for order in [[base, move, del], [del, move, base], [move, base, del]] {
            XCTAssertEqual(try NoteReducer.reconstruct(order).pages.map(\.id), [p[0].id, p[1].id])
        }
        // Concurrent moves of one page: LWW on its order (B's is later).
        let toFront = log.delta(devA, 200, NoteOps.movePage(p[1].id, to: 0, in: p)!.ops)
        let toBack = log.delta(devB, 300, NoteOps.movePage(p[1].id, to: 2, in: p)!.ops)
        XCTAssertEqual(try NoteReducer.reconstruct([toBack, base, toFront]).pages.map(\.id), [p[0].id, p[2].id, p[1].id])
        // Concurrent moves of different pages both apply.
        let a = log.delta(devA, 400, NoteOps.movePage(p[0].id, to: 2, in: p)!.ops)
        let b = log.delta(devB, 400, NoteOps.movePage(p[2].id, to: 0, in: p)!.ops)
        XCTAssertEqual(try NoteReducer.reconstruct([b, base, a]).pages.map(\.id), [p[2].id, p[1].id, p[0].id])
    }
}
