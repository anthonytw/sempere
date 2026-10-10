import Foundation
import XCTest
@testable import Sempere

/// Item gestures (`NoteOps` item builders, `ItemFrames`): every edit's ops,
/// applied by the reducer, give the page the builder predicts; moves are one
/// `setItem`, undo of a delete re-adds under new ids with `parent`, copies get
/// new ids on top; hit testing and resizing of rotated frames.
final class ItemOpsTests: XCTestCase {
    let pageID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
    let blob = BlobRef(sha256: String(repeating: "ab", count: 32), size: 1000, type: "image/png")

    func image(_ id: UUID = UUID(), frame: Rect = Rect(x: 10, y: 20, w: 100, h: 50), z: String = "a",
               rotation: Double? = nil) -> Item {
        var item = Item.image(id: id, blob: blob, pixelSize: Size(w: 200, h: 100), frame: frame, z: z)
        item.rotation = rotation
        return item
    }

    func text(_ s: String, z: String = "a") -> Item {
        .text(TextContent(size: 12, color: .black, runs: [TextRun(s)]), frame: Rect(x: 0, y: 0, w: 50, h: 20), z: z)
    }

    /// Reconstructs the page after `edits` (each one delta) on a fresh note.
    func reduced(_ edits: [[Op]]) throws -> Page {
        var log = LogBuilder()
        var revs = [log.delta(devA, 0, NoteOps.newNote(title: "Items", pageId: pageID))]
        for (i, ops) in edits.enumerated() { revs.append(log.delta(devA, Int64(i + 1) * 10, ops)) }
        return try XCTUnwrap(try NoteReducer.reconstruct(revs).pages.first { $0.id == pageID })
    }

    func strip(_ items: [Item]) -> [Item] {
        items.map { var i = $0; i.origin = nil; i.clocks = nil; return i }
    }

    func testAddMoveResizeDeleteMatchTheReducer() throws {
        let empty = Page(id: pageID, order: "a")
        let a = image(), b = text("hello")
        let add = try NoteOps.placeOnTop(a, on: empty)
        let add2 = try NoteOps.placeOnTop(b, on: add.page)
        XCTAssertEqual(add.added, [a.id])
        XCTAssertNotEqual(add.page.items[0].z, "a", "placed on top with a fresh key")
        let move = try XCTUnwrap(NoteOps.setFrame(a.id, to: Rect(x: 40, y: 60, w: 100, h: 50), on: add2.page))
        XCTAssertEqual(move.ops.count, 1)
        guard case .setItem(_, let id, .frame(let f)) = move.ops[0] else { return XCTFail("\(move.ops)") }
        XCTAssertEqual(id, a.id)
        XCTAssertEqual(f, Rect(x: 40, y: 60, w: 100, h: 50))
        let turn = try XCTUnwrap(NoteOps.setRotation(a.id, to: -90, on: move.page))
        let gone = try XCTUnwrap(NoteOps.removeItems([b.id, UUID()], from: turn.page))
        XCTAssertEqual(gone.ops.count, 1)
        let page = try reduced([add.ops, add2.ops, move.ops, turn.ops, gone.ops])
        XCTAssertEqual(strip(page.items), gone.page.items)
        XCTAssertEqual(page.items.first?.rotation, 270)
    }

    func testNoOpGesturesWriteNothing() throws {
        let a = image()
        let page = Page(id: pageID, order: "a", items: [a])
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: 10.0001, y: 20, w: 100, h: 50), on: page),
                     "below the stored precision")
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: 0, y: 0, w: 0, h: 5), on: page))
        XCTAssertNil(NoteOps.setFrame(a.id, to: Rect(x: .nan, y: 0, w: 5, h: 5), on: page))
        XCTAssertNil(NoteOps.setFrame(UUID(), to: Rect(x: 0, y: 0, w: 5, h: 5), on: page))
        XCTAssertNil(NoteOps.setRotation(a.id, to: 360, on: page))
        XCTAssertNil(NoteOps.removeItems([UUID()], from: page))
        XCTAssertNil(NoteOps.bringToFront(a.id, on: page), "already on top")
    }

    /// The app's Rotate 90° Left/Right and its two-finger turn (GA-02).
    func testRotationTurnsAndSnaps() {
        XCTAssertEqual(NoteOps.rotation(nil, turnedBy: 90), 90)
        XCTAssertEqual(NoteOps.rotation(nil, turnedBy: -90), 270)
        XCTAssertEqual(NoteOps.rotation(270, turnedBy: 90), 0, "four right turns are upright")
        XCTAssertEqual(NoteOps.rotation(10, turnedBy: -370), 0)
        XCTAssertEqual(NoteOps.rotation(350, turnedBy: 720.5), 350.5)
        XCTAssertEqual(NoteOps.rotation(nil, turnedBy: .infinity), 0)
        XCTAssertEqual(NoteOps.snappedRotation(88.4), 90, "within 3° of a multiple of 15")
        XCTAssertEqual(NoteOps.snappedRotation(358), 0, "wraps to upright")
        XCTAssertEqual(NoteOps.snappedRotation(52.26), 52.3, "otherwise a tenth of a degree")
        XCTAssertEqual(NoteOps.snappedRotation(.nan), 0)
        // A turn is one setItem rotation op and a full turn back is none.
        let a = image()
        let page = Page(id: pageID, order: "a", items: [a])
        let turned = NoteOps.rotation(a.rotation, turnedBy: -90)
        let edit = NoteOps.setRotation(a.id, to: turned, on: page)
        XCTAssertEqual(edit?.ops.count, 1)
        XCTAssertEqual(edit?.page.items.first?.rotation, 270)
        XCTAssertNil(NoteOps.setRotation(a.id, to: NoteOps.rotation(a.rotation, turnedBy: 360), on: page))
    }

    func testBringToFrontDrawsAboveTheOthersOfItsLayer() throws {
        let a = image(z: "a"), b = image(z: "b"), bg = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 10, h: 10),
                                                                     frame: Rect(x: 0, y: 0, w: 10, h: 10), z: "z")
        let page = Page(id: pageID, order: "a", items: [bg, a, b].sorted(by: Item.drawsBefore))
        let edit = try XCTUnwrap(NoteOps.bringToFront(a.id, on: page))
        XCTAssertEqual(edit.page.items.map(\.id), [bg.id, b.id, a.id])
        let reducedPage = try reduced([try NoteOps.addItems([bg, a, b], to: Page(id: pageID, order: "a")).ops, edit.ops])
        XCTAssertEqual(reducedPage.items.map(\.id), [bg.id, b.id, a.id])
    }

    func testUndoOfDeleteRestoresUnderNewIDsWithParent() throws {
        let a = image(), b = text("x", z: "b")
        let start = try NoteOps.addItems([a, b], to: Page(id: pageID, order: "a"))
        let gone = try XCTUnwrap(NoteOps.removeItems([a.id, b.id], from: start.page))
        var ids = [UUID(), UUID()].makeIterator()
        let back = try NoteOps.restoreItems([a, b], to: gone.page, newID: { ids.next()! })
        XCTAssertEqual(back.page.items.map(\.parent), [a.id, b.id])
        XCTAssertEqual(back.page.items.map(\.z), ["a", "b"], "drawn where they were")
        let page = try reduced([start.ops, gone.ops, back.ops])
        XCTAssertEqual(strip(page.items), back.page.items)
        XCTAssertFalse(page.items.contains { $0.id == a.id }, "the removed id stays removed")
    }

    func testCopiesGetNewIDsOnTopWithoutParentOrRec() throws {
        var a = image(z: "m")
        a.rec = RecordingLink(id: UUID(), at: 3)
        let target = Page(id: pageID, order: "a", items: [image(z: "q")])
        let copy = try NoteOps.copyItems([a, a], to: target, dx: 10, dy: 5)
        XCTAssertEqual(copy.added.count, 2)
        XCTAssertNotEqual(copy.added[0], a.id)
        XCTAssertNotEqual(copy.added[0], copy.added[1])
        let copies = copy.page.items.filter { copy.added.contains($0.id) }
        XCTAssertEqual(copies.map(\.frame.x), [20, 20])
        XCTAssertEqual(copies.map(\.frame.y), [25, 25])
        XCTAssertTrue(copies.allSatisfy { $0.parent == nil && $0.rec == nil && $0.blob == a.blob })
        XCTAssertEqual(copy.page.items.map(\.id).suffix(2), copy.added[...], "on top, in the order given")
        XCTAssertEqual(NoteOps.blobs(of: [a, a, text("t")]), [blob])
    }

    func testAddRejectsInvalidAndDuplicateItems() {
        let a = image()
        let page = Page(id: pageID, order: "a", items: [a])
        XCTAssertThrowsError(try NoteOps.addItems([a], to: page)) { XCTAssertEqual($0 as? ItemEditError, .duplicateID(a.id)) }
        var bad = image()
        bad.frame.w = 0
        XCTAssertThrowsError(try NoteOps.addItems([bad], to: Page(id: pageID, order: "a")))
    }

    // MARK: ItemFrames

    func testHitTestingFollowsRotationAndPrefersContent() {
        let tall = image(frame: Rect(x: 0, y: 0, w: 100, h: 20), rotation: 90)   // spans y -40...60 at x 40...60
        XCTAssertTrue(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 50, y: -30)))
        XCTAssertFalse(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 90, y: 10)))
        XCTAssertTrue(ItemFrames.contains(tall.frame, rotation: tall.rotation, .init(x: 62, y: 10), slop: 3))
        let bg = Item.pdfPage(blob: blob, pageIndex: 0, pageSize: Size(w: 10, h: 10), frame: Rect(x: 0, y: 0, w: 200, h: 200),
                              z: "z")
        let low = image(frame: Rect(x: 0, y: 0, w: 30, h: 30), z: "a"), high = image(frame: Rect(x: 10, y: 10, w: 30, h: 30), z: "b")
        let items = [bg, low, high]
        XCTAssertEqual(ItemFrames.item(at: .init(x: 20, y: 20), in: items)?.id, high.id)
        XCTAssertEqual(ItemFrames.item(at: .init(x: 5, y: 5), in: items)?.id, low.id)
        XCTAssertEqual(ItemFrames.item(at: .init(x: 150, y: 150), in: items)?.id, bg.id)
        XCTAssertNil(ItemFrames.item(at: .init(x: 150, y: 150), in: items, includeBackground: false))
    }

    func testBoundsOfARotatedFrame() {
        let b = ItemFrames.bounds(Rect(x: 0, y: 0, w: 100, h: 20), rotation: 90)
        XCTAssertEqual(b.x, 40, accuracy: 1e-9)
        XCTAssertEqual(b.y, -40, accuracy: 1e-9)
        XCTAssertEqual(b.w, 20, accuracy: 1e-9)
        XCTAssertEqual(b.h, 100, accuracy: 1e-9)
    }

    func testResizeKeepsTheOppositeCornerOnThePage() {
        for rotation in [0.0, 30, 90, 215] {
            let frame = Rect(x: 100, y: 100, w: 80, h: 40)
            for corner in ItemFrames.Corner.allCases {
                let fixedBefore = ItemFrames.corners(frame, rotation: rotation)[corner.opposite.rawValue]
                for keep in [false, true] {
                    let r = ItemFrames.resized(frame, rotation: rotation, corner: corner, dx: 13, dy: -7, keepAspect: keep)
                    let fixedAfter = ItemFrames.corners(r, rotation: rotation)[corner.opposite.rawValue]
                    XCTAssertEqual(fixedAfter.x, fixedBefore.x, accuracy: 1e-9, "r\(rotation) \(corner) aspect \(keep)")
                    XCTAssertEqual(fixedAfter.y, fixedBefore.y, accuracy: 1e-9, "r\(rotation) \(corner) aspect \(keep)")
                    if keep { XCTAssertEqual(r.w / r.h, 2, accuracy: 1e-9) }
                }
            }
        }
    }

    /// Side handles (a text box's width): the opposite side's middle stays on
    /// the page, only the side's axis changes (or both by one factor, keeping
    /// proportions), rotated or not.
    func testSideHandlesKeepTheOppositeSideOnThePage() {
        for rotation in [0.0, 30, 90, 215] {
            let frame = Rect(x: 100, y: 100, w: 80, h: 40)
            for edge in ItemFrames.Edge.allCases {
                let handle = ItemFrames.Handle.edge(edge)
                let fixedBefore = ItemFrames.point(of: .edge(edge.opposite), frame, rotation: rotation)
                for keep in [false, true] {
                    let r = ItemFrames.resized(frame, rotation: rotation, handle: handle, dx: 13, dy: -7, keepAspect: keep)
                    let fixedAfter = ItemFrames.point(of: .edge(edge.opposite), r, rotation: rotation)
                    XCTAssertEqual(fixedAfter.x, fixedBefore.x, accuracy: 1e-9, "r\(rotation) \(edge) aspect \(keep)")
                    XCTAssertEqual(fixedAfter.y, fixedBefore.y, accuracy: 1e-9, "r\(rotation) \(edge) aspect \(keep)")
                    if keep { XCTAssertEqual(r.w / r.h, 2, accuracy: 1e-9) }
                    if !keep, edge == .left || edge == .right { XCTAssertEqual(r.h, 40, accuracy: 1e-9, "height stays") }
                    if !keep, edge == .top || edge == .bottom { XCTAssertEqual(r.w, 80, accuracy: 1e-9, "width stays") }
                }
            }
        }
        let frame = Rect(x: 0, y: 0, w: 80, h: 40)
        XCTAssertEqual(ItemFrames.resized(frame, rotation: nil, handle: .edge(.right), dx: 20, dy: 99, keepAspect: false),
                       Rect(x: 0, y: 0, w: 100, h: 40), "a side ignores the other axis of the drag")
        XCTAssertEqual(ItemFrames.resized(frame, rotation: nil, handle: .edge(.left), dx: 30, dy: 0, keepAspect: false),
                       Rect(x: 30, y: 0, w: 50, h: 40))
        XCTAssertEqual(ItemFrames.resized(frame, rotation: nil, handle: .edge(.left), dx: 500, dy: 0, keepAspect: false).w, 8,
                       "floor")
        XCTAssertEqual(ItemFrames.resized(frame, rotation: nil, handle: .edge(.right), dx: 40, dy: 0, keepAspect: true),
                       Rect(x: 0, y: -10, w: 120, h: 60), "proportions kept about the fixed side's middle")
        XCTAssertEqual(ItemFrames.resized(frame, rotation: nil, handle: .edge(.right), dx: .nan, dy: 0, keepAspect: false),
                       frame, "a drag that is not finite changes nothing")
        // Corners through the handle API are the corner API.
        for c in ItemFrames.Corner.allCases {
            XCTAssertEqual(ItemFrames.resized(frame, rotation: 30, handle: .corner(c), dx: 5, dy: 9, keepAspect: true),
                           ItemFrames.resized(frame, rotation: 30, corner: c, dx: 5, dy: 9, keepAspect: true))
            let p = ItemFrames.point(of: .corner(c), frame, rotation: 30), q = ItemFrames.corners(frame, rotation: 30)[c.rawValue]
            XCTAssertEqual(p.x, q.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-9)
        }
    }

    /// Every kind offers the same handles whichever way it is selected: text
    /// boxes their sides (the height follows the text), the rest its corners.
    func testHandlesPerKind() {
        XCTAssertEqual(ItemFrames.handles(for: .text), [.edge(.left), .edge(.right)])
        for kind in [ItemKind.image, .pdfPage, .video, .math, ItemKind(rawValue: "future")] {
            XCTAssertEqual(ItemFrames.handles(for: kind), ItemFrames.Corner.allCases.map { .corner($0) }, "\(kind)")
            XCTAssertTrue(ItemFrames.keepsAspect(kind), "\(kind)")
        }
        XCTAssertFalse(ItemFrames.keepsAspect(.text))
        // An audio card (format.md §8.2.9) has corners but resizes freely: its label is laid out in
        // the frame, so a taller card shows more transcript and a wider one longer lines.
        XCTAssertEqual(ItemFrames.handles(for: .audio), ItemFrames.Corner.allCases.map { .corner($0) })
        XCTAssertFalse(ItemFrames.keepsAspect(.audio))
        let card = Rect(x: 0, y: 0, w: 300, h: 96)
        let taller = ItemFrames.resized(card, rotation: nil, handle: .corner(.bottomRight), dx: 0, dy: 60,
                                        keepAspect: ItemFrames.keepsAspect(.audio))
        XCTAssertEqual(taller, Rect(x: 0, y: 0, w: 300, h: 156), "only the height grows")
    }

    func testFittedIsTheLargestFrameOfTheProportionsCentred() {
        let box = Rect(x: 10, y: 20, w: 200, h: 100)
        XCTAssertEqual(ItemFrames.fitted(Size(w: 100, h: 100), into: box), Rect(x: 60, y: 20, w: 100, h: 100))
        XCTAssertEqual(ItemFrames.fitted(Size(w: 400, h: 100), into: box), Rect(x: 10, y: 45, w: 200, h: 50))
        XCTAssertEqual(ItemFrames.fitted(Size(w: 0, h: 100), into: box), box)
        XCTAssertEqual(ItemFrames.fitted(Size(w: .infinity, h: 100), into: box), box)
    }

    /// Replace Image: one delta (remove + add), the new image in the old
    /// one's place (fitted into its frame, same rotation, layer and z), with
    /// `parent`; the reducer agrees, and only images can be replaced.
    func testReplaceImageIsOneDeltaInTheOldPlace() throws {
        var old = image(frame: Rect(x: 10, y: 20, w: 100, h: 50), z: "m", rotation: 30)
        old.crop = Rect(x: 0, y: 0, w: 200, h: 100)
        old.rec = RecordingLink(id: UUID(), at: 3)
        let t = text("hi", z: "n")
        let page = Page(id: pageID, order: "a", items: [old, t])
        let newBlob = BlobRef(sha256: String(repeating: "cd", count: 32), size: 9, type: "image/jpeg")
        let newID = UUID()
        let edit = try NoteOps.replaceImage(old.id, blob: newBlob, pixelSize: Size(w: 300, h: 300), orientation: 6,
                                            on: page, newID: newID)
        XCTAssertEqual(edit.ops.count, 2)
        guard case .removeItem(_, let gone) = edit.ops[0], case .addItem(_, let added) = edit.ops[1] else {
            return XCTFail("\(edit.ops)")
        }
        XCTAssertEqual(gone, old.id)
        XCTAssertEqual(added.id, newID)
        XCTAssertEqual(added.parent, old.id)
        XCTAssertEqual(added.frame, Rect(x: 35, y: 20, w: 50, h: 50), "square picture fitted into the old frame")
        XCTAssertEqual(added.rotation, 30)
        XCTAssertEqual(added.z, "m")
        XCTAssertEqual(added.layer, old.layer)
        XCTAssertEqual(added.blob, newBlob)
        XCTAssertEqual(added.orientation, 6)
        XCTAssertNil(added.crop)
        XCTAssertNil(added.rec)
        XCTAssertEqual(edit.added, [newID])
        XCTAssertEqual(Set(edit.page.items.map(\.id)), [newID, t.id])
        let add = try NoteOps.addItems([old, t], to: Page(id: pageID, order: "a"))
        let reduced = try self.reduced([add.ops, edit.ops])
        XCTAssertEqual(strip(reduced.items), edit.page.items)
        XCTAssertThrowsError(try NoteOps.replaceImage(t.id, blob: newBlob, pixelSize: Size(w: 1, h: 1), on: page)) {
            XCTAssertEqual($0 as? AttachmentOpsError, .noSuchImage(t.id.uuidString.lowercased()))
        }
        XCTAssertThrowsError(try NoteOps.replaceImage(UUID(), blob: newBlob, pixelSize: Size(w: 1, h: 1), on: page))
        XCTAssertThrowsError(try NoteOps.replaceImage(old.id, blob: newBlob, pixelSize: Size(w: 0, h: 1), on: page))
        // The generic builder refuses a replacement under the same id.
        XCTAssertThrowsError(try NoteOps.replaceItem(old.id, with: old, on: page))
    }

    func testResizeFollowsTheDragAndHasAFloor() {
        let frame = Rect(x: 0, y: 0, w: 80, h: 40)
        let r = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: 20, dy: 10, keepAspect: false)
        XCTAssertEqual(r, Rect(x: 0, y: 0, w: 100, h: 50))
        let l = ItemFrames.resized(frame, rotation: nil, corner: .topLeft, dx: 20, dy: 10, keepAspect: false)
        XCTAssertEqual(l, Rect(x: 20, y: 10, w: 60, h: 30))
        // Rotated 90°: dragging the bottom-right corner (now at the bottom-left on the page) left widens it.
        let t = ItemFrames.resized(frame, rotation: 90, corner: .bottomRight, dx: -10, dy: 0, keepAspect: false)
        XCTAssertEqual(t.h, 50, accuracy: 1e-9)
        XCTAssertEqual(t.w, 80, accuracy: 1e-9)
        let tiny = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -500, dy: -500, keepAspect: true)
        XCTAssertEqual(tiny.h, 8, accuracy: 1e-9)
        XCTAssertEqual(tiny.w, 16, accuracy: 1e-9)
        // Keeping proportions, a corner dragged inward along one axis only shrinks the item.
        let narrower = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -20, dy: 0, keepAspect: true)
        XCTAssertEqual(narrower, Rect(x: 0, y: 0, w: 60, h: 30))
        let lower = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: 4, dy: 20, keepAspect: true)
        XCTAssertEqual(lower.h, 60, accuracy: 1e-9, "the axis that changed more wins")
        XCTAssertEqual(lower.w, 120, accuracy: 1e-9)
        let flat = ItemFrames.resized(frame, rotation: nil, corner: .bottomRight, dx: -500, dy: 0, keepAspect: false)
        XCTAssertEqual(flat.w, 8)
        XCTAssertEqual(ItemFrames.moved(frame, dx: 3, dy: -4), Rect(x: 3, y: -4, w: 80, h: 40))
    }

    // MARK: Text boxes (task E2)

    func testNormalizedRunsAreNFCMergedAndWithoutEmptyRuns() {
        let runs = NoteOps.normalizedRuns([TextRun("Cafe\u{301}\r\n"), TextRun(""), TextRun("x"), TextRun("y", b: true),
                                           TextRun("z", b: true)])
        XCTAssertEqual(runs, [TextRun("Caf\u{E9}\nx"), TextRun("yz", b: true)])
    }

    /// Pasted text can hold controls the format refuses: line breaking ones
    /// become `\n`, the others go, so the edit is never refused as a whole.
    func testNormalizedRunsHoldNoControlCharacters() throws {
        let runs = NoteOps.normalizedRuns([TextRun("a\u{0B}b\u{0C}c\rd\u{0}e\u{1B}f\tg")])
        XCTAssertEqual(runs, [TextRun("a\nb\nc\ndef\tg")])
        XCTAssertTrue(runs.allSatisfy { TextRun.isValidText($0.t) })
        let page = Page(id: pageID, order: "a", items: [text("hello")])
        var content = try XCTUnwrap(page.items[0].text)
        content.runs = runs
        XCTAssertNotNil(try NoteOps.setText(page.items[0].id, to: content, on: page))
    }

    func testSetTextWritesTextAndFrameInOneDelta() throws {
        let a = text("hello")
        let page = Page(id: pageID, order: "a", items: [a])
        var content = try XCTUnwrap(a.text)
        content.runs = [TextRun("hello world")]
        content.breaks = [6]
        let edit = try XCTUnwrap(try NoteOps.setText(a.id, to: content, frame: Rect(x: 0, y: 0, w: 50, h: 28.8), on: page))
        XCTAssertEqual(edit.ops.count, 2)
        guard case .setItem(_, _, .frame) = edit.ops[0], case .setItem(_, _, .text(let t)) = edit.ops[1] else {
            return XCTFail("\(edit.ops)")
        }
        XCTAssertEqual(t.breaks, [6])
        let start = try NoteOps.placeOnTop(a, on: Page(id: pageID, order: "a"))
        let on = try XCTUnwrap(try NoteOps.setText(a.id, to: content, frame: Rect(x: 0, y: 0, w: 50, h: 28.8), on: start.page))
        XCTAssertEqual(strip(try reduced([start.ops, on.ops]).items), on.page.items)
        // Unchanged: nothing; same frame: only the text.
        XCTAssertNil(try NoteOps.setText(a.id, to: try XCTUnwrap(a.text), frame: a.frame, on: page))
        XCTAssertEqual(try NoteOps.setText(a.id, to: content, on: page)?.ops.count, 1)
        // Not a text box, or bad content: refused.
        let img = image()
        XCTAssertNil(try NoteOps.setText(img.id, to: content, on: Page(id: pageID, order: "a", items: [img])))
        content.runs = [TextRun("bad\u{7}")]
        XCTAssertThrowsError(try NoteOps.setText(a.id, to: content, on: page))
        content.runs = [TextRun("ok")]
        content.size = 2000
        XCTAssertThrowsError(try NoteOps.setText(a.id, to: content, on: page))
    }

    func testResizingATextBoxRelaysItOut() throws {
        let a = text("hello world")
        let page = Page(id: pageID, order: "a", items: [a])
        var calls = 0
        func relayout(_ c: TextContent, _ f: Rect) -> (content: TextContent, frame: Rect) {
            calls += 1
            var out = c
            out.breaks = f.w < 40 ? [6] : nil
            return (out, Rect(x: f.x, y: f.y, w: f.w, h: f.w < 40 ? 28.8 : 14.4))
        }
        // A move keeps the width: no relayout, one setItem(frame).
        let move = try XCTUnwrap(NoteOps.setFrame(a.id, to: Rect(x: 5, y: 5, w: 50, h: 20), on: page, relayout: relayout))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(move.ops.count, 1)
        // Narrower: new breaks and the height the lines need, in the same delta.
        let narrow = try XCTUnwrap(NoteOps.setFrame(a.id, to: Rect(x: 0, y: 0, w: 30, h: 99), on: page, relayout: relayout))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(narrow.ops.count, 2)
        XCTAssertEqual(narrow.page.items[0].frame, Rect(x: 0, y: 0, w: 30, h: 28.8))
        XCTAssertEqual(narrow.page.items[0].text?.breaks, [6])
        // Images are never laid out.
        let img = image()
        let resized = try XCTUnwrap(NoteOps.setFrame(img.id, to: Rect(x: 0, y: 0, w: 30, h: 15),
                                                     on: Page(id: pageID, order: "a", items: [img]), relayout: relayout))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(resized.ops.count, 1)
    }
}
