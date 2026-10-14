import Age
import Foundation
import XCTest
@testable import Sempere

/// What a person sees: metadata, deleted, and per page (in order) its order
/// key, recognition and the multiset of drawn strokes. Ids, origins, clocks
/// and the z-order of re-added strokes are left out.
private struct Content: Equatable, CustomStringConvertible {
    struct Drawn: Hashable { var ink: Ink; var points: [StrokePoint]; var transform: Transform }
    struct PageContent: Equatable { var order: String; var recognition: Recognition?; var strokes: [Drawn: Int] }
    var meta: NoteMeta
    var deleted: Bool
    var pages: [PageContent]

    init(_ s: NoteState) {
        meta = s.meta
        deleted = s.deleted
        pages = s.pages.map { p in
            var strokes: [Drawn: Int] = [:]
            for st in p.strokes { strokes[Drawn(ink: st.ink, points: st.points, transform: st.transform ?? .identity), default: 0] += 1 }
            return PageContent(order: p.order, recognition: p.recognition, strokes: strokes)
        }
    }

    var description: String {
        "title=\(meta.title) tags=\(meta.tags) deleted=\(deleted) pages=\(pages.map { "\($0.order):\($0.strokes.values.reduce(0, +))" })"
    }
}

/// A stroke drawn at a distinct place, so content comparisons can tell strokes apart.
private func drawn(_ n: Int, id: UUID = UUID()) -> Stroke {
    Stroke(id: id, ink: Ink(tool: .pen, color: .black, width: 2),
           points: [StrokePoint(x: Double(n), y: 2, w: 2, h: 2, al: 1.5), StrokePoint(x: Double(n) + 5, y: 9, w: 2, h: 2, al: 1.5)])
}

/// Deterministic ids for restore copies.
private final class IDs {
    var n = 0
    func next() -> UUID {
        n += 1
        return UUID(uuidString: String(format: "c0b1e500-0000-4000-8000-%012d", n))!
    }
}

final class HistoryTests: XCTestCase {
    let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let p2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    let p3 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a3")!
    let restorer = DeviceID("dddddddd")!
    /// One sequence per test, so copies made by successive restores never share an id.
    private let ids = IDs()

    private func restore(_ revs: [Revision], to point: RevisionName, at t: Int64) throws -> Revision? {
        var clock = HybridClock()
        return try NoteHistory.makeRestore(from: revs, to: point, device: restorer, clock: &clock,
                                           wall: wallAt(baseMillis + t), app: "test/0", newID: ids.next)
    }

    private func assertSameContent(_ a: NoteState, _ b: NoteState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Content(a), Content(b), file: file, line: line)
    }

    // MARK: Restore points and materialising

    func testRestorePointsAreOneAndOrderedPerRevision() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let b1 = log.delta(devB, 5, [.setMeta(.title("B"))])
        let a2 = log.delta(devA, 5, [.setMeta(.title("A"))])
        let snap = try log.snapshot(devC, 20, from: [a1, b1, a2])
        let points = NoteHistory.restorePoints([snap, b1, a2, a1])
        XCTAssertEqual(points.map(\.name), [a1.name, a2.name, b1.name, snap.name])
        XCTAssertEqual(points.map(\.device), [devA, devA, devB, devC])
        XCTAssertEqual(points.map(\.kind), [.delta, .delta, .delta, .snapshot])
        XCTAssertEqual(points[1].wall, a2.wall)
        XCTAssertEqual(points[1].app, "test/0")
        XCTAssertTrue(points.allSatisfy(\.complete))
    }

    func testStateAtARevisionIsTheMergeOfEverythingUpToIt() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2)
        let revs = [
            log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .setMeta(.title("one")), .addStroke(page: p1, stroke: s1)]),
            log.delta(devB, 10, [.addStroke(page: p1, stroke: s2), .setMeta(.title("two"))]),
            log.delta(devA, 20, [.removeStroke(page: p1, strokeId: s1.id)]),
        ]
        for (i, r) in revs.enumerated() {
            let state = try NoteHistory.state(revs.shuffled(), at: r.name)
            XCTAssertEqual(state, try NoteReducer.reconstruct(Array(revs[...i])))
        }
        XCTAssertEqual(try NoteHistory.state(revs, at: revs[0].name).allStrokeIds, [s1.id])
        XCTAssertEqual(try NoteHistory.state(revs, at: revs[1].name).meta.title, "two")
        XCTAssertEqual(try NoteHistory.state(revs, at: revs[2].name), try NoteReducer.reconstruct(revs))

        let bogus = RevisionName(hlc: HLC("17000000000000000")!, device: devC, seq: 1, kind: .delta)
        XCTAssertThrowsError(try NoteHistory.state(revs, at: bogus)) {
            XCTAssertEqual($0 as? HistoryError, .unknownRevision(bogus.filename))
        }
    }

    // MARK: Restore

    func testRestorePastAStrokeEraseReAddsWithNewIdAndParent() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2), s3 = drawn(3)
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1),
                                     .addStroke(page: p1, stroke: s2)])
        let d2 = log.delta(devA, 10, [.removeStroke(page: p1, strokeId: s1.id)])
        let d3 = log.delta(devA, 20, [.addStroke(page: p1, stroke: s3)])
        let revs = [d1, d2, d3]
        let delta = try XCTUnwrap(try restore(revs, to: d1.name, at: 30))
        XCTAssertEqual(delta.ops, [
            .removeStroke(page: p1, strokeId: s3.id),
            .addStroke(page: p1, stroke: Stroke(id: UUID(uuidString: "c0b1e500-0000-4000-8000-000000000001")!,
                                                ink: s1.ink, points: s1.points, parent: s1.id)),
        ])
        XCTAssertEqual(delta.device, restorer)
        XCTAssertEqual(delta.seq, 1)
        XCTAssertTrue(revs.allSatisfy { $0.hlc < delta.hlc })
        let after = try NoteReducer.reconstruct(revs + [delta])
        assertSameContent(after, try NoteHistory.state(revs, at: d1.name))
        XCTAssertFalse(after.allStrokeIds.contains(s1.id), "an erased id is never re-added")
        XCTAssertEqual(after.pages[0].strokes.first { $0.parent == s1.id }?.points, s1.points)
    }

    func testRestorePastAPageDeletionRecreatesThePage() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2), s3 = drawn(3)
        let rec = Recognition(engine: "test", text: "hello", words: [.init(text: "hello", box: .init(x: 1, y: 2, w: 3, h: 4))])
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1),
                                     .addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: s2),
                                     .addStroke(page: p2, stroke: s3), .setPageRecognition(pageId: p2, recognition: rec)])
        let d2 = log.delta(devB, 10, [.removePage(pageId: p2)])
        let d3 = log.delta(devA, 20, [.addPage(Page(id: p3, order: "a2"))])
        let revs = [d1, d2, d3]
        let delta = try XCTUnwrap(try restore(revs, to: d1.name, at: 30))
        let summary = RestoreSummary(delta.ops)
        XCTAssertEqual(summary.pagesRemoved, 1)
        XCTAssertEqual(summary.pagesRestored, 1)
        XCTAssertEqual(summary.strokesRestored, 2)
        XCTAssertEqual(summary.recognitionChanges, 0)

        let after = try NoteReducer.reconstruct(revs + [delta])
        assertSameContent(after, try NoteHistory.state(revs, at: d1.name))
        XCTAssertEqual(after.pages.count, 2)
        let copy = after.pages[1]
        XCTAssertNotEqual(copy.id, p2)
        XCTAssertEqual(copy.parent, p2)
        XCTAssertEqual(copy.order, "a1")
        XCTAssertEqual(copy.recognition, rec)
        XCTAssertEqual(Set(copy.strokes.compactMap(\.parent)), [s2.id, s3.id])
        XCTAssertFalse(after.pages.contains { $0.id == p3 })

        // The page's parent survives a snapshot.
        var other = LogBuilder()
        let snap = try other.snapshot(devC, 40, from: revs + [delta])
        let fromSnap = try NoteReducer.reconstruct([snap])
        XCTAssertEqual(fromSnap.pages[1].parent, p2)
        let json = try InkJSON.encoder().encode(snap)
        XCTAssertEqual(try InkJSON.decoder().decode(Revision.self, from: json), snap)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\"parent\":\"\(p2.uuidString.lowercased())\""))
    }

    /// Restoring tags (format.md §5.7, §5.4.1): keys gone since are re-added,
    /// keys added since are removed (every instance observed), a changed
    /// spelling is removed and re-added; restoring again writes nothing.
    func testRestoreSetsTagsBackWithPerTagOps() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addTag("math"), .addTag("exam")])
        // Since then: "exam" removed, "new" added, "math" respelt "Math".
        let d2 = log.delta(devB, 10, [.removeTag("exam", observed: [Origin(d1.name, op: 2)]), .addTag("new"),
                                      .removeTag("math", observed: [Origin(d1.name, op: 1)]), .addTag("Math")])
        let revs = [d1, d2]
        XCTAssertEqual(try NoteReducer.reconstruct(revs).meta.tags, ["new", "Math"])
        let delta = try XCTUnwrap(try restore(revs, to: d1.name, at: 30))
        XCTAssertEqual(RestoreSummary(delta.ops).metaFields, ["tags"])
        XCTAssertFalse(delta.ops.contains { if case .setMeta = $0 { return true } else { return false } })
        XCTAssertEqual(try NoteReducer.reconstruct(revs + [delta]).meta.tags, ["math", "exam"])
        XCTAssertNil(try restore(revs + [delta], to: d1.name, at: 40))
    }

    func testRestoreSetsMetadataOrderRecognitionAndDeletedBack() throws {
        var log = LogBuilder()
        let rec = Recognition(engine: "test", text: "old")
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addPage(Page(id: p2, order: "a1")),
                                     .setMeta(.title("Lecture")), .addTag("math"), .setMeta(.paper(.ruled)),
                                     .setPageRecognition(pageId: p1, recognition: rec)])
        let d2 = log.delta(devA, 10, [.setMeta(.title("Renamed")), .removeTag("math", observed: [Origin(d1.name, op: 3)]),
                                      .setMeta(.notebook("School")),
                                      .setPageOrder(pageId: p2, order: "Zz"), .setMeta(.pageSize(.a4)),
                                      .setPageRecognition(pageId: p1, recognition: nil)])
        let d3 = log.delta(devB, 20, [.deleteNote])
        let revs = [d1, d2, d3]
        let delta = try XCTUnwrap(try restore(revs, to: d1.name, at: 30))
        let summary = RestoreSummary(delta.ops)
        XCTAssertEqual(summary.metaFields.sorted(), ["notebook", "pageSize", "tags", "title"])
        XCTAssertEqual(summary.pageOrderChanges, 1)
        XCTAssertEqual(summary.recognitionChanges, 1)
        XCTAssertEqual(summary.deleted, false)
        let after = try NoteReducer.reconstruct(revs + [delta])
        assertSameContent(after, try NoteHistory.state(revs, at: d1.name))
        XCTAssertEqual(after.pages.map(\.id), [p1, p2], "same pages, not copies")
        XCTAssertNil(after.meta.notebook)
        XCTAssertFalse(after.deleted)

        // Restoring to the deleted state deletes again.
        let back = try XCTUnwrap(try restore(revs + [delta], to: d3.name, at: 40))
        XCTAssertEqual(RestoreSummary(back.ops).deleted, true)
        assertSameContent(try NoteReducer.reconstruct(revs + [delta, back]), try NoteReducer.reconstruct(revs))
    }

    func testRestoringTwiceIsANoOp() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2)
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1),
                                     .addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: s2),
                                     .setMeta(.title("t"))])
        let d2 = log.delta(devA, 10, [.removeStroke(page: p1, strokeId: s1.id), .removePage(pageId: p2),
                                      .setMeta(.title("u"))])
        var revs = [d1, d2]
        let first = try XCTUnwrap(try restore(revs, to: d1.name, at: 20))
        revs.append(first)
        XCTAssertNil(try restore(revs, to: d1.name, at: 30), "already matches: nothing to write")
        // Restoring to the restore delta itself is also a no-op.
        XCTAssertNil(try restore(revs, to: first.name, at: 30))
        // Back to d2, then to d1 again: the second copies are fresh ids whose parent is still the original.
        let undo = try XCTUnwrap(try restore(revs, to: d2.name, at: 40))
        revs.append(undo)
        assertSameContent(try NoteReducer.reconstruct(revs), try NoteHistory.state(revs, at: d2.name))
        let again = try XCTUnwrap(try restore(revs, to: d1.name, at: 50))
        revs.append(again)
        let state = try NoteReducer.reconstruct(revs)
        assertSameContent(state, try NoteHistory.state(revs, at: d1.name))
        XCTAssertEqual(state.pages[1].parent, p2)
        XCTAssertEqual(state.pages[0].strokes.map(\.parent), [s1.id])
    }

    /// A and B edit concurrently; the restore point sits between their
    /// revisions in `(hlc, device, seq)` order, and B keeps editing without
    /// having seen the restore.
    func testConcurrentDevicesRestoreAndReMerge() throws {
        var log = LogBuilder()
        let a1s = drawn(1), b1s = drawn(2), a2s = drawn(3), b2s = drawn(4), late = drawn(5)
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: a1s),
                                     .setMeta(.title("start"))])
        let b1 = log.delta(devB, 10, [.addStroke(page: p1, stroke: b1s)])                // B saw a1
        let a2 = log.delta(devA, 10, [.addStroke(page: p1, stroke: a2s)])                // concurrent with b1
        let b2 = log.delta(devB, 20, [.removeStroke(page: p1, strokeId: a1s.id), .addStroke(page: p1, stroke: b2s),
                                      .setMeta(.title("B's title"))])
        let a3 = log.delta(devA, 30, [.addPage(Page(id: p2, order: "a1")), .removeStroke(page: p1, strokeId: b1s.id)])
        let revs = [a1, b1, a2, b2, a3]

        // As of a2: a1, then a2 and b1 (same hlc, aaaaaaaa sorts first, so b1 is after a2).
        let atA2 = try NoteHistory.state(revs, at: a2.name)
        XCTAssertEqual(atA2.allStrokeIds, [a1s.id, a2s.id])
        let atB1 = try NoteHistory.state(revs, at: b1.name)
        XCTAssertEqual(atB1.allStrokeIds, [a1s.id, a2s.id, b1s.id])

        let delta = try XCTUnwrap(try restore(revs, to: b1.name, at: 40))
        let restored = try NoteReducer.reconstruct(revs + [delta])
        assertSameContent(restored, atB1)
        XCTAssertEqual(restored.meta.title, "start")

        // B, not having seen the restore, writes concurrently: a stroke on the
        // surviving page and a title. Its stamp (35) is below the restore's (40).
        let b3 = log.delta(devB, 35, [.addStroke(page: p1, stroke: late), .setMeta(.title("B again"))])
        let merged = try NoteReducer.reconstruct(revs + [b3, delta])
        XCTAssertEqual(try NoteReducer.reconstruct([delta, b3] + revs.reversed()), merged)
        var expected = atB1
        expected.pages[0].strokes.append(late)
        assertSameContent(merged, expected)
        XCTAssertEqual(merged.meta.title, "start", "the restore's newer stamp wins the title")
    }

    /// A replica that never saw the restore merges with it into exactly the
    /// restoring device's state, in any order and through snapshots.
    func testRestoredNoteReMergesWithAnUntouchedReplica() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2), s3 = drawn(3)
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1),
                                     .addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: s2)])
        let d2 = log.delta(devB, 10, [.removePage(pageId: p2), .removeStroke(page: p1, strokeId: s1.id),
                                      .addStroke(page: p1, stroke: s3), .setMeta(.title("later"))])
        let replica = [d1, d2]
        let replicaSnap = try log.snapshot(devB, 15, from: replica)
        let delta = try XCTUnwrap(try restore(replica, to: d1.name, at: 20))
        let local = try NoteReducer.reconstruct(replica + [delta])

        var rng = SplitMix64(seed: 7)
        for _ in 0..<10 {
            XCTAssertEqual(try NoteReducer.reconstruct((replica + [delta]).shuffled(using: &rng)), local)
        }
        // The replica snapshotted (and compacted) before it received the restore.
        XCTAssertEqual(try NoteReducer.reconstruct([replicaSnap, delta]), local)
        XCTAssertEqual(try NoteReducer.reconstruct([replicaSnap, d2, delta, d1]), local)
        // And a snapshot written after the restore round-trips the same state.
        let after = try log.snapshot(devC, 30, from: [replicaSnap, delta])
        XCTAssertEqual(try NoteReducer.reconstruct([after]).pages, local.pages)
        assertSameContent(local, try NoteHistory.state(replica, at: d1.name))
    }

    // MARK: Compaction and unreadable revisions

    func testCompactedRevisionsAreNotRestorePoints() throws {
        var log = LogBuilder()
        let s1 = drawn(1), s2 = drawn(2)
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: s1)])
        let a2 = log.delta(devA, 10, [.addStroke(page: p1, stroke: s2)])
        let b1 = log.delta(devB, 20, [.setMeta(.title("b"))])
        let snap = try log.snapshot(devA, 30, from: [a1, a2, b1])
        let a4 = log.delta(devA, 40, [.removeStroke(page: p1, strokeId: s1.id)])
        // Compaction deleted a1 and a2 (covered by the snapshot); b1 survived.
        let left = [b1, snap, a4]
        let points = NoteHistory.restorePoints(left)
        XCTAssertEqual(points.map(\.name), [b1.name, snap.name, a4.name])
        XCTAssertEqual(points.map(\.complete), [false, true, true])
        XCTAssertThrowsError(try NoteHistory.state(left, at: b1.name)) {
            XCTAssertEqual($0 as? HistoryError, .incompleteHistory(b1.name))
        }
        XCTAssertThrowsError(try restore(left, to: b1.name, at: 50))
        XCTAssertEqual(try NoteHistory.state(left, at: snap.name).allStrokeIds, [s1.id, s2.id])
        let delta = try XCTUnwrap(try restore(left, to: snap.name, at: 50))
        assertSameContent(try NoteReducer.reconstruct(left + [delta]), try NoteHistory.state(left, at: snap.name))
    }

    func testRevisionCompactedAfterThePointDoesNotMakeItIncomplete() throws {
        var log = LogBuilder()
        let b1 = log.delta(devB, 0, [.addPage(Page(id: p1, order: "a0"))])
        let a1 = log.delta(devA, 10, [.setMeta(.title("one"))])
        let a2 = log.delta(devA, 20, [.setMeta(.title("two"))])
        let snap = try log.snapshot(devC, 30, from: [b1, a1, a2])
        // a2 is gone; a1 (same device, lower seq) is ordered after b1, so a2 is too.
        let left = [b1, a1, snap]
        // At a1 itself, a2 (same device, higher seq) is ordered after the point as well.
        XCTAssertEqual(NoteHistory.restorePoints(left).map(\.complete), [true, true, true])
        XCTAssertEqual(try NoteHistory.state(left, at: b1.name).meta.title, "")
        XCTAssertEqual(try NoteHistory.state(left, at: a1.name).meta.title, "one")
    }

    func testPointItselfProvesLaterSeqsOfItsDeviceComeAfterIt() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0")), .addStroke(page: p1, stroke: drawn(1))])
        let a2 = log.delta(devA, 10, [.addStroke(page: p1, stroke: drawn(2))])
        let snap = try log.snapshot(devB, 20, from: [a1, a2])
        // a2 was compacted away; a1 is the point and has a lower seq of the same device.
        let left = [a1, snap]
        XCTAssertEqual(NoteHistory.restorePoints(left).map(\.complete), [true, true])
        XCTAssertEqual(try NoteHistory.state(left, at: a1.name).allStrokeIds.count, 1)
        let delta = try XCTUnwrap(try restore(left, to: a1.name, at: 30))
        XCTAssertEqual(RestoreSummary(delta.ops).strokesRemoved, 1)
    }

    func testUnreadableSnapshotMakesEveryPointIncomplete() throws {
        var log = LogBuilder()
        let a1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let b1 = log.delta(devB, 10, [.setMeta(.title("b"))])
        let a2 = log.delta(devA, 20, [.addStroke(page: p1, stroke: drawn(1))])
        let snap = try log.snapshot(devA, 30, from: [a1, a2])
        // a1 and a2 were compacted; the only record of them is the snapshot, which
        // cannot be read. As of b1 the note had page p1, but b1 alone does not.
        let loaded = LoadedNote(revisions: [b1], failures: [snap.name: .tagMismatch])
        XCTAssertEqual(loaded.restorePoints.map(\.complete), [false])
        XCTAssertThrowsError(try loaded.state(at: b1.name)) {
            XCTAssertEqual($0 as? HistoryError, .incompleteHistory(b1.name))
        }
    }

    func testHugeIncludedRangeIsNotEnumerated() throws {
        var log = LogBuilder()
        let b1 = log.delta(devB, 0, [.addPage(Page(id: p1, order: "a0"))])
        let a1 = log.delta(devA, 10, [.setMeta(.title("one"))])
        for upTo in [1 << 40, Int.max - 1] {
            var snap = try log.snapshot(devC, 20, from: [b1, a1])
            guard case .snapshot(_, let state) = snap.body else { return XCTFail("not a snapshot") }
            snap.body = .snapshot(included: Included([devA: .init(upTo: upTo), devB: .init(upTo: 1)]), state: state)
            // Every devA seq but 1 is gone; b1 precedes all of them only if a1 proves it, and a1 (seq 1) does.
            XCTAssertEqual(NoteHistory.restorePoints([b1, a1, snap]).map(\.complete), [true, true, true], "\(upTo)")
            // Without a1, nothing proves the gone devA revisions came after b1.
            XCTAssertEqual(NoteHistory.restorePoints([b1, snap]).map(\.complete), [false, true], "\(upTo)")
        }
    }

    func testUnreadableRevisionMakesLaterPointsIncomplete() throws {
        var log = LogBuilder()
        let d1 = log.delta(devA, 0, [.addPage(Page(id: p1, order: "a0"))])
        let d2 = log.delta(devA, 10, [.setMeta(.title("x"))])
        let d3 = log.delta(devA, 20, [.setMeta(.title("y"))])
        let loaded = LoadedNote(revisions: [d1, d3], failures: [d2.name: .tagMismatch])
        XCTAssertEqual(loaded.restorePoints.map(\.complete), [true, false])
        XCTAssertNoThrow(try loaded.state(at: d1.name))
        XCTAssertThrowsError(try loaded.state(at: d3.name))
    }

    // MARK: Naming a revision

    func testResolveRevisionByNameStemOrPrefix() throws {
        let a = RevisionName(hlc: HLC("17911308010000000")!, device: devA, seq: 1, kind: .delta)
        let b = RevisionName(hlc: HLC("17911308020000000")!, device: devB, seq: 1, kind: .snapshot)
        let names = [a, b]
        XCTAssertEqual(try NoteHistory.resolve(a.filename, among: names), a)
        XCTAssertEqual(try NoteHistory.resolve("17911308020000000-bbbbbbbb-1", among: names), b)
        XCTAssertEqual(try NoteHistory.resolve("1791130802", among: names), b)
        XCTAssertThrowsError(try NoteHistory.resolve("17911308", among: names)) {
            XCTAssertEqual($0 as? HistoryError, .ambiguousRevision("17911308", [a, b]))
        }
        XCTAssertThrowsError(try NoteHistory.resolve("1791", among: names)) {
            XCTAssertEqual($0 as? HistoryError, .unknownRevision("1791"))
        }
        XCTAssertThrowsError(try NoteHistory.resolve("nope-nope", among: names))
    }
}

/// The same through a vault on disk.
final class VaultHistoryTests: VaultTestCase {
    func testRestoreWritesOneDeltaAndNeverTouchesHistory() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        let before = try FileManager.default.contentsOfDirectory(atPath: fileURL(vault, testNote, log[0].name)
            .deletingLastPathComponent().path).sorted()
        let bytes = try before.map { try Data(contentsOf: fileURL(vault, testNote, RevisionName($0)!)) }

        let points = try vault.restorePoints(noteId: testNote)
        XCTAssertEqual(points.map(\.name), log.map(\.name).sorted())
        let target = log[1].name               // before B removed s1 and A added s3
        let expected = try vault.state(noteId: testNote, at: target)
        XCTAssertEqual(expected.allStrokeIds.count, 1)

        let device = DeviceID("dddddddd")!
        var clock = HybridClock()
        let dry = try vault.restore(note: testNote, toRevision: target, device: device, clock: &clock, app: "test/0",
                                    dryRun: true)
        XCTAssertFalse(dry.written)
        XCTAssertNotNil(dry.delta)
        XCTAssertEqual(try vault.revisionNames(of: testNote).count, log.count)

        let result = try vault.restore(note: testNote, toRevision: target, device: device, clock: &clock, app: "test/0")
        XCTAssertTrue(result.written)
        XCTAssertEqual(result.summary.strokesRemoved, 2)
        XCTAssertEqual(result.summary.strokesRestored, 1)
        XCTAssertEqual(result.summary.metaFields, ["tags"])
        let names = try vault.revisionNames(of: testNote)
        XCTAssertEqual(names.count, log.count + 1)
        XCTAssertEqual(names.last, result.delta?.name)
        // Old files are byte-for-byte unchanged.
        XCTAssertEqual(try before.map { try Data(contentsOf: fileURL(vault, testNote, RevisionName($0)!)) }, bytes)
        XCTAssertEqual(Content(try vault.reconstruct(noteId: testNote)), Content(expected))

        let again = try vault.restore(note: testNote, toRevision: target, device: device, clock: &clock, app: "test/0")
        XCTAssertNil(again.delta)
        XCTAssertFalse(again.written)
        XCTAssertTrue(again.summary.isEmpty)
        XCTAssertEqual(try vault.revisionNames(of: testNote).count, log.count + 1)
        XCTAssertTrue(vault.verify().isHealthy)
    }

    func testRestoreRefusesWhenARevisionIsUnreadable() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let log = sampleLog()
        for r in log { try vault.write(r) }
        try flipByte(fileURL(vault, testNote, log[4].name), at: 5)
        var clock = HybridClock()
        XCTAssertThrowsError(try vault.restore(note: testNote, toRevision: log[0].name, device: devC, clock: &clock,
                                               app: "test/0")) { e in
            guard case VaultError.revision = e else { return XCTFail("\(e)") }
        }
        // Viewing an earlier point still works.
        XCTAssertNoThrow(try vault.state(noteId: testNote, at: log[0].name))
        XCTAssertEqual(try vault.restorePoints(noteId: testNote).count, log.count - 1)
    }
}
