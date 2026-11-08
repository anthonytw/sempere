import Foundation
import Sempere

/// The canvas a `NoteEditor` shows its pages on, and the app glue it needs: the drawing type and how stored strokes
/// become it, how a canvas drawing updates a page's `StrokeLedger`, and the few platform hooks of the editor's
/// workflows (recording, the part of a page on screen, text layout). The app's is `PencilCanvas` (PencilKit: a
/// `PKDrawing` of `PKStroke`s); the package's tests use a canvas of stored strokes.
///
/// The editor holds the drawing each page's canvas shows next to the page's ledger, one canvas stroke per ledger
/// entry, and changes both in the same main-actor turn (a merge, the end of a cached open, ink taken off a page):
/// that is why the canvas is a type parameter of the editor rather than a service it calls.
///
/// The static conversion functions run off the main actor; the hooks run on it.
public protocol NoteCanvas: SendableMetatype {
    /// What one canvas shows: its strokes in order (`strokes(of:)`, `drawing(of:)`).
    associatedtype Drawing
    /// One stroke of a `Drawing`.
    associatedtype CanvasStroke
    /// The tool a drawing change was made with (new strokes record its width).
    associatedtype Tool
    /// The app's own state for one editor (its canvas target, the recording being made, …). Made with the
    /// editor (`makeGlue`) and held for as long as it.
    associatedtype Glue: AnyObject

    /// A drawing with no strokes.
    static var emptyDrawing: Drawing { get }
    /// The strokes of `drawing`, in order.
    static func strokes(of drawing: Drawing) -> [CanvasStroke]
    /// A drawing of `strokes`, in order.
    static func drawing(of strokes: [CanvasStroke]) -> Drawing
    /// The canvas stroke a stored stroke is shown as.
    static func canvasStroke(_ stroke: Stroke) -> CanvasStroke
    /// The ledger's fingerprint of a canvas stroke (`StrokeLedger`).
    static func info(of stroke: CanvasStroke) -> CanvasStrokeInfo
    /// `strokes` converted, one canvas stroke each in order. With `visible` (page points), a page with many
    /// strokes may hand the ones reaching into it to `visibleFirst` first, as a drawing of their own.
    static func convert(_ strokes: [Stroke], visible: CGRect?, visibleFirst: ((Drawing) -> Void)?) -> Drawing
    /// A drawing as the drawing cache stores it (`DrawingCache`).
    static func encode(_ drawing: Drawing) -> Data
    static func decode(_ data: Data) -> Drawing?
    /// Whether `drawing` is, stroke by stroke, what `convert` makes of `strokes` (a cached drawing is checked
    /// against the note as read before it is kept).
    static func matches(_ drawing: Drawing, _ strokes: [Stroke]) -> Bool
    /// Brings `ledger` up to the canvas's `drawing` (a pen-up, an erase, an undo), made with `tool`; `stamp`
    /// links new strokes to the recording running (format.md §8.3.3).
    static func update(_ ledger: inout StrokeLedger, to drawing: Drawing, tool: Tool?,
                       stamp: (@Sendable (Date) -> RecordingLink?)?) -> StrokeLedger.Change

    /// A text box laid out again at a new frame (its line breaks and height), as the canvas draws it.
    static func relayout(_ content: TextContent, frame: Rect) -> (content: TextContent, frame: Rect)
    /// Where a search's words fall inside a text box, as the canvas lays it out.
    static var textBoxMatcher: TextBoxMatcher { get }

    /// The app's state for a new editor.
    @MainActor static func makeGlue() -> Glue
    /// What stamps ink and items placed now with the recording running in `editor`; nil when none runs.
    @MainActor static func recordingStamp(of editor: NoteEditorModel<Self>) -> (@Sendable (Date) -> RecordingLink?)?
    /// The part of page `page` on screen (page points), else of the page on screen; nil when not known.
    @MainActor static func visibleRect(ofPage page: UUID, in editor: NoteEditorModel<Self>) -> CGRect?
    /// `editor` closes (`NoteEditor.close`): a recording in progress is saved into it first, playback stops.
    @MainActor static func editorWillClose(_ editor: NoteEditorModel<Self>) async
    /// Recording `id` is about to be removed from `editor` (its playback stops).
    @MainActor static func recordingWillBeRemoved(_ id: UUID, in editor: NoteEditorModel<Self>)
    /// A recording change failed (`NoteEditor.renameRecording`, `removeRecording`): the app shows it.
    @MainActor static func recordingFailed(_ failure: RecordingChangeFailure, in editor: NoteEditorModel<Self>)
}

/// A page's canvas drawing, ready to show, with the ledger fingerprint of each of its strokes (one canvas
/// stroke per stored stroke, in stored order). Built off the main actor; immutable once built.
public struct PreparedInk<Canvas: NoteCanvas>: @unchecked Sendable {
    public let drawing: Canvas.Drawing
    public let infos: [CanvasStrokeInfo]

    public init(drawing: Canvas.Drawing) {
        self.drawing = drawing
        infos = Canvas.strokes(of: drawing).map(Canvas.info(of:))
    }
}

/// A canvas value handed between actors as it is (canvas drawings are immutable once built).
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A canvas that shows a page of a note's ink (the app's `PageCanvasView.Coordinator`, one per canvas, in the
/// one-page view and in the paged stack). The editor holds them weakly (`NoteEditor.attachInkView`) so that a
/// merge of revisions written elsewhere (`NoteEditor.mergeRevisions`) updates every canvas in the same main-actor
/// turn as the page's `StrokeLedger`: a canvas never reports a drawing the ledger does not know, which it would
/// take as the user's erase or stroke and write back (an echo).
@MainActor
public protocol RemoteInkView<Canvas>: AnyObject {
    associatedtype Canvas: NoteCanvas
    /// The page whose ink this canvas shows; nil for a spare canvas.
    var shownPageID: UUID? { get }
    /// True in the middle of a stroke or an object-eraser gesture: the drawing must not be replaced until it ends.
    var isUsingInk: Bool { get }
    /// Shows `editor`'s drawing of the page again (`NoteEditor.readyDrawing`), keeping scroll and zoom; it is
    /// not a change of the user's.
    func reloadInk(from editor: NoteEditorModel<Canvas>)
}

/// A weak reference to a `RemoteInkView`.
@MainActor
struct WeakInkView<Canvas: NoteCanvas> {
    weak var view: (any RemoteInkView<Canvas>)?
}

/// Why a note cannot be edited (`NoteEditor.readOnly`). The app words it.
public enum NoteReadOnly: Equatable, Sendable {
    /// Opened without a writer, for no other reason given.
    case noWriter
    /// An earlier version shown from Version History.
    case preview
    /// The note is in Recently Deleted.
    case deleted
    /// Revisions of the note could not be read (their count).
    case unreadableRevisions(Int)
    /// A newer version of Sempere wrote content in this note (`NewerContent.summary`, format.md §7.4).
    case newerVersion(summary: String)
    /// The vault is read-only for this version (format.md §7.3).
    case vault(ReadOnlyReasons)
    /// The vault was opened with its recovery key.
    case recoveryKey
    /// The vault's device list does not check on this device (design §4.3).
    case deviceList(ListProblem)
    /// The background read of an editor opened from the drawing cache failed (the error's description).
    case loadFailed(String)
}

/// A recognition pass that failed (`NoteEditor.recognitionFailure`): the error's description.
public enum RecognitionPassFailure: Equatable, Sendable {
    /// A page could not be read.
    case read(String)
    /// What was read could not be saved.
    case save(String)
}

/// A recording change that failed (`NoteCanvas.recordingFailed`): the error's description.
public enum RecordingChangeFailure: Equatable, Sendable {
    case rename(String)
    case delete(String)
}

/// An error that says a note is not downloaded yet (a partial copy, `AppModel.partialNoteVerifier`): an editor
/// opened from the cache fetches the note once more and reads it again. The app's model error conforms.
public protocol NoteNotDownloaded: Error {
    var isNotDownloaded: Bool { get }
}
