import Foundation
import Sempere

// MARK: - Ink taken off a page and put back (the app's "Convert to Math", `NoteEditor+MathInk.swift`)

/// Canvas strokes a conversion took off a page, as the ledger held them:
/// what undo puts back. Immutable; held by undo closures (like the eraser's
/// `DrawingBox`), hence `@unchecked Sendable`.
public final class TakenInk<Canvas: NoteCanvas>: @unchecked Sendable {
    public let page: UUID
    /// The ledger entries removed: fingerprints and stored strokes.
    public let entries: [StrokeLedger.Entry]
    /// The canvas strokes they were shown as.
    public let canvasStrokes: [Canvas.CanvasStroke]

    public init(page: UUID, entries: [StrokeLedger.Entry], canvasStrokes: [Canvas.CanvasStroke]) {
        self.page = page; self.entries = entries; self.canvasStrokes = canvasStrokes
    }

    /// Every stored stroke taken.
    public var strokes: [Stroke] { entries.flatMap(\.strokes) }
}

extension NoteEditorModel {
    /// The page's ledger and the drawing its canvases show, one canvas stroke
    /// per ledger entry (re-converted from the live strokes when they are not).
    func alignedInk(_ pageID: UUID) -> (StrokeLedger, [Canvas.CanvasStroke])? {
        if ledgers[pageID] == nil || canvasDrawings[pageID].map({ Canvas.strokes(of: $0).count }) != ledgers[pageID]?.entries.count {
            _ = drawing(for: pageID)
        }
        guard let l = ledgers[pageID], let shown = canvasDrawings[pageID].map(Canvas.strokes(of:)),
              shown.count == l.entries.count else {
            return nil
        }
        return (l, shown)
    }

    /// Takes every canvas stroke holding one of `ids` off page `pageID`, as an
    /// erase would: the ledger retires them, so their `removeStroke` ops go
    /// into the next save (with whatever else is pending: one delta), and the
    /// canvases showing the page show the rest in this main-actor turn
    /// (`RemoteInkView.reloadInk`, which also clears the canvas's own undo
    /// steps). Nil when nothing was taken.
    public func takeInk(_ ids: Set<UUID>, from pageID: UUID, keepUndo: Bool = false) -> TakenInk<Canvas>? {
        guard !isReadOnly, !isShutDown, !ids.isEmpty, let (ledger, shown) = alignedInk(pageID) else { return nil }
        var l = ledger
        var keep: [StrokeLedger.Item] = []
        var kept: [Canvas.CanvasStroke] = []
        var taken: [StrokeLedger.Entry] = []
        var takenCanvas: [Canvas.CanvasStroke] = []
        for (i, e) in l.entries.enumerated() {
            if e.strokes.contains(where: { ids.contains($0.id) }) {
                taken.append(e)
                takenCanvas.append(shown[i])
            } else {
                let strokes = e.strokes
                keep.append(StrokeLedger.Item(info: e.info, make: { strokes }))
                kept.append(shown[i])
            }
        }
        guard !taken.isEmpty else { return nil }
        let change = l.update(keep)
        ledgers[pageID] = l
        showChangedInk(Canvas.drawing(of: kept), change: change, on: pageID, keepUndo: keepUndo)
        return TakenInk(page: pageID, entries: taken, canvasStrokes: takenCanvas)
    }

    /// Puts ink `takeInk` took back on its page, above the rest (undo). The
    /// ledger revives the strokes: their own ids while the removal is not
    /// saved, new ids with `parent` once it is (format.md §5.2). Returns
    /// the ids the strokes have now; nil when the page is gone or the note
    /// cannot be edited.
    @discardableResult
    public func putInkBack(_ ink: TakenInk<Canvas>, keepUndo: Bool = false) -> [UUID]? {
        let pageID = ink.page
        guard !isReadOnly, !isShutDown, pages.contains(where: { $0.id == pageID }),
              let (ledger, shown) = alignedInk(pageID) else { return nil }
        var l = ledger
        var items = l.entries.map { e -> StrokeLedger.Item in
            let strokes = e.strokes
            return StrokeLedger.Item(info: e.info, make: { strokes })
        }
        for e in ink.entries {
            let strokes = e.strokes
            items.append(StrokeLedger.Item(info: e.info, make: { strokes }))
        }
        let change = l.update(items)
        ledgers[pageID] = l
        let drawing = Canvas.drawing(of: shown + ink.canvasStrokes)
        showChangedInk(drawing, change: change, on: pageID, keepUndo: keepUndo)
        return l.entries.suffix(ink.entries.count).flatMap(\.strokes).map(\.id)
    }

    /// The page's ink changed outside its canvas: the drawing its canvases
    /// show, saved like a canvas change (dirty, recognized again).
    func showChangedInk(_ drawing: Canvas.Drawing, change: StrokeLedger.Change, on pageID: UUID, keepUndo: Bool) {
        canvasDrawings[pageID] = drawing
        if !change.isEmpty {
            inkRevisions[pageID, default: 0] &+= 1
            dirtyPages.insert(pageID)
            touchedPages.insert(pageID)
            scheduleRecognition()
        }
        reloadKeepsUndo = keepUndo
        defer { reloadKeepsUndo = false }
        for view in inkViews.compactMap(\.view) where view.shownPageID == pageID { view.reloadInk(from: self) }
        inkViews.removeAll { $0.view == nil }
    }
}
