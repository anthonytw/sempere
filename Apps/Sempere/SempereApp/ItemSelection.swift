import PencilKit
import Sempere
import UIKit

/// What selecting items does, decided without UIKit (tested): which item a
/// touch picks, what a tap does, whether a drag moves or resizes, and the
/// frame it leads to. One model for every kind (text boxes, images, PDF
/// pages, videos, math and kinds this version does not know) and every way
/// of selecting (selection mode, the lasso, a finger held on an item, a
/// secondary click, the text tool): docs/attachments.md §13 "Selecting items".
struct ItemSelectionModel {
    /// Handle radius on screen, in points; touches this close to a handle resize.
    static let handleRadius = 22.0
    /// Extra room around an item that still selects it, on screen.
    static let slop = 8.0

    /// Which items a selection can pick.
    enum Scope: Equatable {
        /// Every item (selection mode, the lasso, a held finger, a secondary click).
        case all
        /// Text boxes only (the text tool: a tap elsewhere starts a new box).
        case textBoxes

        func includes(_ item: Item) -> Bool {
            switch self {
            case .all: return true
            case .textBoxes: return item.kind == .text && item.text != nil
            }
        }
    }

    /// The selected item, if any.
    var selected: UUID?
    var scope = Scope.all

    /// What a drag starting at a page point does.
    enum Drag: Equatable {
        case move(UUID)
        case resize(UUID, ItemFrames.Handle)
    }

    /// What a tap does.
    enum Tap: Equatable {
        /// Select this item (and show its menu).
        case select(UUID)
        /// The tap is on the selected item: show its menu again.
        case menu(UUID)
        /// The tap is on the selected text box: type in it.
        case edit(UUID)
        /// The tap is beside the selection: drop it.
        case clear
        /// Nothing selected and nothing hit: the page's own action (a new
        /// text box with the text tool, Paste in selection mode).
        case empty
    }

    /// The items `scope` lets a touch pick.
    func candidates(_ items: [Item]) -> [Item] { items.filter(scope.includes) }

    /// The item a tap at `p` (page points) selects, at `zoom`.
    static func hit(_ p: ItemFrames.Point, items: [Item], zoom: Double) -> Item? {
        ItemFrames.item(at: p, in: items, slop: slop / max(zoom, 0.01))
    }

    /// What a tap at `p` does: the first tap on an item selects it, a tap
    /// on the selected one edits a text box (so a double tap edits it from
    /// scratch) or shows the menu of any other kind; a tap beside the
    /// selection clears it, and only a tap with nothing selected is the
    /// page's. `editable` false (a read-only note) never edits.
    func tap(at p: ItemFrames.Point, items: [Item], zoom: Double, editable: Bool = true) -> Tap {
        guard let hit = Self.hit(p, items: candidates(items), zoom: zoom) else {
            return selected == nil ? .empty : .clear
        }
        guard hit.id == selected else { return .select(hit.id) }
        return editable && hit.kind == .text && hit.text != nil ? .edit(hit.id) : .menu(hit.id)
    }

    /// The handles the selected `item` shows and takes (`ItemFrames.handles`).
    static func handles(for item: Item) -> [ItemFrames.Handle] { ItemFrames.handles(for: item.kind) }

    /// What a drag from `p` does: a handle of the selected item resizes it,
    /// the inside of an item (the selected one first) moves it; nil leaves
    /// the drag to scrolling. A background item (a full-page PDF page) moves
    /// only once it is selected, so dragging over it scrolls.
    func drag(at p: ItemFrames.Point, items: [Item], zoom: Double) -> Drag? {
        let z = max(zoom, 0.01)
        let items = candidates(items)
        if let id = selected, let item = items.first(where: { $0.id == id }) {
            let r = Self.handleRadius / z
            let near = Self.handles(for: item).map { ($0, Self.distance(ItemFrames.point(of: $0, item.frame, rotation: item.rotation), p)) }
            if let best = near.min(by: { $0.1 < $1.1 }), best.1 <= r { return .resize(id, best.0) }
            if ItemFrames.contains(item.frame, rotation: item.rotation, p, slop: Self.slop / z) { return .move(id) }
        }
        return ItemFrames.item(at: p, in: items, slop: Self.slop / z, includeBackground: false).map { .move($0.id) }
    }

    /// The frame a drag by `dx`, `dy` (page points) gives `item`.
    static func frame(for drag: Drag, item: Item, dx: Double, dy: Double) -> Rect {
        switch drag {
        case .move:
            return ItemFrames.moved(item.frame, dx: dx, dy: dy)
        case .resize(_, let handle):
            // Pictures keep their proportions; a text box re-wraps (its height follows its lines).
            return ItemFrames.resized(item.frame, rotation: item.rotation, handle: handle, dx: dx, dy: dy,
                                      keepAspect: ItemFrames.keepsAspect(item.kind))
        }
    }

    static func distance(_ a: ItemFrames.Point, _ b: ItemFrames.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// The selected item's outline and resize handles, in canvas content
/// coordinates, above the ink. Not interactive. The same look for every
/// kind: a solid outline, a faint tint over the item, and white handles
/// (round at corners, a bar at a side).
final class ItemSelectionView: UIView {
    private let outline = CAShapeLayer()
    private var handles: [CAShapeLayer] = []
    /// Diameter of a corner handle, and the long side of a side handle, on screen.
    static let handleSize: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        outline.fillColor = UIColor.tintColor.withAlphaComponent(0.06).cgColor
        outline.strokeColor = UIColor.tintColor.cgColor
        outline.lineWidth = 2
        layer.addSublayer(outline)
        isHidden = true
        accessibilityIdentifier = "itemSelection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The handles shown now (tests).
    private(set) var shownHandles: [ItemFrames.Handle] = []

    /// Outlines `frame` turned by `rotation` at `zoom` with `handles` (empty:
    /// none, a read-only note); nil hides the selection.
    func show(frame: Rect?, rotation: Double?, zoom: CGFloat, handles shown: [ItemFrames.Handle]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let frame else { isHidden = true; shownHandles = []; return }
        isHidden = false
        shownHandles = shown
        let z = Double(zoom)
        func screen(_ p: ItemFrames.Point) -> CGPoint { CGPoint(x: p.x * z, y: p.y * z) }
        let corners = ItemFrames.corners(frame, rotation: rotation).map(screen)
        let path = UIBezierPath()
        path.move(to: corners[0])
        for p in corners.dropFirst() { path.addLine(to: p) }
        path.close()
        outline.path = path.cgPath
        while handles.count < shown.count {
            let h = CAShapeLayer()
            h.fillColor = UIColor.white.cgColor
            h.strokeColor = UIColor.tintColor.cgColor
            h.lineWidth = 1.5
            h.shadowColor = UIColor.black.cgColor
            h.shadowOpacity = 0.25
            h.shadowRadius = 1.5
            h.shadowOffset = CGSize(width: 0, height: 0.5)
            layer.addSublayer(h)
            handles.append(h)
        }
        let d = Self.handleSize
        let angle = CGFloat(ItemFrames.radians(rotation))
        for (i, h) in handles.enumerated() {
            guard i < shown.count else { h.isHidden = true; continue }
            h.isHidden = false
            let c = screen(ItemFrames.point(of: shown[i], frame, rotation: rotation))
            let shape: UIBezierPath
            switch shown[i] {
            case .corner:
                shape = UIBezierPath(ovalIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
            case .edge(let e):
                // A bar along the side, turned with the item.
                let vertical = e == .left || e == .right
                let r = vertical ? CGRect(x: -d / 4, y: -d * 0.75, width: d / 2, height: d * 1.5)
                    : CGRect(x: -d * 0.75, y: -d / 4, width: d * 1.5, height: d / 2)
                shape = UIBezierPath(roundedRect: r, cornerRadius: d / 4)
                shape.apply(CGAffineTransform(rotationAngle: angle))
            }
            shape.apply(CGAffineTransform(translationX: c.x, y: c.y))
            h.path = shape.cgPath
        }
    }
}

/// What the selection needs from the app: the clipboard and pasting
/// (`AppModel`), and the editor's sheets.
struct ItemCommands {
    var copy: @MainActor (_ items: [Item], _ note: UUID) -> Void = { _, _ in }
    var canPaste: @MainActor () -> Bool = { false }
    var paste: @MainActor (_ page: UUID, _ actions: ItemActions) async -> [Item] = { _, _ in [] }
    /// Opens the crop sheet for an image or PDF page; nil: no Crop in the menu.
    var crop: (@MainActor (_ item: Item, _ page: UUID, _ actions: ItemActions) -> Void)?
    /// Picks another picture for an image (Replace Image); nil: not in the menu.
    var replace: (@MainActor (_ item: Item, _ page: UUID, _ actions: ItemActions, _ from: ReplaceSource,
                              _ done: @escaping @MainActor (Item) -> Void) -> Void)?
    /// Plays a video item (format.md §8.2.7); nil: no Play in the menu, and a tap on a clip does nothing.
    var play: (@MainActor (_ item: Item, _ page: UUID) -> Void)?
    /// Plays the recording an audio item shows, or pauses it when it plays (format.md §8.2.9); nil: the
    /// card's control and its Play in the menu do nothing.
    var toggleRecording: (@MainActor (_ recording: UUID) -> Void)?
    /// Opens a recording's transcript; nil: no Show Transcript in the menu.
    var showTranscript: (@MainActor (_ recording: UUID) -> Void)?
    /// Opens the equation sheet for a math item; nil: no Edit Equation in the menu.
    var editMath: (@MainActor (_ item: Item, _ page: UUID, _ actions: ItemActions) -> Void)?
}

/// Where Replace Image takes the new picture from.
enum ReplaceSource: Equatable {
    case photos, files
}

/// What the selection menu offers for an item (pure, tested): the same
/// entries whichever way the item was selected.
enum ItemMenu {
    enum Entry: Equatable {
        case play, playRecording, pauseRecording, showTranscript, editText, copy, duplicate, editMath, crop, replaceImage,
             rotateLeft, rotateRight, bringToFront, delete, paste
    }

    /// An audio item's recording (format.md §8.2.9), when the note has it: whether the
    /// card's Play/Pause is wired, the recording plays, and it has a transcript to show.
    struct AudioState: Equatable {
        var canToggle: Bool
        var isPlaying: Bool
        var hasTranscript: Bool
    }

    /// The entries for `item` (nil: nothing selected), in order. `audio` is the
    /// recording an audio item shows (nil: none, or the recording is missing).
    static func entries(for item: Item?, editable: Bool, canPlay: Bool, canCrop: Bool, canReplace: Bool,
                        canPaste: Bool, canEditMath: Bool = false, audio: AudioState? = nil) -> [Entry] {
        var out: [Entry] = []
        if let item {
            if item.kind == .video, canPlay { out.append(.play) }
            if item.kind == .audio, let audio {
                if audio.canToggle { out.append(audio.isPlaying ? .pauseRecording : .playRecording) }
                if audio.hasTranscript { out.append(.showTranscript) }
            }
            if editable, item.kind == .text, item.text != nil { out.append(.editText) }
            out.append(.copy)
            if editable {
                out.append(.duplicate)
                if canEditMath, item.kind == .math, item.math != nil { out.append(.editMath) }
                if canCrop, item.cropBounds != nil { out.append(.crop) }
                if canReplace, item.kind == .image { out.append(.replaceImage) }
                out.append(.rotateLeft)
                out.append(.rotateRight)
                out.append(.bringToFront)
                out.append(.delete)
            }
        }
        if editable, canPaste { out.append(.paste) }
        return out
    }
}

/// Selecting, moving, resizing and deleting items on the canvas
/// (docs/attachments.md §13 "Selecting items"). Ways in, one model
/// (`ItemSelectionModel`) for all of them:
/// - selection mode (`setActive(true)`, the toolbar's Select): PencilKit's
///   drawing gesture is off, a tap selects the topmost item (content before
///   backgrounds);
/// - the text tool (`setActive(true, scope: .textBoxes)`): the same for text
///   boxes, a tap elsewhere starts a new box (`onEmptyTap`);
/// - while drawing: a tap with PencilKit's lasso on an item, a finger held on
///   an item (when fingers do not draw), or a secondary click (a Mac, a
///   trackpad) pick that item (`onPick`): the host turns a transient
///   selection on, which ends once nothing is selected.
/// A selected item shows its outline, its handles (`ItemFrames.handles`) and
/// its menu (`ItemMenu`); a drag on it moves it, a drag on a handle resizes
/// it; a tap on the selected item shows the menu again, or types in a text
/// box (`onEditText`). Every gesture ends in one delta and one undo step
/// (`ItemActions`); while it runs, the item layer shows the frame it would
/// get. UIKit calls the edit-menu delegate on the main thread; that protocol
/// is not main-actor isolated, so the conformance is.
@MainActor
final class ItemSelectionController: NSObject, UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    private weak var canvas: UIScrollView?
    private weak var itemLayer: ItemLayerView?
    let overlay = ItemSelectionView()
    private let tap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    /// Two fingers on the selected item turn it (`rotated`), alongside the canvas's own pinch.
    private let rotate = UIRotationGestureRecognizer()
    /// The item a two-finger turn is turning, and the turn so far (degrees clockwise).
    private var turning: (item: Item, degrees: Double)?
    /// Outside selection mode: a finger tap on a video item plays it, when fingers do not draw.
    private let videoTap = UITapGestureRecognizer()
    /// The play/pause buttons of the page's audio cards (format.md §8.2.9).
    private let audioControls = AudioCardControls()
    /// The note's recordings and what the player plays, for the cards' buttons (`PageCanvasView.Coordinator.apply`).
    var recordings: [Recording] = []
    var playing: AudioPlayState?
    /// While drawing with the lasso: a tap on an item picks it.
    private let lassoTap = UITapGestureRecognizer()
    /// While drawing: a finger held on an item picks it (when fingers do not draw).
    private let hold = UILongPressGestureRecognizer()
    /// Any time: a secondary click (right button, two-finger click) on an item picks it and shows its menu.
    private let secondaryClick = UITapGestureRecognizer()
    private var menu: UIEditMenuInteraction?
    private var model = ItemSelectionModel()
    private var drag: (ItemSelectionModel.Drag, Item)?

    var editor: NoteEditor?
    var pageID: UUID? {
        didSet { if oldValue != pageID { reportSelection() } }
    }
    /// The page last reported to the editor as having a selected item.
    private var reportedPage: UUID?
    var commands = ItemCommands()
    /// Opens a text box in its editor ("Edit Text", a tap on the selected box).
    var onEditText: ((Item) -> Void)?
    /// A tap with nothing selected and nothing hit, in page points (the text tool's new box).
    var onEmptyTap: ((ItemFrames.Point) -> Void)?
    /// An item was picked while drawing (lasso, held finger, secondary click):
    /// the host turns the transient selection on, then the item is selected.
    var onPick: (() -> Void)?
    /// The selection became empty (a transient selection ends).
    var onCleared: (() -> Void)?
    /// Whether the lasso is the canvas's tool (the lasso tap works only then).
    var lassoSelected: () -> Bool = { false }
    /// Whether picking while drawing is allowed now (the canvas is editable, nothing is typed in).
    var canPick: () -> Bool = { false }
    /// The scroll view that pans the page: the canvas itself, or the paged
    /// stack around it (`PageStackHost`), whose scroll a drag on an item stops.
    weak var scroller: UIScrollView?
    /// Undo and redo of item gestures, on the canvas's undo manager.
    private(set) var actions: ItemActions?

    /// The selected item (tests, menus).
    var selectedID: UUID? { model.selected }
    /// Which items can be picked now.
    var scope: ItemSelectionModel.Scope { model.scope }

    func attach(to canvas: UIScrollView, itemLayer: ItemLayerView) {
        self.canvas = canvas
        self.itemLayer = itemLayer
        canvas.addSubview(overlay)
        tap.addTarget(self, action: #selector(tapped(_:)))
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        rotate.addTarget(self, action: #selector(rotated(_:)))
        for g in [tap, pan, rotate] as [UIGestureRecognizer] {
            g.delegate = self
            g.isEnabled = false
            canvas.addGestureRecognizer(g)
        }
        videoTap.addTarget(self, action: #selector(videoTapped(_:)))
        videoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        lassoTap.addTarget(self, action: #selector(lassoTapped(_:)))
        hold.addTarget(self, action: #selector(held(_:)))
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        hold.minimumPressDuration = 0.45
        secondaryClick.addTarget(self, action: #selector(secondaryClicked(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        for g in [videoTap, lassoTap, hold, secondaryClick] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            g.delegate = self
            canvas.addGestureRecognizer(g)
        }
        audioControls.attach(to: canvas)
        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        self.menu = menu
    }

    /// Selection on or off, for `scope`; off clears the selection.
    func setActive(_ active: Bool, scope: ItemSelectionModel.Scope = .all) {
        tap.isEnabled = active
        pan.isEnabled = active
        rotate.isEnabled = active
        if model.scope != scope {
            model.scope = scope
            if let id = model.selected, !items.contains(where: { $0.id == id && scope.includes($0) }) { select(nil) }
        }
        if !active { select(nil) }
    }

    var isActive: Bool { tap.isEnabled }

    /// The note or page on the canvas changed.
    func reset(editor: NoteEditor, pageID: UUID, undoManager: UndoManager?) {
        if self.editor !== editor || self.pageID != pageID || actions?.undoManager !== undoManager {
            self.editor = editor
            self.pageID = pageID
            actions = ItemActions(editor: editor, undoManager: undoManager)
            select(nil)
        }
    }

    private var items: [Item] {
        guard let editor, let pageID else { return [] }
        return editor.items(on: pageID)
    }

    private var zoom: CGFloat { max(canvas?.zoomScale ?? 1, 0.01) }

    private func pagePoint(_ g: UIGestureRecognizer) -> ItemFrames.Point {
        let p = g.location(in: canvas)
        return ItemFrames.Point(x: Double(p.x / zoom), y: Double(p.y / zoom))
    }

    /// Selects `id` (nil: nothing) and redraws the outline. An empty
    /// selection tells the host (`onCleared`).
    func select(_ id: UUID?) {
        let had = model.selected
        model.selected = id
        if id == nil { dismissMenu() }
        refresh()
        if id == nil, had != nil { onCleared?() }
    }

    /// Picks `id` as a lasso tap, a held finger or a secondary click does:
    /// the host's transient selection first, then the item and its menu.
    func pick(_ id: UUID) {
        if !isActive { onPick?() }
        guard isActive else { return }
        select(id)
        presentMenu()
    }

    /// The recording audio item `item` shows (format.md §8.2.9: by id, else a restored copy), if the note has it.
    private func shownRecording(_ item: Item) -> UUID? {
        NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
            .recording(shownBy: item)?.id
    }

    /// Redraws the outline (the zoom, the item or the selection changed).
    func refresh() {
        defer { reportSelection() }
        overlay.frame = CGRect(origin: .zero, size: canvas?.contentSize ?? .zero)
        canvas?.bringSubviewToFront(overlay)
        let items = self.items   // sorted from the editor: read once
        let frames = itemLayer?.shownFrames() ?? [:]
        let shown = items.map { item -> Item in
            var shown = item
            if let frame = frames[item.id] { shown.frame = frame }
            return shown
        }
        audioControls.layout(shown, recordings: recordings, playing: playing, zoom: zoom,
                             hidden: itemLayer?.hiddenItem, toggle: isActive ? nil : commands.toggleRecording)
        guard let id = model.selected, let item = items.first(where: { $0.id == id }) else {
            if model.selected != nil, drag == nil {
                model.selected = nil
                dismissMenu()
                onCleared?()
            }
            overlay.show(frame: nil, rotation: nil, zoom: zoom, handles: [])
            return
        }
        let frame = itemLayer?.shownFrame(of: id) ?? item.frame
        overlay.show(frame: frame, rotation: turning?.item.id == id ? (item.rotation ?? 0) + (turning?.degrees ?? 0) : item.rotation,
                     zoom: zoom,
                     handles: editor?.canEditItems == true ? ItemSelectionModel.handles(for: item) : [])
    }

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === videoTap { return videoUnderFingerTap(g) != nil }
        if g === lassoTap { return !isActive && lassoSelected() && canPick() && itemHit(g) != nil }
        if g === hold { return !isActive && canPick() && !fingersDraw && itemHit(g) != nil }
        if g === secondaryClick { return editor != nil && (isActive || canPick()) }
        if g === rotate { return turnTarget(g) != nil }
        guard g === pan else { return true }
        // Only a drag on an item (or a handle) is ours; any other scrolls.
        guard editor?.canEditItems == true else { return false }
        return model.drag(at: pagePoint(g), items: items, zoom: Double(zoom)) != nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Picking while drawing never stops PencilKit's own gestures (the lasso still lassoes ink).
        g === videoTap || g === lassoTap || g === hold || g === secondaryClick || g === rotate
    }

    /// Whether a finger draws on this canvas (then a held finger is ink, not a pick).
    private var fingersDraw: Bool {
        guard let canvas = canvas as? PKCanvasView else { return true }
        return ObjectEraserController.fingersDraw(canvas)
    }

    /// The topmost item under the touch, of every kind.
    private func itemHit(_ g: UIGestureRecognizer) -> Item? {
        ItemSelectionModel.hit(pagePoint(g), items: items, zoom: Double(zoom))
    }

    /// The video (or audio card) under a finger tap in drawing mode: only when Play is wired,
    /// selection mode is off, and fingers do not draw on this canvas (else the tap is ink). A tap on a
    /// card's button is the button's (UIKit gives a control's tap to it, not to this recognizer).
    private func videoUnderFingerTap(_ g: UIGestureRecognizer) -> Item? {
        guard !isActive, !fingersDraw, let hit = itemHit(g) else { return nil }
        switch hit.kind {
        case .video: return commands.play == nil ? nil : hit
        case .audio: return commands.toggleRecording == nil ? nil : hit
        default: return nil
        }
    }

    @objc private func videoTapped(_ g: UITapGestureRecognizer) {
        guard let item = videoUnderFingerTap(g), let pageID else { return }
        if item.kind == .audio {
            if let recording = shownRecording(item) { commands.toggleRecording?(recording) }
        } else {
            commands.play?(item, pageID)
        }
    }

    @objc private func lassoTapped(_ g: UITapGestureRecognizer) {
        if let hit = itemHit(g) { pick(hit.id) }
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let hit = itemHit(g) else { return }
        pick(hit.id)
    }

    @objc private func secondaryClicked(_ g: UITapGestureRecognizer) {
        if let hit = ItemSelectionModel.hit(pagePoint(g), items: isActive ? model.candidates(items) : items, zoom: Double(zoom)) {
            pick(hit.id)
        } else if isActive {
            select(nil)
            if commands.canPaste(), editor?.canEditItems == true { presentMenu(at: g.location(in: canvas)) }
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = pagePoint(g)
        switch model.tap(at: p, items: items, zoom: Double(zoom), editable: editor?.canEditItems == true) {
        case .select(let id):
            select(id)
            presentMenu()
        case .menu:
            presentMenu()
        case .edit(let id):
            guard let pageID, let item = editor?.item(id, on: pageID), let edit = onEditText else { return }
            select(nil)
            edit(item)
        case .clear:
            select(nil)
        case .empty:
            if let empty = onEmptyTap {
                empty(p)
            } else if commands.canPaste(), editor?.canEditItems == true {
                presentMenu(at: g.location(in: canvas))
            }
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let start = pagePoint(g)
            let translation = g.translation(in: canvas)
            let origin = ItemFrames.Point(x: start.x - Double(translation.x / zoom), y: start.y - Double(translation.y / zoom))
            guard let d = model.drag(at: origin, items: items, zoom: Double(zoom)) else { return }
            let id: UUID
            switch d { case .move(let i), .resize(let i, _): id = i }
            guard let item = items.first(where: { $0.id == id }) else { return }
            drag = (d, item)
            dismissMenu()
            model.selected = id
            refresh()
            // A drag on an item moves the item, not the page: stop a scroll that started with it.
            if let scroll = (scroller ?? canvas)?.panGestureRecognizer, scroll.state == .began || scroll.state == .changed {
                scroll.isEnabled = false
                scroll.isEnabled = true
            }
            fallthrough
        case .changed:
            guard let current = drag else { return }
            let (d, item) = current
            let t = g.translation(in: canvas)
            let frame = ItemSelectionModel.frame(for: d, item: item, dx: Double(t.x / zoom), dy: Double(t.y / zoom))
            itemLayer?.preview(item.id, frame: frame)
            refresh()
        case .ended:
            guard let current = drag, let pageID else { return cancelDrag() }
            let (d, item) = current
            let t = g.translation(in: canvas)
            let frame = ItemSelectionModel.frame(for: d, item: item, dx: Double(t.x / zoom), dy: Double(t.y / zoom))
            drag = nil
            itemLayer?.preview(item.id, frame: nil)
            if case .resize = d {
                actions?.setFrame(item.id, to: frame, on: pageID, name: String(localized: "Resize", comment: "Undo action name (Edit menu: Undo …)"))
            } else {
                actions?.setFrame(item.id, to: frame, on: pageID, name: String(localized: "Move", comment: "Undo action name (Edit menu: Undo …)"))
            }
            refresh()
        default:
            cancelDrag()
        }
    }

    /// The selected item when both fingers of `g` are on it (and it can be edited).
    private func turnTarget(_ g: UIGestureRecognizer) -> Item? {
        guard editor?.canEditItems == true, let id = model.selected, let pageID,
              let item = editor?.item(id, on: pageID), let canvas, g.numberOfTouches == 2 else { return nil }
        let z = Double(zoom)
        let b = ItemFrames.bounds(itemLayer?.shownFrame(of: id) ?? item.frame, rotation: item.rotation)
        let rect = CGRect(x: b.x * z, y: b.y * z, width: b.w * z, height: b.h * z)
        return (0..<2).allSatisfy { rect.contains(g.location(ofTouch: $0, in: canvas)) } ? item : nil
    }

    /// A two-finger turn of the selected item: the item and its outline follow the
    /// fingers, and the end writes one delta (`ItemActions.rotate`, one undo step).
    @objc private func rotated(_ g: UIRotationGestureRecognizer) {
        switch g.state {
        case .began:
            guard let item = turnTarget(g) else {
                g.state = .cancelled
                return
            }
            turning = (item, 0)
            dismissMenu()
            fallthrough
        case .changed:
            guard let current = turning else { return }
            let degrees = Double(g.rotation) * 180 / .pi
            turning = (current.item, degrees)
            itemLayer?.preview(current.item.id, turn: degrees)
            refresh()
        case .ended:
            guard let current = turning else { return }
            endTurn()
            if let pageID {
                actions?.rotate(current.item.id, by: Double(g.rotation) * 180 / .pi, on: pageID, snapping: true)
            }
            refresh()
        default:
            endTurn()
            refresh()
        }
    }

    private func endTurn() {
        if let current = turning { itemLayer?.preview(current.item.id, turn: nil) }
        turning = nil
    }

    private func cancelDrag() {
        if let current = drag { itemLayer?.preview(current.1.id, frame: nil) }
        drag = nil
        refresh()
    }

    // MARK: Menu

    /// Shows the menu next to the selected item (or at `point`, for Paste on the empty page).
    private func presentMenu(at point: CGPoint? = nil) {
        guard canvas?.window != nil, let source = point ?? selectedRect.map({ CGPoint(x: $0.midX, y: $0.minY) }) else { return }
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }

    private func dismissMenu() { menu?.dismissMenu() }

    /// The selected item's bounds in canvas coordinates.
    private var selectedRect: CGRect? {
        guard let id = model.selected, let item = items.first(where: { $0.id == id }) else { return nil }
        let b = ItemFrames.bounds(itemLayer?.shownFrame(of: id) ?? item.frame, rotation: item.rotation)
        let z = Double(zoom)
        return CGRect(x: b.x * z, y: b.y * z, width: b.w * z, height: b.h * z)
    }

    /// The menu keeps clear of the selected item.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectedRect ?? CGRect(origin: configuration.sourcePoint, size: .zero)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let editable = editor?.canEditItems == true
        let item = model.selected.flatMap { id in pageID.flatMap { editor?.item(id, on: $0) } }
        let recording = item.flatMap(shownRecording)
        let audio = recording.map { id in
            ItemMenu.AudioState(canToggle: commands.toggleRecording != nil,
                                isPlaying: editor?.player?.recording?.id == id && editor?.player?.isPlaying == true,
                                hasTranscript: commands.showTranscript != nil && editor?.recording(id)?.transcript != nil)
        }
        let entries = ItemMenu.entries(for: item, editable: editable, canPlay: commands.play != nil, canCrop: commands.crop != nil,
                                       canReplace: commands.replace != nil, canPaste: commands.canPaste(),
                                       canEditMath: commands.editMath != nil, audio: audio)
        let elements = entries.compactMap { menuElement($0, item: item) }
        return elements.isEmpty ? nil : UIMenu(children: elements)
    }

    private func menuElement(_ entry: ItemMenu.Entry, item: Item?) -> UIMenuElement? {
        guard let pageID, let editor else { return nil }
        switch entry {
        case .paste:
            return UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteClipboard() }
        default: break
        }
        guard let item else { return nil }
        let id = item.id
        switch entry {
        case .play:
            guard let play = commands.play else { return nil }
            return UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in play(item, pageID) }
        case .playRecording, .pauseRecording:
            guard let toggle = commands.toggleRecording, let recording = shownRecording(item) else { return nil }
            let pause = entry == .pauseRecording
            return UIAction(title: pause ? String(localized: "Pause") : String(localized: "Play"), image: UIImage(systemName: pause ? "pause.fill" : "play.fill")) { _ in
                toggle(recording)
            }
        case .showTranscript:
            guard let show = commands.showTranscript, let recording = shownRecording(item) else { return nil }
            return UIAction(title: String(localized: "Show Transcript"), image: UIImage(systemName: "text.quote")) { _ in show(recording) }
        case .editText:
            guard let edit = onEditText else { return nil }
            return UIAction(title: String(localized: "Edit Text"), image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                self?.select(nil)
                edit(item)
            }
        case .copy:
            return UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.commands.copy([item], editor.noteID)
            }
        case .duplicate:
            return UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                guard let self, let new = self.actions?.duplicate([id], on: pageID).first else { return }
                self.select(new.id)
            }
        case .editMath:
            guard let editMath = commands.editMath, let actions else { return nil }
            return UIAction(title: String(localized: "Edit Equation…"), image: UIImage(systemName: "function")) { [weak self] _ in
                self?.select(nil)
                editMath(item, pageID, actions)
            }
        case .crop:
            guard let crop = commands.crop, let actions else { return nil }
            return UIAction(title: String(localized: "Crop…"), image: UIImage(systemName: "crop")) { _ in crop(item, pageID, actions) }
        case .replaceImage:
            guard let replace = commands.replace, let actions else { return nil }
            return UIMenu(title: String(localized: "Replace Image"), image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: [
                UIAction(title: String(localized: "From Photos…"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                    replace(item, pageID, actions, .photos) { self?.pick($0.id) }
                },
                UIAction(title: String(localized: "From Files…"), image: UIImage(systemName: "folder")) { [weak self] _ in
                    replace(item, pageID, actions, .files) { self?.pick($0.id) }
                },
            ])
        case .rotateLeft, .rotateRight:
            let left = entry == .rotateLeft
            return UIAction(title: left ? String(localized: "Rotate 90° Left") : String(localized: "Rotate 90° Right"),
                            image: UIImage(systemName: left ? "rotate.left" : "rotate.right")) { [weak self] _ in
                self?.actions?.rotate(id, by: left ? -90 : 90, on: pageID)
                self?.refresh()
            }
        case .bringToFront:
            return UIAction(title: String(localized: "Bring to Front"), image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
                self?.actions?.bringToFront(id, on: pageID)
                self?.refresh()
            }
        case .delete:
            return UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteSelection()
            }
        case .paste:
            return nil
        }
    }

    /// Runs a menu command on the selected item (Duplicate, Bring to Front, Delete: the Mac's
    /// Note menu and shortcuts); false when nothing is selected, the note cannot be edited or
    /// it is another command.
    @discardableResult
    func perform(_ command: MenuCommand) -> Bool {
        guard let id = model.selected, let pageID, editor?.canEditItems == true else { return false }
        switch command {
        case .duplicateItem:
            guard let new = actions?.duplicate([id], on: pageID).first else { return false }
            select(new.id)
        case .bringItemToFront:
            actions?.bringToFront(id, on: pageID)
            refresh()
        case .deleteItem:
            deleteSelection()
        default:
            return false
        }
        return true
    }

    /// Tells the editor whether this canvas's page has a selected item (it enables the menu commands).
    private func reportSelection() {
        if let old = reportedPage, old != pageID { editor?.itemSelection(on: old, isSelected: false) }
        reportedPage = pageID
        if let pageID { editor?.itemSelection(on: pageID, isSelected: model.selected != nil) }
    }

    /// Deletes the selected item (one delta, undoable).
    func deleteSelection() {
        guard let id = model.selected, let pageID else { return }
        actions?.delete([id], on: pageID)
        select(nil)
    }

    /// Pastes the clipboard onto this page and selects the first pasted item.
    func pasteClipboard() {
        guard let pageID, let actions else { return }
        let paste = commands.paste
        Task { [weak self] in
            let pasted = await paste(pageID, actions)
            if let first = pasted.first { self?.select(first.id) }
        }
    }
}
