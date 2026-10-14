import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// Merges after the first apply only the new revisions to the editor's
/// reduced note and compare only the pages they changed (`ReducedNote`,
/// `NoteEditor.applyMerged`); what the editor shows must stay what a fresh
/// read of the note shows, with nothing echoed.
@MainActor
struct RemoteMergeIncrementalTests {
    static let other = DeviceID("dddddddd")!

    /// A note of `pages` pages and `revisions` deltas of `perRevision`
    /// strokes each, written by `other` an hour ago, open in an editor with
    /// a ledger (a canvas) on its first `shown` pages.
    static func largeNote(pages: Int, revisions: Int, perRevision: Int, shown: Int, seed: UInt64)
        async throws -> (Vault, NoteEditor, DeviceClock, UUID, [UUID]) {
        let (vault, _) = try TS.unlockedFixture()
        let id = UUID()
        var rng = SeedRNG(seed)
        let pageIDs = (0..<pages).map { _ in UUID.seeded(&rng) }
        let start = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        func write(_ seq: Int, _ ops: [Op]) throws {
            let ms = start + Int64(seq) * 10
            try vault.write(Revision(noteId: id, device: other, seq: seq, hlc: HLC(millis: ms, counter: 0)!,
                                     wall: Date(timeIntervalSince1970: Double(ms) / 1000), app: "other-device/1",
                                     body: .delta(ops: ops)))
        }
        try write(1, [.setMeta(.title("Large"))]
                  + pageIDs.enumerated().map { .addPage(Page(id: $1, order: String(format: "p%03d", $0))) })
        for seq in 2...revisions {
            try write(seq, (0..<perRevision).map { _ in
                let s = TS.stroke(x: Double(rng.next() % 500), y: Double(rng.next() % 700), n: 4)
                return .addStroke(page: pageIDs[Int(rng.next() % UInt64(pages))], stroke: s)
            })
        }
        let (editor, clock) = try await NoteEditorTests.open(vault, note: id, debounce: .seconds(600))
        for page in pageIDs.prefix(shown) { _ = editor.drawing(for: page) }
        return (vault, editor, clock, id, pageIDs)
    }

    /// The editor shows exactly what a fresh read of the note gives.
    static func expectMatchesDisk(_ editor: NoteEditor, _ vault: Vault, _ id: UUID,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let disk = try vault.reconstruct(noteId: id)
        #expect(editor.pages.map(\.id) == disk.pages.map(\.id), sourceLocation: sourceLocation)
        #expect(editor.meta.title == disk.meta.title, sourceLocation: sourceLocation)
        for p in disk.pages {
            #expect(editor.liveStrokes(of: p.id).map(\.id) == p.strokes.map(\.id), sourceLocation: sourceLocation)
            #expect(editor.pages.first { $0.id == p.id }?.recognition == p.recognition, sourceLocation: sourceLocation)
            if let shown = editor.readyDrawing(for: p.id) {
                #expect(shown.strokes.count == p.strokes.count, sourceLocation: sourceLocation)
            }
        }
    }

    /// Measures one remote stroke on one page of a large note (500
    /// revisions, 100 pages, about 20 000 strokes, 5 pages on canvases):
    /// the first merge reduces everything (it has no reduced note yet),
    /// later ones only the new revision; the same merge with
    /// `incrementalMerges` off is the cost before.
    @Test func oneRemoteStrokeOnALargeNote() async throws {
        let (vault, editor, clock, id, pages) = try await Self.largeNote(pages: 100, revisions: 500, perRevision: 40,
                                                                         shown: 5, seed: 3)
        func remoteStroke(on page: UUID) throws {
            try vault.apply([.addStroke(page: page, stroke: TS.stroke(x: 10, y: 10, n: 4))], to: id,
                            deviceState: TS.deviceStateURL(), app: "other-device/1")
        }
        try remoteStroke(on: pages[2])
        #expect(try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
            == .merged(fromOtherDevice: true))
        let first = editor.lastMergeWork

        editor.incrementalMerges = false
        try remoteStroke(on: pages[2])
        #expect(try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
            == .merged(fromOtherDevice: true))
        let full = editor.lastMergeWork

        editor.incrementalMerges = true
        try remoteStroke(on: pages[2])
        #expect(try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
            == .merged(fromOtherDevice: true))
        let incremental = editor.lastMergeWork
        try Self.expectMatchesDisk(editor, vault, id)

        let strokes = editor.pages.reduce(0) { $0 + $1.strokes.count }
        let onPage = editor.liveStrokes(of: pages[2]).count
        func line(_ w: NoteEditor.MergeWork) -> String {
            "decoded \(w.decoded), reduced \(w.reduced), pages compared \(w.pagesCompared), strokes visited "
                + "\(w.strokesVisited), main actor \(w.applyTime) of which PKDrawing \(w.drawingTime)"
        }
        print("PERF-REPORT remote merge, \(strokes) strokes on \(pages.count) pages, one remote stroke on a shown page"
              + " of \(onPage): first merge: \(line(first)); full (before): \(line(full)); incremental (after): \(line(incremental))")
        #expect(full.decoded == 1 && incremental.decoded == 1)
        #expect(full.reduced >= 500)
        #expect(incremental.reduced == 1)
        #expect(full.pagesCompared == pages.count)
        #expect(incremental.pagesCompared == 1)
        #expect(incremental.strokesVisited <= 3 * onPage, "only the changed page")
        #expect(full.strokesVisited >= strokes)
        await editor.close()
        #expect(try NoteEditorTests.myDeltas(vault, clock, note: id).isEmpty, "no echo")
    }

    /// Random interleavings of remote writes (several devices, strokes,
    /// erasures, slices, recognition, titles, now and then a late revision
    /// or a page add that make the merge read in full) and local ink and
    /// erasures on canvases: after every merge the editor shows what a fresh
    /// read shows, and the canvases report nothing to save.
    @Test(arguments: [UInt64(11), 12, 13])
    func randomInterleavingsMatchAFreshRead(seed: UInt64) async throws {
        let (vault, editor, clock, id, pages) = try await Self.largeNote(pages: 6, revisions: 8, perRevision: 6,
                                                                         shown: 3, seed: seed)
        var rng = SeedRNG(seed)
        func pick<T>(_ a: [T]) -> T { a[Int(rng.next() % UInt64(a.count))] }
        let devices = (0..<3).map { _ in TS.deviceStateURL() }
        var lateSeq = 1_000
        var incremental = 0
        for step in 0..<40 {
            let roll = rng.next() % 100
            let page = pick(editor.pages.map(\.id))
            if roll < 25, editor.hasCanvas(page) {
                // Ink here: a stroke drawn, or one erased, on a canvas.
                var drawing = try #require(editor.readyDrawing(for: page))
                if rng.next() % 3 == 0, !drawing.strokes.isEmpty {
                    drawing.strokes.remove(at: Int(rng.next() % UInt64(drawing.strokes.count)))
                } else {
                    drawing.strokes.append(TS.canvasStroke(TS.stroke(x: Double(rng.next() % 400), y: 300, n: 5)))
                }
                editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
                continue
            }
            var ops: [Op] = []
            let live = try vault.reconstruct(noteId: id).pages.first { $0.id == page }?.strokes ?? []
            switch roll {
            case 25..<55: ops = [.addStroke(page: page, stroke: TS.stroke(x: Double(rng.next() % 400), y: 100, n: 5))]
            case 55..<65 where !live.isEmpty: ops = [.removeStroke(page: page, strokeId: pick(live).id)]
            case 65..<72 where !live.isEmpty:
                let victim = pick(live)
                ops = [.removeStroke(page: page, strokeId: victim.id)]
                var piece = TS.stroke(x: 5, y: 5, n: 4)
                piece.parent = victim.id
                ops.append(.addStroke(page: page, stroke: piece))
            case 72..<80: ops = [.setPageRecognition(pageId: page, recognition: Recognition(engine: "test-1", text: "r\(step)"))]
            case 80..<88: ops = [.setMeta(.title("T\(step)"))]
            case 88..<94:
                // A late revision: older than everything read, so the merge reads in full.
                lateSeq += 1
                try vault.write(Revision(noteId: id, device: DeviceID("eeeeeeee")!, seq: lateSeq,
                                         hlc: HLC(millis: 1_000 + Int64(step), counter: 0)!,
                                         wall: Date(timeIntervalSince1970: 1), app: "late-device/1",
                                         body: .delta(ops: [.addStroke(page: page, stroke: TS.stroke(x: 9, y: 9, n: 4))])))
            default:
                let edit = NoteOps.addPage(at: editor.pages.count, in: editor.pages)
                ops = edit.ops
            }
            if !ops.isEmpty {
                try vault.apply(ops, to: id, deviceState: pick(devices), app: "other-device/1")
            }
            _ = try await editor.mergeRevisions(vault: vault, clock: clock, coordinated: false, verify: nil)
            if editor.lastMergeWork.reduced < 5 { incremental += 1 }
            try Self.expectMatchesDisk(editor, vault, id)
            for p in pages where editor.readyDrawing(for: p) != nil {
                let drawing = try #require(editor.readyDrawing(for: p))
                #expect(editor.drawingDidChange(pageID: p, drawing: drawing, tool: nil).isEmpty, "nothing to save")
            }
        }
        #expect(incremental > 5, "the incremental path ran (\(incremental) merges)")
        await editor.close()
    }
}

private extension NoteEditor {
    /// Whether a canvas (a ledger) shows `page`.
    func hasCanvas(_ page: UUID) -> Bool { readyDrawing(for: page) != nil }
}

/// SplitMix64, so the generated notes are the same on every run.
struct SeedRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension UUID {
    static func seeded(_ rng: inout SeedRNG) -> UUID {
        let a = rng.next(), b = rng.next()
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: v >> (8 * i)) }
        return UUID(uuid: (byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
                           byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)))
    }
}
