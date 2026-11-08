import Foundation
import Observation
import PencilKit
import Sempere
import SempereAppCore
import SempereRender

/// The app's editor: the package's `NoteEditor` (the model half, `SempereAppCore`) on PencilKit's canvas.
typealias NoteEditor = SempereAppCore.NoteEditorModel<PencilCanvas>
/// Ink "Convert to Math" took off a page, as PencilKit strokes.
typealias ConvertedInk = SempereAppCore.TakenInk<PencilCanvas>

/// PencilKit as the editor's canvas (`NoteCanvas`): a page is a `PKDrawing`, one `PKStroke` per stored stroke
/// (`StrokeConversion`), fingerprinted by `CanvasStrokeInfo.init(_: PKStroke)`; drawings are prepared off the
/// main actor by `DrawingPreparation`.
enum PencilCanvas: NoteCanvas {
    typealias Drawing = PKDrawing
    typealias CanvasStroke = PKStroke
    typealias Tool = PKTool
    typealias Glue = NoteEditorAppState

    static var emptyDrawing: PKDrawing { PKDrawing() }
    static func strokes(of drawing: PKDrawing) -> [PKStroke] { drawing.strokes }
    static func drawing(of strokes: [PKStroke]) -> PKDrawing { PKDrawing(strokes: strokes) }
    static func canvasStroke(_ stroke: Stroke) -> PKStroke { StrokeConversion.pkStroke(stroke) }
    static func info(of stroke: PKStroke) -> CanvasStrokeInfo { CanvasStrokeInfo(stroke) }

    static func convert(_ strokes: [Stroke], visible: CGRect?, visibleFirst: ((PKDrawing) -> Void)?) -> PKDrawing {
        DrawingPreparation.convert(strokes, visible: visible, visibleFirst: visibleFirst).drawing
    }

    static func encode(_ drawing: PKDrawing) -> Data { drawing.dataRepresentation() }
    static func decode(_ data: Data) -> PKDrawing? { try? PKDrawing(data: data) }
    static func matches(_ drawing: PKDrawing, _ strokes: [Stroke]) -> Bool { DrawingPreparation.matches(drawing, strokes) }

    static func update(_ ledger: inout StrokeLedger, to drawing: PKDrawing, tool: PKTool?,
                       stamp: (@Sendable (Date) -> RecordingLink?)?) -> StrokeLedger.Change {
        ledger.update(drawing.strokes, tool: tool, stamp: stamp)
    }

    static func relayout(_ content: TextContent, frame: Rect) -> (content: TextContent, frame: Rect) {
        TextKitBreaks.relayout(content, frame: frame)
    }

    /// Where words fall inside a text box: laid out by CoreText, the shaper that draws the canvas's text.
    static var textBoxMatcher: TextBoxMatcher {
        { words, item in TextMatchBoxes.boxes(of: words, in: item, shaper: CoreTextShaper()) }
    }

    @MainActor static func makeGlue() -> NoteEditorAppState { NoteEditorAppState() }

    @MainActor static func recordingStamp(of editor: NoteEditor) -> (@Sendable (Date) -> RecordingLink?)? {
        guard let s = editor.recordingSession, s.isActive else { return nil }
        return s.stamp
    }

    @MainActor static func visibleRect(ofPage page: UUID, in editor: NoteEditor) -> CGRect? {
        editor.canvasTarget?.visibleRect(ofPage: page) ?? editor.canvasTarget?.visiblePageRect
    }

    @MainActor static func editorWillClose(_ editor: NoteEditor) async {
        // A recording in progress is saved into the note before the last save.
        await editor.finishRecording()
    }

    /// The editor stops its own playback of the recording (`NoteEditorModel.removeRecording`).
    @MainActor static func recordingWillBeRemoved(_ id: UUID, in editor: NoteEditor) {}

    @MainActor static func recordingFailed(_ failure: RecordingChangeFailure, in editor: NoteEditor) {
        switch failure {
        case .rename(let detail):
            editor.recordingError = String(localized: "Could not rename the recording: \(detail)")
        case .delete(let detail):
            editor.recordingError = String(localized: "Could not delete the recording: \(detail)")
        case .recover(let detail):
            editor.recordingError = String(localized: "A recording interrupted by the app closing could not be recovered: \(detail)")
        }
    }
}

/// What the app keeps for one open note next to the package's editor (`NoteCanvas.Glue`): the canvas it shows
/// on, "Convert to Math", and the recording being made and played. The editor's properties of the same names
/// (below) read and write these.
@MainActor
@Observable
final class NoteEditorAppState {
    /// The canvas showing this note, for menu commands (`CanvasCommandTarget`).
    @ObservationIgnored weak var canvasTarget: (any CanvasCommandTarget)?

    // Handwriting → math (`NoteEditor+MathInk.swift`, docs/attachments.md §14 G1 part 2).
    /// "Convert to Math" is picking ink: the canvases draw a lasso instead of ink.
    var mathLassoActive = false
    /// Ink picked for conversion, waiting in the equation sheet.
    var mathConversion: MathConversionRequest?
    /// Why the last lasso picked nothing (shown with the lasso's hint).
    var mathLassoMessage: String?
    /// The undo steps of conversions, held for as long as the editor (the
    /// undo manager does not retain its targets).
    @ObservationIgnored var conversionActions: ItemActions?

    // Recordings (`NoteEditor+RecordingSession.swift`, format.md §8.3, docs/attachments.md §9).
    /// The recording being made into this note, if one is.
    var recordingSession: RecordingSession?
    /// The last recording, playback or transcription failure.
    var recordingError: String?
    /// Saves of finished recordings still running (`close` waits for them).
    @ObservationIgnored var recordingSaves: [Task<Void, Never>] = []
    /// Called once a recording made here is saved, with its audio file and
    /// the session folder holding it: the model transcribes it (when that
    /// setting is on) and deletes the folder. Nil: the folder is deleted.
    @ObservationIgnored var onRecordingSaved: ((Recording, URL, URL) -> Void)?
}

extension NoteEditor {
    var canvasTarget: (any CanvasCommandTarget)? {
        get { glue.canvasTarget }
        set { glue.canvasTarget = newValue }
    }
    var mathLassoActive: Bool {
        get { glue.mathLassoActive }
        set { glue.mathLassoActive = newValue }
    }
    var mathConversion: MathConversionRequest? {
        get { glue.mathConversion }
        set { glue.mathConversion = newValue }
    }
    var mathLassoMessage: String? {
        get { glue.mathLassoMessage }
        set { glue.mathLassoMessage = newValue }
    }
    var conversionActions: ItemActions? {
        get { glue.conversionActions }
        set { glue.conversionActions = newValue }
    }
    var recordingSession: RecordingSession? {
        get { glue.recordingSession }
        set { glue.recordingSession = newValue }
    }
    var recordingError: String? {
        get { glue.recordingError }
        set { glue.recordingError = newValue }
    }
    var recordingSaves: [Task<Void, Never>] {
        get { glue.recordingSaves }
        set { glue.recordingSaves = newValue }
    }
    var onRecordingSaved: ((Recording, URL, URL) -> Void)? {
        get { glue.onRecordingSaved }
        set { glue.onRecordingSaved = newValue }
    }

    // MARK: Words

    /// Why the note cannot be edited, worded (`readOnly`).
    var readOnlyReason: String? { readOnly?.text }

    /// The last autosave failure, worded (`saveFailure`).
    var saveError: String? {
        saveFailure.map { detail in String(localized: "Could not save: \(detail)") }
    }

    /// The last recognition failure, worded (`recognitionFailure`).
    var recognitionError: String? {
        switch recognitionFailure {
        case .read(let detail): return String(localized: "Could not read handwriting: \(detail)")
        case .save(let detail): return String(localized: "Could not save recognized text: \(detail)")
        case nil: return nil
        }
    }

    // MARK: Thumbnails

    /// What a page thumbnail draws: the drawing the page's canvas shows when
    /// there is one (no conversion), else `thumbnailStrokes`.
    func thumbnailSource(of page: Page) -> PageThumbnail.Source {
        if let drawing = shownDrawing(of: page.id) { return .drawing(drawing) }
        return .strokes(thumbnailStrokes(of: page))
    }
}

extension NoteReadOnly {
    /// The reason as the canvas's banner says it.
    var text: String {
        switch self {
        case .noWriter:
            return String(localized: "This note is read-only.")
        case .preview:
            return String(localized: "Preview of an earlier version. Nothing here can be edited.")
        case .deleted:
            return String(localized: "This note is in Recently Deleted.")
        case .unreadableRevisions(let count):
            return String(localized: "\(count) revisions of this note could not be read, so it opens read-only.")
        case .newerVersion(let summary):
            return String(localized: "Parts of this note were written by a newer version of Sempere (\(summary)). It is shown as far as this version understands it, read-only: update Sempere to edit it.")
        case .vault(let reasons):
            return AppModel.readOnlyText(reasons)
        case .recoveryKey:
            return AppModel.recoveryReadOnlyText
        case .deviceList(let problem):
            return AppModel.listReadOnlyText(problem)
        case .loadFailed(let detail):
            return String(localized: "This note could not be read: \(detail)")
        }
    }
}

extension AppModel.ModelError: NoteNotDownloaded {}
