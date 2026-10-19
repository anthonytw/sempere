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

    /// What a tap does. A tap never shows the item's menu: that is a held
    /// finger's, a secondary click's or the selection's menu button's
    /// (TestFlight 1.0.0: a menu that came up on every tap floated over the
    /// page and came back at the next tap).
    enum Tap: Equatable {
        /// Select this item.
        case select(UUID)
        /// The tap is on the selected item (not a text box being edited): it stays selected.
        case keep(UUID)
        /// The tap is on the selected text box: type in it.
        case edit(UUID)
        /// The tap is beside the selection: drop it.
        case clear
        /// Nothing selected and nothing hit: the page's own action (a new
        /// text box with the text tool).
        case empty
        /// Nothing selected, and the tap is on an item the scope leaves out (a
        /// picture or a clip under the text tool): nothing, not a new box on it.
        case ignore
    }

    /// The items `scope` lets a touch pick.
    func candidates(_ items: [Item]) -> [Item] { items.filter(scope.includes) }

    /// The item a tap at `p` (page points) selects, at `zoom`.
    static func hit(_ p: ItemFrames.Point, items: [Item], zoom: Double) -> Item? {
        ItemFrames.item(at: p, in: items, slop: slop / max(zoom, 0.01))
    }

    /// What a tap at `p` does: the first tap on an item selects it, a tap
    /// on the selected one edits a text box (so a double tap edits it from
    /// scratch) and keeps any other kind selected; a tap beside the
    /// selection clears it, and only a tap with nothing selected and no item
    /// under it is the page's. `editable` false (a read-only note) never edits.
    func tap(at p: ItemFrames.Point, items: [Item], zoom: Double, editable: Bool = true) -> Tap {
        guard let hit = Self.hit(p, items: candidates(items), zoom: zoom) else {
            if selected != nil { return .clear }
            // A content item the scope leaves out is not empty page (a background, a PDF page, is).
            let other = Self.hit(p, items: items.filter { !$0.layer.isBackground }, zoom: zoom)
            return other == nil ? .empty : .ignore
        }
        guard hit.id == selected else { return .select(hit.id) }
        return editable && hit.kind == .text && hit.text != nil ? .edit(hit.id) : .keep(hit.id)
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

/// Whether a finger touch is a tap, decided from where and when it began, moved and ended
/// (`FingerItemTapRecognizer`; pure, tested). A tap is one finger that stays within `slop`
/// points of where it landed and lifts before `maxDuration`: longer is a hold
/// (`ItemSelectionController.hold`, 0.45 s), farther is a stroke or a scroll.
struct FingerTapTracker: Equatable {
    static let slop: CGFloat = 8
    static let maxDuration: TimeInterval = 0.4

    private(set) var start: CGPoint
    private(set) var began: TimeInterval
    private(set) var failed = false

    init(at point: CGPoint, time: TimeInterval) {
        start = point
        began = time
    }

    /// The finger moved to `point` (or a second finger came: `touches > 1`).
    mutating func moved(to point: CGPoint, touches: Int = 1) {
        if touches > 1 || hypot(point.x - start.x, point.y - start.y) > Self.slop { failed = true }
    }

    /// The finger lifted at `point`, `time`: whether it was a tap.
    func isTap(endingAt point: CGPoint, time: TimeInterval) -> Bool {
        var end = self
        end.moved(to: point)
        return !end.failed && time - began < Self.maxDuration
    }
}

/// Sees every touch that lands on the canvas and recognizes nothing: a new touch, finger or
/// Pencil, dismisses an item menu that is up (`ItemSelectionController.touchedDown`), whatever
/// the other recognizers make of it (ink, a scroll, a tap that PencilKit keeps).
final class TouchDownRecognizer: UIGestureRecognizer {
    var onTouchDown: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown?()
        state = .failed
    }
}

/// The pan of an item drag. UIKit's `translation` starts where the recognizer began, which on a
/// Mac (a mouse drag) is after the pointer has moved past the slop (and, when the page's scroll or
/// PencilKit's recognizers held it back, later still): `translation(in:)` read 0 at `.began`, so an
/// item trailed the pointer by that first stretch (about ten points) and a handle was looked for
/// where the pointer had got to, not where it went down. This one keeps where the press began.
final class ItemPanRecognizer: UIPanGestureRecognizer {
    /// Where the press that this pan follows went down, in the coordinates of `view`.
    private(set) var downLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if downLocation == nil, let touch = touches.first, let view {
            downLocation = touch.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        downLocation = nil
    }

    /// How far the pointer has gone since the press (the same as `translation(in: view)` where the
    /// recognizer began with the press).
    func travel(in view: UIView) -> CGPoint {
        let here = location(in: view)
        guard let down = downLocation else { return translation(in: view) }
        return CGPoint(x: here.x - down.x, y: here.y - down.y)
    }
}

/// A finger tap that begins on a placed item, for a canvas where fingers draw (an iPhone). PencilKit
/// draws a dot for a tap and a stroke for a drag, so the tap is told apart from the stroke before
/// ink starts: this recognizer fails at once for a touch that lands off every item (ink is not
/// delayed), and for a touch that moves, holds or is joined by a second finger (the stroke or
/// scroll then goes on as before). While it is still a possible tap, PencilKit's drawing waits
/// (`ItemSelectionController.gestureRecognizer(_:shouldBeRequiredToFailBy:)`), so a tap on an item
/// selects it and leaves no dot. A stroke that starts on an item draws (annotating a picture or a
/// PDF page); only a tap selects.
final class FingerItemTapRecognizer: UIGestureRecognizer {
    /// Whether a tap may start at this point of the view (an item is there, and picking is allowed now).
    var startsAt: ((CGPoint) -> Bool)?
    private var tracker: FingerTapTracker?
    private var timeout: DispatchWorkItem?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracker == nil, numberOfTouches == 1, let touch = touches.first, touch.type == .direct, let view,
              startsAt?(touch.location(in: view)) == true else {
            state = .failed
            return
        }
        tracker = FingerTapTracker(at: touch.location(in: view), time: touch.timestamp)
        // A held finger is the hold recognizer's, and PencilKit's drawing may go on from there.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            self.state = .failed
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FingerTapTracker.maxDuration, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, let view else { return }
        tracker?.moved(to: touch.location(in: view), touches: numberOfTouches)
        if tracker?.failed == true { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, let touch = touches.first, let view, let tracker else { state = .failed; return }
        state = tracker.isTap(endingAt: touch.location(in: view), time: touch.timestamp) ? .recognized : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    override func reset() {
        timeout?.cancel()
        timeout = nil
        tracker = nil
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
    private let pan = ItemPanRecognizer()
    /// Two fingers on the selected item turn it (`rotated`), alongside the canvas's own pinch.
    private let rotate = UIRotationGestureRecognizer()
    /// The item a two-finger turn is turning, and the turn so far (degrees clockwise).
    private var turning: (item: Item, degrees: Double)?
    /// While drawing: a finger tap on an item selects it, when fingers do not draw (a tap selects,
    /// as a click does on a Mac; only a clip's or a card's own button plays it).
    private let itemTap = UITapGestureRecognizer()
    /// The same for a canvas where fingers draw (an iPhone, `fingersPick`): a tap that begins on an
    /// item, told apart from a stroke before PencilKit draws a dot (`FingerItemTapRecognizer`).
    let fingerTap = FingerItemTapRecognizer()
    /// Whether a finger tap or hold picks an item although fingers draw (an iPhone: it has no Pencil
    /// and finger drawing is the one way to write). A stroke still draws, wherever it starts; only
    /// a tap (up before 0.4 s, within 8 points) or a hold (0.45 s) on an item picks it. The iPad
    /// leaves a finger that draws to PencilKit: its taps pick only with a paired Pencil.
    /// Whether the tool in hand lets a finger pick now (not an eraser: a tap erases there).
    var canFingerPick: () -> Bool = { true }
    var fingersPick = Platform.isPhone {
        didSet { applyFingerMode() }
    }
    private func applyFingerMode() {
        fingerTap.isEnabled = fingersPick
        itemTap.isEnabled = !fingersPick
    }
    /// The play/pause buttons of the page's audio cards (format.md §8.2.9).
    private let audioControls = AudioCardControls()
    /// The play buttons of the page's videos (format.md §8.2.7).
    private let videoButtons = VideoPlayButtons()
    /// The selected item's menu and Delete buttons (iPad).
    let bar = ItemSelectionBar()
    /// The note's recordings and what the player plays, for the cards' buttons (`PageCanvasView.Coordinator.apply`).
    var recordings: [Recording] = []
    var playing: AudioPlayState?
    /// While drawing with the lasso: a tap on an item picks it.
    private let lassoTap = UITapGestureRecognizer()
    /// A finger held on an item selects it and shows its menu: while drawing (when fingers do not
    /// draw), in selection mode and with the text tool (the Pencil too, then). Held on the empty
    /// page in selection mode it offers Paste. PencilKit's own long press ("Select All", "Insert
    /// Space") waits for it (`shouldBeRequiredToFailBy`), so a hold on an item shows the item's menu.
    private let hold = UILongPressGestureRecognizer()
    /// Any time: a secondary click (right button, two-finger click) on an item picks it and shows its menu.
    private let secondaryClick = UITapGestureRecognizer()
    /// Any new touch on the canvas dismisses a menu that is up (`touchedDown`).
    private let touchDown = TouchDownRecognizer()
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
        canvas.addSubview(bar)
        bar.menuElements = { [weak self] in self?.menuElements() ?? [] }
        bar.onDelete = { [weak self] in self?.deleteSelection() }
        tap.addTarget(self, action: #selector(tapped(_:)))
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        rotate.addTarget(self, action: #selector(rotated(_:)))
        for g in [tap, pan, rotate] as [UIGestureRecognizer] {
            g.delegate = self
            g.isEnabled = false
            canvas.addGestureRecognizer(g)
        }
        itemTap.addTarget(self, action: #selector(itemTapped(_:)))
        itemTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerTap.addTarget(self, action: #selector(itemTapped(_:)))
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerTap.startsAt = { [weak self] p in self?.fingerTapMayStart(at: p) ?? false }
        applyFingerMode()
        lassoTap.addTarget(self, action: #selector(lassoTapped(_:)))
        hold.addTarget(self, action: #selector(held(_:)))
        hold.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        hold.minimumPressDuration = 0.45
        secondaryClick.addTarget(self, action: #selector(secondaryClicked(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        // A mouse or trackpad only: on the iPad simulator (and so perhaps on a device) a finger tap
        // also passed the button mask, so every tap showed the menu.
        secondaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        touchDown.onTouchDown = { [weak self] in self?.touchedDown() }
        for g in [itemTap, fingerTap, lassoTap, hold, secondaryClick, touchDown] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            g.delegate = self
            canvas.addGestureRecognizer(g)
        }
        audioControls.attach(to: canvas)
        videoButtons.attach(to: canvas)
        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        self.menu = menu
    }

    /// Selection on or off, for `scope`; off clears the selection. While it is on, PencilKit's
    /// own recognizers (its long press: "Select All", "Insert Space") are off with its drawing
    /// (`PageCanvasHost.setPencilKitGestures`), so a hold is the item's.
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

    /// Where `g` is on the page; with `down`, where its press went down (an item drag's pan).
    private func pagePoint(_ g: UIGestureRecognizer, down: Bool = false) -> ItemFrames.Point {
        let p = (down ? (g as? ItemPanRecognizer)?.downLocation : nil) ?? g.location(in: canvas)
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

    /// Picks `id` as a finger or lasso tap, a held finger or a secondary click
    /// does: the host's transient selection first, then the item, and its
    /// menu when `menu` (a held finger, a secondary click; never a tap).
    func pick(_ id: UUID, menu: Bool = true) {
        if !isActive { onPick?() }
        guard isActive else { return }
        select(id)
        if menu { presentMenu() }
    }

    /// The page scrolled or zoomed under the selection: its menu goes (it would float over
    /// another part of the page), and so does one a hold under way would show at its lift.
    func viewMoved() {
        guard drag == nil, turning == nil else { return }
        heldTarget = nil
        dismissMenu()
    }

    /// A scroll, a pinch or a stroke starts on this canvas (TestFlight 1.0.0 (6): on a dense
    /// page the hold menu "gets stuck … and doesn't go away"). Every edit menu goes at once:
    /// the one shown on any canvas (`menuOwner`: a page of the stack shows it, another is
    /// scrolled or written on), PencilKit's own ("Select All", "Insert Space") and a text box's,
    /// and a hold under way or just lifted shows none (`gestureEpoch`), nor is a dismissed menu
    /// put back (`menuKeep`).
    /// `stroke`: PencilKit began a stroke. Where fingers draw (an iPhone) a held finger's stroke
    /// may begin around the hold itself, so a stroke only dismisses the menus shown and leaves a
    /// hold under way alone.
    func gestureStarted(stroke: Bool = false) {
        guard drag == nil, turning == nil else { return }
        if !(stroke && holding) {
            gestureEpoch &+= 1
            heldTarget = nil
        }
        if let owner = Self.menuOwner, owner !== self { owner.dismissMenu() }
        dismissMenu()
        dismissOtherMenus()
    }

    /// Bumped by every scroll, pinch and stroke start: a hold's menu that was waiting for its lift
    /// (`held`) is not shown after one.
    private(set) var gestureEpoch = 0

    /// The controller whose menu was presented last (any canvas, any page of the stack).
    private static weak var menuOwner: ItemSelectionController?

    /// Dismisses the edit menus of the canvas's other interactions (PencilKit's, a text view's).
    private func dismissOtherMenus() {
        guard let canvas else { return }
        var views: [UIView] = [canvas]
        while let view = views.popLast() {
            for case let other as UIEditMenuInteraction in view.interactions where other !== menu { other.dismissMenu() }
            views.append(contentsOf: view.subviews)
        }
    }

    /// Whether the page under this canvas is being scrolled or zoomed now.
    private var pageMoving: Bool {
        [scroller, canvas].contains { s in
            guard let s else { return false }
            return s.isDragging || s.isDecelerating || s.isZooming || s.isZoomBouncing
        }
    }

    /// The recording audio item `item` shows (format.md §8.2.9: by id, else a restored copy), if the note has it.
    private func shownRecording(_ item: Item) -> UUID? {
        NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
            .recording(shownBy: item)?.id
    }

    /// Redraws the outline (the zoom, the item or the selection changed).
    func refresh() {
        defer {
            reportSelection()
            #if DEBUG
            debugReport()
            #endif
        }
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
        var playVideo: (@MainActor (Item) -> Void)?
        if !isActive, let play = commands.play {
            playVideo = { [weak self] item in
                guard let pageID = self?.pageID else { return }
                play(item, pageID)
            }
        }
        videoButtons.layout(shown, zoom: zoom, hidden: itemLayer?.hiddenItem, play: playVideo)
        guard let id = model.selected, let item = items.first(where: { $0.id == id }) else {
            if model.selected != nil, drag == nil {
                model.selected = nil
                dismissMenu()
                onCleared?()
            }
            overlay.show(frame: nil, rotation: nil, zoom: zoom, handles: [])
            bar.show(around: nil, in: .zero, canDelete: false)
            return
        }
        let frame = itemLayer?.shownFrame(of: id) ?? item.frame
        let rotation = turning?.item.id == id ? (item.rotation ?? 0) + (turning?.degrees ?? 0) : item.rotation
        overlay.show(frame: frame, rotation: rotation, zoom: zoom,
                     handles: editor?.canEditItems == true ? ItemSelectionModel.handles(for: item) : [])
        // The bar steps aside while the item moves or turns; a Mac has the secondary click and the menus instead.
        if Platform.isMac || drag != nil || turning != nil {
            bar.show(around: nil, in: .zero, canDelete: false)
        } else {
            let b = ItemFrames.bounds(frame, rotation: rotation)
            let z = Double(zoom)
            bar.show(around: CGRect(x: b.x * z, y: b.y * z, width: b.w * z, height: b.h * z),
                     in: canvas?.contentSize ?? .zero, canDelete: editor?.canEditItems == true)
            canvas?.bringSubviewToFront(bar)
        }
    }

    #if DEBUG
    /// `SEMPERE_DEMO_ITEMS` (Mac UI tests, `MacItemUITests`): the canvas's
    /// accessibility value says where its items are, which one is selected and
    /// how many item edits the page has had, so a test can aim the pointer and
    /// check that a gesture wrote one delta.
    private static let reports = DebugLaunch.environment["SEMPERE_DEMO_ITEMS"] != nil

    private func debugReport() {
        guard Self.reports, let canvas, let pageID else { return }
        func n(_ v: Double) -> String { String(format: "%.1f", v) }
        let frames = itemLayer?.shownFrames() ?? [:]
        let list = items.map { item in
            let f = frames[item.id] ?? item.frame
            return "\(item.kind.rawValue):\(n(f.x)),\(n(f.y)),\(n(f.w)),\(n(f.h)),\(n(item.rotation ?? 0))"
        }
        let selected = model.selected.flatMap { id in items.first { $0.id == id }?.kind.rawValue } ?? "none"
        // `width` is the canvas's own width in UIKit points: a Catalyst app in the iPad idiom is drawn at
        // 77 %, so a test scales by the canvas's width on screen over this one to aim the pointer.
        // `typing`, last since it may hold any character, is the text of the box being typed in: PencilKit
        // lists only its strokes as the canvas's accessibility children, so a test cannot read the text view.
        canvas.accessibilityValue = "zoom=\(String(format: "%.3f", Double(zoom)));offset=\(n(Double(canvas.contentOffset.x))),"
            + "\(n(Double(canvas.contentOffset.y)));width=\(n(Double(canvas.bounds.width)))"
            + ";edits=\(editor?.itemRevisions[pageID] ?? 0);selected=\(selected);menu=\(menuShown ? 1 : 0)"
            + ";menus=\(menusShown);trace=\(debugTrace.joined(separator: ","));bar=\(bar.isHidden ? 0 : 1);barFrame=\(n(Double(bar.frame.minX))),\(n(Double(bar.frame.minY))),"
            + "\(n(Double(bar.frame.width))),\(n(Double(bar.frame.height)));palette=\(debugPalette() ? 1 : 0);strokes=\(debugStrokes());items="
            + list.joined(separator: "|") + ";emoji=\(debugEmoji());\(debugInput())" + (debugTyping().map { ";typing=" + $0 } ?? "")
    }

    /// The text of the box being typed in on this page, if any (`debugReport`).
    var debugTyping: () -> String? = { nil }

    /// The emoji list under the box being typed in: `rows,highlighted` (`0,0` when none shows).
    var debugEmoji: () -> String = { "0,0" }

    /// Whether this canvas has the focus with its palette up (`debugReport`).
    var debugPalette: () -> Bool = { false }

    /// How many strokes the page's ink has (`debugReport`: an iPhone test checks that a tap leaves no dot).
    var debugStrokes: () -> Int = { 0 }

    /// What a finger does on the canvas now (`debugReport`, the iPhone's mode tests): `pan=` the fingers its
    /// own scroll takes, `ink=` whether PencilKit's drawing is on, `select=` whether selection mode is.
    var debugInput: () -> String = { "" }

    /// Writes the report again (the text being typed changed).
    func debugRefreshReport() { debugReport() }
    #endif

    // MARK: Gestures

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === itemTap { return !isActive && canPick() && !fingersDraw && itemHit(g) != nil }
        if g === fingerTap { return fingerTapMayStart(at: g.location(in: canvas)) }
        if g === lassoTap { return !isActive && lassoSelected() && canPick() && itemHit(g) != nil }
        if g === hold { return holdTarget(g) != nil }
        if g === secondaryClick { return editor != nil && (isActive || canPick()) }
        if g === rotate { return turnTarget(g) != nil }
        guard g === pan else { return true }
        // Only a drag on an item (or a handle) is ours; any other scrolls.
        guard editor?.canEditItems == true else { return false }
        return model.drag(at: pagePoint(g, down: true), items: items, zoom: Double(zoom)) != nil
    }

    /// While drawing, a held Pencil is ink: only a finger holds an item then. A touch on a
    /// button (a card's, a clip's, the selection bar's) or in a text box being typed in is theirs.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view, v !== canvas {
            if v is UIControl || v is UITextView { return false }
            view = v.superview
        }
        return g !== hold || touch.type != .pencil || isActive
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Picking while drawing never stops PencilKit's own gestures (the lasso still lassoes ink).
        g === itemTap || g === fingerTap || g === lassoTap || g === hold || g === secondaryClick || g === rotate
            || g === touchDown
    }

    /// A finger or the Pencil came down on the canvas: an item menu that is up (on any page)
    /// goes, and is not put back. A touch on the selection bar or a card's button is theirs
    /// (`shouldReceive`), and the menu itself is not in the canvas.
    func touchedDown() {
        menuKeep = nil
        // Even when no "will dismiss" came for it: a menu UIKit still shows must not outlive a touch.
        Self.menuOwner?.dismissMenu()
    }

    /// On a Mac a pointer drag on an item is the item's: the page's scroll (the canvas's own, or
    /// the paged stack's, which takes the pointer while nothing draws) waits until the item drag
    /// has failed (it fails at once off an item), instead of starting with the same mouse event
    /// and keeping the drag from ever beginning (TestFlight 1.0.0). The iPad keeps its behaviour.
    ///
    /// PencilKit's own long press (the "Select All" / "Insert Space" bar, TestFlight 1.0.0: it came
    /// up instead of the item's menu) waits for the hold to fail, which it does at once off an item.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        if g === hold { return Self.isSystemLongPress(other, ours: self) }
        // A finger tap on an item is not a dot: PencilKit's drawing waits for it to fail (at once off
        // an item, or when the finger moves, holds or is joined by another), so a tap leaves no ink.
        if g === fingerTap { return Self.isDrawingRecognizer(other, of: canvas) }
        guard Platform.isMac, g === pan else { return false }
        return other === canvas?.panGestureRecognizer || other === scroller?.panGestureRecognizer
    }

    /// PencilKit's recognizers that draw: the public one and the inner view's second one
    /// (`PageCanvasHost.pencilKitGestures`).
    static func isDrawingRecognizer(_ g: UIGestureRecognizer, of canvas: UIScrollView?) -> Bool {
        guard let canvas = canvas as? PKCanvasView else { return false }
        let drawing = canvas.drawingGestureRecognizer
        return g === drawing || g.isKind(of: type(of: drawing))
    }

    /// Whether a finger tap may begin at `point` (canvas coordinates): picking is allowed, nothing
    /// is selected yet (the selection's own tap handles taps then) and an item is there.
    func fingerTapMayStart(at point: CGPoint) -> Bool {
        guard fingersPick, !isActive, canPick(), canFingerPick() else { return false }
        let z = zoom
        return ItemSelectionModel.hit(ItemFrames.Point(x: Double(point.x / z), y: Double(point.y / z)),
                                      items: items, zoom: Double(zoom)) != nil
    }

    /// A long press that shows a menu (PencilKit's own, on the canvas or its inner views): one
    /// with a hold time. The app's long presses that draw or erase (`ObjectEraserController`'s)
    /// begin at once and never wait.
    static func isSystemLongPress(_ g: UIGestureRecognizer, ours: ItemSelectionController) -> Bool {
        guard let press = g as? UILongPressGestureRecognizer, press !== ours.hold else { return false }
        return press.minimumPressDuration > 0.1
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

    /// What a held finger (or, with selection on, the Pencil) picks: an item, or the empty page
    /// for Paste in selection mode; nil: the hold is not ours (ink, scrolling, PencilKit's).
    private enum HoldTarget { case item(UUID), page }

    private func holdTarget(_ g: UIGestureRecognizer) -> HoldTarget? {
        guard editor != nil else { return nil }
        if isActive {
            if let hit = ItemSelectionModel.hit(pagePoint(g), items: model.candidates(items), zoom: Double(zoom)) {
                return .item(hit.id)
            }
            return scope == .all && commands.canPaste() && editor?.canEditItems == true ? .page : nil
        }
        guard canPick(), !fingersDraw || (fingersPick && canFingerPick()), let hit = itemHit(g) else { return nil }
        return .item(hit.id)
    }

    @objc private func itemTapped(_ g: UIGestureRecognizer) {
        guard !isActive, let hit = itemHit(g) else { return }
        pick(hit.id, menu: false)
    }

    @objc private func lassoTapped(_ g: UITapGestureRecognizer) {
        if let hit = itemHit(g) { pick(hit.id, menu: false) }
    }

    /// A hold is under way, or just ended: the tap the same touch may still end as is not a tap.
    private var holding = false
    /// What the hold under way picked, and where (its menu comes when the finger lifts).
    /// `point` in the canvas's content, `screen` in the window's (the page may scroll under the finger).
    private var heldTarget: (target: HoldTarget, point: CGPoint, screen: CGPoint)?

    /// A hold selects the item at once and shows its menu when the finger lifts, as UIKit's own
    /// edit menus do: a menu shown while the finger is still down went away at the lift (iPad
    /// simulator). A hold that turns into a drag shows no menu.
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            holding = true
            guard let target = holdTarget(g) else { return }
            heldTarget = (target, g.location(in: canvas), g.location(in: nil))
            switch target {
            case .item(let id): pick(id, menu: false)
            case .page: select(nil)
            }
        case .changed:
            // The held finger went on to scroll or drag: that is not a hold for a menu.
            if let current = heldTarget, Self.travelled(from: current.screen, to: g.location(in: nil)) {
                heldTarget = nil
            }
        case .ended:
            DispatchQueue.main.async { [weak self] in self?.holding = false }   // after a tap at the same lift
            guard let current = heldTarget, !Self.travelled(from: current.screen, to: g.location(in: nil)) else {
                heldTarget = nil
                return
            }
            heldTarget = nil
            let epoch = gestureEpoch
            // A moment after the lift: the touch's other recognizers (PencilKit's, which end after this
            // one while drawing) dismiss an edit menu that is already up. Not when a scroll, a pinch or
            // a stroke started meanwhile, or the page still moves: a menu presented while its
            // canvas scrolls stayed up after the page stopped (TestFlight 1.0.0 (6)).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.drag == nil, self.gestureEpoch == epoch, !self.pageMoving else { return }
                switch current.target {
                case .item(let id):
                    guard self.model.selected == id else { return }
                    self.presentMenu()
                    if let shown = self.shownMenu { self.menuKeep = (id, Date().addingTimeInterval(0.8), shown) }
                case .page: if self.model.selected == nil { self.presentMenu(at: current.point) }
                }
            }
        case .cancelled, .failed:
            DispatchQueue.main.async { [weak self] in self?.holding = false }
            heldTarget = nil
        default:
            break
        }
    }

    /// Whether a held finger moved far enough from where the hold began to be a scroll or a drag
    /// (UIKit's long press goes on however far the finger moves once it has begun).
    static func travelled(from a: CGPoint, to b: CGPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > FingerTapTracker.slop * 2
    }

    @objc private func secondaryClicked(_ g: UITapGestureRecognizer) {
        if let hit = ItemSelectionModel.hit(pagePoint(g), items: isActive ? model.candidates(items) : items, zoom: Double(zoom)) {
            pick(hit.id)
        } else if isActive {
            select(nil)
            if commands.canPaste(), editor?.canEditItems == true { presentMenu(at: g.location(in: canvas)) }
        }
    }

    /// A tap selects and never shows the menu (a held finger, a secondary click or the menu
    /// button does); any tap dismisses a menu that is up.
    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard !holding else { return }   // the end of a hold, which showed the menu
        dismissMenu()
        let p = pagePoint(g)
        switch model.tap(at: p, items: items, zoom: Double(zoom), editable: editor?.canEditItems == true) {
        case .select(let id):
            select(id)
        case .keep, .ignore:
            break
        case .edit(let id):
            guard let pageID, let item = editor?.item(id, on: pageID), let edit = onEditText else { return }
            select(nil)
            edit(item)
        case .clear:
            select(nil)
        case .empty:
            onEmptyTap?(p)
        }
    }

    private func travel(_ g: UIPanGestureRecognizer) -> CGPoint {
        guard let canvas else { return .zero }
        return (g as? ItemPanRecognizer)?.travel(in: canvas) ?? g.translation(in: canvas)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            guard let d = model.drag(at: pagePoint(g, down: true), items: items, zoom: Double(zoom)) else { return }
            let id: UUID
            switch d { case .move(let i), .resize(let i, _): id = i }
            guard let item = items.first(where: { $0.id == id }) else { return }
            drag = (d, item)
            heldTarget = nil   // a hold that became a drag shows no menu
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
            let t = travel(g)
            let frame = ItemSelectionModel.frame(for: d, item: item, dx: Double(t.x / zoom), dy: Double(t.y / zoom))
            itemLayer?.preview(item.id, frame: frame)
            refresh()
        case .ended:
            guard let current = drag, let pageID else { return cancelDrag() }
            let (d, item) = current
            let t = travel(g)
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
    /// On a Mac a trackpad rotation reports no touches: the pointer must be over the selected item.
    private func turnTarget(_ g: UIGestureRecognizer) -> Item? {
        guard editor?.canEditItems == true, let id = model.selected, let pageID,
              let item = editor?.item(id, on: pageID), let canvas else { return nil }
        let z = Double(zoom)
        let b = ItemFrames.bounds(itemLayer?.shownFrame(of: id) ?? item.frame, rotation: item.rotation)
        let rect = CGRect(x: b.x * z, y: b.y * z, width: b.w * z, height: b.h * z)
        if g.numberOfTouches == 2 {
            return (0..<2).allSatisfy { rect.contains(g.location(ofTouch: $0, in: canvas)) } ? item : nil
        }
        return Platform.isMac && rect.contains(g.location(in: canvas)) ? item : nil
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
    private func presentMenu(at point: CGPoint? = nil, _ line: Int = #line) {
        guard canvas?.window != nil, let source = point ?? selectedRect.map({ CGPoint(x: $0.midX, y: $0.minY) }) else { return }
        #if DEBUG
        trace("p\(line)")
        #endif
        let id = UUID()
        shownMenu = id
        if let owner = Self.menuOwner, owner !== self { owner.dismissMenu() }   // one menu at a time, on any page
        Self.menuOwner = self
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: id as NSUUID, sourcePoint: source))
    }

    /// The configuration of the menu presented last: a late dismissal of an earlier one does not count.
    private var shownMenu: UUID?

    private func dismissMenu(_ line: Int = #line) {
        #if DEBUG
        if menuShown { trace("d\(line)") }
        #endif
        menuKeep = nil
        menu?.dismissMenu()
    }

    /// A menu a hold brought up for an item, while it may be put back once: the update that a new
    /// selection sets off (the editor's selected-item state, the window's commands) dismissed it
    /// right after it appeared when the hold picked the item while drawing (iPad simulator). Any
    /// dismissal the app asks for (a tap, a scroll, Escape, a drag) clears it.
    private var menuKeep: (item: UUID, until: Date, menu: UUID)?

    #if DEBUG
    /// The last menu events, for the UI tests' report (`debugReport`).
    private var debugTrace: [String] = []
    func trace(_ event: String) {
        debugTrace.append(event)
        if debugTrace.count > 12 { debugTrace.removeFirst() }
    }
    #endif

    /// Whether the item's (or Paste's) edit menu is up, and how many times it came up (debug report).
    private(set) var menuShown = false
    private(set) var menusShown = 0

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuShown = true
        menusShown += 1
        #if DEBUG
        trace("W")
        debugReport()
        #endif
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        let dismissed = (configuration.identifier as? NSUUID).map { $0 as UUID }
        guard dismissed == shownMenu else { return }
        menuShown = false
        if Self.menuOwner === self { Self.menuOwner = nil }
        if let keep = menuKeep, keep.menu == dismissed, Date() < keep.until {
            menuKeep = nil
            #if DEBUG
            trace("k")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.model.selected == keep.item, self.drag == nil, self.turning == nil else { return }
                self.presentMenu()
            }
        }
        #if DEBUG
        trace("X")
        debugReport()
        #endif
    }

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
        let elements = menuElements()
        return elements.isEmpty ? nil : UIMenu(children: elements)
    }

    /// The selected item's menu (`ItemMenu`), or Paste alone with nothing selected: the held
    /// finger's and secondary click's menu, and the selection bar's menu button's.
    func menuElements() -> [UIMenuElement] {
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
        return entries.compactMap { menuElement($0, item: item) }
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

    // MARK: Pointer and keys (Mac)

    /// The pointer's shape at `point` (canvas content coordinates): what a drag
    /// starting there would do (`ItemSelectionModel.drag`), nil: nothing (the
    /// system arrow) or selection is off.
    func pointer(at point: CGPoint) -> ItemPointer? {
        guard isActive, editor?.canEditItems == true else { return nil }
        // While a drag runs the pointer keeps the shape it started with.
        if let current = drag { return ItemPointer.zone(current.0, items: [current.1]) }
        let p = ItemFrames.Point(x: Double(point.x / zoom), y: Double(point.y / zoom))
        let items = self.items
        return ItemPointer.zone(model.drag(at: p, items: items, zoom: Double(zoom)), items: items)
    }

    /// Escape: drops the selection; false when nothing is selected.
    @discardableResult
    func clearSelection() -> Bool {
        guard model.selected != nil else { return false }
        select(nil)
        return true
    }

    /// An arrow key: moves the selected item by `dx`, `dy` screen points (one
    /// delta and one undo step per press); false when nothing can move.
    @discardableResult
    func nudge(dx: Double, dy: Double) -> Bool {
        guard drag == nil, turning == nil, editor?.canEditItems == true, let id = model.selected, let pageID,
              let item = editor?.item(id, on: pageID) else { return false }
        let z = Double(zoom)
        dismissMenu()
        actions?.setFrame(id, to: ItemFrames.moved(item.frame, dx: dx / z, dy: dy / z), on: pageID,
                          name: String(localized: "Move", comment: "Undo action name (Edit menu: Undo …)"))
        refresh()
        return true
    }

    /// Whether an item is selected (keys act on it).
    var hasSelection: Bool { model.selected != nil }

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
