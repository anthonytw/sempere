import Sempere
import PencilKit
import SwiftUI
import UIKit

/// A paged note on the canvas: every page in one vertical scroll, a gap and
/// a shadow between pages, the Add Page button below the last one
/// (`PageStackLayout`). Pages get a canvas (`PageCanvasHost`, embedded) only
/// while they are on screen or within a screen of it, so a note of hundreds
/// of pages draws a handful; each page's ink comes from the editor's
/// `readyDrawing` / `prepareDrawing` (the drawing cache) as on the one-page
/// canvas. Zoom applies to all pages; the current page (`NoteEditor.pageIndex`)
/// follows the scroll, and `NoteEditor.pageJump` scrolls to a page chosen
/// elsewhere. Pageless notes keep `PageCanvasView`.
struct PageStackView: UIViewRepresentable {
    let editor: NoteEditor
    /// The note's pages, top to bottom (`editor.pages`' ids).
    let pageIDs: [UUID]
    let pageSize: PageSize
    /// `NoteEditor.pageJump`: a change scrolls to the current page.
    var pageJump = 0
    var paletteVisible = true
    var paletteCompact = false
    var drawingSuspended = false
    /// `NoteEditor.canvasGeneration`: a change reloads every page's ink.
    var generation = 0
    var itemSource = ItemLayerSource()
    var itemCommands = ItemCommands()
    var selectingItems = false
    var onSelectingItemsEnded: () -> Void = {}
    /// The text tool (`PageCanvasContent.addingText`).
    var addingText = false
    var onAddingTextEnded: () -> Void = {}
    /// Images and PDFs dropped on a page (`PageCanvasContent.onDrop`).
    var onDrop: ((_ providers: [NSItemProvider], _ pageID: UUID, _ point: CGPoint) -> Void)?

    func makeUIView(context: Context) -> PageStackHost {
        PageStackHost()
    }

    func updateUIView(_ stack: PageStackHost, context: Context) {
        editor.canvasTarget = stack
        stack.update(PageStackHost.Configuration(
            editor: editor, pageIDs: pageIDs, pageSize: pageSize, pageJump: pageJump, generation: generation,
            paletteVisible: paletteVisible, paletteCompact: paletteCompact, drawingSuspended: drawingSuspended,
            itemSource: itemSource, itemCommands: itemCommands, selectingItems: selectingItems,
            onSelectingItemsEnded: onSelectingItemsEnded, addingText: addingText, onAddingTextEnded: onAddingTextEnded,
            onDrop: onDrop))
    }

    static func dismantleUIView(_ stack: PageStackHost, coordinator: ()) {
        let editor = stack.editor
        stack.tearDown()
        Task { await editor?.flush() }
    }
}

/// UIKit side of `PageStackView`: a scroll view over a content view that
/// holds one embedded `PageCanvasHost` per page near the screen.
///
/// Zoom: the scroll view zooms the content view natively during a pinch (a
/// transform, so the ink is briefly scaled as a bitmap); when the pinch ends
/// the scale is baked in (`bake`): the transform goes back to identity and
/// every page canvas is laid out again at the new scale, so PencilKit draws
/// the ink sharp. `scale` is screen points per page point between pinches.
final class PageStackHost: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// What the stack shows (`PageStackView`'s properties).
    struct Configuration {
        var editor: NoteEditor
        var pageIDs: [UUID]
        var pageSize: PageSize
        var pageJump = 0
        var generation = 0
        var paletteVisible = true
        var paletteCompact = false
        var drawingSuspended = false
        var itemSource = ItemLayerSource()
        var itemCommands = ItemCommands()
        var selectingItems = false
        var onSelectingItemsEnded: () -> Void = {}
        var addingText = false
        var onAddingTextEnded: () -> Void = {}
        var onDrop: ((_ providers: [NSItemProvider], _ pageID: UUID, _ point: CGPoint) -> Void)?
    }

    /// One page's canvas and the coordinator that loads its ink.
    struct Slot {
        let host: PageCanvasHost
        let coordinator: PageCanvasView.Coordinator
    }

    let scroller = UIScrollView()
    /// Holds the pages and the footer; what the scroll view zooms during a pinch.
    let content = UIView()
    /// Add Page, below the last page.
    let footerButton = UIButton(configuration: .bordered())
    /// One palette for all pages: each page's canvas observes it.
    private(set) var toolPicker = PageCanvasHost.makePicker(compact: ToolPalette.isCompact(), replacing: nil)
    private(set) var editor: NoteEditor?
    private(set) var configuration: Configuration?
    /// Canvases of the pages on screen and within a screen of it, by page id.
    private(set) var slots: [UUID: Slot] = [:]
    /// Canvases off screen, kept for reuse (at most `spareLimit`).
    private(set) var spares: [Slot] = []
    static let spareLimit = 3
    private(set) var layout = PageStackLayout(pageWidth: 612, pageHeight: 792, count: 0)
    /// Screen points per page point; 0 before the first layout.
    private(set) var scale: CGFloat = 0
    /// Whether the scale follows the width (the page fills it): true until the user zooms.
    private var fitted = true
    private var laidOutWidth: CGFloat = 0
    private var tracker = PageScrollTracker()
    private var appliedJump: Int?
    /// A jump waits for the first layout (no size yet) or the end of a pinch.
    private(set) var pendingJump = false
    /// `NoteEditor.revealToken` last acted on (scroll to the current search match).
    private var appliedReveal: Int?
    /// A reveal waits for the jump to the match's page, the first layout or the end of a pinch.
    private(set) var pendingReveal = false
    private var baking = false
    private var paletteCompact = ToolPalette.isCompact()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        scroller.delegate = self
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.alwaysBounceVertical = true
        scroller.bouncesZoom = true
        // Touches reach the page canvases at once: a Pencil stroke must not wait for a scroll to fail.
        scroller.delaysContentTouches = false
        scroller.accessibilityIdentifier = "pageStack"
        content.accessibilityIdentifier = "pageStack.content"
        scroller.addSubview(content)
        addSubview(scroller)
        // A swipe to the left or right turns the page while an iPhone is only reading
        // (`PhoneReading.swipeTurnsPages`); the recognizers do nothing otherwise.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            swipe.name = direction == .left ? "pageSwipeLeft" : "pageSwipeRight"
            scroller.addGestureRecognizer(swipe)
        }
        footerButton.isHidden = true
        footerButton.accessibilityIdentifier = "pageFooter"
        var config = UIButton.Configuration.bordered()
        config.title = String(localized: "Add Page")
        config.image = UIImage(systemName: "doc.badge.plus")
        config.imagePadding = 8
        config.buttonSize = .large
        footerButton.configuration = config
        footerButton.addAction(UIAction { [weak self] _ in self?.editor?.addPage() }, for: .primaryActionTriggered)
        content.addSubview(footerButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Configuration

    /// Shows `configuration`: pages, sizes, flags; scrolls to the current
    /// page when the editor changed or `pageJump` moved.
    func update(_ configuration: Configuration) {
        let editor = configuration.editor
        let newEditor = self.editor !== editor
        self.configuration = configuration
        self.editor = editor
        if configuration.paletteCompact != paletteCompact {
            paletteCompact = configuration.paletteCompact
            let picker = PageCanvasHost.makePicker(compact: paletteCompact, replacing: toolPicker)
            toolPicker = picker
            for slot in Array(slots.values) + spares { slot.host.adopt(picker) }
        }
        let size = PageCanvasHost.displayable(configuration.pageSize)
        let footer = !editor.isReadOnly && !configuration.drawingSuspended
        layout = PageStackLayout(pageWidth: size.width, pageHeight: size.height, count: configuration.pageIDs.count,
                                 footerScreenHeight: footer ? Double(PageExtent.footerScreenHeight) : 0)
        footerButton.isHidden = !footer
        if newEditor {
            for id in Array(slots.keys) { recycle(id) }
            tracker = PageScrollTracker()
            fitted = true
            appliedJump = configuration.pageJump
            pendingJump = true
            // A note opened from a search hit may have highlighted it before the stack saw the editor.
            appliedReveal = editor.revealToken
            pendingReveal = editor.searchCursor != nil
        } else if appliedJump != configuration.pageJump {
            appliedJump = configuration.pageJump
            pendingJump = true
        }
        if appliedReveal != editor.revealToken {
            appliedReveal = editor.revealToken
            pendingReveal = true
        }
        // Stepping to a search match selects its page too: the reveal alone scrolls,
        // so a match already on screen does not first send the page to the top.
        if pendingJump, pendingReveal, let match = editor.searchCursor?.current, match.pageId == editor.currentPage?.id {
            pendingJump = false
        }
        layoutContent()
        if pendingJump { performJump() }
        if pendingReveal { performReveal() }
        updateSlots()
        updateGestures()
    }

    /// The stack goes away: every load stops and every canvas is dropped.
    func tearDown() {
        for id in Array(slots.keys) { recycle(id) }
        for slot in spares { slot.coordinator.forget(host: slot.host) }
        spares = []
        if editor?.canvasTarget === self { editor?.canvasTarget = nil }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroller.frame != bounds { scroller.frame = bounds }
        if bounds.width != laidOutWidth {
            defer { updateSlots() }   // every page at the new scale
            let old = scale
            let offset = scroller.contentOffset
            laidOutWidth = bounds.width
            layoutContent()
            if old > 0, scale != old, scroller.zoomScale == 1 {
                // A new width (rotation, split view): the top of the screen keeps its place in the note.
                let size = scroller.contentSize
                let y = PageStackLayout.rescaledOffset(Double(offset.y), anchor: 0, from: Double(old), to: Double(scale),
                                                       contentLength: Double(size.height),
                                                       viewport: Double(scroller.bounds.height))
                scroller.contentOffset = CGPoint(x: 0, y: CGFloat(y))
            }
        }
        if pendingJump { performJump() }
        if pendingReveal { performReveal() }
        updateSlots(reconfigure: false)
        #if DEBUG
        if debugLaunchPending, bounds.width > 0, editor != nil {
            debugLaunchPending = false
            DebugLaunch.stackDidLayOut(self)
        }
        #endif
    }

    #if DEBUG
    private var debugLaunchPending = DebugLaunch.isActive
    #endif

    /// The scale at which a page fills the width; nil before layout.
    var fitScale: CGFloat? {
        layout.fitScale(viewWidth: Double(bounds.width)).map { CGFloat($0) }
    }

    /// Sizes the content for `scale` (the fit unless the user zoomed) and
    /// places the footer. Leaves the pages to `updateSlots`.
    private func layoutContent() {
        guard let fit = fitScale else { return }
        let maxScale = fit * CGFloat(ZoomSteps.maxFactor)
        scale = scale == 0 || fitted ? fit : min(max(scale, fit), maxScale)
        // During a pinch the content carries the zoom's transform: it is sized when the pinch ends.
        guard scroller.zoomScale == 1 else { return }
        let size = layout.contentSize(scale: Double(scale))
        content.frame = CGRect(origin: .zero, size: size)
        scroller.contentSize = size
        scroller.minimumZoomScale = fit / scale
        scroller.maximumZoomScale = maxScale / scale
        placeFooter()
        // Fewer pages (a delete) or a smaller scale: never left past the end. Not while
        // the user's finger or a fling moves the scroll (its bounce is the scroll view's).
        if !scroller.isDragging, !scroller.isDecelerating {
            let offset = clamped(scroller.contentOffset)
            if offset != scroller.contentOffset { scroller.contentOffset = offset }
        }
    }

    private func placeFooter() {
        guard !footerButton.isHidden else { return }
        footerButton.sizeToFit()
        let b = footerButton.bounds.size
        footerButton.frame = CGRect(x: (content.bounds.width - b.width) / 2,
                                    y: CGFloat(layout.footerTop(scale: Double(scale))) + (PageExtent.footerScreenHeight - b.height) / 2,
                                    width: b.width, height: b.height)
    }

    /// The visible part of the content, in the content's own coordinates (at `scale`).
    var visibleContentRect: CGRect {
        content.convert(scroller.bounds, from: scroller)
    }

    /// Gives a canvas to each page near the screen and takes it from the
    /// others. New canvases are configured; with `reconfigure` (the note, the
    /// flags or the scale changed) every canvas shown is, while a plain
    /// scroll leaves the others alone.
    func updateSlots(reconfigure: Bool = true) {
        guard let editor, let configuration, scale > 0 else { return }
        let visible = visibleContentRect
        let wanted = layout.pages(visibleTop: Double(visible.minY), height: Double(visible.height),
                                  scale: Double(scale), margin: Double(visible.height))
        let ids = configuration.pageIDs
        var keep: [Int: UUID] = [:]
        for i in wanted where ids.indices.contains(i) { keep[i] = ids[i] }
        let kept = Set(keep.values)
        for id in Array(slots.keys) where !kept.contains(id) { recycle(id) }
        for (index, id) in keep.sorted(by: { $0.key < $1.key }) {
            if let slot = slots[id] {
                if reconfigure { configure(slot, index: index, pageID: id, editor: editor, configuration: configuration) }
            } else {
                let slot = makeSlot()
                slots[id] = slot
                configure(slot, index: index, pageID: id, editor: editor, configuration: configuration)
            }
        }
        ensureFocus()
    }

    private func configure(_ slot: Slot, index: Int, pageID: UUID, editor: NoteEditor, configuration: Configuration) {
        let frame = layout.pageFrame(index, scale: Double(scale))
        if !Self.sameFrame(slot.host.frame, frame) { slot.host.frame = frame }
        let page: Page
        if editor.pages.indices.contains(index), editor.pages[index].id == pageID {
            page = editor.pages[index]
        } else if let found = editor.pages.first(where: { $0.id == pageID }) {
            page = found
        } else {
            return
        }
        slot.host.footer = .none
        slot.host.paletteVisible = configuration.paletteVisible
        slot.coordinator.apply(
            editor: editor, pageID: pageID,
            content: PageCanvasContent(paper: editor.displayedPaper(of: page), pageSize: configuration.pageSize,
                                       generation: configuration.generation,
                                       drawingSuspended: configuration.drawingSuspended,
                                       itemSource: configuration.itemSource, itemCommands: configuration.itemCommands,
                                       selectingItems: configuration.selectingItems,
                                       onSelectingItemsEnded: configuration.onSelectingItemsEnded,
                                       onDrop: configuration.onDrop, addingText: configuration.addingText,
                                       onAddingTextEnded: configuration.onAddingTextEnded),
            to: slot.host)
        slot.host.itemSelection.scroller = scroller
    }

    private func makeSlot() -> Slot {
        let slot: Slot
        if let spare = spares.popLast() {
            slot = spare
        } else {
            let host = PageCanvasHost(frame: .zero, sharedPicker: toolPicker)
            let coordinator = PageCanvasView.Coordinator()
            host.canvas.delegate = coordinator
            slot = Slot(host: host, coordinator: coordinator)
        }
        content.insertSubview(slot.host, belowSubview: footerButton)
        return slot
    }

    /// Takes the canvas from page `id`: its ink is dropped (the editor keeps
    /// the page's ledger and the drawing it showed) and it waits for reuse.
    private func recycle(_ id: UUID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.host.textEditor.endEditing()   // a box being typed in is written before its page goes
        slot.coordinator.forget(host: slot.host)
        slot.host.removeFromSuperview()
        if spares.count < Self.spareLimit { spares.append(slot) }
    }

    /// Some page on screen has the focus (the palette shows for the first
    /// responder): the current page's, unless the user drew on another.
    private func ensureFocus() {
        guard window != nil else { return }
        // A page being drawn on, or a text box being typed in, already has it.
        if slots.values.contains(where: { $0.host.canvas.isFirstResponder || $0.host.textEditor.isEditing }) { return }
        guard let id = editor?.currentPage?.id, let slot = slots[id] else { return }
        slot.host.focus()
    }

    /// Fingers and the Pencil: while the pages can be drawn on, the Pencil
    /// (and on a Mac the pointer) draws and never scrolls, and when fingers
    /// draw too, scrolling takes two (as on PencilKit's own canvas).
    private func updateGestures() {
        guard let editor, let configuration else { return }
        let drawing = !editor.isReadOnly && !configuration.drawingSuspended && !configuration.selectingItems
            && !configuration.addingText
        let pan = scroller.panGestureRecognizer
        pan.allowedTouchTypes = Self.panTouchTypes(drawing: drawing, isMac: Platform.isMac)
        pan.minimumNumberOfTouches = Self.minimumPanTouches(drawing: drawing, fingersDraw: fingersDraw)
    }

    // MARK: - Swipe to turn pages (iPhone, reading)

    /// Whether a swipe turns the page now.
    var swipeTurnsPages: Bool {
        PhoneReading.swipeTurnsPages(isPhone: Platform.isPhone, drawingSuspended: configuration?.drawingSuspended ?? false,
                                     zoomed: scroller.zoomScale > 1.001 || !fitted, pageCount: configuration?.pageIDs.count ?? 0)
    }

    /// One selector for both: `UIView`'s (this view's own recognizers) and the delegate's (the
    /// page swipes on the scroller). Anything but a page swipe gets `UIView`'s answer.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UISwipeGestureRecognizer, gestureRecognizer.view === scroller else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return swipeTurnsPages
    }

    /// The vertical scroll and a pinch go on while the swipe is being recognised.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UISwipeGestureRecognizer
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        turnPage(towardsLeft: swipe.direction == .left)
    }

    /// Shows the next page (a swipe to the left) or the previous one; nothing at the ends or
    /// where swiping does not turn pages.
    func turnPage(towardsLeft: Bool) {
        guard swipeTurnsPages, let editor, let count = configuration?.pageIDs.count,
              let target = PhoneReading.pageAfterSwipe(from: editor.pageIndex, towardsLeft: towardsLeft,
                                                        pageCount: count) else { return }
        editor.selectPage(target)
    }

    /// Frames equal up to UIKit's rounding (a frame set reads back a few ulps off).
    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// The touch types that scroll the stack.
    static func panTouchTypes(drawing: Bool, isMac: Bool) -> [NSNumber] {
        var types: [UITouch.TouchType] = [.direct, .indirect]
        if !drawing { types.append(.pencil) }
        if !drawing || !isMac { types.append(.indirectPointer) }
        return types.map { NSNumber(value: $0.rawValue) }
    }

    /// Two fingers scroll while one finger draws.
    static func minimumPanTouches(drawing: Bool, fingersDraw: Bool) -> Int {
        drawing && fingersDraw ? 2 : 1
    }

    /// Whether a finger draws on the pages (their drawing policy, `ObjectEraserController.fingersDraw`).
    private var fingersDraw: Bool {
        if let slot = slots.values.first ?? spares.first { return ObjectEraserController.fingersDraw(slot.host.canvas) }
        return Platform.isMac || Platform.isPhone || !UIPencilInteraction.prefersPencilOnlyDrawing
    }

    // MARK: - Scrolling and the current page

    /// Scrolls so the editor's current page is at the top of the screen.
    private func performJump() {
        guard let editor, scale > 0, bounds.height > 0, scroller.zoomScale == 1 else { return }
        pendingJump = false
        let index = editor.pageIndex
        let y = CGFloat(layout.offset(toShow: index, scale: Double(scale), viewportHeight: Double(scroller.bounds.height)))
        tracker.jumped(to: index, offset: Double(y))
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: y), animated: false)
        updateSlots(reconfigure: false)
    }

    /// Scrolls so the current search match (`NoteEditor.searchCursor`) is on
    /// screen, after the jump to its page; its page stays the current one.
    /// The embedded canvases never scroll, so their own reveal is not used.
    private func performReveal() {
        guard let editor, scale > 0, bounds.height > 0, scroller.zoomScale == 1, !pendingJump else { return }
        pendingReveal = false
        guard let match = editor.searchCursor?.current,
              let index = configuration?.pageIDs.firstIndex(of: match.pageId) else { return }
        let view = scroller.bounds.size, now = scroller.contentOffset
        guard let target = layout.revealOffset(of: (match.box.x, match.box.y, match.box.w, match.box.h), onPage: index,
                                               scale: Double(scale), offset: (Double(now.x), Double(now.y)),
                                               viewport: (Double(view.width), Double(view.height))) else { return }
        tracker.jumped(to: index, offset: target.y)
        scroller.setContentOffset(CGPoint(x: CGFloat(target.x), y: CGFloat(target.y)), animated: false)
        updateSlots(reconfigure: false)
    }

    /// Tells the editor which page the scroll is on.
    private func trackCurrentPage() {
        // A jump is waiting (another note, a chosen page): the offset it replaces says nothing.
        guard let editor, scale > 0, !pendingJump else { return }
        let visible = visibleContentRect
        let positional = layout.currentPage(visibleTop: Double(visible.minY), height: Double(visible.height),
                                            scale: Double(scale))
        guard let page = tracker.current(at: Double(scroller.contentOffset.y), positional: positional) else { return }
        if page != editor.pageIndex { editor.scrolledToPage(page) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !baking else { return }
        updateSlots(reconfigure: false)
        trackCurrentPage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        content
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !baking else { return }
        updateSlots(reconfigure: false)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale zoom: CGFloat) {
        bake()
    }

    /// Turns the pinch's transform into the page scale: the pages are laid
    /// out again at `scale × zoom`, the screen showing the same part of the note.
    func bake() {
        let zoom = scroller.zoomScale
        guard zoom != 1, scale > 0, let fit = fitScale else { return }
        let offset = scroller.contentOffset
        baking = true
        scroller.zoomScale = 1
        baking = false
        let new = min(max(scale * zoom, fit), fit * CGFloat(ZoomSteps.maxFactor))
        fitted = abs(new - fit) < fit * 0.001
        scale = new
        layoutContent()
        scroller.contentOffset = clamped(offset)
        if pendingJump { performJump() }
        if pendingReveal { performReveal() }
        updateSlots()
        trackCurrentPage()
    }

    /// Sets the page scale (menu zoom commands), keeping the middle of the screen in place.
    func setScale(_ target: CGFloat) {
        guard scale > 0, scroller.zoomScale == 1, let fit = fitScale else { return }
        let old = scale
        let new = min(max(target, fit), fit * CGFloat(ZoomSteps.maxFactor))
        guard new != old else { return }
        let offset = scroller.contentOffset
        fitted = abs(new - fit) < fit * 0.001
        scale = new
        layoutContent()
        let size = scroller.contentSize, view = scroller.bounds.size
        let x = PageStackLayout.rescaledOffset(Double(offset.x), anchor: Double(view.width / 2), from: Double(old),
                                               to: Double(new), contentLength: Double(size.width), viewport: Double(view.width))
        let y = PageStackLayout.rescaledOffset(Double(offset.y), anchor: Double(view.height / 2), from: Double(old),
                                               to: Double(new), contentLength: Double(size.height), viewport: Double(view.height))
        scroller.contentOffset = CGPoint(x: CGFloat(x), y: CGFloat(y))
        updateSlots()
        trackCurrentPage()
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
        let size = scroller.contentSize, view = scroller.bounds.size
        return CGPoint(
            x: CGFloat(PageStackLayout.clampedOffset(Double(offset.x), contentLength: Double(size.width), viewport: Double(view.width))),
            y: CGFloat(PageStackLayout.clampedOffset(Double(offset.y), contentLength: Double(size.height), viewport: Double(view.height))))
    }

    /// The canvas with the focus, else the current page's (menu commands).
    var focusedSlot: Slot? {
        slots.values.first { $0.host.canvas.isFirstResponder } ?? editor?.currentPage.flatMap { slots[$0.id] }
    }
}

// MARK: - Menu commands (Mac)

extension PageStackHost: CanvasCommandTarget {
    @discardableResult
    func select(tool choice: ToolChoice) -> Bool {
        guard let editor, !editor.isReadOnly,
              let item = toolPicker.toolItems.first(where: { choice.matches($0) }) else { return false }
        toolPicker.selectedToolItemIdentifier = item.identifier
        for slot in slots.values { slot.host.toolDidChange() }
        return true
    }

    func zoom(in zoomingIn: Bool) {
        guard let fit = fitScale, scale > 0 else { return }
        setScale(CGFloat(ZoomSteps.step(from: Double(scale), fit: Double(fit), zoomingIn: zoomingIn)))
    }

    func zoomToFit() {
        guard let fit = fitScale else { return }
        setScale(fit)
    }

    func zoomToActualSize() {
        guard let fit = fitScale else { return }
        setScale(CGFloat(ZoomSteps.actualSize(fit: Double(fit))))
    }

    /// The visible part of the current page (where Photos, the camera and Paste put an image).
    var visiblePageRect: CGRect? {
        guard let editor, let page = editor.currentPage else { return nil }
        return visibleRect(ofPage: page.id)
    }

    func visibleRect(ofPage id: UUID) -> CGRect? {
        guard scale > 0, let index = configuration?.pageIDs.firstIndex(of: id) else { return nil }
        return layout.visiblePart(ofPage: index, visible: visibleContentRect, scale: Double(scale))
    }

    func toggleRuler() {
        guard let editor, !editor.isReadOnly, let slot = focusedSlot else { return }
        slot.host.toggleRuler()
    }

    /// The command goes to the selected item of the current page, else of the canvas with
    /// the focus, else of the first page (in page order) that has one. Each page's canvas
    /// keeps its own selection, so several pages can have one: never an arbitrary page's.
    @discardableResult
    func perform(itemCommand: MenuCommand) -> Bool {
        guard let editor, !editor.isReadOnly else { return false }
        let current = editor.currentPage.flatMap { slots[$0.id] }
        let ordered = [current, focusedSlot].compactMap { $0 } + editor.pages.compactMap { slots[$0.id] }
        return ordered.first { $0.host.itemSelection.selectedID != nil }?.host.itemSelection.perform(itemCommand) ?? false
    }
}
