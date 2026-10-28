import Foundation
import XCTest
@testable import Sempere
import Age

/// The merge of placed items and recordings (format.md §5.3, §8.2.2, §8.3.1):
/// the concurrency scenarios of docs/attachments.md §14 (task A1), snapshots,
/// history and restore, summaries.
final class AttachmentMergeTests: VaultTestCase {
    let page = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let page2 = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    let imageBlob = BlobRef(sha256: String(repeating: "ab", count: 32), size: 482_113, type: "image/jpeg")
    let pdfBlob = BlobRef(sha256: String(repeating: "cd", count: 32), size: 1_830_221, type: "application/pdf")
    let audioBlob = BlobRef(sha256: String(repeating: "ef", count: 32), size: 28_311_552, type: "audio/mp4")

    func image(_ id: UUID = UUID(), frame: Rect = Rect(x: 72, y: 144, w: 216, h: 288)) -> Item {
        .image(id: id, blob: imageBlob, pixelSize: Size(w: 3024, h: 4032), orientation: 6, frame: frame, z: "a0")
    }

    func textBox(_ text: String, z: String = "a1") -> Item {
        .text(TextContent(size: 12, color: .black, runs: [TextRun(text)]), frame: Rect(x: 72, y: 90, w: 300, h: 40), z: z)
    }

    func recording(_ id: UUID = UUID(), title: String? = nil) -> Recording {
        Recording(id: id, blob: audioBlob, started: wallAt(baseMillis), duration: 12.5, codec: "aac", title: title)
    }

    /// A note with one page.
    func newNote(_ log: inout LogBuilder, extra: [Op] = []) -> Revision {
        log.delta(devA, 0, NoteOps.newNote(title: "Att", pageId: page) + extra)
    }

    func items(_ s: NoteState) -> [Item] { s.pages.flatMap(\.items) }

    /// Reconstructs every permutation of `revs` (up to 5 revisions) and
    /// checks they all agree; returns the state.
    @discardableResult
    func merged(_ revs: [Revision], file: StaticString = #filePath, line: UInt = #line) throws -> NoteState {
        let reference = try NoteReducer.reconstruct(revs)
        func permutations(_ a: [Revision]) -> [[Revision]] {
            guard a.count > 1 else { return [a] }
            return a.indices.flatMap { i -> [[Revision]] in
                var rest = a
                let x = rest.remove(at: i)
                return permutations(rest).map { [x] + $0 }
            }
        }
        if revs.count <= 5 {
            for p in permutations(revs) {
                XCTAssertEqual(try NoteReducer.reconstruct(p), reference, file: file, line: line)
            }
        }
        return reference
    }

    // MARK: docs/attachments.md §14 scenarios

    /// Concurrent `setItem(frame)`: the higher stamp wins, in both orders and
    /// through a snapshot of either side.
    func testConcurrentFrameSetHigherStampWins() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let a = log.delta(devA, 10, [.setItem(page: page, itemId: img.id, change: .frame(Rect(x: 1, y: 1, w: 10, h: 10)))])
        let b = log.delta(devB, 20, [.setItem(page: page, itemId: img.id, change: .frame(Rect(x: 2, y: 2, w: 20, h: 20)))])
        let s = try merged([d0, a, b])
        XCTAssertEqual(items(s).map(\.frame), [Rect(x: 2, y: 2, w: 20, h: 20)])
        XCTAssertEqual(items(s).first?.clocks?["frame"], b.stamp.description)
        // A snapshot holding the loser does not beat the later op it does not cover...
        let snapA = try log.snapshot(devC, 30, from: [d0, a])
        XCTAssertEqual(try merged([snapA, b]).pages, s.pages)
        // ...and one holding the winner beats the older uncovered op.
        let snapB = try log.snapshot(devC, 40, from: [d0, b])
        XCTAssertEqual(items(try merged([snapB, a])).map(\.frame), [Rect(x: 2, y: 2, w: 20, h: 20)])
    }

    /// A move on one device and a crop on another set different registers:
    /// both apply.
    func testMoveAndCropOnDifferentFieldsBothApply() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let move = log.delta(devA, 10, [.setItem(page: page, itemId: img.id, change: .frame(Rect(x: 5, y: 5, w: 216, h: 288)))])
        let crop = log.delta(devB, 5, [.setItem(page: page, itemId: img.id, change: .crop(Rect(x: 0, y: 0, w: 100, h: 100)))])
        let got = try XCTUnwrap(items(try merged([d0, move, crop])).first)
        XCTAssertEqual(got.frame, Rect(x: 5, y: 5, w: 216, h: 288))
        XCTAssertEqual(got.crop, Rect(x: 0, y: 0, w: 100, h: 100))
        XCTAssertEqual(got.blob, imageBlob)
        XCTAssertEqual(got.orientation, 6)
    }

    /// `removeItem` and a concurrent (even later-stamped) `setItem`: removed.
    func testRemoveWinsOverConcurrentSet() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let remove = log.delta(devA, 10, [.removeItem(page: page, itemId: img.id)])
        let set = log.delta(devB, 20, [.setItem(page: page, itemId: img.id, change: .z("zz"))])
        let s = try merged([d0, remove, set])
        XCTAssertTrue(items(s).isEmpty)
        XCTAssertEqual(s.tombstones?.items, [img.id])
        // A snapshot from either side keeps it removed.
        XCTAssertTrue(items(try merged([try log.snapshot(devC, 30, from: [d0, set]), remove])).isEmpty)
        XCTAssertTrue(items(try merged([try log.snapshot(devC, 40, from: [d0, remove]), set])).isEmpty)
    }

    /// `setItem` arriving before its `addItem` is an orphan: a snapshot of
    /// what arrived leaves it out of `included`, and it applies once the add
    /// arrives.
    func testSetItemBeforeItsAddIsAnOrphanAppliedLater() throws {
        var log = LogBuilder()
        let d0 = newNote(&log)
        let img = image()
        let add = log.delta(devA, 10, [.addItem(page: page, item: img)])
        let set = log.delta(devB, 20, [.setItem(page: page, itemId: img.id, change: .rotation(90)),
                                       .addStroke(page: page, stroke: stroke())])
        let snap = try log.snapshot(devC, 30, from: [d0, set])
        guard case .snapshot(let included, let state) = snap.body else { return XCTFail() }
        XCTAssertFalse(included.covers(device: devB, seq: set.seq), "an orphan is not covered")
        XCTAssertTrue(state.pages[0].items.isEmpty)
        XCTAssertEqual(state.pages[0].strokes.count, 1, "the delta's other ops still apply")
        // Once the add arrives, the uncovered set applies.
        let s = try merged([snap, set, add])
        XCTAssertEqual(items(s).first?.rotation, 90)
        // Without the orphan delta itself (only the snapshot), the rotation would be lost: it is still needed.
        XCTAssertNil(items(try NoteReducer.reconstruct([snap, add])).first?.rotation)
        // A recording's register likewise.
        let rec = recording()
        let addRec = log.delta(devA, 35, [.addRecording(rec)])
        let setTitle = log.delta(devB, 40, [.setRecording(recordingId: rec.id, change: .title("Lecture"))])
        let snap2 = try log.snapshot(devC, 50, from: [d0, setTitle])
        guard case .snapshot(let inc2, _) = snap2.body else { return XCTFail() }
        XCTAssertFalse(inc2.covers(device: devB, seq: setTitle.seq))
        XCTAssertEqual(try merged([snap2, setTitle, addRec]).recordings.map(\.title), ["Lecture"])
    }

    /// `addItem` naming a page nobody has seen is an orphan too.
    func testAddItemOnUnknownPageIsAnOrphan() throws {
        var log = LogBuilder()
        let d0 = newNote(&log)
        let addPage = log.delta(devA, 10, [.addPage(Page(id: page2, order: "b"))])
        let img = image()
        let addItem = log.delta(devB, 20, [.addItem(page: page2, item: img)])
        let snap = try log.snapshot(devC, 30, from: [d0, addItem])
        guard case .snapshot(let included, _) = snap.body else { return XCTFail() }
        XCTAssertFalse(included.covers(device: devB, seq: addItem.seq))
        XCTAssertEqual(items(try merged([snap, addItem, addPage])).map(\.id), [img.id])
    }

    /// A late `setItem` on an item whose add and remove were compacted away
    /// (only a snapshot's tombstone remains) is a covered no-op, not an orphan.
    func testLateSetOnCompactedRemovedItemIsCoveredNoOp() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let remove = log.delta(devA, 10, [.removeItem(page: page, itemId: img.id)])
        let snap = try log.snapshot(devA, 20, from: [d0, remove])
        // Compaction deleted d0 and remove; a device offline since d0 writes:
        let late = log.delta(devB, 5, [.setItem(page: page, itemId: img.id, change: .frame(Rect(x: 0, y: 0, w: 1, h: 1)))])
        let s = try merged([snap, late])
        XCTAssertTrue(items(s).isEmpty)
        let next = try log.snapshot(devC, 30, from: [snap, late])
        guard case .snapshot(let included, let state) = next.body else { return XCTFail() }
        XCTAssertTrue(included.covers(device: devB, seq: late.seq), "covered: the op is a no-op, not an orphan")
        XCTAssertEqual(state.tombstones?.items, [img.id])
        // Likewise for a recording.
        let rec = recording()
        let addRec = log.delta(devA, 40, [.addRecording(rec)])
        let rmRec = log.delta(devA, 50, [.removeRecording(recordingId: rec.id)])
        let snap2 = try log.snapshot(devA, 60, from: [snap, addRec, rmRec])
        let lateRec = log.delta(devB, 45, [.setRecording(recordingId: rec.id, change: .title("x"))])
        let next2 = try log.snapshot(devC, 70, from: [snap2, lateRec])
        guard case .snapshot(let inc2, let st2) = next2.body else { return XCTFail() }
        XCTAssertTrue(inc2.covers(device: devB, seq: lateRec.seq))
        XCTAssertTrue(st2.recordings.isEmpty)
        XCTAssertEqual(st2.tombstones?.recordings, [rec.id])
    }

    /// A late `setItem` on an item whose *page* was removed, after compaction
    /// deleted the item's add and the page's removal: the page tombstone is
    /// permanent, so the op is a covered no-op (§8.2.2), not an orphan that no
    /// snapshot could ever cover (and compaction never delete).
    func testLateSetOnItemOfCompactedRemovedPageIsCoveredNoOp() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addPage(Page(id: page2, order: "b")), .addItem(page: page2, item: img)])
        let removePage = log.delta(devA, 10, [.removePage(pageId: page2)])
        let snap = try log.snapshot(devA, 20, from: [d0, removePage])
        // Compaction deleted d0 and removePage; a device offline since d0 writes:
        let late = log.delta(devB, 5, [.setItem(page: page2, itemId: img.id, change: .rotation(90))])
        XCTAssertTrue(items(try merged([snap, late])).isEmpty)
        let next = try log.snapshot(devC, 30, from: [snap, late])
        guard case .snapshot(let included, _) = next.body else { return XCTFail() }
        XCTAssertTrue(included.covers(device: devB, seq: late.seq), "covered: the page is removed")
    }

    /// A snapshot re-emits an item of an unknown kind, with an unknown layer
    /// and unknown fields, unchanged (plus `origin` and `clocks`).
    func testSnapshotReEmitsUnknownKindUnchanged() throws {
        let source = #"""
            {"id":"6f1c2d4e-0000-4000-8000-000000000009","kind":"hologram","layer":4242,"frame":[1,2,3,4],
             "z":"q","beam":{"rgb":[1,2,3],"on":true},"blob":{"sha256":"\#(String(repeating: "ab", count: 32))","size":3,"type":"x/y"},
             "text":"not a text object","crop":7}
            """#
        let item = try InkJSON.decoder().decode(Item.self, from: Data(source.utf8))
        var log = LogBuilder()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: item)])
        let snap = try log.snapshot(devB, 10, from: [d0])
        let json = try InkJSON.encoder().encode(snap)
        let back = try InkJSON.decoder().decode(Revision.self, from: json)
        guard case .snapshot(_, let state) = back.body else { return XCTFail() }
        var got = try XCTUnwrap(state.pages.first?.items.first)
        XCTAssertEqual(got.origin, Origin(d0.name, op: NoteOps.newNote(title: "Att", pageId: page).count).description)
        XCTAssertEqual(Set(got.clocks?.keys.map { $0 } ?? []), ["frame", "rotation", "z", "beam", "text", "crop"],
                       "unknown fields are registers; `blob` is immutable everywhere")
        got.origin = nil; got.clocks = nil
        XCTAssertEqual(got, item)
        XCTAssertEqual(try JSONValue(encoding: got), try InkJSON.decoder().decode(JSONValue.self, from: Data(source.utf8)))
        // ...and a later register change of an unknown field merges like any other.
        let set = log.delta(devA, 20, [.setItem(page: page, itemId: item.id, change: .other(field: "beam", value: .null))])
        XCTAssertEqual(items(try merged([snap, set])).first?.extra["beam"], .null)
    }

    /// Restoring a deleted image twice writes nothing the second time.
    func testRestoreOfDeletedImageTwiceIsNoOp() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let crop = log.delta(devA, 10, [.setItem(page: page, itemId: img.id, change: .crop(Rect(x: 1, y: 1, w: 9, h: 9)))])
        let remove = log.delta(devB, 20, [.removeItem(page: page, itemId: img.id)])
        var clock = HybridClock()
        let restore = try XCTUnwrap(try NoteHistory.makeRestore(from: [d0, crop, remove], to: crop.name, device: devC,
                                                                clock: &clock, wall: wallAt(baseMillis + 30), app: "test"))
        XCTAssertEqual(RestoreSummary(restore.ops).itemsRestored, 1)
        let s = try NoteReducer.reconstruct([d0, crop, remove, restore])
        let copy = try XCTUnwrap(items(s).first)
        XCTAssertNotEqual(copy.id, img.id)
        XCTAssertEqual(copy.parent, img.id)
        XCTAssertEqual(copy.crop, Rect(x: 1, y: 1, w: 9, h: 9), "register values as of the point")
        XCTAssertTrue(copy.hasSameImmutableFields(as: img))
        XCTAssertNil(try NoteHistory.makeRestore(from: [d0, crop, remove, restore], to: crop.name, device: devC,
                                                 clock: &clock, wall: wallAt(baseMillis + 40), app: "test"))
    }

    // MARK: Other merge rules

    /// A removed page removes its items; ops on it stay covered no-ops.
    func testRemovedPageRemovesItsItems() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addPage(Page(id: page2, order: "b")), .addItem(page: page2, item: img)])
        let rm = log.delta(devA, 10, [.removePage(pageId: page2)])
        let late = log.delta(devB, 5, [.addItem(page: page2, item: textBox("x")),
                                       .setItem(page: page2, itemId: img.id, change: .z("b"))])
        let s = try merged([d0, rm, late])
        XCTAssertTrue(items(s).isEmpty)
        let snap = try log.snapshot(devC, 20, from: [d0, rm, late])
        guard case .snapshot(let included, _) = snap.body else { return XCTFail() }
        XCTAssertTrue(included.covers(device: devB, seq: late.seq))
    }

    /// A snapshot that covers an item's add but does not hold it has seen it removed.
    func testCoveredAddNotHeldIsRemoved() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log)
        let add = log.delta(devA, 10, [.addItem(page: page, item: img)])
        // A writer older than tombstones for items: its snapshot covers `add` but holds nothing.
        var clock = HybridClock()
        var snap = try SnapshotBuilder.makeSnapshot(from: [d0, add], device: devB, seq: 1, clock: &clock,
                                                    wall: wallAt(baseMillis + 20), app: "old")
        guard case .snapshot(let included, var state) = snap.body else { return XCTFail() }
        state.pages[0].items = []
        state.tombstones = nil
        snap.body = .snapshot(included: included, state: state)
        XCTAssertTrue(items(try merged([d0, add, snap])).isEmpty)
    }

    /// Items draw by `(layer, z, id)`; the snapshot lists them in that order
    /// and recordings by `(started, id)`.
    func testOrdering() throws {
        var log = LogBuilder()
        let bg = Item.pdfPage(blob: pdfBlob, pageIndex: 0, pageSize: Size(w: 612, h: 792),
                              frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "z")
        let t1 = textBox("one", z: "b"), t2 = textBox("two", z: "a")
        let late = Recording(id: UUID(), blob: audioBlob, started: wallAt(baseMillis + 5000))
        let early = Recording(id: UUID(), blob: audioBlob, started: wallAt(baseMillis))
        let d0 = newNote(&log, extra: [.addItem(page: page, item: t1), .addItem(page: page, item: bg),
                                       .addItem(page: page, item: t2), .addRecording(late), .addRecording(early)])
        let s = try merged([d0])
        XCTAssertEqual(items(s).map(\.id), [bg.id, t2.id, t1.id])
        XCTAssertEqual(s.recordings.map(\.id), [early.id, late.id])
        // Changing `z` reorders.
        let set = log.delta(devA, 10, [.setItem(page: page, itemId: t2.id, change: .z("c"))])
        XCTAssertEqual(items(try merged([d0, set])).map(\.id), [bg.id, t1.id, t2.id])
    }

    /// Recording registers merge LWW; remove wins over a concurrent set.
    func testRecordingRegisters() throws {
        var log = LogBuilder()
        let rec = recording(title: "first")
        let d0 = newNote(&log, extra: [.addRecording(rec)])
        let a = log.delta(devA, 20, [.setRecording(recordingId: rec.id, change: .title("A"))])
        let b = log.delta(devB, 10, [.setRecording(recordingId: rec.id, change: .title("B")),
                                     .setRecording(recordingId: rec.id, change: .other(field: "speaker", value: .string("me")))])
        let s = try merged([d0, a, b])
        XCTAssertEqual(s.recordings.first?.title, "A")
        XCTAssertEqual(s.recordings.first?.extra["speaker"], .string("me"))
        let transcript = BlobRef(sha256: String(repeating: "12", count: 32), size: 9, type: BlobRef.transcriptType)
        let c = log.delta(devC, 30, [.setRecording(recordingId: rec.id, change: .transcript(transcript)),
                                     .setRecording(recordingId: rec.id, change: .title(nil))])
        let s2 = try merged([d0, a, b, c])
        XCTAssertEqual(s2.recordings.first?.transcript, transcript)
        XCTAssertNil(s2.recordings.first?.title)
        XCTAssertEqual(s2.blobReferences, [transcript, audioBlob].sorted { $0.sha256 < $1.sha256 })
        let rm = log.delta(devA, 15, [.removeRecording(recordingId: rec.id)])
        XCTAssertTrue(try merged([d0, a, b, c, rm]).recordings.isEmpty)
    }

    /// Within one delta later ops win; an add's registers carry its stamp.
    func testSetInSameDeltaAsAdd() throws {
        var log = LogBuilder()
        let t = textBox("draft")
        let newText = TextContent(size: 12, color: .black, runs: [TextRun("final")])
        let d0 = newNote(&log, extra: [.addItem(page: page, item: t), .setItem(page: page, itemId: t.id, change: .text(newText))])
        let got = try XCTUnwrap(items(try merged([d0])).first)
        XCTAssertEqual(got.text, newText)
        XCTAssertEqual(got.clocks?["text"], d0.stamp.description)
        XCTAssertEqual(got.clocks?["frame"], d0.stamp.description)
    }

    /// A typed register a kind does not have (`crop` on a text box) is an
    /// unknown field there (§8.2.1): kept in `extra`, never a typed field.
    func testRegisterOfAnotherKindIsKeptAsUnknownField() throws {
        var log = LogBuilder()
        let t = textBox("x")
        let d0 = newNote(&log, extra: [.addItem(page: page, item: t)])
        let set = log.delta(devA, 10, [.setItem(page: page, itemId: t.id, change: .crop(Rect(x: 0, y: 0, w: 1, h: 1)))])
        let got = try XCTUnwrap(items(try merged([d0, set])).first)
        XCTAssertNil(got.crop)
        XCTAssertEqual(got.extra["crop"], .array([.number(0), .number(0), .number(1), .number(1)]))
        XCTAssertNoThrow(try InkJSON.encoder().encode(got))
        let snap = try log.snapshot(devB, 20, from: [d0, set])
        XCTAssertEqual(items(try NoteReducer.reconstruct([snap])).first?.extra["crop"], got.extra["crop"])
    }

    /// `apply` (live editing) agrees with `reconstruct`.
    func testIncrementalApplyMatchesReconstruct() throws {
        var log = LogBuilder()
        let img = image(), rec = recording()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img), .addRecording(rec)])
        let d1 = log.delta(devB, 10, [.setItem(page: page, itemId: img.id, change: .rotation(45)),
                                      .setRecording(recordingId: rec.id, change: .title("t"))])
        let d2 = log.delta(devA, 20, [.addItem(page: page, item: textBox("x")), .removeItem(page: page, itemId: img.id)])
        let base = try NoteReducer.reconstruct([d0])
        let applied = try NoteReducer.apply([d1, d2], to: base, stamp: d0.stamp)
        let full = try NoteReducer.reconstruct([d0, d1, d2])
        XCTAssertEqual(applied.pages.map { $0.items.map(\.id) }, full.pages.map { $0.items.map(\.id) })
        XCTAssertEqual(applied.recordings.map(\.title), ["t"])
        XCTAssertEqual(applied.tombstones?.items, [img.id])
    }

    // MARK: History and restore

    /// A restore round trip with items and recordings: whatever changed
    /// since the point (moves, edits, removals, additions, a re-created
    /// page) is set back, and restoring again writes nothing.
    func testRestoreRoundTripWithItems() throws {
        var log = LogBuilder()
        let img = image(), t = textBox("hello"), rec = recording(title: "talk")
        var linked = textBox("during the talk", z: "c")
        linked.rec = RecordingLink(id: rec.id, at: 3)
        let bg = Item.pdfPage(blob: pdfBlob, pageIndex: 2, pageSize: Size(w: 612, h: 792),
                              frame: Rect(x: 0, y: 0, w: 612, h: 792), z: "a")
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img), .addItem(page: page, item: t),
                                       .addItem(page: page, item: linked), .addRecording(rec),
                                       .addPage(Page(id: page2, order: "b")), .addItem(page: page2, item: bg)])
        let point = d0.name
        let target = try NoteHistory.state([d0], at: point)
        // Since: a move, a text edit, the image moved to page 2, the recording renamed then removed,
        // a new item, page 2 removed.
        let moved = image(UUID())
        let d1 = log.delta(devA, 10, [
            .setItem(page: page, itemId: t.id, change: .frame(Rect(x: 9, y: 9, w: 300, h: 40))),
            .setItem(page: page, itemId: t.id, change: .text(TextContent(size: 20, color: .white, runs: [TextRun("bye")]))),
            .setItem(page: page, itemId: t.id, change: .other(field: "note", value: .string("x"))),
            .setRecording(recordingId: rec.id, change: .title("renamed")),
            .addItem(page: page, item: textBox("new")),
        ])
        var movedCopy = moved
        movedCopy.parent = img.id
        let d2 = log.delta(devB, 20, [.removeItem(page: page, itemId: img.id), .addItem(page: page2, item: movedCopy),
                                      .removeRecording(recordingId: rec.id)])
        let d3 = log.delta(devA, 30, [.removePage(pageId: page2)])
        let revs = [d0, d1, d2, d3]
        var clock = HybridClock()
        let restore = try XCTUnwrap(try NoteHistory.makeRestore(from: revs, to: point, device: devC, clock: &clock,
                                                                wall: wallAt(baseMillis + 40), app: "test"))
        let summary = RestoreSummary(restore.ops)
        XCTAssertEqual(summary.pagesRestored, 1)
        XCTAssertEqual(summary.itemsRemoved, 1, "the new text box")
        XCTAssertEqual(summary.itemsRestored, 2, "the image on page 1 and the PDF page on the re-created page")
        XCTAssertEqual(summary.itemChanges, 1)
        XCTAssertEqual(summary.recordingsRestored, 1)
        XCTAssertFalse(restore.ops.contains { if case .setItem(_, _, .other) = $0 { return true }; return false },
                       "an unknown field the point lacks cannot be made absent again")

        let after = try NoteReducer.reconstruct(revs + [restore])
        func shape(_ s: NoteState) -> [[String]] {
            s.pages.map { p in
                p.items.map { i in
                    "\(i.kind) \(i.layer) \(i.z) \(i.frame) \(i.text?.string ?? "") \(String(describing: i.crop)) "
                        + "\(String(describing: i.blob?.sha256)) \(String(describing: i.pageIndex))"
                }
            }
        }
        XCTAssertEqual(shape(after), shape(target))
        XCTAssertEqual(after.recordings.map(\.title), ["talk"])
        let restoredRec = try XCTUnwrap(after.recordings.first)
        XCTAssertEqual(restoredRec.parent, rec.id)
        // The text box's `rec` still names the old recording; it resolves to the restored copy (§8.3.3).
        let link = try XCTUnwrap(items(after).first { $0.text?.string == "during the talk" }?.rec)
        XCTAssertEqual(after.recording(for: link)?.id, restoredRec.id)
        XCTAssertNil(after.recording(for: RecordingLink(id: UUID(), at: 0)))
        // The image restored on page 1 names the original.
        XCTAssertEqual(after.pages[0].items.first { $0.kind == .image }?.parent, img.id)

        // Restoring again writes nothing.
        XCTAssertNil(try NoteHistory.makeRestore(from: revs + [restore], to: point, device: devC, clock: &clock,
                                                 wall: wallAt(baseMillis + 50), app: "test"))
        // Through the vault and its snapshot too.
        let snap = try log.snapshot(devB, 60, from: revs + [restore])
        XCTAssertNil(try NoteHistory.makeRestore(from: revs + [restore, snap], to: point, device: devC, clock: &clock,
                                                 wall: wallAt(baseMillis + 70), app: "test"))
    }

    /// History of a note with attachments is shown as of each point.
    func testStateAtPointHoldsItems() throws {
        var log = LogBuilder()
        let img = image()
        let d0 = newNote(&log, extra: [.addItem(page: page, item: img)])
        let d1 = log.delta(devA, 10, [.removeItem(page: page, itemId: img.id)])
        XCTAssertEqual(items(try NoteHistory.state([d0, d1], at: d0.name)).map(\.id), [img.id])
        XCTAssertTrue(items(try NoteHistory.state([d0, d1], at: d1.name)).isEmpty)
    }

    // MARK: Summaries

    func testSummaryCountsItemsAndRecordings() throws {
        try XCTSkipUnless(postQuantumAvailable)
        let vault = try makeVault(pqIdentity())
        let deviceState = tmp.appendingPathComponent("device.json")
        let img = image(), rec = recording()
        let id = UUID()
        try vault.apply(NoteOps.newNote(title: "Att", pageId: page) + [
            .addItem(page: page, item: img), .addItem(page: page, item: textBox("photosynthesis notes")),
            .addRecording(rec),
        ], to: id, deviceState: deviceState, app: "test")
        let s = try vault.summary(of: id)
        XCTAssertEqual(s.items, 2)
        XCTAssertEqual(s.textItems, 1)
        XCTAssertEqual(s.recordings, 1)
        XCTAssertEqual(s.blobs, [imageBlob, audioBlob].sorted { $0.sha256 < $1.sha256 })
        XCTAssertEqual(s.pageTexts.map(\.text), ["photosynthesis notes"])
        XCTAssertEqual(s.recognizedPages, 0)
        XCTAssertEqual(NoteSearch.search("photosynth", in: [s]).map(\.note), [id])
        // A snapshot of it is now allowed and keeps everything.
        var clock = HybridClock()
        try vault.snapshot(noteId: id, device: devB, clock: &clock, wall: Date(), app: "test")
        var after = try vault.summary(of: id)
        after.modified = s.modified
        XCTAssertEqual(after, s)
    }
}
