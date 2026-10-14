import Foundation
import Sempere
import PencilKit
import Testing
import UIKit
@testable import SempereApp

/// The canvas path of a drawing change (`StrokeLedger.update(_:tool:)`, which
/// fingerprints only the strokes that fail the cheap check) against the full
/// match (every canvas stroke fingerprinted, nothing trimmed), over random
/// sequences of the edits PencilKit makes: draw, paste a copy, erase, pixel
/// erase (masked pieces, some keeping the id), slice (`substroke`), lasso
/// move and recolour (id kept, sometimes reordered), undo and redo, with
/// saves and failed saves in between. Both ledgers must give the same live
/// strokes, removals, additions, parents and ops, up to the fresh ids each
/// one makes. Finding P17.
@MainActor
struct StrokeLedgerEditSequenceTests {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let page = UUID()

    /// A new canvas stroke. Few positions, dates and colours, so keys,
    /// families and path signatures collide often.
    static func drawn(_ rng: inout RNG) -> PKStroke {
        let color = Bool.random(using: &rng) ? Sempere.Color(r: 0x1A, g: 0x2B, b: 0x3C, a: 0xFF) : Sempere.Color(r: 200, g: 0, b: 0, a: 255)
        let s = TS.stroke(x: Double(Int.random(in: 0..<4, using: &rng)) * 40, y: Double(Int.random(in: 0..<3, using: &rng)) * 30,
                          n: [6, 12, 24].randomElement(using: &rng)!, color: color)
        return TS.canvasStroke(s, created: Date(timeIntervalSinceReferenceDate: Double(Int.random(in: 0..<3, using: &rng))))
    }

    /// Same content, a new `PKStroke.id` (a paste, or a piece PencilKit re-identified).
    static func copy(_ pk: PKStroke, mask: UIBezierPath?? = .none) -> PKStroke {
        PKStroke(ink: pk.ink, path: pk.path, transform: pk.transform, mask: mask ?? pk.mask, randomSeed: pk.randomSeed)
    }

    static func edit(_ canvas: inout [PKStroke], _ rng: inout RNG) {
        let i = canvas.isEmpty ? 0 : Int.random(in: 0..<canvas.count, using: &rng)
        switch Int.random(in: 0..<8, using: &rng) {
        case 0, 1:
            canvas.append(drawn(&rng))
        case 2 where !canvas.isEmpty:
            canvas.append(copy(canvas[i]))
        case 3 where !canvas.isEmpty:
            canvas.remove(at: i)
        case 4 where !canvas.isEmpty:
            // Pixel erase: one or two masked pieces; the first sometimes keeps the id.
            let b = canvas[i].renderBounds
            let left = UIBezierPath(rect: CGRect(x: b.minX - 5, y: b.minY - 5, width: b.width / 3 + 5, height: b.height + 10))
            let right = UIBezierPath(rect: CGRect(x: b.midX + 10, y: b.minY - 5, width: b.width, height: b.height + 10))
            var first = copy(canvas[i], mask: left)
            if Bool.random(using: &rng) { first.id = canvas[i].id }
            canvas.replaceSubrange(i...i, with: Bool.random(using: &rng) ? [first, copy(canvas[i], mask: right)] : [first])
        case 5 where !canvas.isEmpty && canvas[i].path.count > 3:
            // A slice that rewrites the path.
            let n = CGFloat(canvas[i].path.count - 1)
            canvas[i] = canvas[i].substroke(range: 0...(n / 2).rounded(.down))
        case 6 where !canvas.isEmpty:
            // Lasso move of a few strokes, ids kept; sometimes brought to the top.
            let picked = Array(Set((0..<Int.random(in: 1...3, using: &rng)).map { _ in Int.random(in: 0..<canvas.count, using: &rng) })).sorted()
            let dy = CGFloat(Int.random(in: 1...3, using: &rng)) * 10
            for k in picked { canvas[k].transform = canvas[k].transform.translatedBy(x: 0, y: dy) }
            if Bool.random(using: &rng) {
                let moved = picked.map { canvas[$0] }
                for k in picked.reversed() { canvas.remove(at: k) }
                canvas += moved
            }
        case 7 where !canvas.isEmpty:
            canvas[i].ink = PKInk(canvas[i].ink.inkType, color: Bool.random(using: &rng) ? .red : .blue)
        default:
            canvas.append(drawn(&rng))
        }
    }

    /// Maps the canvas-path ledger's ids to the full match's: stored ids map
    /// to themselves; a fresh id is paired with the other ledger's fresh id
    /// at the same place in the change.
    struct IDMap {
        var map: [UUID: UUID] = [:]

        func callAsFunction(_ id: UUID?) -> UUID? { id.map { map[$0] ?? $0 } }

        mutating func pair(_ fast: StrokeLedger.Change, _ full: StrokeLedger.Change) {
            #expect(fast.added.count == full.added.count)
            for (a, b) in zip(fast.added, full.added) where map[a.id] == nil && a.id != b.id {
                map[a.id] = b.id
            }
        }

        func same(_ a: [Stroke], _ b: [Stroke]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { x, y in
                self(x.id) == y.id && self(x.parent) == y.parent && x.points == y.points && x.ink == y.ink
                    && x.transform == y.transform && x.rec == y.rec
            }
        }

        func same(_ a: [Op], _ b: [Op]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { x, y in
                switch (x, y) {
                case let (.removeStroke(_, i), .removeStroke(_, j)): return self(i) == j
                case let (.addStroke(_, s), .addStroke(_, t)): return same([s], [t])
                default: return false
                }
            }
        }
    }

    @Test func randomEditsGiveTheFullMatchResult() throws {
        var rng = RNG(state: 0x5E3_17)
        var sequences = 0, changes = 0, trimmed = 0
        for _ in 0..<150 {
            sequences += 1
            let stored = (0..<Int.random(in: 0...10, using: &rng)).map { _ in TS.stroke(x: Double(Int.random(in: 0..<4, using: &rng)) * 40) }
            var canvas = PKDrawing(strokes: stored.map(StrokeConversion.pkStroke)).strokes
            let infos = canvas.map(CanvasStrokeInfo.init)
            var fast = try #require(StrokeLedger(stored: stored, infos: infos))
            var full = try #require(StrokeLedger(stored: stored, infos: infos))
            var ids = IDMap()
            var undo: [[PKStroke]] = [], redo: [[PKStroke]] = []
            var saves: [(StrokeLedger.Save, StrokeLedger.Save)] = []
            for _ in 0..<25 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0 where !undo.isEmpty:
                    redo.append(canvas)
                    canvas = undo.removeLast()
                case 1 where !redo.isEmpty:
                    undo.append(canvas)
                    canvas = redo.removeLast()
                case 2:
                    let a = fast.beginSave(page: Self.page), b = full.beginSave(page: Self.page)
                    #expect((a == nil) == (b == nil))
                    if let a, let b {
                        #expect(ids.same(a.ops, b.ops))
                        saves.append((a, b))
                    }
                    continue
                case 3 where !saves.isEmpty:
                    let (a, b) = saves.removeLast()
                    fast.saveFailed(a)
                    full.saveFailed(b)
                    continue
                default:
                    undo.append(canvas)
                    redo = []
                    for _ in 0..<Int.random(in: 1...3, using: &rng) { Self.edit(&canvas, &rng) }
                }
                // Through a drawing, as the canvas hands them over.
                let shown = PKDrawing(strokes: canvas).strokes
                var fingerprinted = 0
                let a = fast.update(count: shown.count, unchanged: { i, _, info in info.isUnchanged(shown[i]) },
                                    item: { fingerprinted += 1; return StrokeLedger.item(for: shown[$0], inking: nil) })
                let b = full.update(count: shown.count, unchanged: { _, _, _ in false },
                                    item: { StrokeLedger.item(for: shown[$0], inking: nil) })
                changes += 1
                trimmed += shown.count - fingerprinted
                ids.pair(a, b)
                #expect(ids.same(a.removed, b.removed))
                #expect(ids.same(a.added, b.added))
                #expect(ids.same(fast.live, full.live))
                #expect(fast.hasPending == full.hasPending)
            }
        }
        // The fast path did trim: most strokes of most changes were not fingerprinted.
        #expect(trimmed > changes)
        print("StrokeLedgerEditSequenceTests: \(sequences) sequences, \(changes) changes, \(trimmed) strokes not fingerprinted")
    }
}

/// `CanvasStrokeInfo.init(_: PKStroke)` writes its arrays without
/// temporaries: the same fingerprint as the former build (kept here as the
/// reference), and `StrokeLedger.inkBounds` is the drawing's bounds.
@MainActor
struct CanvasStrokeInfoBuildTests {
    /// The fingerprint as built before P17 (arrays concatenated, a set of indices).
    static func reference(_ pk: PKStroke) -> CanvasStrokeInfo {
        let path = pk.path
        let n = path.count
        let color = Sempere.Color(pk.ink.color)
        let t = pk.transform
        let ink = pk.ink.inkType.rawValue
        var family: [Double] = [Double(color.r), Double(color.g), Double(color.b), Double(color.a)]
        family += [Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)]
        family.append(path.creationDate.timeIntervalSinceReferenceDate)
        var signature: [Double] = [Double(n)]
        var key = family
        key.append(Double(n))
        key.append(Double(pk.randomSeed))
        if n > 0 {
            for i in Set([0, n / 3, n / 2, (2 * n) / 3, n - 1]).sorted() {
                let p = path[i]
                key += [Double(p.location.x), Double(p.location.y), Double(p.size.width), p.timeOffset, Double(p.force)]
            }
            let first = path[0].location, last = path[n - 1].location
            signature += [Double(first.x), Double(first.y), Double(last.x), Double(last.y)]
        }
        if pk.mask != nil {
            key.append(-1)
            for r in pk.maskedPathRanges { key += [Double(r.lowerBound), Double(r.upperBound)] }
        }
        let b = pk.renderBounds
        return CanvasStrokeInfo(key: .init(ink: ink, values: key), family: .init(ink: ink, values: family),
                                pathSignature: signature,
                                bounds: .init(minX: Double(b.minX), minY: Double(b.minY), maxX: Double(b.maxX), maxY: Double(b.maxY)),
                                canvasID: pk.id)
    }

    @Test func sampledIndicesAreTheSortedSet() {
        for n in 0..<400 {
            let expected = n > 0 ? Set([0, n / 3, n / 2, (2 * n) / 3, n - 1]).sorted() : []
            #expect(CanvasStrokeInfo.sampled(n) == expected, "n = \(n)")
            #expect(CanvasStrokeInfo.sampledCount(n) == expected.count)
        }
    }

    @Test func fingerprintsAreTheReferenceAndInkBoundsTheDrawingBounds() throws {
        var rng = StrokeLedgerEditSequenceTests.RNG(state: 0xB0_0D5)
        for _ in 0..<60 {
            var canvas: [PKStroke] = []
            for _ in 0..<Int.random(in: 0...6, using: &rng) {
                var pk = TS.canvasStroke(TS.stroke(x: Double(Int.random(in: 0..<300, using: &rng)), y: Double(Int.random(in: 0..<900, using: &rng)),
                                                   n: [1, 2, 3, 7, 24].randomElement(using: &rng)!))
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    let b = pk.renderBounds
                    pk.mask = UIBezierPath(rect: CGRect(x: b.minX, y: b.minY - 5, width: b.width / 2, height: b.height + 10))
                case 1: pk.mask = UIBezierPath(rect: CGRect(x: -900, y: -900, width: 1, height: 1))   // fully masked
                case 2: pk.transform = CGAffineTransform(translationX: 3, y: 40).scaledBy(x: 1.5, y: 0.5)
                default: break
                }
                canvas.append(pk)
            }
            let drawing = PKDrawing(strokes: canvas)
            let shown = drawing.strokes
            let infos = shown.map(CanvasStrokeInfo.init)
            #expect(infos == shown.map(Self.reference))
            var ledger = StrokeLedger(stored: [], info: CanvasStrokeInfo.init(stored:))
            ledger.update(shown, tool: nil)
            let bounds = drawing.bounds
            if bounds.isNull {
                #expect(ledger.inkBounds == nil)
            } else {
                let u = try #require(ledger.inkBounds)
                #expect(u == .init(minX: Double(bounds.minX), minY: Double(bounds.minY), maxX: Double(bounds.maxX), maxY: Double(bounds.maxY)))
            }
        }
    }

    /// The editor grows an infinite page from the ledger's bounds exactly as
    /// it did from `drawing.bounds`, and hands the canvas those bounds once.
    @Test func theEditorMeasuresInkFromTheLedger() async throws {
        let (vault, _) = try TS.unlockedFixture()
        let note = UUID()
        let clock = try DeviceClock(url: TS.deviceStateURL())
        let size = PageSize(width: 612, height: 800, infinite: true)
        try await NoteWriter(vault: vault, noteID: note, clock: clock, nextSeq: 1)
            .write([.addPage(Page(order: PageOrder.between(nil, nil))), .setMeta(.pageSize(size))])
        let editor = try await NoteEditor.open(vault: vault, noteID: note, clock: clock, debounce: .seconds(60))
        let page = try #require(editor.currentPage).id
        var drawing = editor.drawing(for: page)
        for y in [100.0, 700, 1300] {
            var pk = TS.canvasStroke(TS.stroke(x: 30, y: y))
            pk.transform = CGAffineTransform(translationX: 0, y: 11.3)
            drawing.strokes.append(pk)
            let expected = drawing.bounds
            let before = editor.pageSize
            editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
            #expect(editor.takeMeasuredInk(of: page) == expected)
            #expect(editor.takeMeasuredInk(of: page) == nil, "once")
            var grown = before
            if Double(expected.maxY) > before.height - NoteEditor.growMargin {
                grown.height = (Double(expected.maxY) + NoteEditor.growStep).rounded(.up)
            }
            #expect(editor.pageSize == grown)
        }
        drawing.strokes = []
        editor.drawingDidChange(pageID: page, drawing: drawing, tool: nil)
        #expect(editor.takeMeasuredInk(of: page)?.isNull == true)
    }
}
