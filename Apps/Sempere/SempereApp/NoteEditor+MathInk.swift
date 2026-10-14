import Foundation
import Sempere
import SempereRender
import UIKit

/// Ink picked with the math lasso, waiting in the equation sheet
/// (`MathEditorView` in conversion mode).
struct MathConversionRequest: Identifiable {
    let id = UUID()
    let page: UUID
    /// The strokes taken (`InkLasso.select`), in page order.
    let strokeIDs: [UUID]
    /// Those strokes, for the recogniser.
    let strokes: [Stroke]
    /// The canvas's undo manager, for one "Convert to Math" step.
    weak var undoManager: UndoManager?
}

/// "Convert to Math" on the open note (docs/attachments.md §14 G1 part 2):
/// a lasso picks strokes (`InkLasso`, the rule `sempere recognize-math`
/// uses), an on-device model reads them (`MathModels`, the sheet), the user
/// confirms the LaTeX, and ONE delta replaces the ink with a math item (or
/// adds it beside): the render's blob first, then the `addItem` with the
/// strokes' removal (`NoteOps.convertInk` decides the frame and checks the
/// strokes; the ledger writes the `removeStroke` ops, as for an erase).
extension NoteEditor {
    /// Starts picking ink: canvases draw a lasso instead of ink.
    func beginMathLasso() {
        guard !isReadOnly, !isShutDown else { return }
        mathLassoMessage = nil
        mathLassoActive = true
    }

    /// Stops picking ink (Cancel, or a tool picked).
    func endMathLasso() {
        mathLassoActive = false
        mathLassoMessage = nil
    }

    /// The strokes of page `pageID` a lasso through `loop` (page points)
    /// takes: live strokes (saved or not), markers left out (a highlight is
    /// not math).
    func mathSelection(pageID: UUID, loop: [CGPoint]) -> [Stroke] {
        let strokes = liveStrokes(of: pageID).filter { $0.ink.tool != .marker }
        let ids = Set(InkLasso.select(strokes, lasso: loop.map { InkLasso.Point(x: Double($0.x), y: Double($0.y)) }))
        return strokes.filter { ids.contains($0.id) }
    }

    /// A lasso ended on page `pageID`: the strokes it took go to the equation
    /// sheet (`mathConversion`); with none, the lasso stays on and says so.
    func mathLassoFinished(pageID: UUID, loop: [CGPoint], undoManager: UndoManager?) {
        guard mathLassoActive, !isReadOnly, !isShutDown else { return }
        let picked = mathSelection(pageID: pageID, loop: loop)
        guard !picked.isEmpty else {
            mathLassoMessage = String(localized: "No handwriting inside the loop. Circle the equation again.",
                                      comment: "Convert to Math: the lasso took no strokes")
            return
        }
        endMathLasso()
        mathConversion = MathConversionRequest(page: pageID, strokeIDs: picked.map(\.id), strokes: picked,
                                               undoManager: undoManager)
    }

    /// Converts the request's ink into `content`: typesets it (SwiftMath),
    /// writes the render, then in one main-actor turn takes the ink off the
    /// page (`replace`) and adds the item, saved as ONE delta. Returns the
    /// item and the ink taken (for undo).
    ///
    /// - Throws: `ItemError.notEditable` when the note closed or turned
    ///   read-only, `AttachmentOpsError.noSuchStrokes` when some of the ink
    ///   was erased meanwhile, typesetting and write errors.
    func convertInk(_ request: MathConversionRequest, to content: MathContent,
                    placement: MathPlacement) async throws -> (item: Item, ink: ConvertedInk?) {
        guard canEditItems else { throw ItemError.notEditable }
        // Fail before writing anything when the ink is gone already.
        try checkConversion(request, content: content, placement: placement)
        let (data, value) = try MathTypesetter.rendered(content)
        let ref = try await storeBlob(data, type: MathContent.renderType)
        var stored = value
        stored.render = ref
        // The note may have changed (or closed) while the blob was written.
        let conversion = try checkConversion(request, content: stored, placement: placement)
        var ink: ConvertedInk?
        if placement == .replace {
            guard let taken = takeInk(Set(conversion.removed), from: request.page) else { throw ItemError.notEditable }
            ink = taken
        }
        let edit = ItemEdit(ops: conversion.ops.filter { if case .addItem = $0 { return true } else { return false } },
                            page: conversion.page, added: [conversion.item.id])
        guard applyItemEdit(edit) else {
            if let ink { putInkBack(ink) }
            throw ItemError.notEditable
        }
        return (conversion.item, ink)
    }

    /// The conversion as the page is now (its live strokes).
    @discardableResult
    private func checkConversion(_ request: MathConversionRequest, content: MathContent,
                                 placement: MathPlacement) throws -> InkConversion {
        guard canEditItems, var page = pages.first(where: { $0.id == request.page }) else { throw ItemError.notEditable }
        page.strokes = liveStrokes(of: page.id)
        return try NoteOps.convertInk(request.strokeIDs, toMath: content, on: page, pageSize: pageSize, placement: placement)
    }
}

extension ItemActions {
    /// Registers the undo of a conversion: the item goes and the ink comes
    /// back, in one delta; redo converts again (the same render, no typesetting).
    func converted(_ item: Item, ink: ConvertedInk?, on page: UUID) {
        register(Self.convertName) { $0.unconvert(item, ink: ink, on: page) }
    }

    static var convertName: String {
        String(localized: "Convert to Math", comment: "Undo action name (Edit menu: Undo …)")
    }

    /// Undo of a conversion: the ink first (pending in the ledger), then the
    /// item's removal, which saves both as one delta.
    func unconvert(_ item: Item, ink: ConvertedInk?, on page: UUID) {
        let back = ink.flatMap { editor.putInkBack($0, keepUndo: true) }
        let gone = editor.removeItems([item.id], from: page)
        guard !gone.isEmpty else { return }
        register(Self.convertName) { actions in
            // Redo: the same ink (under the ids it has now) goes, the item comes back under a new id.
            var taken: ConvertedInk?
            if let back { taken = actions.editor.takeInk(Set(back), from: page, keepUndo: true) }
            guard let restored = actions.editor.restoreItems(gone, on: page).first else { return }
            actions.converted(restored, ink: taken, on: page)
        }
    }
}
