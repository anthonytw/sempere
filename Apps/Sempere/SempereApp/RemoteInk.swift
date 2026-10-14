import Foundation

/// A canvas that shows a page of a note's ink (`PageCanvasView.Coordinator`,
/// one per canvas, in the one-page view and in the paged stack). The editor
/// holds them weakly (`NoteEditor.attachInkView`) so that a merge of
/// revisions written elsewhere (`NoteEditor.mergeRevisions`) updates every
/// canvas in the same main-actor turn as the page's `StrokeLedger`: a canvas
/// never reports a drawing the ledger does not know, which it would take as
/// the user's erase or stroke and write back (an echo).
@MainActor
protocol RemoteInkView: AnyObject {
    /// The page whose ink this canvas shows; nil for a spare canvas.
    var shownPageID: UUID? { get }
    /// True in the middle of a stroke or an object-eraser gesture: the
    /// drawing must not be replaced until it ends.
    var isUsingInk: Bool { get }
    /// Shows `editor`'s drawing of the page again (`NoteEditor.readyDrawing`),
    /// keeping scroll and zoom; it is not a change of the user's.
    func reloadInk(from editor: NoteEditor)
}

/// A weak reference to a `RemoteInkView`.
@MainActor
struct WeakInkView {
    weak var view: (any RemoteInkView)?
}
