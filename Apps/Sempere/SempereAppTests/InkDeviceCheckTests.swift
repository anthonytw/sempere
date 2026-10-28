import Foundation
import PencilKit
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// The ink device checks of the audit's checklist (plan "Device checks after the audit"), automated
/// through the real canvas path (`InkInjector`) on synthetic ink (`SyntheticInk`, as `sempere pages
/// scribble` writes it): c4 edited strokes, c11 pen-up and edits on a dense page, c12 and c50 the
/// object eraser, c52 the ink's extent. What only hardware can tell (Pencil latency, the feel of a
/// sweep on an older iPad) stays with the owner; timings here are generous bounds that catch a
/// regression to the old whole-drawing paths, not device numbers.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct InkDeviceCheckTests {
    static let ink = Sempere.Color(r: 0x1A, g: 0x2B, b: 0x3C, a: 0xFF)

    /// Live strokes of `page` as a fresh reader of `vault` sees them, and whether the merge left
    /// duplicates (format.md §5.6.1).
    static func onDisk(_ vault: Vault, _ note: UUID, page: UUID) throws -> (live: [Stroke], duplicates: Int) {
        let state = try vault.reconstruct(noteId: note)
        let live = try #require(state.pages.first { $0.id == page }).strokes
        return (live, try vault.strokeConflicts(of: note).duplicates.count)
    }

    // MARK: - c4

    /// c4: draw, lasso-move, resize, recolor, undo, redo, then a pixel erase across the stroke, on
    /// device A while device B has the note open on a second copy of the vault (synced by copying
    /// files, as iCloud Drive does). After every save both copies, both editors and B's canvas hold
    /// exactly one stroke (two masked pieces after the pixel erase, both naming the erased stroke as
    /// parent), the merge on B writes nothing (no echo), and no duplicate is ever left. Then B edits
    /// and A takes it the same way.
    @Test func c4EditedStrokesStaySingleOnBothCopies() async throws {
        let made = try InkFixture.denseNote(strokes: 0)
        let urlB = made.url.deletingLastPathComponent().appendingPathComponent("copy-b.sempere")
        try FileManager.default.copyItem(at: made.url, to: urlB)
        let identity = try IdentityFile.parse(try String(contentsOf: made.key, encoding: .utf8))
        let vaultB = try Vault.open(at: urlB, identities: [identity])
        let (editorA, clockA) = try await InkFixture.editor(made)
        let (editorB, clockB) = try await InkFixture.editor(made, vault: vaultB)
        let a = try InkInjector(editor: editorA), b = try InkInjector(editor: editorB)
        defer { a.close(); b.close() }
        #expect(await a.ready())
        #expect(await b.ready())

        /// Saves on `from`, syncs, merges on `to`; checks both copies and both canvases.
        func saveAndSync(_ step: String, from: InkInjector, to: InkInjector, clockTo: DeviceClock, vaultTo: Vault,
                         expect count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            await from.editor.flush()
            try InkFixture.sync(made.url, urlB)
            let echoBefore = try NoteEditorTests.myDeltas(vaultTo, clockTo, note: made.note).count
            _ = try await to.editor.mergeRevisions(vault: vaultTo, clock: clockTo, coordinated: false, verify: nil)
            await to.editor.flush()
            #expect(try NoteEditorTests.myDeltas(vaultTo, clockTo, note: made.note).count == echoBefore,
                    "\(step): the merge writes nothing", sourceLocation: sourceLocation)
            for (name, vault) in [("A", made.vault), ("B", vaultB)] {
                let disk = try Self.onDisk(vault, made.note, page: made.page)
                #expect(disk.live.count == count, "\(step): copy \(name) has \(disk.live.count) strokes",
                        sourceLocation: sourceLocation)
                #expect(disk.duplicates == 0, "\(step): copy \(name) has duplicates", sourceLocation: sourceLocation)
            }
            for (name, i) in [("A", a), ("B", b)] {
                #expect(i.editor.liveStrokes(of: made.page).count == count, "\(step): editor \(name)", sourceLocation: sourceLocation)
                #expect(i.strokes.count == count, "\(step): canvas \(name) shows \(i.strokes.count)", sourceLocation: sourceLocation)
            }
        }

        a.draw([TS.stroke(x: 100, y: 200, color: Self.ink)])
        try await saveAndSync("draw", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        let drawn = try #require(a.strokes.first).id
        a.lassoMove([drawn], dx: 40, dy: 25)
        try await saveAndSync("lasso move", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        a.resize([try #require(a.strokes.first).id], scale: 1.6)
        try await saveAndSync("resize", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        a.recolor([try #require(a.strokes.first).id], .systemRed)
        try await saveAndSync("recolor", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        let recolored = try #require(Self.onDisk(made.vault, made.note, page: made.page).live.first)
        a.performUndo()
        try await saveAndSync("undo", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        #expect(try Self.onDisk(vaultB, made.note, page: made.page).live.first?.ink.color != recolored.ink.color)
        a.performRedo()
        try await saveAndSync("redo", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 1)
        #expect(try Self.onDisk(vaultB, made.note, page: made.page).live.first?.ink.color == recolored.ink.color)

        // B edits the stroke it received; A takes it.
        b.lassoMove([try #require(b.strokes.first).id], dx: -30, dy: 60)
        try await saveAndSync("move on B", from: b, to: a, clockTo: clockA, vaultTo: made.vault, expect: 1)
        b.recolor([try #require(b.strokes.first).id], .systemBlue)
        try await saveAndSync("recolor on B", from: b, to: a, clockTo: clockA, vaultTo: made.vault, expect: 1)

        // A pixel erase across the stroke: two pieces of it, the stroke itself gone.
        let whole = try #require(Self.onDisk(made.vault, made.note, page: made.page).live.first)
        a.pixelErase(across: try #require(a.strokes.first).id)
        try await saveAndSync("pixel erase", from: a, to: b, clockTo: clockB, vaultTo: vaultB, expect: 2)
        let pieces = try Self.onDisk(vaultB, made.note, page: made.page).live
        #expect(pieces.allSatisfy { $0.parent == whole.id && $0.id != whole.id })

        // Reopened from either copy: the same two pieces.
        await editorA.close()
        await editorB.close()
        for vault in [made.vault, vaultB] {
            let (again, _) = try await InkFixture.editor(made, vault: vault)
            #expect(Set(again.liveStrokes(of: made.page).map(\.id)) == Set(pieces.map(\.id)))
            await again.close()
        }
    }

    // MARK: - c11, c52 on the dense page

    /// c11 + c52: a page of 20 000 strokes. Each pen-up's main-thread work (the canvas delegate:
    /// ledger update and extent) stays within a generous bound (the whole-drawing path before P17
    /// took ~245 ms per change on the simulator; the ledger's ~26 ms) and never asks PencilKit for
    /// `drawing.bounds`. Undo, redo, a lasso move, a recolor and a pixel erase in the middle of the
    /// page are all kept after the autosave and a reopen, with no duplicate.
    @Test func c11PenUpAndEditsOnADensePageAreQuickAndAllKept() async throws {
        let made = try InkFixture.denseNote()
        let (editor, _) = try await InkFixture.editor(made, debounce: .milliseconds(300))
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready(timeout: .seconds(120)))
        let n = InkFixture.denseStrokes
        #expect(i.strokes.count == n)
        let penY = (Double(i.strokes[n / 2].renderBounds.midY) + 7).rounded()   // between rows, mid-page
        let measuredBefore = i.host.boundsMeasured
        let timesBefore = i.changeTimes.count

        // Ten pen-ups in the middle of the page, one at a time as a writer would.
        for k in 0..<10 {
            i.draw([TS.stroke(x: 60 + Double(k) * 40, y: penY, n: 30, color: Self.ink)])
        }
        let penUps = Array(i.changeTimes.dropFirst(timesBefore))
        #expect(penUps.count == 10)
        let median = penUps.sorted()[penUps.count / 2]
        print("PERF-REPORT c11 pen-up on \(n) strokes: median \(String(format: "%.1f", median)) ms, max \(String(format: "%.1f", penUps.max() ?? 0)) ms")
        #expect(median < 150, "pen-up took \(median) ms on the main thread")
        #expect(i.host.boundsMeasured == measuredBefore, "a pen-up measured drawing.bounds")

        // Edits in the middle of the page.
        i.performUndo()                      // the last pen-up goes
        i.performRedo()                      // and comes back
        let middle = i.strokes[n / 2].id, other = i.strokes[n / 2 + n / 40].id, cut = i.strokes[n / 2 + n / 20].id
        i.lassoMove([middle], dx: 0, dy: 300)
        i.recolor([other], .systemGreen)
        i.pixelErase(across: cut, keepID: false)
        #expect(i.host.boundsMeasured == measuredBefore, "an edit measured drawing.bounds")
        let editTimes = Array(i.changeTimes.dropFirst(timesBefore + 10))
        #expect(editTimes.count == 5)
        #expect((editTimes.max() ?? 0) < 1_000, "edits took \(editTimes) ms")
        #expect(i.strokes.count == n + 10 + 1)   // + 10 drawn, the cut stroke now two masked pieces
        // Each visible range of a masked piece is stored as a stroke of its own (StrokeConversion): a
        // looping stroke cut once can leave more than two.
        let ranges = i.strokes.filter { $0.mask != nil }.map(\.maskedPathRanges.count).reduce(0, +)
        #expect(ranges >= 2)
        let shown = n + 10 - 1 + ranges
        #expect(editor.liveStrokes(of: made.page).count == shown)

        // The autosave, then a reopen: everything kept, nothing doubled.
        #expect(await TS.waitUntil(timeout: .seconds(30)) { !editor.hasPendingChanges })
        await editor.close()
        let disk = try Self.onDisk(made.vault, made.note, page: made.page)
        #expect(disk.live.count == shown)
        #expect(disk.duplicates == 0)
        #expect(Set(disk.live.map(\.id)).count == shown)
        let (again, _) = try await InkFixture.editor(made)
        let reopened = again.liveStrokes(of: made.page)
        #expect(reopened.count == shown)
        #expect(reopened.filter { $0.parent == middle }.count == 1, "the moved stroke, once")
        #expect(reopened.filter { $0.parent == other && $0.ink.color != Self.ink }.count == 1, "the recolored stroke, once")
        #expect(reopened.filter { $0.parent == cut }.count == ranges, "the pieces of the erased stroke")
        #expect(!reopened.contains { [middle, other, cut].contains($0.id) })
        #expect(reopened.filter { $0.points.first?.y == penY }.count == 10, "every pen-up kept")
        await again.close()
    }

    /// c52: writing near the bottom of an infinite page grows it, and the canvas scrolls one screen
    /// past the new ink, with the extent from the editor's ledger (no `drawing.bounds` at pen-up);
    /// a pixel erase of the lowest stroke moves the ink's bottom up to the next stroke, and the
    /// scroll extent is again what the remaining ink and the (never shrinking) page give.
    @Test func c52InkExtentFollowsTheLedger() async throws {
        let made = try InkFixture.denseNote(strokes: 2_000)
        let (editor, _) = try await InkFixture.editor(made)
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready())
        let measured = i.host.boundsMeasured
        let heightBefore = editor.pageSize.height

        func expectedContentHeight() -> CGFloat {
            let z = i.host.canvas.zoomScale
            let viewport = Double(i.host.canvas.bounds.height / max(z, 0.0001))
            let bottom = i.drawing.bounds.isNull ? nil : Double(i.drawing.bounds.maxY)
            return CGFloat(PageExtent.scrollHeight(pageSize: editor.pageSize, inkMaxY: bottom, viewportHeight: viewport)) * z
        }

        // Ink just below the stored height of the page.
        let low = heightBefore - 20
        i.draw([TS.stroke(x: 80, y: low, n: 30, color: Self.ink)])
        i.show()   // SwiftUI's update with the grown page size
        #expect(editor.pageSize.height > heightBefore, "the page grew")
        #expect(editor.pageSize.height >= Double(i.drawing.bounds.maxY) + NoteEditor.growMargin)
        #expect(i.host.inkMaxY == Double(i.drawing.bounds.maxY))
        #expect(abs(i.host.canvas.contentSize.height - expectedContentHeight()) < 1)
        let viewport = i.host.canvas.bounds.height
        #expect(i.host.canvas.contentSize.height >= CGFloat(i.drawing.bounds.maxY) * i.host.canvas.zoomScale + viewport - 1,
                "one screen past the ink")
        #expect(i.host.boundsMeasured == measured)

        // Pixel-erase the lowest stroke: the bottom of the ink is the next stroke's.
        let lowest = try #require(i.strokes.max { $0.renderBounds.maxY < $1.renderBounds.maxY }).id
        i.pixelEraseWhole(lowest)
        let next = Double(i.drawing.bounds.maxY)
        #expect(next < low)
        #expect(i.host.inkMaxY == next)
        #expect(abs(i.host.canvas.contentSize.height - expectedContentHeight()) < 1)
        #expect(i.host.boundsMeasured == measured)
        await editor.close()
    }

    // MARK: - c12, c50: the object eraser

    /// The strokes a sweep along `path` touches, by the eraser's own hit test (the reference).
    static func touched(_ strokes: [PKStroke], path: [EraserPoint], radius: Double) -> Set<UUID> {
        var out = Set<UUID>()
        for s in strokes {
            let shape = StrokeHitShape(s)
            for (a, b) in zip(path, path.dropFirst()) where shape.intersects(sweepFrom: a, to: b, radius: radius) {
                out.insert(s.id)
                break
            }
        }
        return out
    }

    /// A zigzag across rows `y0`...`y1` of the dense page.
    static func zigzag(from y0: Double, to y1: Double) -> [EraserPoint] {
        stride(from: y0, through: y1, by: 6).enumerated().map { k, y in EraserPoint(x: k % 2 == 0 ? 30 : 590, y: y) }
    }

    /// c12: a sweep across dense ink removes every stroke it touched and nothing else, as one
    /// delta of removals; one Undo puts every one back. Touch-down stays quick on 20 000 strokes.
    @Test func c12ObjectEraserSweepRemovesEveryTouchedStrokeAndOneUndoRestores() async throws {
        let made = try InkFixture.denseNote()
        let (editor, clock) = try await InkFixture.editor(made)
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready(timeout: .seconds(120)))
        let radius = ObjectEraserSize.load()
        let midY = Double(i.strokes[InkFixture.denseStrokes / 2].renderBounds.midY)
        let path = Self.zigzag(from: midY, to: midY + 120)
        let all = i.strokes
        let expected = Self.touched(all, path: path, radius: radius)
        #expect(expected.count > 100)

        let start = DispatchTime.now().uptimeNanoseconds
        i.host.objectEraser.begin(at: path[0])
        let touchDown = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("PERF-REPORT c12 object-eraser touch-down on \(all.count) strokes: \(String(format: "%.1f", touchDown)) ms")
        #if !targetEnvironment(simulator)
        #expect(touchDown < 1_000)   // the simulator's PencilKit redraws in software (`InkFixture.denseStrokes`)
        #endif
        for p in path.dropFirst() { i.host.objectEraser.move(to: p) }
        i.eraserEnd(at: path[path.count - 1])

        #expect(Set(all.map(\.id)).subtracting(i.strokes.map(\.id)) == expected)
        #expect(i.strokes.count == all.count - expected.count)
        await editor.flush()
        var mine = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note)
        #expect(mine.count == 1)
        let removals = (mine.first ?? []).filter { if case .removeStroke = $0 { return true }; return false }
        #expect(Set(removals) == Set(expected.map { Op.removeStroke(page: made.page, strokeId: $0) }))
        #expect(removals.count == expected.count)

        // One Undo restores every stroke of the gesture.
        #expect(i.undoManager.canUndo)
        i.performUndo()
        #expect(i.strokes.count == all.count)
        await editor.flush()
        mine = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note)
        #expect(mine.count == 2)
        let disk = try Self.onDisk(made.vault, made.note, page: made.page)
        #expect(disk.live.count == all.count && disk.duplicates == 0)
        #expect(Set(disk.live.compactMap(\.parent)) == expected, "the erased strokes, back under new ids")
        #expect(!i.undoManager.canUndo)
        await editor.close()
    }

    /// A paged note of two pages with a row of strokes on each, for the mid-sweep checks.
    static func twoInkedPages() async throws -> (InkFixture.Made, NoteEditor, DeviceClock, second: UUID) {
        let made = try InkFixture.denseNote(strokes: 120)
        let state = TS.deviceStateURL()
        let second = Page(order: PageOrder.between(PageOrder.between(nil, nil), nil))
        var ink = SyntheticInk(seed: 4, options: .init(pointsPerStroke: 16, rowHeight: 20, top: 40))
        let ops: [Op] = [.addPage(second), .setMeta(.pageSize(.letter))]
            + ink.strokes(120).map { Op.addStroke(page: second.id, stroke: $0) }
        _ = try made.vault.apply(ops, to: made.note, deviceState: state, app: "fixture/1")
        let (editor, clock) = try await InkFixture.editor(made)
        return (made, editor, clock, second.id)
    }

    /// c12: a page switch in the middle of a sweep: the rest of the gesture erases nothing on the
    /// page now shown, and nothing is written onto it.
    @Test func c12APageSwitchMidSweepWritesNothingOnTheOtherPage() async throws {
        let (made, editor, clock, second) = try await Self.twoInkedPages()
        let i = try InkInjector(editor: editor, page: made.page)
        defer { i.close() }
        #expect(await i.ready())
        let path = Self.zigzag(from: 30, to: 90)
        i.host.objectEraser.begin(at: path[0])
        for p in path.prefix(4).dropFirst() { i.host.objectEraser.move(to: p) }
        let erasedBefore = 120 - i.strokes.count

        // The other page comes in under the Pencil (the strip, a page jump).
        i.coordinator.apply(editor: editor, pageID: second,
                            content: PageCanvasContent(paper: .blank, pageSize: editor.pageSize), to: i.host)
        #expect(await i.ready())
        for p in path.dropFirst(4) { i.host.objectEraser.move(to: p) }
        i.eraserEnd(at: path[path.count - 1])
        #expect(i.strokes.count == 120, "the second page keeps every stroke")
        await editor.flush()
        let ops = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note).joined()
        #expect(!ops.contains { if case .removeStroke(let p, _) = $0 { return p == second }; return false })
        #expect(try Self.onDisk(made.vault, made.note, page: second).live.count == 120)
        #expect(try Self.onDisk(made.vault, made.note, page: made.page).live.count == 120 - erasedBefore)
        await editor.close()
    }

    /// c12: a remote merge arriving in the middle of a sweep waits for the pen to lift (the merge
    /// never replaces a drawing under a gesture), then shows the other device's ink. The sweep
    /// removes exactly the strokes it touched of the page it began on, never the stroke that
    /// arrived, and nothing is written onto the other page, which the merge changed.
    @Test func c12ARemoteMergeMidSweepWaitsAndErasesOnlyWhatTheSweepTouched() async throws {
        let (made, editor, clock, second) = try await Self.twoInkedPages()
        let i = try InkInjector(editor: editor, page: made.page)
        defer { i.close() }
        #expect(await i.ready())
        let path = Self.zigzag(from: 30, to: 90)
        let before = i.strokes
        let expected = Self.touched(before, path: path, radius: ObjectEraserSize.load())
        i.host.objectEraser.begin(at: path[0])
        for p in path.prefix(4).dropFirst() { i.host.objectEraser.move(to: p) }
        try await Task.sleep(for: .milliseconds(100))   // a display frame passes

        // Another device adds a stroke right where the sweep is heading, and erases on page 2.
        let remote = TS.stroke(x: 300, y: 70, n: 30)
        let gone = try #require(Self.onDisk(made.vault, made.note, page: second).live.first).id
        try TS.writeAsAnotherDevice([.addStroke(page: made.page, stroke: remote), .removeStroke(page: second, strokeId: gone)],
                                    to: made.note, vault: made.url, key: made.key)
        let merge = Task { try await editor.mergeRevisions(vault: made.vault, clock: clock, coordinated: false, verify: nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!i.strokes.contains { $0.id == remote.id }, "no drawing replaced under the gesture")
        for p in path.dropFirst(4) { i.host.objectEraser.move(to: p) }
        i.eraserEnd(at: path[path.count - 1])
        #expect(try await merge.value == .merged(fromOtherDevice: true))
        #expect(i.strokes.contains { $0.id == remote.id }, "the merged stroke is shown once the pen lifts")
        #expect(Set(before.map(\.id)).subtracting(i.strokes.map(\.id)) == expected)
        await editor.flush()
        let ops = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note).joined()
        #expect(!ops.contains { if case .removeStroke(_, let s) = $0 { return s == remote.id }; return false })
        #expect(!ops.contains { if case .removeStroke(let p, _) = $0 { return p == second }; return false })
        #expect(!ops.contains { if case .addStroke(let p, _) = $0 { return p == second }; return false })
        #expect(try Self.onDisk(made.vault, made.note, page: second).live.count == 119)
        let first = try Self.onDisk(made.vault, made.note, page: made.page)
        #expect(first.live.contains { $0.id == remote.id })
        #expect(first.live.count == 120 - expected.count + 1 && first.duplicates == 0)
        await editor.close()
    }

    /// c50: one gesture that erases one stroke and crosses a second removes both, recorded as one
    /// delta, and one Undo restores both; then on a page whose count stays the same (erase one, draw
    /// one) the erase is still recorded (a removal, the new stroke no replacement of it) and one
    /// Undo per gesture restores it.
    @Test func c50EraseBookkeeping() async throws {
        let made = try InkFixture.denseNote(strokes: 0)
        let (editor, clock) = try await InkFixture.editor(made)
        let i = try InkInjector(editor: editor)
        defer { i.close() }
        #expect(await i.ready())
        i.draw([TS.stroke(x: 100, y: 100, color: Self.ink), TS.stroke(x: 100, y: 300, color: Self.ink),
                TS.stroke(x: 100, y: 500, color: Self.ink)])
        await editor.flush()
        let ids = i.strokes.map(\.id)
        let stored = editor.liveStrokes(of: made.page)
        let base = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note).count

        // One gesture: down on the first stroke, across the second, up between them and the third.
        #expect(i.objectErase([EraserPoint(x: 130, y: 100), EraserPoint(x: 130, y: 200), EraserPoint(x: 130, y: 320),
                               EraserPoint(x: 130, y: 400)]) == 2)
        #expect(i.strokes.map(\.id) == [ids[2]])
        await editor.flush()
        var mine = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note)
        #expect(mine.count == base + 1)
        #expect(Set(mine.last ?? []) == Set(stored.prefix(2).map { Op.removeStroke(page: made.page, strokeId: $0.id) }))
        i.performUndo()
        #expect(i.strokes.count == 3)
        await editor.flush()
        #expect(Set(try Self.onDisk(made.vault, made.note, page: made.page).live.compactMap(\.parent))
                == Set(stored.prefix(2).map(\.id)))

        // Erase one, draw one: the count stays 3, both are recorded.
        let before = editor.liveStrokes(of: made.page)
        let target = try #require(i.strokes.first)
        let b = target.renderBounds
        #expect(i.objectErase([EraserPoint(x: Double(b.midX), y: Double(b.midY))]) == 1)
        let erasedID = try #require(Set(before.map(\.id)).subtracting(editor.liveStrokes(of: made.page).map(\.id)).first)
        i.draw([TS.stroke(x: 300, y: 700, color: Self.ink)])
        #expect(i.strokes.count == 3)
        await editor.flush()
        mine = try NoteEditorTests.myDeltas(made.vault, clock, note: made.note)
        let last = mine.last ?? []
        let erased = try #require(before.first { $0.id == erasedID })
        #expect(last.contains(.removeStroke(page: made.page, strokeId: erased.id)))
        let added = last.compactMap { op -> Stroke? in if case .addStroke(_, let s) = op { return s }; return nil }
        #expect(added.count == 1 && added.first?.parent == nil, "the new stroke replaces nothing")

        // Undo the stroke, then the erase: one step each.
        i.performUndo()
        #expect(i.strokes.count == 2)
        i.performUndo()
        #expect(i.strokes.count == 3)
        await editor.flush()
        let disk = try Self.onDisk(made.vault, made.note, page: made.page)
        #expect(disk.live.count == 3 && disk.duplicates == 0)
        #expect(disk.live.contains { $0.parent == erased.id })
        #expect(!disk.live.contains { $0.id == added.first?.id })
        await editor.close()
    }
}

extension EraserPreferenceTests {
    /// c5: the eraser mode chosen on one note is the one the next note's canvas starts with, on
    /// the one-page canvas and on the paged stack, and in the next launch (a new tool state over the
    /// same defaults); it survives a round trip back.
    @Test func c5TheEraserChoiceIsKeptAcrossNotes() async throws {
        let defaults = DrawingToolboxTests.scratchDefaults()
        let toolbox = DrawingToolbox(defaults: defaults)

        // Note 1: pick the pixel eraser in the palette (as on the device), erase with it.
        let first = try InkFixture.denseNote(strokes: 10)
        let (e1, _) = try await InkFixture.editor(first)
        let one = try InkInjector(editor: e1, toolbox: toolbox)
        #expect(await one.ready())
        toolbox.setEraserMode(.pixel)
        #expect(one.host.select(drawingTool: .eraser))
        #expect(EraserPreference.isPixel(try #require(EraserPreference.eraserType(of: one.host.canvas.tool))))
        #expect(!one.host.objectEraserSelected, "PencilKit's pixel eraser, not the app's object eraser")
        one.pixelErase(across: try #require(one.strokes.first).id)
        #expect(EraserPreference.isPixel(EraserPreference.load(from: defaults)), "remembered")
        one.close()
        await e1.close()

        // Note 2, on the one-page canvas and on the paged stack: the eraser is the pixel one.
        let second = try InkFixture.denseNote(strokes: 10)
        let (e2, _) = try await InkFixture.editor(second)
        let two = try InkInjector(editor: e2, toolbox: toolbox)
        defer { two.close() }
        let stack = try await StackTS.editor(pages: 2)
        let (window, paged) = StackTS.stack(stack, toolbox: toolbox)
        defer { window.isHidden = true }
        let slot = try StackTS.slot(paged, stack, page: 0)
        for (canvas, what) in [(two.host, "the one-page canvas"), (slot.host, "the paged stack")] {
            #expect(EraserPreference.eraserType(of: canvas.canvas.tool).map(EraserPreference.isPixel) == true, "\(what)")
            #expect(!canvas.objectEraserSelected, "\(what)")
        }
        // The next launch.
        #expect(DrawingToolbox(defaults: defaults).state.eraserMode == .pixel)
        #expect(DrawingToolbox(defaults: defaults).state.tool == .eraser)

        // Back to the object eraser on note 2; note 1 opens with it again.
        toolbox.setEraserMode(.object)
        #expect(EraserPreference.load(from: defaults) == .vector)
        #expect(two.host.objectEraserSelected && slot.host.objectEraserSelected)
        let (e1b, _) = try await InkFixture.editor(first)
        let again = try InkInjector(editor: e1b, toolbox: toolbox)
        defer { again.close() }
        #expect(again.host.objectEraserSelected)
        #expect(DrawingToolbox(defaults: defaults).state.eraserMode == .object)
        await e1b.close()
        await e2.close()
    }
}
