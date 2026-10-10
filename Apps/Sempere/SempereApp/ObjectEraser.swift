import Foundation
import Sempere
import PencilKit
import UIKit

/// The app's object (stroke) eraser, used instead of PencilKit's when the
/// tool picker's eraser is in object mode: PencilKit's `.vector` eraser has
/// no size, this one has `ObjectEraserSize` presets.
///
/// While it is active, `PageCanvasHost` turns PencilKit's drawing gesture off
/// and this controller's gesture takes the touches: every stroke whose ink
/// the swept circle touches is removed from `canvas.drawing` (at the next
/// display frame, and at touch-up). Only strokes near the sweep are looked
/// at (`StrokeBoundsGrid`). Setting
/// `drawing` reaches the canvas delegate like any PencilKit edit, so the
/// `StrokeLedger` turns it into the same `removeStroke` ops as PencilKit's own
/// eraser, and autosave is unchanged. One gesture is one undo step on the
/// canvas's undo manager; undo puts the strokes back (the ledger revives
/// their ids, or gives them new ids with `parent` once the removal is on
/// disk, format.md §5.2), redo removes them again.
@MainActor
final class ObjectEraserController: NSObject, UIGestureRecognizerDelegate {
    private weak var canvas: PKCanvasView?
    private weak var host: UIView?
    /// Touch-down to touch-up, with no movement threshold, so a tap erases too.
    private let press = UILongPressGestureRecognizer()
    /// Pointer or Pencil hover (Mac, iPads with hover): shows the cursor.
    private let hover = UIHoverGestureRecognizer()
    private let cursor = EraserCursorView()
    private var savedMinimumTouches: Int?
    /// The scroll view's pan touch types before the eraser took the Pencil.
    private var savedPanTouchTypes: [NSNumber]?

    // One gesture's state. The strokes are taken once at touch-down; erased
    // ones are marked dead rather than removed, so indices stay valid.
    private var before: PKDrawing?
    private var remaining: [PKStroke] = []
    private var alive: [Bool] = []
    private var bounds: [StrokeBoundsGrid.Box] = []
    private var grid: StrokeBoundsGrid?
    private var shapes: [StrokeHitShape?] = []
    private var last: EraserPoint?
    /// Strokes erased since the canvas was last given the drawing. The
    /// first erase gives it at once; later ones wait for the next display
    /// frame (`frameLink`), so the canvas, and the ledger behind it, take
    /// at most about one drawing per frame; touch-up gives the rest.
    private var pending = false
    private var frameLink: CADisplayLink?
    /// The stroke count of the drawing this gesture last gave the canvas.
    private var shownCount = 0
    private var radius = ObjectEraserSize.defaultRadius

    /// Whether the eraser takes touches (object eraser selected, note editable).
    private(set) var isActive = false
    /// A gesture is erasing now (between its first touch and its end).
    var isErasing: Bool { before != nil }

    func attach(to host: UIView, canvas: PKCanvasView) {
        self.host = host
        self.canvas = canvas
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.addTarget(self, action: #selector(pressed(_:)))
        press.delegate = self
        press.isEnabled = false
        canvas.addGestureRecognizer(press)
        hover.addTarget(self, action: #selector(hovered(_:)))
        hover.isEnabled = false
        canvas.addGestureRecognizer(hover)
        cursor.isHidden = true
        host.addSubview(cursor)
    }

    /// Turns the eraser on or off. On: PencilKit's drawing gesture is off, and
    /// with finger drawing allowed a one-finger drag erases (scrolling takes two).
    func setActive(_ active: Bool) {
        guard let canvas else { return }
        if active {
            // The Pencil erases and never scrolls.
            if savedPanTouchTypes == nil {
                let saved = canvas.panGestureRecognizer.allowedTouchTypes
                savedPanTouchTypes = saved
                canvas.panGestureRecognizer.allowedTouchTypes = Self.panTouchTypesWithoutPencil(saved)
            }
            let fingers = Self.fingersDraw(canvas)
            press.allowedTouchTypes = Self.pressTouchTypes(fingersDraw: fingers, pointerErases: Platform.isMac)
            if fingers, savedMinimumTouches == nil {
                savedMinimumTouches = canvas.panGestureRecognizer.minimumNumberOfTouches
                canvas.panGestureRecognizer.minimumNumberOfTouches = 2
            } else if !fingers, let saved = savedMinimumTouches {
                canvas.panGestureRecognizer.minimumNumberOfTouches = saved
                savedMinimumTouches = nil
            }
        } else {
            if let saved = savedPanTouchTypes {
                canvas.panGestureRecognizer.allowedTouchTypes = saved
                savedPanTouchTypes = nil
            }
            if let saved = savedMinimumTouches {
                canvas.panGestureRecognizer.minimumNumberOfTouches = saved
                savedMinimumTouches = nil
            }
            cursor.isHidden = true
        }
        isActive = active
        press.isEnabled = active
        hover.isEnabled = active
    }

    /// The touches that erase: the Pencil, fingers when they draw, and on a
    /// Mac the mouse and trackpad (`indirectPointer`), which PencilKit's own
    /// gesture is switched off for while this eraser is active.
    static func pressTouchTypes(fingersDraw: Bool, pointerErases: Bool) -> [NSNumber] {
        var types = [UITouch.TouchType.pencil]
        if fingersDraw { types.append(.direct) }
        if pointerErases { types.append(.indirectPointer) }
        return types.map { NSNumber(value: $0.rawValue) }
    }

    /// The scroll view's pan touch types minus the Pencil: fingers, and the
    /// pointer and trackpad on a Mac or with a keyboard, still scroll.
    static func panTouchTypesWithoutPencil(_ types: [NSNumber]) -> [NSNumber] {
        types.filter { $0.intValue != UITouch.TouchType.pencil.rawValue }
    }

    /// Whether finger touches draw on `canvas` (and so erase with this eraser).
    static func fingersDraw(_ canvas: PKCanvasView) -> Bool {
        switch canvas.drawingPolicy {
        case .anyInput: return true
        case .pencilOnly: return false
        default: return !UIPencilInteraction.prefersPencilOnlyDrawing
        }
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch zoom and two-finger scrolling keep working.
        other === canvas?.pinchGestureRecognizer || other === canvas?.panGestureRecognizer
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard let canvas else { return }
        let p = pagePoint(g.location(in: canvas))
        showCursor(at: g.location(in: host))
        switch g.state {
        case .began: begin(at: p)
        case .changed: move(to: p)
        case .ended, .cancelled, .failed: end(at: p)
        default: break
        }
    }

    /// Touch-down: erases what the eraser touches at `p` (page points).
    func begin(at p: EraserPoint) {
        guard let canvas else { return }
        radius = ObjectEraserSize.load()
        let drawing = canvas.drawing
        before = drawing
        remaining = drawing.strokes
        alive = Array(repeating: true, count: remaining.count)
        shownCount = remaining.count
        bounds = remaining.map { stroke in
            let b = stroke.renderBounds
            return StrokeBoundsGrid.Box(minX: Double(b.minX), minY: Double(b.minY), maxX: Double(b.maxX), maxY: Double(b.maxY))
        }
        grid = StrokeBoundsGrid(bounds)
        shapes = Array(repeating: nil, count: remaining.count)
        last = p
        erase(to: p)
    }

    /// The touch moved to `p`: erases what the sweep from the last point touches.
    func move(to p: EraserPoint) {
        erase(to: p)
    }

    /// Touch-up (or a cancelled gesture): one undo step for the whole gesture.
    func end(at p: EraserPoint) {
        erase(to: p)
        flush()
        finish()
    }

    /// Drops the gesture in progress without touching the canvas: the drawing
    /// under it was replaced (another page or note was loaded). The rest of
    /// the gesture erases nothing, and it registers no undo, so strokes of
    /// the old page can never be written onto the new one.
    func cancelGesture() {
        stopFrames()
        before = nil
        reset()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            radius = ObjectEraserSize.load()
            showCursor(at: g.location(in: host))
        default:
            if press.state == .possible { cursor.isHidden = true }
        }
    }

    /// Drawing (page) coordinates of a point in the canvas's bounds.
    private func pagePoint(_ p: CGPoint) -> EraserPoint {
        let z = max(canvas?.zoomScale ?? 1, 0.0001)
        return EraserPoint(x: Double(p.x / z), y: Double(p.y / z))
    }

    private func showCursor(at p: CGPoint) {
        let diameter = CGFloat(2 * radius) * (canvas?.zoomScale ?? 1)
        cursor.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        cursor.center = p
        cursor.isHidden = false
        host?.bringSubviewToFront(cursor)
    }

    private func erase(to p: EraserPoint) {
        guard canvas != nil, let from = last, let grid else { return }
        last = p
        let r = radius
        let sweep = StrokeBoundsGrid.Box(minX: min(from.x, p.x) - r, minY: min(from.y, p.y) - r,
                                         maxX: max(from.x, p.x) + r, maxY: max(from.y, p.y) + r)
        var hit = false
        for i in grid.candidates(sweep) where alive[i] {
            if shapes[i] == nil {
                // Cheap reject on PencilKit's bounds before sampling the path.
                let b = bounds[i]
                if b.maxX < sweep.minX || b.minX > sweep.maxX || b.maxY < sweep.minY || b.minY > sweep.maxY {
                    continue
                }
                shapes[i] = StrokeHitShape(remaining[i])
            }
            if shapes[i]?.intersects(sweepFrom: from, to: p, radius: r) == true {
                alive[i] = false
                hit = true
            }
        }
        guard hit else { return }
        pending = true
        if frameLink == nil {
            flush()
            guard isErasing else { return }
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            frameLink = link
        }
    }

    /// A display frame: gives the canvas what was erased since the last one;
    /// with nothing new, waits for the next erase to give it at once again.
    @objc private func frame() {
        if pending { flush() } else { stopFrames() }
    }

    /// Gives the canvas the strokes still alive, if any were erased since it
    /// last got them. Setting `drawing` reaches the canvas delegate, so the
    /// ledger sees the change. A drawing replaced behind the gesture's back
    /// (defence in depth for `cancelGesture`) is never overwritten: the
    /// gesture is dropped instead.
    private func flush() {
        guard pending, let canvas else { return }
        pending = false
        guard canvas.drawing.strokes.count == shownCount else {
            cancelGesture()
            return
        }
        let kept = remaining.indices.filter { alive[$0] }.map { remaining[$0] }
        shownCount = kept.count
        canvas.drawing = PKDrawing(strokes: kept)
    }

    private func stopFrames() {
        frameLink?.invalidate()
        frameLink = nil
        pending = false
    }

    private func reset() {
        remaining = []
        alive = []
        bounds = []
        grid = nil
        shapes = []
        last = nil
    }

    private func finish() {
        stopFrames()
        defer {
            before = nil
            reset()
            if !hover.isEnabled || hover.state == .possible { cursor.isHidden = true }
        }
        guard let canvas, let before else { return }
        let after = canvas.drawing
        guard after.strokes.count != before.strokes.count else { return }
        registerUndo(restoring: DrawingBox(before), redoing: DrawingBox(after), action: String(localized: "Erase", comment: "Undo action name (Edit menu: Undo …)"))
    }

    /// One undo step that sets the drawing back to `restoring`, and its redo.
    private func registerUndo(restoring: DrawingBox, redoing: DrawingBox, action: String) {
        guard let undo = canvas?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.canvas?.drawing = restoring.drawing
                target.registerUndo(restoring: redoing, redoing: restoring, action: action)
            }
        }
        undo.setActionName(action)
    }
}

/// A drawing held by the undo stack.
final class DrawingBox: @unchecked Sendable {
    let drawing: PKDrawing
    init(_ drawing: PKDrawing) { self.drawing = drawing }
}

/// The eraser's outline at the touch point.
final class EraserCursorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.white.withAlphaComponent(0.25)
        layer.borderColor = UIColor.darkGray.cgColor
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }
}

extension StrokeHitShape {
    /// The ink of a canvas stroke as the eraser sees it: its path sampled
    /// every 2 pt (only the visible ranges of a pixel-erased stroke), through
    /// its transform, with the drawn half-width at each sample (`NibSize`).
    init(_ stroke: PKStroke) {
        let tool = InkTool(stroke.ink.inkType)
        let t = stroke.transform
        let scale = Double(abs(t.a * t.d - t.b * t.c)).squareRoot()
        let ranges: [ClosedRange<CGFloat>?] = stroke.mask == nil ? [nil] : stroke.maskedPathRanges.map { Optional($0) }
        var runs: [[Sample]] = []
        for range in ranges {
            var run: [Sample] = []
            for p in stroke.path.interpolatedPoints(in: range, by: .distance(2)) {
                let at = p.location.applying(t)
                let size = NibSize.formatSize(p.size, tool: tool)
                run.append(Sample(x: Double(at.x), y: Double(at.y), radius: max(size.w, size.h, 1) / 2 * scale))
            }
            runs.append(run)
        }
        self.init(runs: runs)
    }
}

enum ObjectEraser {
    /// `drawing` without the strokes an eraser of `radius` touches moving
    /// from `a` to `b` (page points), and how many were removed.
    static func erasing(_ drawing: PKDrawing, from a: EraserPoint, to b: EraserPoint,
                        radius: Double) -> (drawing: PKDrawing, removed: Int) {
        let kept = drawing.strokes.filter { !StrokeHitShape($0).intersects(sweepFrom: a, to: b, radius: radius) }
        return (PKDrawing(strokes: kept), drawing.strokes.count - kept.count)
    }
}
