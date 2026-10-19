import SempereRender
import Sempere
import PencilKit
import SwiftUI
import UIKit

/// One page of a note on a `PKCanvasView`, with the system tool picker and
/// the paper underneath. Fits the page width; pinch zooms up to 4x.
struct PageCanvasView: UIViewRepresentable {
    let editor: NoteEditor
    let pageID: UUID
    let paper: Paper
    let pageSize: PageSize
    /// The tool palette's shown/compact state (`ToolPalette`).
    var paletteVisible = true
    var paletteCompact = false
    /// Reading on an iPhone: the canvas only pans and zooms, the palette is hidden
    /// (`PhoneReading`).
    var drawingSuspended = false
    /// `NoteEditor.canvasGeneration`: a change reloads the drawing even when
    /// the page id stays the same.
    var generation = 0
    /// Where the item layer reads attachments (`AppModel.attachmentCache`).
    var itemSource = ItemLayerSource()
    /// Copy and paste of items (`AppModel.itemClipboard`).
    var itemCommands = ItemCommands()
    /// Selection mode: items are selected, moved and resized; nothing draws.
    var selectingItems = false
    /// Called when selection mode ends from the canvas (a tool was picked).
    var onSelectingItemsEnded: () -> Void = {}
    /// Called when the palette's Hand tool is picked (an iPhone): selection mode on.
    var onHandToolPicked: () -> Void = {}
    /// The text tool: taps edit text boxes or start new ones.
    var addingText = false
    /// Called when the text tool ends from the canvas (a tool was picked).
    var onAddingTextEnded: (CanvasModes.TextToolEnd) -> Void = { _ in }
    /// Images and PDFs dropped on the page (`CanvasDrop`), with the page point they were dropped at.
    var onDrop: ((_ providers: [NSItemProvider], _ pageID: UUID, _ point: CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PageCanvasHost {
        let host = PageCanvasHost()
        host.canvas.delegate = context.coordinator
        return host
    }

    func updateUIView(_ host: PageCanvasHost, context: Context) {
        let c = context.coordinator
        editor.canvasTarget = host
        let index = editor.pages.firstIndex { $0.id == pageID }
        let isLast = index == editor.pages.count - 1
        let footer = PhoneReading.footer(infinite: pageSize.infinite, isLast: isLast, readOnly: editor.isReadOnly,
                                         drawingSuspended: drawingSuspended)
        host.footer = footer
        host.footerAction = { [weak editor] in
            guard let editor else { return }
            switch footer {
            case .addPage: editor.addPage()
            case .nextPage: if let index { editor.selectPage(index + 1) }
            case .none: break
            }
        }
        host.paletteCompact = paletteCompact
        host.paletteVisible = paletteVisible
        c.apply(editor: editor, pageID: pageID,
                content: PageCanvasContent(paper: paper, pageSize: pageSize, generation: generation,
                                           drawingSuspended: drawingSuspended, itemSource: itemSource,
                                           itemCommands: itemCommands, selectingItems: selectingItems,
                                           onSelectingItemsEnded: onSelectingItemsEnded,
                                           onHandToolPicked: onHandToolPicked,
                                           onDrop: onDrop, addingText: addingText,
                                           onAddingTextEnded: onAddingTextEnded),
                to: host)
        if c.revealToken != editor.revealToken {
            c.revealToken = editor.revealToken
            host.revealHighlight()
        }
    }

    static func dismantleUIView(_ host: PageCanvasHost, coordinator: Coordinator) {
        host.textEditor.endEditing()   // a box being typed in is written before the canvas goes
        coordinator.loadTask?.cancel()
        coordinator.editor?.detachInkView(coordinator)
        coordinator.host = nil
        Task { await coordinator.editor?.flush() }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, RemoteInkView {
        var editor: NoteEditor?
        weak var host: PageCanvasHost?
        var pageID: UUID?
        var editorID: ObjectIdentifier?
        var generation: Int?
        /// `NoteEditor.revealToken` last acted on (scroll to the current search match).
        var revealToken = 0
        /// True while the canvas's drawing is being replaced: its changes are not the user's.
        var isLoading = false
        /// The page's drawing being prepared off the main actor.
        var loadTask: Task<Void, Never>?
        /// Bumped per load, so a late partial drawing never lands over a newer one.
        private var loadToken = 0
        /// A stroke is being drawn (PencilKit's tool is in use).
        private var usingTool = false

        var shownPageID: UUID? { pageID }
        var isUsingInk: Bool {
            guard let host else { return false }   // a canvas that went away draws nothing
            return usingTool || host.isErasingInk || host.isDrawingWithPointer
        }

        /// Shows page `pageID` of `editor` on `host`: its ink (loaded when the
        /// page, the editor or the generation changed), paper and items. The
        /// one-page canvas and each page of the paged stack (`PageStackHost`)
        /// configure their canvases through this.
        func apply(editor: NoteEditor, pageID: UUID, content: PageCanvasContent, to host: PageCanvasHost) {
            if self.editor !== editor { self.editor?.detachInkView(self) }
            self.editor = editor
            editor.attachInkView(self)
            self.host = host
            if self.pageID != pageID || editorID != ObjectIdentifier(editor) || generation != content.generation {
                let samePage = self.pageID == pageID && editorID == ObjectIdentifier(editor)
                self.pageID = pageID
                editorID = ObjectIdentifier(editor)
                generation = content.generation
                load(editor: editor, pageID: pageID, host: host, keepScroll: samePage)
            }
            host.isReadOnly = editor.isReadOnly
            host.drawingSuspended = content.drawingSuspended
            host.apply(paper: content.paper, pageSize: content.pageSize)
            let pageItems = editor.items(on: pageID)
            // Audio items show the note's recordings (format.md §8.2.9).
            host.itemLayer.show(pageItems, note: editor.noteID, paper: content.paper, source: content.itemSource,
                                recordings: editor.recordings)
            let overText = MarkerOrder.textOverlay(pageItems, meta: editor.meta)
            host.textOverlay.isHidden = overText.isEmpty
            host.textOverlay.show(overText, note: editor.noteID, paper: content.paper, source: content.itemSource)
            host.itemSelection.reset(editor: editor, pageID: pageID, undoManager: host.canvas.undoManager)
            host.itemSelection.commands = content.itemCommands
            // The cards' play/pause buttons: pause on the one the player plays.
            host.itemSelection.recordings = editor.recordings
            host.itemSelection.playing = editor.player.flatMap { p in
                p.recording.map { AudioPlayState(recording: $0.id, isPlaying: p.isPlaying) }
            }
            host.onItemSelectionEnded = content.onSelectingItemsEnded
            host.onHandToolPicked = content.onHandToolPicked
            host.itemSelectionActive = content.selectingItems && !editor.isReadOnly && !content.drawingSuspended
            host.syncHandTool()
            if let onDrop = content.onDrop {
                host.dropHandler = { providers, point in onDrop(providers, pageID, point) }
            } else {
                host.dropHandler = nil
            }
            host.itemSelection.refresh()
            host.textEditor.reset(editor: editor, pageID: pageID)
            host.onTextToolEnded = content.onAddingTextEnded
            host.textToolActive = content.addingText && !editor.isReadOnly && !content.drawingSuspended
            host.setHighlights(editor.highlightBoxes(onPage: pageID))
            if editor.listeningToInk {
                host.inkTapHandler = { [weak editor] p in editor?.inkTapped(pageID: pageID, x: Double(p.x), y: Double(p.y)) }
            } else {
                host.inkTapHandler = nil
            }
            // "Convert to Math": the lasso picks ink on this page (`NoteEditor+MathInk`).
            if editor.mathLassoActive {
                host.mathLassoHandler = { [weak editor] loop, undo in
                    editor?.mathLassoFinished(pageID: pageID, loop: loop, undoManager: undo)
                }
                host.onMathLassoEnded = { [weak editor] in editor?.endMathLasso() }
            } else {
                host.mathLassoHandler = nil
                host.onMathLassoEnded = nil
            }
        }

        /// The canvas goes back to the stack's spares: no page, no ink, no
        /// load in flight. The page is dropped before the drawing, so clearing
        /// the canvas never reaches the editor as an erase.
        func forget(host: PageCanvasHost) {
            loadTask?.cancel()
            loadTask = nil
            loadToken &+= 1
            pageID = nil
            usingTool = false
            editor?.detachInkView(self)
            editor = nil   // a spare canvas holds no note
            editorID = nil
            generation = nil
            host.cancelErasing()
            host.itemSelectionActive = false
            host.endTransientSelection()
            host.inkTapHandler = nil
            host.mathLassoHandler = nil
            host.onMathLassoEnded = nil
            host.setHighlights([])
            host.textOverlay.isHidden = true   // a spare canvas shows no note's text
            isLoading = true
            host.canvas.drawing = PKDrawing()
            host.canvas.undoManager?.removeAllActions()
            isLoading = false
        }

        /// Shows the page's ink: at once when the editor has its drawing
        /// ready, else prepared off the main actor (from the drawing cache, or
        /// converted with the strokes on screen first), with drawing disabled
        /// until the whole page is in.
        func load(editor: NoteEditor, pageID: UUID, host: PageCanvasHost, keepScroll: Bool) {
            loadTask?.cancel()
            loadToken &+= 1
            let token = loadToken
            isLoading = true
            usingTool = false      // a stroke under way belonged to the drawing being replaced
            host.cancelErasing()   // an erase in progress belongs to the old page
            if !keepScroll { host.scrollToTop() }
            if let ready = editor.readyDrawing(for: pageID) {
                show(ready, host: host, editor: editor, partial: false)
                return
            }
            host.canvas.drawing = PKDrawing()
            host.canvas.undoManager?.removeAllActions()   // the previous page's undo must not run on this one
            host.isPreparing = true
            let visible = host.visiblePageRect
            loadTask = Task { @MainActor [weak self, weak host, weak editor] in
                guard let editor else { return }
                let drawing = await editor.prepareDrawing(for: pageID, visible: visible) { [weak self, weak host] part in
                    guard let self, let host, self.loadToken == token, self.isLoading else { return }
                    host.canvas.drawing = part
                    host.inkDidChange()
                    editor.didShowInk(partial: true)
                }
                guard let self, let host, self.loadToken == token, !Task.isCancelled else { return }
                // Nil: the page changed while it was prepared; the editor's own conversion is current.
                self.show(drawing ?? editor.drawing(for: pageID), host: host, editor: editor, partial: false)
            }
        }

        /// Revisions written elsewhere changed this page's ink
        /// (`NoteEditor.mergeRevisions`): shows the editor's drawing again,
        /// at the same scroll and zoom. A page still being prepared is left to
        /// its load, which checks the strokes it converted against the page.
        func reloadInk(from editor: NoteEditor) {
            guard let host, let pageID, self.editor === editor, !host.isPreparing,
                  let drawing = editor.readyDrawing(for: pageID) else { return }
            loadTask?.cancel()
            loadTask = nil
            loadToken &+= 1
            host.cancelErasing()
            show(drawing, host: host, editor: editor, partial: false, keepUndo: editor.reloadKeepsUndo)
        }

        /// `keepUndo`: the change is itself an undo or redo step (of "Convert to
        /// Math"): the undo manager is in the middle of it and must not be cleared.
        private func show(_ drawing: PKDrawing, host: PageCanvasHost, editor: NoteEditor, partial: Bool,
                          keepUndo: Bool = false) {
            isLoading = true
            host.canvas.drawing = drawing
            if !keepUndo { host.canvas.undoManager?.removeAllActions() }   // undo must not cross pages or notes
            isLoading = false
            host.isPreparing = false
            host.inkDidChange()
            editor.didShowInk(partial: partial)
            #if DEBUG
            if DebugLaunch.isActive {
                NSLog("SempereDebug loaded strokes=%d bounds=%@", drawing.strokes.count, NSCoder.string(for: drawing.bounds))
            }
            #endif
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if let type = EraserPreference.eraserType(of: canvasView.tool) { EraserPreference.save(type) }
            guard !isLoading, let editor, let pageID else { return }
            let interval = Perf.begin(.inkChange)
            let change = editor.drawingDidChange(pageID: pageID, drawing: canvasView.drawing, tool: canvasView.tool)
            host?.inkDidChange(measured: editor.takeMeasuredInk(of: pageID))
            Perf.end(interval, "added=\(change.added.count) removed=\(change.removed.count)")
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            usingTool = false
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            host?.zoomChanged()
            if scrollView.isZooming { host?.itemSelection.viewMoved() }
        }

        /// The user scrolls: the item's menu goes (layout and focus changes that move the offset do not count).
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            host?.visibleAreaChanged()
            if scrollView.isDragging || scrollView.isDecelerating { host?.itemSelection.viewMoved() }
            #if DEBUG
            host?.itemSelection.debugRefreshReport()   // the report's offset (`PhoneReadingScrollUITests`)
            #endif
        }

        /// A scroll or a pinch starts: every menu on the canvas goes at once, the item's and
        /// PencilKit's (`ItemSelectionController.gestureStarted`).
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            host?.itemSelection.gestureStarted()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            host?.itemSelection.gestureStarted()
        }

        /// A pinch ended: the fitted width is a detent (`ZoomDetent`).
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            host?.zoomEnded()
        }

        /// A stroke starts: the canvas (a page of the stack, or the one-page
        /// canvas, which takes the focus by itself only when nothing else holds
        /// the keyboard, `CanvasFocus`) takes the focus, so undo and the
        /// palette act on it.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            usingTool = true
            host?.itemSelection.gestureStarted(stroke: true)   // writing on the page: no menu stays over it
            guard let host, !canvasView.isFirstResponder else { return }
            host.focus()
        }
    }
}

/// What a page's canvas shows besides its ink (`PageCanvasView.Coordinator.apply`).
struct PageCanvasContent {
    var paper: Paper
    var pageSize: PageSize
    /// `NoteEditor.canvasGeneration`: a change reloads the ink.
    var generation = 0
    var drawingSuspended = false
    var itemSource = ItemLayerSource()
    var itemCommands = ItemCommands()
    var selectingItems = false
    var onSelectingItemsEnded: () -> Void = {}
    var onHandToolPicked: () -> Void = {}
    /// Images and PDFs dropped on the page, with the page point (nil: drops refused).
    var onDrop: ((_ providers: [NSItemProvider], _ pageID: UUID, _ point: CGPoint) -> Void)?
    /// The text tool: taps edit text boxes or start new ones.
    var addingText = false
    var onAddingTextEnded: (CanvasModes.TextToolEnd) -> Void = { _ in }
}

/// UIKit side of `PageCanvasView`.
final class PageCanvasHost: UIView, PKToolPickerObserver, UIPointerInteractionDelegate, UIDropInteractionDelegate {
    let canvas = PKCanvasView()
    private let paperView = PaperView()
    /// The page's placed items, between the paper and the ink.
    let itemLayer = ItemLayerView()
    /// Text boxes drawn again above the ink, multiplied, on a note with
    /// `markersBehindText` (`MarkerOrder`); hidden otherwise.
    let textOverlay = ItemLayerView()
    /// Selecting, moving and resizing items (selection mode).
    let itemSelection = ItemSelectionController()
    /// Called when picking a tool ends selection mode.
    var onItemSelectionEnded: (() -> Void)?
    /// Called when the palette's Hand tool is picked: the note view turns selection mode on.
    var onHandToolPicked: (() -> Void)?
    /// The last palette tool that draws (the Hand tool is not one), to go back to when selection mode ends.
    private var lastDrawingToolID: String?
    /// Typing in text boxes (the text tool, and "Edit Text" in selection mode).
    let textEditor = TextBoxEditorController()
    /// Called when picking a tool ends the text tool, or it placed its one box.
    var onTextToolEnded: ((CanvasModes.TextToolEnd) -> Void)?
    /// The text tool started a new box: when its edit ends, the tool has done its one placement.
    private var placingTextBox = false

    /// The text tool: PencilKit's drawing is off, a tap selects a text box
    /// (a tap on the selected one, or a double tap, types in it) or starts a
    /// new one.
    var textToolActive = false {
        didSet {
            guard textToolActive != oldValue else { return }
            textEditor.toolActive = textToolActive
            if textToolActive { transientSelection = false }
            updateSelectionMode()
        }
    }

    /// Selection mode: PencilKit's drawing and the object eraser are off,
    /// touches select and move items (`ItemSelectionController`).
    var itemSelectionActive = false {
        didSet {
            guard itemSelectionActive != oldValue else { return }
            if itemSelectionActive { transientSelection = false }
            updateSelectionMode()
        }
    }

    /// Selection mode for one item, picked while drawing (a lasso tap, a held
    /// finger, a secondary click): drawing is off while it is selected and
    /// comes back once nothing is (or a tool is picked).
    private(set) var transientSelection = false {
        didSet {
            guard transientSelection != oldValue else { return }
            updateSelectionMode()
        }
    }

    /// The selection controller follows the modes: every item in selection
    /// mode or a transient selection, text boxes with the text tool, nothing
    /// while a box is typed in.
    private func updateSelectionMode() {
        let editing = textEditor.isEditing
        if itemSelectionActive || transientSelection {
            itemSelection.onEmptyTap = nil
            itemSelection.setActive(!editing, scope: .all)
        } else if textToolActive {
            itemSelection.onEmptyTap = { [weak self] p in
                guard let self else { return }
                self.textEditor.beginNew(at: p)
                self.placingTextBox = self.textEditor.isEditing
            }
            itemSelection.setActive(!editing, scope: .textBoxes)
        } else {
            itemSelection.onEmptyTap = nil
            itemSelection.setActive(false)
        }
        updateEraser()
        cursorInteraction?.invalidate()
    }

    // MARK: Keys for the selected item (Mac keyboards, an iPad's too)

    /// Escape drops the selection; the arrow keys move the selected item by
    /// one point (ten with Shift), one undo step per press; Delete deletes it.
    /// Only while an item is selected and nothing is typed, so the keys scroll
    /// otherwise.
    override var keyCommands: [UIKeyCommand]? {
        guard itemSelection.hasSelection, !textEditor.isEditing else { return super.keyCommands }
        var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(itemKey(_:)))]
        if !isReadOnly {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(itemKey(_:))))
        }
        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                      UIKeyCommand.inputRightArrow] {
            commands.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(itemKey(_:))))
            commands.append(UIKeyCommand(input: input, modifierFlags: .shift, action: #selector(itemKey(_:))))
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func itemKey(_ command: UIKeyCommand) {
        let step: Double = command.modifierFlags.contains(.shift) ? 10 : 1
        switch command.input {
        case UIKeyCommand.inputEscape: itemSelection.clearSelection()
        case UIKeyCommand.inputDelete: itemSelection.perform(.deleteItem)
        case UIKeyCommand.inputUpArrow: itemSelection.nudge(dx: 0, dy: -step)
        case UIKeyCommand.inputDownArrow: itemSelection.nudge(dx: 0, dy: step)
        case UIKeyCommand.inputLeftArrow: itemSelection.nudge(dx: -step, dy: 0)
        case UIKeyCommand.inputRightArrow: itemSelection.nudge(dx: step, dy: 0)
        default: break
        }
    }

    /// Ends a transient selection (the drawing tool comes back).
    func endTransientSelection() {
        guard transientSelection else { return }
        itemSelection.select(nil)
        transientSelection = false
    }
    /// "Tap Ink to Play" (`NoteEditor+Recordings`): while set, PencilKit's
    /// drawing is off and a tap is handed over in page points.
    var inkTapHandler: ((CGPoint) -> Void)? {
        didSet {
            guard (inkTapHandler == nil) != (oldValue == nil) else { return }
            inkTap.isEnabled = inkTapHandler != nil
            updateEraser()
        }
    }
    private lazy var inkTap = UITapGestureRecognizer(target: self, action: #selector(inkTapped(_:)))
    /// "Convert to Math": while set, PencilKit's drawing is off and a lasso
    /// (`MathLassoController`) hands its loop over in page points, with the
    /// canvas's undo manager.
    var mathLassoHandler: (([CGPoint], UndoManager?) -> Void)? {
        didSet {
            mathLasso.onFinish = mathLassoHandler.map { handler in
                { [weak self] loop in handler(loop, self?.canvas.undoManager) }
            }
            guard (mathLassoHandler == nil) != (oldValue == nil) else { return }
            updateEraser()
        }
    }
    /// Called when picking a tool ends the lasso.
    var onMathLassoEnded: (() -> Void)?
    private let mathLasso = MathLassoController()
    /// Search highlights (`NoteEditor+SearchHighlight.swift`), above the paper and the items, below the ink.
    private let highlightView = UIView()
    private(set) var highlights: [HighlightBox] = []
    private var pendingReveal: Recognition.Box?
    /// Starts with the last-used eraser mode, the object eraser by default.
    /// A page of the paged stack shares the stack's picker (`init(frame:sharedPicker:)`).
    private(set) var toolPicker: PKToolPicker
    /// One page of a paged note's stack (`PageStackHost`): the stack scrolls
    /// and zooms, this canvas shows the whole page at the stack's scale and
    /// never scrolls itself; it has its own undo, and the stack's picker.
    let isEmbedded: Bool
    /// The page's undo steps (embedded only): pages of the stack never undo each other's ink.
    private let pageUndo = UndoManager()
    private var pageSize = PageSize.letter
    private var paper = Paper.blank
    private var fittedWidth: CGFloat = 0
    /// The sized object eraser that replaces PencilKit's (`ObjectEraser.swift`).
    /// The app's object eraser (tests drive its gesture through `begin`, `move` and `end`).
    let objectEraser = ObjectEraserController()
    /// Smoothed mouse and trackpad strokes on a Mac (`MouseInk.swift`).
    private let mouseInk = MouseInkController()
    /// The "Smooth Mouse Strokes" level last applied (Mac; Off elsewhere).
    private var smoothingLevel = StrokeSmoothing.Level.off
    /// Bottom of the ink on the page (page points), nil without ink.
    private(set) var inkMaxY: Double?
    /// The Add Page / Next Page button below a finite page.
    let footerButton = UIButton(configuration: .bordered())
    /// The pointer's shape over the canvas (Mac, `pointerInteraction(_:styleFor:)`).
    private var cursorInteraction: UIPointerInteraction?
    /// Takes images and PDFs dropped on the page; nil: drops are refused.
    var dropHandler: ((_ providers: [NSItemProvider], _ point: CGPoint) -> Void)?

    /// What the button below a finite page does (`PageExtent`).
    var footer = PageExtent.Footer.none {
        didSet { if footer != oldValue { updateFooter() } }
    }
    var footerAction: (() -> Void)?

    /// The palette is shown (the toolbar button) unless the note is read-only.
    var paletteVisible = true {
        didSet {
            guard paletteVisible != oldValue else { return }
            updateToolPicker()
            // The stack gives the focus to one of its pages itself (`PageStackHost.paletteTurnedOn`).
            if paletteVisible, !isEmbedded, Self.paletteTakesFocus(isPhone: Platform.isPhone),
               !CanvasFocus.typingElsewhere(than: self) {
                reclaimFocus()
            }
        }
    }

    /// Whether turning the palette on gives the canvas the first responder. PencilKit shows the palette
    /// only for the first responder, and a canvas never takes it by itself from a list or a field
    /// (`CanvasFocus`): with the note list holding the focus, the toolbar button flipped its icon and
    /// nothing came up (TestFlight 1.0.0 (6), the owner's iPad). The user asked for the palette, so the
    /// canvas takes the focus from a list or the sidebar, as a touch on it does (`reclaimFocus`); a field
    /// being typed in keeps it (`CanvasFocus.typingElsewhere`). The iPhone's palette follows its
    /// Annotate mode, which already focuses the canvas (`PhoneCanvasMode`), so it is left alone.
    nonisolated static func paletteTakesFocus(isPhone: Bool) -> Bool { !isPhone }

    /// The palette is the short one: pen, marker, eraser, lasso.
    var paletteCompact = ToolPalette.isCompact() {
        didSet { if paletteCompact != oldValue { rebuildToolPicker() } }
    }

    /// Reading mode (iPhone): fingers scroll and zoom, nothing draws, no palette.
    var drawingSuspended = false {
        didSet {
            guard drawingSuspended != oldValue else { return }
            updateEraser()
            updateToolPicker()
        }
    }

    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            updateEraser()
            updateToolPicker()
        }
    }

    /// The page's ink is still being prepared: nothing can be drawn, and a
    /// spinner shows over the canvas.
    var isPreparing = false {
        didSet {
            guard isPreparing != oldValue else { return }
            updateEraser()
            if isPreparing { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// The part of the page on screen, in page points (nil before layout).
    var visiblePageRect: CGRect? {
        let z = canvas.zoomScale
        guard z > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = CGRect(x: canvas.contentOffset.x / z, y: canvas.contentOffset.y / z,
                          width: bounds.width / z, height: bounds.height / z)
        // Zoomed out below the fit: the margins beside the page are not on it.
        guard canvas.contentInset.left > 0 else { return rect }
        return rect.intersection(CGRect(x: 0, y: rect.minY, width: CGFloat(pageSize.width), height: rect.height))
    }

    /// The canvas scrolled: the paper builds the bands coming into view (`PaperView.setVisible`).
    func visibleAreaChanged() {
        paperView.setVisible(canvas.bounds)
    }

    override init(frame: CGRect) {
        toolPicker = ToolPalette.makePicker(compact: ToolPalette.isCompact())
        isEmbedded = false
        super.init(frame: frame)
        setUp()
    }

    /// A page of the paged stack, with the stack's tool picker.
    init(frame: CGRect, sharedPicker: PKToolPicker) {
        toolPicker = sharedPicker
        isEmbedded = true
        super.init(frame: frame)
        setUp()
    }

    private func setUp() {
        backgroundColor = .secondarySystemBackground
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Ink colors are stored as drawn on light paper; never invert them.
        canvas.overrideUserInterfaceStyle = .light
        canvas.accessibilityIdentifier = "pageCanvas"   // UI tests draw on it
        // A Mac has no Pencil: the mouse and trackpad always draw, whatever
        // the system's Pencil preference says (`.default` follows it).
        // An iPhone has no Pencil: a finger draws (once annotating is switched on).
        canvas.drawingPolicy = Platform.isMac || Platform.isPhone ? .anyInput : .default
        #if DEBUG
        // UI tests on the iPad simulator (`IPadCanvasUITests`): a paired Pencil's default, where a finger
        // taps, holds and scrolls instead of drawing (the simulator's fingers draw otherwise).
        if DebugLaunch.environment["SEMPERE_DEBUG_PENCIL_ONLY"] != nil { canvas.drawingPolicy = .pencilOnly }
        #endif
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.insertSubview(paperView, at: 0)
        canvas.insertSubview(itemLayer, aboveSubview: paperView)
        highlightView.isUserInteractionEnabled = false
        canvas.insertSubview(highlightView, aboveSubview: itemLayer)   // over the items, under the ink
        textOverlay.layer.compositingFilter = "multiplyBlendMode"
        textOverlay.accessibilityIdentifier = "textOverlay"
        textOverlay.isHidden = true
        canvas.addSubview(textOverlay)   // above PencilKit's ink view
        footerButton.isHidden = true
        footerButton.addAction(UIAction { [weak self] _ in self?.footerAction?() }, for: .primaryActionTriggered)
        canvas.addSubview(footerButton)
        addSubview(canvas)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     spinner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16)])
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        toolPicker.colorUserInterfaceStyle = .light
        objectEraser.attach(to: self, canvas: canvas)
        mouseInk.attach(to: canvas)
        mouseInk.onBegin = { [weak self] in
            // As `canvasViewDidBeginUsingTool`: the canvas drawn on takes the focus.
            guard let self, !self.canvas.isFirstResponder else { return }
            self.focus()
        }
        mathLasso.attach(to: canvas)
        itemSelection.attach(to: canvas, itemLayer: itemLayer)
        textEditor.attach(to: canvas, itemLayer: itemLayer)
        textEditor.actions = { [weak self] in self?.itemSelection.actions }
        textEditor.onEditingChanged = { [weak self] editing in self?.textEditingChanged(editing) }
        #if DEBUG
        itemSelection.debugTyping = { [weak self] in self?.textEditor.textView?.text }
        itemSelection.debugStrokes = { [weak self] in self?.canvas.drawing.strokes.count ?? 0 }
        itemSelection.debugInput = { [weak self] in
            guard let self else { return "" }
            return "pan=\(self.canvas.panGestureRecognizer.minimumNumberOfTouches);ink=\(self.canvas.drawingGestureRecognizer.isEnabled ? 1 : 0)"
                + ";select=\(self.itemSelectionActive ? 1 : 0)"
        }
        itemSelection.debugEmoji = { [weak self] in self?.textEditor.emojiSummary ?? "0,0" }
        itemSelection.debugPalette = { [weak self] in
            guard let self else { return false }
            return self.canvas.isFirstResponder && self.toolPicker.isVisible
        }
        textEditor.onTextChanged = { [weak self] in self?.itemSelection.debugRefreshReport() }
        #endif
        itemSelection.onEditText = { [weak self] item in self?.textEditor.begin(item) }
        itemSelection.lassoSelected = { [weak self] in self?.canvas.tool is PKLassoTool }
        textEditor.penColour = { [weak self] in (self?.canvas.tool as? PKInkingTool).map { Sempere.Color($0.color) } }
        itemSelection.canPick = { [weak self] in self?.drawingEditable ?? false }
        itemSelection.canFingerPick = { [weak self] in !(self?.toolPicker.selectedToolItem is PKToolPickerEraserItem) }
        itemSelection.onPick = { [weak self] in self?.transientSelection = true }
        itemSelection.onCleared = { [weak self] in
            guard let self, self.transientSelection, !self.textEditor.isEditing else { return }
            self.transientSelection = false
        }
        canvas.addInteraction(UIDropInteraction(delegate: self))
        inkTap.isEnabled = false
        canvas.addGestureRecognizer(inkTap)
        if Platform.isMac {
            let pointer = UIPointerInteraction(delegate: self)
            addInteraction(pointer)
            cursorInteraction = pointer
            // "Smooth Mouse Strokes" changed in Settings: PencilKit or the app draws the pointer.
            NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                                   name: UserDefaults.didChangeNotification, object: nil)
        }
        if !isEmbedded {
            // A window that becomes key (a note window opened or clicked) gives the canvas the focus then.
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                                   name: UIWindow.didBecomeKeyNotification, object: nil)
        }
        if isEmbedded {
            // The stack scrolls and zooms; the page shows a sheet with a shadow on the stack's background.
            backgroundColor = .clear
            canvas.isScrollEnabled = false
            canvas.alwaysBounceVertical = false
            canvas.bouncesZoom = false
            canvas.showsVerticalScrollIndicator = false
            canvas.showsHorizontalScrollIndicator = false
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.2
            layer.shadowRadius = 4
            layer.shadowOffset = CGSize(width: 0, height: 1)
            #if DEBUG
            debugLaunchPending = false   // the stack applies the debug zoom and scroll
            #endif
        }
    }

    /// Embedded pages have their own undo manager; the canvas finds it up the responder chain.
    override var undoManager: UndoManager? {
        #if DEBUG
        if !isEmbedded, let testUndoManager { return testUndoManager }
        #endif
        return isEmbedded ? pageUndo : super.undoManager
    }

    #if DEBUG
    /// Tests give a one-page canvas outside the app's scenes an undo manager (`InkInjector`).
    var testUndoManager: UndoManager?
    #endif

    /// Makes this canvas the first responder (its palette, its undo) when it
    /// can be drawn on: the user drew on it.
    func focus() {
        // A text box being typed in keeps the keyboard: its text view is the first responder.
        guard window != nil, !isReadOnly, !drawingSuspended, !textEditor.isEditing else { return }
        canvas.becomeFirstResponder()
    }

    /// A touch on the canvas (a stroke, a tap, a click) brings its palette
    /// back: once something else took the first responder (the sidebar, a
    /// list, a field), drawing or tapping the page must restore the tools
    /// (TestFlight 1.0.0: the palette went when the sidebar took the focus,
    /// and drawing did not bring it back). The user touched the canvas, so
    /// this is the user's focus, not the canvas taking it by itself
    /// (`CanvasFocus`); a text box being typed in keeps the keyboard.
    ///
    /// Also, while PencilKit's drawing is off, a recognizer of its own made or turned on since
    /// (PencilKit sets up its selection views when the canvas's tool becomes the lasso, which the
    /// picker may tell it after `updateEraser` ran) is turned off before the press is handed to the
    /// recognizers.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches, !canvas.drawingGestureRecognizer.isEnabled {
            setPencilKitGestures(enabled: false)
        }
        if hit != nil, event?.type == .touches, !reclaimScheduled, !paletteShowing {
            reclaimScheduled = true
            // After the touch is delivered: becoming first responder in the middle of hit-testing is not safe.
            DispatchQueue.main.async { [weak self] in
                self?.reclaimScheduled = false
                self?.reclaimFocus()
            }
        }
        return hit
    }

    private var reclaimScheduled = false

    /// Whether this canvas has the focus and its palette is up (or the palette is meant to be hidden).
    var paletteShowing: Bool {
        canvas.isFirstResponder && (toolPicker.isVisible || !paletteVisible)
    }

    /// Takes the first responder and shows the palette for it (a touch on the canvas).
    func reclaimFocus() {
        guard window != nil, !isReadOnly, !drawingSuspended, !textEditor.isEditing else { return }
        toolPicker.setVisible(paletteVisible, forFirstResponder: canvas)
        if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        #if DEBUG
        itemSelection.trace("r")
        itemSelection.debugRefreshReport()
        #endif
    }

    /// `focus()` unless something outside `container` (the stack for a page
    /// of it) holds the keyboard: a search or text field, or a list moved
    /// through with the arrow keys (`CanvasFocus`). For focus the canvas takes
    /// by itself (opening, layout, an edit ending), never the user's.
    func focusUnlessKeyboardElsewhere(container: UIView? = nil) {
        guard window != nil, !canvas.isFirstResponder,
              !CanvasFocus.keyboardIsElsewhere(than: container ?? self) else { return }
        focus()
    }

    /// The paged stack this page belongs to (embedded only).
    private var enclosingStack: UIView? {
        var view = superview
        while let v = view, !(v is PageStackHost) { view = v.superview }
        return view
    }

    /// The selected tool changed outside the picker's own UI (a menu command):
    /// the object eraser and the pointer follow it.
    func toolDidChange() {
        updateEraser()
        cursorInteraction?.invalidate()
    }
    /// A circle the size of the ink tool's stroke at the current zoom, so the
    /// pointer shows where a mouse stroke lands. The object eraser draws its
    /// own cursor, and the lasso and the pixel eraser keep the system arrow.
    ///
    /// While items can be selected, the pointer says what a drag does instead
    /// (`ItemPointer`): a four-way arrow over an item, a two-way arrow along a
    /// resize handle, the system arrow elsewhere. Each such zone is a region of
    /// its own, so the shape follows the pointer across them.
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard itemSelection.isActive else { return defaultRegion }
        let zone = itemSelection.pointer(at: convert(request.location, to: canvas))
        // A small region around the pointer: UIKit asks again once it leaves it.
        let rect = CGRect(x: request.location.x - 2, y: request.location.y - 2, width: 4, height: 4)
        return UIPointerRegion(rect: rect, identifier: (zone?.identifier ?? "item.none") as NSString)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard !isReadOnly else { return nil }
        if itemSelection.isActive {
            guard let zone = itemSelection.pointer(at: convert(CGPoint(x: region.rect.midX, y: region.rect.midY), to: canvas))
            else { return UIPointerStyle.system() }
            return UIPointerStyle(shape: .path(zone.path), constrainedAxes: [])
        }
        if objectEraserSelected { return UIPointerStyle.hidden() }
        guard let tool = canvas.tool as? PKInkingTool else { return nil }
        let d = CGFloat(PointerCursor.diameter(toolWidth: Double(tool.width), zoom: Double(canvas.zoomScale)))
        return UIPointerStyle(shape: .path(UIBezierPath(ovalIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))),
                              constrainedAxes: [])
    }

    // MARK: Drops (images and PDFs from other apps, the Finder or Files)

    /// Whether a drop session can be taken: something to add, from another
    /// app (a note dragged out of this app's list is not added to itself), on
    /// a note that can be edited.
    func canTakeDrop(_ session: UIDropSession) -> Bool {
        dropHandler != nil && !isReadOnly && !isPreparing && session.localDragSession == nil
            && session.hasItemsConforming(toTypeIdentifiers: CanvasDrop.typeIdentifiers)
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        canTakeDrop(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: canTakeDrop(session) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let z = max(canvas.zoomScale, 0.01)
        let p = session.location(in: canvas)
        dropHandler?(session.items.map(\.itemProvider), CGPoint(x: p.x / z, y: p.y / z))
    }

    /// Remembers the eraser mode the user picks, for the next canvas, and
    /// hands the object eraser to `ObjectEraserController`.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        if let eraser = toolPicker.selectedToolItem as? PKToolPickerEraserItem {
            EraserPreference.save(eraser.eraserTool.eraserType)
        }
        let hand = toolPicker.selectedToolItemIdentifier == ToolPalette.handIdentifier
        if hand {
            // The Hand tool: one finger scrolls and taps select (selection mode), as the Select toggle does.
            if !itemSelectionActive { onHandToolPicked?() }
        } else {
            lastDrawingToolID = toolPicker.selectedToolItemIdentifier
            if itemSelectionActive { onItemSelectionEnded?() }   // picking a tool is picking drawing
        }
        if textToolActive { onTextToolEnded?(.toolPicked) }
        if mathLassoHandler != nil { onMathLassoEnded?() }
        endTransientSelection()
        updateEraser()
        cursorInteraction?.invalidate()
    }

    /// Keeps the palette's Hand tool in step with selection mode (the iPhone's Select toggle in the
    /// overflow menu turns it on too; a new note turns it off): in selection mode the Hand shows as
    /// picked, and once selection ends with the Hand still picked the last drawing tool comes back.
    func syncHandTool() {
        guard toolPicker.toolItems.contains(where: { $0.identifier == ToolPalette.handIdentifier }) else { return }
        let picked = toolPicker.selectedToolItemIdentifier
        if itemSelectionActive {
            if picked != ToolPalette.handIdentifier { toolPicker.selectedToolItemIdentifier = ToolPalette.handIdentifier }
        } else if picked == ToolPalette.handIdentifier {
            let back = toolPicker.toolItems.first { $0.identifier == lastDrawingToolID }
                ?? toolPicker.toolItems.first { $0.identifier != ToolPalette.handIdentifier }
            if let back { toolPicker.selectedToolItemIdentifier = back.identifier }
        }
    }

    @objc private func inkTapped(_ g: UITapGestureRecognizer) {
        let z = max(canvas.zoomScale, 0.01)
        let p = g.location(in: canvas)
        inkTapHandler?(CGPoint(x: p.x / z, y: p.y / z))
    }

    /// An object-eraser gesture is in progress.
    var isErasingInk: Bool { objectEraser.isErasing }
    /// A smoothed mouse stroke is being drawn.
    var isDrawingWithPointer: Bool { mouseInk.isDrawing }
    /// Whether the app, not PencilKit, draws pointer strokes now (`MouseSmoothing.takesPointer`).
    var pointerInkActive: Bool { mouseInk.isActive }
    /// Whether ink can be drawn now: PencilKit's gesture, or on a Mac the app's pointer ink.
    var drawsInk: Bool { canvas.drawingGestureRecognizer.isEnabled || mouseInk.isActive }

    /// Drops an object-eraser gesture or a mouse stroke in progress (the drawing is being replaced).
    func cancelErasing() {
        objectEraser.cancelGesture()
        mouseInk.cancelStroke()
    }

    /// Its window became key: the one-page canvas takes the focus unless something holds the keyboard.
    @objc private func windowBecameKey(_ note: Notification) {
        guard let window, note.object as? UIWindow === window, !isReadOnly, !drawingSuspended else { return }
        focusUnlessKeyboardElsewhere()
    }

    /// Any setting changed (possibly off the main thread): if "Smooth Mouse
    /// Strokes" did, PencilKit or the app draws the pointer from now on. Other
    /// settings (the eraser mode is saved during erasing) change nothing here.
    @objc nonisolated private func defaultsChanged() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let level = MouseSmoothing.load()
            guard level != self.smoothingLevel else { return }
            self.smoothingLevel = level
            self.updateEraser()
        }
    }

    /// PencilKit's ruler snaps only its own strokes: while it shows, PencilKit draws the pointer.
    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) {
        updateEraser()
    }

    /// Whether the picker's selected tool is the object eraser.
    var objectEraserSelected: Bool {
        (toolPicker.selectedToolItem as? PKToolPickerEraserItem)?.eraserTool.eraserType == .vector
    }

    /// Whether the canvas draws now: nothing selects, types or plays, and the note can be edited.
    var drawingEditable: Bool {
        !isReadOnly && !isPreparing && !drawingSuspended && !itemSelectionActive && !textToolActive && !transientSelection
            && !textEditor.isEditing && inkTapHandler == nil && mathLassoHandler == nil
    }

    /// The app's sized object eraser stands in for PencilKit's `.vector` one;
    /// every other tool (pixel eraser included) is PencilKit's. On a Mac with
    /// "Smooth Mouse Strokes" on, the app draws the ink tools' pointer strokes.
    private func updateEraser() {
        // First: the eraser and the item selection read the policy (`ObjectEraserController.fingersDraw`).
        if Platform.isPhone { applyPhoneDrawingPolicy() }
        let editable = drawingEditable
        let ours = editable && objectEraserSelected
        objectEraser.setActive(ours)
        if Platform.isMac { smoothingLevel = MouseSmoothing.load() }
        let pointer = !ours && MouseSmoothing.takesPointer(
            isMac: Platform.isMac, level: smoothingLevel, editable: editable,
            inkingTool: toolPicker.selectedToolItem is PKToolPickerInkingItem, rulerActive: canvas.isRulerActive)
        mouseInk.setActive(pointer)
        let lasso = mathLassoHandler != nil && !isReadOnly && !isPreparing && !drawingSuspended
        mathLasso.setActive(lasso)
        let draws = editable && !ours && !pointer
        canvas.drawingGestureRecognizer.isEnabled = draws
        setPencilKitGestures(enabled: draws)
        // The one-page canvas's scroll on an iPhone: one finger, two while annotating (where one
        // draws), as in the paged stack (`PageStackHost.minimumPanTouches`). PencilKit sets the same
        // count itself from the drawing policy (`applyPhoneDrawingPolicy`) whenever it likes, so the
        // two always agree; the object eraser and the math lasso take two while they hold the finger.
        if Platform.isPhone, !isEmbedded, !ours, !lasso {
            canvas.panGestureRecognizer.minimumNumberOfTouches = Self.phonePanTouches(fingerDraws: phoneFingersDraw)
        }
    }

    /// The fingers the one-page canvas's scroll takes on an iPhone: two while a finger draws, else one.
    static func phonePanTouches(fingerDraws: Bool) -> Int { fingerDraws ? 2 : 1 }

    /// iPhone: a finger is ink on this canvas, the note's mode being Annotate (`PhoneCanvasMode`): an
    /// editable note, not suspended (reading) and not in selection mode (the Hand). Taken from the mode,
    /// not from what draws this instant (a text box being typed in, a finger-picked item, a page being
    /// prepared), so the scroll's finger count changes only with the mode.
    var phoneFingersDraw: Bool { !isReadOnly && !drawingSuspended && !itemSelectionActive }

    /// The iPhone's drawing policy follows the mode: `.anyInput` while a finger is ink, else `.pencilOnly`
    /// (no iPhone has a Pencil, so nothing draws).
    ///
    /// PencilKit sets its scroll's `minimumNumberOfTouches` itself, to 2 whenever the policy lets a finger
    /// draw (`-[PKTiledView updateForAllowedDrawingInput]`), and runs that again on its own: when its tiled
    /// view moves to a window, and when the tool picker's visibility changes
    /// (`-[PKTiledView _updateForToolPickerVisibilityChange:]`, a notification that arrives with the
    /// palette's hide animation, about 0.8 s after Annotate goes off). With `.anyInput` kept in reading
    /// mode, that put the pageless note's one-finger scroll back to two fingers a moment after leaving
    /// Annotate (TestFlight build 5). With the policy matching the mode, PencilKit's own count is ours.
    private func applyPhoneDrawingPolicy() {
        let policy: PKCanvasViewDrawingPolicy = phoneFingersDraw ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
    }

    /// PencilKit's recognizers the app turned off along with `drawingGestureRecognizer`
    /// (`setPencilKitGestures`), to turn back on with it.
    private let suppressedGestures = NSHashTable<UIGestureRecognizer>.weakObjects()

    /// PencilKit's other recognizers follow its public drawing one: while the app's own selection,
    /// text tool, object eraser, pointer ink or math lasso has the pointer, none of them may take it.
    /// Turned off, each one that was on is remembered, and only those are turned on again.
    private func setPencilKitGestures(enabled: Bool) {
        if enabled {
            for g in suppressedGestures.allObjects { g.isEnabled = true }
            suppressedGestures.removeAllObjects()
        } else {
            for g in Self.pencilKitGestures(of: canvas) where g.isEnabled {
                g.isEnabled = false
                suppressedGestures.add(g)
            }
        }
    }

    /// PencilKit's own recognizers inside `canvas` besides the public `drawingGestureRecognizer`
    /// (macOS 27 Catalyst; found with gesture traces in the Mac UI tests):
    ///
    /// * A second drawing recognizer on an inner view (`PKTiledGestureView`) that stays on when
    ///   the public one is turned off. Other recognizers wait for it to fail, which it does only
    ///   when the mouse button goes up, so an item drag began at the release and moved nothing.
    /// * The selection interaction's, on `PKSelectionGestureView`, there while the palette's tool
    ///   is the lasso, which it stays when Select or Text is picked: a pan
    ///   (`com.apple.PencilKit.lasso`) and a tap (`com.apple.PencilKit.progressiveTaps`). The pan
    ///   began with an item drag and kept it, so the item never moved ("objects can't be moved
    ///   with the mouse"); the tap's delayed single-tap handler (`_handleSingleTap:`, after the
    ///   double-tap wait) shows PencilKit's edit menu and makes its tiled view the first
    ///   responder, which took the keyboard from the text box the same click had just started
    ///   ("typing into a new text box loses focus").
    static func pencilKitGestures(of canvas: PKCanvasView) -> [UIGestureRecognizer] {
        let drawing = canvas.drawingGestureRecognizer
        var found: [UIGestureRecognizer] = []
        var views: [UIView] = canvas.subviews
        while let view = views.popLast() {
            let selectionView = NSStringFromClass(type(of: view)).contains("PKSelectionGestureView")
            for g in view.gestureRecognizers ?? [] where g !== drawing {
                if selectionView || g.isKind(of: type(of: drawing)) || g.name?.hasPrefix("com.apple.PencilKit.") == true {
                    found.append(g)
                }
            }
            views.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Typing in a text box started or ended: nothing draws or selects
    /// meanwhile; afterwards the palette comes back.
    private func textEditingChanged(_ editing: Bool) {
        updateSelectionMode()
        guard !editing else { return }
        // The text tool is one-shot (`CanvasModes`): the box it started is done, the canvas goes back.
        if placingTextBox {
            placingTextBox = false
            if textToolActive { onTextToolEnded?(.placed) }
        }
        updateToolPicker()
        // A page of the stack takes the palette back itself, unless the edit ended because
        // the user went to a field elsewhere (`CanvasFocus`).
        if isEmbedded { focusUnlessKeyboardElsewhere(container: enclosingStack) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateToolPicker()
    }

    private func updateToolPicker() {
        guard window != nil else { return }
        defer { updateEraser() }
        let show = !isReadOnly && !drawingSuspended && paletteVisible
        toolPicker.setVisible(show, forFirstResponder: canvas)
        // The stack decides which of its pages has the focus (`focus()`); a text box being typed in keeps the keyboard.
        // Never from a field or list that holds the keyboard (`CanvasFocus`).
        if !isEmbedded { focusUnlessKeyboardElsewhere() }
    }

    /// Swaps in a picker of the other size, keeping the selected tool when the
    /// new picker has it.
    private func rebuildToolPicker() {
        guard !isEmbedded else { return }   // the stack swaps its picker for all its pages
        adopt(Self.makePicker(compact: paletteCompact, replacing: toolPicker))
    }

    /// A picker of the given size that keeps `old`'s selected tool when it has it.
    static func makePicker(compact: Bool, replacing old: PKToolPicker?) -> PKToolPicker {
        let new = ToolPalette.makePicker(compact: compact)
        if let old, new.toolItems.contains(where: { $0.identifier == old.selectedToolItemIdentifier }) {
            new.selectedToolItemIdentifier = old.selectedToolItemIdentifier
        }
        new.colorUserInterfaceStyle = .light
        return new
    }

    /// Uses `new` as this canvas's tool picker (a rebuilt one, or the stack's).
    func adopt(_ new: PKToolPicker) {
        let old = toolPicker
        guard new !== old else { return }
        old.setVisible(false, forFirstResponder: canvas)
        old.removeObserver(canvas)
        old.removeObserver(self)
        new.addObserver(canvas)
        new.addObserver(self)
        toolPicker = new
        updateToolPicker()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        if isEmbedded { layer.shadowPath = UIBezierPath(rect: bounds).cgPath }
        fitWidth()
        applyReveal()
        #if DEBUG
        if debugLaunchPending, bounds.width > 0 {
            debugLaunchPending = false
            DebugLaunch.canvasDidLayOut(self)
        }
        #endif
    }

    #if DEBUG
    private var debugLaunchPending = DebugLaunch.isActive
    #endif

    func apply(paper: Paper, pageSize: PageSize) {
        self.paper = paper
        self.pageSize = Self.displayable(pageSize)
        if inkMaxY == nil { inkMaxY = Self.inkBottom(canvas.drawing) }
        fitWidth(force: true)
    }

    /// The drawing changed (loaded, drawn on, erased): the scrollable extent
    /// follows its ink. `measured`: the drawing's bounds as already known
    /// (`NoteEditor.takeMeasuredInk`), else PencilKit measures them.
    func inkDidChange(measured: CGRect? = nil) {
        #if DEBUG
        if measured == nil { boundsMeasured &+= 1 }
        itemSelection.debugRefreshReport()   // the report's stroke count
        #endif
        inkMaxY = Self.inkBottom(measured ?? canvas.drawing.bounds)
        zoomChanged()
    }

    #if DEBUG
    /// How often `inkDidChange` asked PencilKit for `drawing.bounds` (it walks every stroke):
    /// a pen-up must take the extent the editor's ledger measured instead (finding P17, check c52).
    private(set) var boundsMeasured = 0
    #endif

    private static func inkBottom(_ drawing: PKDrawing) -> Double? {
        inkBottom(drawing.bounds)
    }

    private static func inkBottom(_ bounds: CGRect) -> Double? {
        bounds.isNull || bounds.isEmpty ? nil : Double(bounds.maxY)
    }

    private func updateFooter() {
        var config = UIButton.Configuration.bordered()
        switch footer {
        case .none:
            footerButton.isHidden = true
        case .addPage:
            config.title = String(localized: "Add Page")
            config.image = UIImage(systemName: "doc.badge.plus")
            footerButton.isHidden = false
        case .nextPage:
            config.title = String(localized: "Next Page")
            config.image = UIImage(systemName: "chevron.down")
            footerButton.isHidden = false
        }
        config.imagePadding = 8
        config.buttonSize = .large
        footerButton.configuration = config
        footerButton.accessibilityIdentifier = "pageFooter"
        zoomChanged()
    }

    /// `size` with width and height clamped to 1 ... `RenderLimits.maxExtent`
    /// points (letter for non-finite values), so a corrupt page size cannot
    /// produce an absurd zoom scale or content size.
    static func displayable(_ size: PageSize) -> PageSize {
        func clamp(_ v: Double, _ fallback: Double) -> Double {
            v.isFinite ? min(max(v, 1), RenderLimits.maxExtent) : fallback
        }
        var s = size
        s.width = clamp(size.width, PageSize.letter.width)
        s.height = clamp(size.height, PageSize.letter.height)
        return s
    }

    func scrollToTop() {
        canvas.setContentOffset(.zero, animated: false)
    }

    /// The scale at which the page fills the width (0 before layout); the zoom range is
    /// `ZoomDetent.minimum` (half of it, a phone: the fit) to 4x of it.
    var fitScale: CGFloat { fittedWidth }

    /// Zoom range: from `ZoomDetent.minimum` of the fitted width (half of it; the fit on an
    /// iPhone) to 4x (a page of the stack: its frame is the page at the stack's scale, so the
    /// fit is that scale, and it never zooms itself).
    ///
    /// The zoom is set only when the fit itself changed (the first layout, a rotation, a split
    /// view, another page size): `force` (every SwiftUI update, `apply(paper:pageSize:)`) only
    /// renews the range. It used to put a canvas within 0.1 % of the fit back on the fit at every
    /// update, and an update in the middle of a pinch that passed the fit snapped the zoom
    /// under the fingers (TestFlight 1.0.0 (6): "the zoom jostles around a bit").
    private func fitWidth(force: Bool = false) {
        guard bounds.width > 0, pageSize.width > 0 else { return }
        let fit = bounds.width / CGFloat(pageSize.width)
        if fit != fittedWidth || force {
            let refit = fit != fittedWidth
            let wasFitted = fittedWidth == 0 || abs(canvas.zoomScale - fittedWidth) < fittedWidth * 0.001
            fittedWidth = fit
            let minimum = isEmbedded ? fit : CGFloat(ZoomDetent.minimum(fit: Double(fit), paged: false, isPhone: Platform.isPhone))
            // A page of the stack is zoomed by the stack: its own scale is pinned to the fit.
            let maximum = isEmbedded ? fit : fit * CGFloat(ZoomSteps.maxFactor)
            canvas.minimumZoomScale = minimum
            canvas.maximumZoomScale = maximum
            if isEmbedded {
                // Its own pinch must never take the fingers from the stack's (`PageStackHost`).
                canvas.pinchGestureRecognizer?.isEnabled = false
                if canvas.zoomScale != fit { canvas.zoomScale = fit }
            } else if !canvas.isZooming, !canvas.isZoomBouncing {
                if refit && wasFitted {
                    canvas.zoomScale = fit
                } else if canvas.zoomScale < minimum || canvas.zoomScale > maximum {
                    canvas.zoomScale = min(max(canvas.zoomScale, minimum), maximum)
                }
            }
        }
        zoomChanged()
    }

    /// A pinch on the one-page canvas ended: within `ZoomDetent.snapBand` of
    /// the fitted width it settles exactly there; below it the page zooms out
    /// to half the fit, centered (an iPhone stops at the fit). The stack
    /// settles its own pinches (`PageStackHost.bake`).
    func zoomEnded() {
        guard !isEmbedded, fittedWidth > 0 else { return }
        zoomChanged()   // the last frame's extent and margins (an animated settle ends here too)
        let z = Double(canvas.zoomScale), fit = Double(fittedWidth)
        let target = ZoomDetent.settle(z, fit: fit, paged: false, isPhone: Platform.isPhone)
        guard abs(target - z) > fit * 0.001 else { return }
        canvas.setZoomScale(CGFloat(target), animated: true)
        if ZoomDetent.isFit(target, fit: fit) { Self.snapFeedback() }
    }

    /// The tick a pinch gives when it settles on the fitted width.
    static func snapFeedback() {
        guard !Platform.isMac else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Content size and paper follow the zoom (`PageExtent`): an infinite
    /// page scrolls a screen beyond its ink and its stored height; a finite
    /// page ends with room for the Add Page / Next Page button.
    func zoomChanged() {
        let z = canvas.zoomScale
        guard z > 0 else { return }
        cursorInteraction?.invalidate()
        let height = PageExtent.scrollHeight(pageSize: pageSize, inkMaxY: inkMaxY,
                                             viewportHeight: Double(bounds.height / z),
                                             footerHeight: footer == .none ? 0 : Double(PageExtent.footerScreenHeight / z))
        let paperHeight = pageSize.infinite ? height : pageSize.height
        let size = CGSize(width: CGFloat(pageSize.width), height: CGFloat(paperHeight))
        paperView.setVisible(canvas.bounds)   // only the bands on screen are built
        paperView.configure(paper: paper, size: size, sheetHeight: PaperRenderer.sheetHeight(for: pageSize))
        paperView.setZoom(z)
        canvas.contentSize = CGSize(width: size.width * z, height: CGFloat(height) * z)
        if !isEmbedded {
            // Zoomed out below the fit: the page stands in the middle.
            // (Under half a point is rounding at the fit, not a margin: no sideways scroll there.)
            let margin = PageStackHost.sideMargin(contentWidth: canvas.contentSize.width, viewWidth: bounds.width)
            let side = margin < 0.5 ? 0 : margin
            if canvas.contentInset.left != side || canvas.contentInset.right != side {
                canvas.contentInset.left = side
                canvas.contentInset.right = side
            }
        }
        itemLayer.frame = CGRect(origin: .zero, size: canvas.contentSize)
        itemLayer.setZoom(z)
        textOverlay.frame = itemLayer.frame
        textOverlay.setZoom(z)
        if !textOverlay.isHidden { canvas.bringSubviewToFront(textOverlay) }
        itemSelection.refresh()
        textEditor.layoutTextView()
        if footer != .none {
            footerButton.sizeToFit()
            let b = footerButton.bounds.size
            footerButton.frame = CGRect(x: (canvas.contentSize.width - b.width) / 2,
                                        y: CGFloat(pageSize.height) * z + (PageExtent.footerScreenHeight - b.height) / 2,
                                        width: b.width, height: b.height)
        }
        layoutHighlights()
        applyReveal()
    }

    /// Shows `boxes` (page points) as highlights; the current match stands out.
    func setHighlights(_ boxes: [HighlightBox]) {
        guard boxes != highlights else { return }
        highlights = boxes
        layoutHighlights()
    }

    /// Scrolls so the current highlight is on screen (centered unless it is already comfortably visible).
    func revealHighlight() {
        guard let current = highlights.first(where: \.isCurrent) else { return }
        pendingReveal = current.box
        applyReveal()
    }

    /// At most this many highlights are drawn on a page.
    private static let maxHighlights = 500

    private func layoutHighlights() {
        let z = canvas.zoomScale
        highlightView.frame = CGRect(origin: .zero, size: canvas.contentSize)
        let shown = highlights.prefix(Self.maxHighlights)
        var layers = highlightView.layer.sublayers ?? []
        while layers.count > shown.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < shown.count {
            let layer = CALayer()
            layer.cornerRadius = 3
            highlightView.layer.addSublayer(layer)
            layers.append(layer)
        }
        for (layer, h) in zip(layers, shown) {
            layer.frame = CGRect(x: h.box.x * z, y: h.box.y * z, width: h.box.w * z, height: h.box.h * z).insetBy(dx: -2, dy: -2)
            switch h.style {
            case .search:
                layer.backgroundColor = (h.isCurrent ? UIColor.systemOrange.withAlphaComponent(0.5)
                                                     : UIColor.systemYellow.withAlphaComponent(0.4)).cgColor
            case .playback:
                layer.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.3).cgColor
            }
            layer.borderColor = UIColor.systemOrange.cgColor
            layer.borderWidth = h.isCurrent ? 2 : 0
        }
    }

    private func applyReveal() {
        guard let box = pendingReveal, bounds.width > 0, canvas.contentSize.height > 0, canvas.zoomScale > 0 else { return }
        pendingReveal = nil
        let z = canvas.zoomScale
        let rect = CGRect(x: box.x * z, y: box.y * z, width: box.w * z, height: box.h * z)
        let comfortable = CGRect(origin: canvas.contentOffset, size: bounds.size).insetBy(dx: 0, dy: bounds.height * 0.15)
        if comfortable.contains(rect) { return }
        let maxX = max(canvas.contentSize.width - bounds.width, 0), maxY = max(canvas.contentSize.height - bounds.height, 0)
        canvas.setContentOffset(CGPoint(x: min(max(rect.midX - bounds.width / 2, 0), maxX),
                                        y: min(max(rect.midY - bounds.height / 2, 0), maxY)), animated: true)
    }
}

/// How far a page scrolls.
enum PageExtent {
    /// The control below a finite page.
    enum Footer: Equatable { case none, addPage, nextPage }

    /// Screen points below a finite page for its footer button.
    static let footerScreenHeight: CGFloat = 120

    /// The scrollable height of a page in page points.
    ///
    /// - Infinite pages always scroll at least one screen (`viewportHeight`,
    ///   in page points at the current zoom) below both the ink and the
    ///   stored height, so there is always room to keep writing; the stored
    ///   height grows as the user writes (`NoteEditor.growPage`) and this
    ///   follows it.
    /// - Finite pages end at their height plus `footerHeight` (the Add Page /
    ///   Next Page button), and never less than a screen.
    ///
    /// Every term is clamped to `RenderLimits.maxExtent` (non-finite: 0), so
    /// a stroke or page size far out of range cannot produce an absurd
    /// content size.
    static func scrollHeight(pageSize: PageSize, inkMaxY: Double?, viewportHeight: Double, footerHeight: Double = 0) -> Double {
        func clamped(_ v: Double?) -> Double {
            guard let v, v.isFinite else { return 0 }
            return min(max(v, 0), RenderLimits.maxExtent)
        }
        let screen = clamped(viewportHeight)
        let page = clamped(pageSize.height)
        if pageSize.infinite {
            return max(page, clamped(inkMaxY)) + screen
        }
        return max(page + clamped(footerHeight), screen)
    }
}

// MARK: - Menu commands (Mac)

extension PageCanvasHost: CanvasCommandTarget {
    @discardableResult
    func select(tool choice: ToolChoice) -> Bool {
        guard !isReadOnly, let item = toolPicker.toolItems.first(where: { choice.matches($0) }) else { return false }
        toolPicker.selectedToolItemIdentifier = item.identifier
        endTransientSelection()
        updateEraser()
        cursorInteraction?.invalidate()
        return true
    }

    func zoom(in zoomingIn: Bool) {
        guard fittedWidth > 0 else { return }
        let target = ZoomSteps.step(from: Double(canvas.zoomScale), fit: Double(fittedWidth), zoomingIn: zoomingIn)
        canvas.setZoomScale(CGFloat(target), animated: true)
    }

    func zoomToFit() {
        guard fittedWidth > 0 else { return }
        canvas.setZoomScale(fittedWidth, animated: true)
    }

    func zoomToActualSize() {
        guard fittedWidth > 0 else { return }
        canvas.setZoomScale(CGFloat(ZoomSteps.actualSize(fit: Double(fittedWidth))), animated: true)
    }

    func toggleRuler() {
        guard !isReadOnly else { return }
        canvas.isRulerActive.toggle()
        updateEraser()
    }

    @discardableResult
    func perform(itemCommand: MenuCommand) -> Bool {
        guard !isReadOnly else { return false }
        return itemSelection.perform(itemCommand)
    }
}
