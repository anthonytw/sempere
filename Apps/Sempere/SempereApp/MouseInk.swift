import Foundation
import PencilKit
import Sempere
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The "Smooth Mouse Strokes" setting (Settings → General, Mac only) and the
/// rules for when the app, not PencilKit, draws a pointer stroke
/// (docs/mac.md "Mouse and trackpad").
enum MouseSmoothing {
    /// `@AppStorage` key of the user's choice (a `StrokeSmoothing.Level` raw value).
    static let key = "Sempere.mouseSmoothing"
    /// Light unless the user picks otherwise.
    static let defaultLevel = StrokeSmoothing.Level.light

    /// The stored level, `defaultLevel` when never set or not a level.
    static func load(_ defaults: UserDefaults = .standard) -> StrokeSmoothing.Level {
        defaults.string(forKey: key).flatMap(StrokeSmoothing.Level.init(rawValue:)) ?? defaultLevel
    }

    /// The only touches the app's mouse ink takes: the Mac's mouse and
    /// trackpad. The Pencil and fingers never reach it.
    static let touchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    /// Whether the app draws pointer strokes itself (and PencilKit's drawing
    /// gesture is off): on a Mac, with smoothing on, an ink tool selected and
    /// the ruler hidden (PencilKit's ruler snaps its own strokes), on a page
    /// that can be drawn on. Everywhere else PencilKit draws, as before.
    static func takesPointer(isMac: Bool, level: StrokeSmoothing.Level, editable: Bool,
                             inkingTool: Bool, rulerActive: Bool) -> Bool {
        isMac && level != .off && editable && inkingTool && !rulerActive
    }

    /// The stroke for the pointer's raw samples (canvas content coordinates:
    /// page points times `zoom`, seconds) drawn with `tool`: smoothed by
    /// `StrokeSmoothing.finalPath`, in page points, every point at the tool's
    /// width (through `NibSize`, as a loaded stroke of that width would be),
    /// with the mouse's constant force and tilt. Nil without a sample.
    static func stroke(samples: [StrokeSmoothing.Sample], zoom: CGFloat, tool: PKInkingTool,
                       parameters: StrokeSmoothing.Parameters, creationDate: Date) -> PKStroke? {
        let path = StrokeSmoothing.finalPath(samples, parameters: parameters)
        guard let t0 = path.first?.t else { return nil }
        let z = Double(max(zoom, 0.0001))
        let width = Double(tool.width)
        let size = NibSize.pkSize(w: width, h: width, tool: InkTool(tool.inkType))
        let points = path.map { s in
            PKStrokePoint(location: CGPoint(x: s.x / z, y: s.y / z), timeOffset: max(s.t - t0, 0), size: size,
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: points, creationDate: creationDate),
                        transform: .identity, mask: nil)
    }
}

/// One pointer drag, with every coalesced sample and its timestamp (a
/// `UIPanGestureRecognizer` reports one location per event and no time).
final class PointerInkGesture: UIGestureRecognizer {
    /// Samples received since the target last took them, canvas coordinates.
    private(set) var pending: [StrokeSmoothing.Sample] = []
    private weak var tracked: UITouch?

    func takePending() -> [StrokeSmoothing.Sample] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    private func record(_ touch: UITouch, _ event: UIEvent?) {
        guard let view else { return }
        for t in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = t.location(in: view)
            pending.append(StrokeSmoothing.Sample(x: Double(p.x), y: Double(p.y), t: t.timestamp))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A right-click (or control-click) selects an item and shows its menu; it never draws.
        if tracked == nil, Self.isSecondaryClick(buttons: event.buttonMask, modifiers: event.modifierFlags) {
            state = .failed
            return
        }
        guard tracked == nil, let touch = touches.first, touches.count == 1 else {
            if tracked == nil { state = .failed }
            return
        }
        tracked = touch
        let p = touch.location(in: view)
        pending = [StrokeSmoothing.Sample(x: Double(p.x), y: Double(p.y), t: touch.timestamp)]
        state = .began
    }

    /// Whether a click is the secondary one (the right button, or the left with ⌃).
    static func isSecondaryClick(buttons: UIEvent.ButtonMask, modifiers: UIKeyModifierFlags) -> Bool {
        buttons.contains(.secondary) || modifiers.contains(.control)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        record(touch, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        record(touch, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        pending = []
    }
}

/// Draws strokes made with a Mac's mouse or trackpad, smoothed
/// (`StrokeSmoothing`), in place of PencilKit's drawing gesture, which
/// `PageCanvasHost` turns off while this is active (`MouseSmoothing.takesPointer`).
///
/// While the pointer drags, the streamlined line is shown in a shape layer over
/// the ink. When it ends, the finished stroke (`MouseSmoothing.stroke`) is
/// appended to `canvas.drawing`: that reaches the canvas delegate like a
/// PencilKit stroke, so the `StrokeLedger` adds it with an `addStroke` op and
/// autosave is unchanged. One stroke is one undo step on the canvas's undo
/// manager, as for the object eraser. Strokes already on the page are never
/// changed, and the Pencil and fingers never come here.
@MainActor
final class MouseInkController: NSObject, UIGestureRecognizerDelegate {
    private weak var canvas: PKCanvasView?
    private let gesture = PointerInkGesture()
    private let preview = CAShapeLayer()
    private var savedPanTouchTypes: [NSNumber]?

    // One stroke's state.
    private var raw: [StrokeSmoothing.Sample] = []
    private var shown: [CGPoint] = []
    private var filter: StrokeSmoothing.StreamlineFilter?
    private var tool: PKInkingTool?
    private var started: Date?

    /// Called when a stroke begins (the stack gives its page the focus).
    var onBegin: (() -> Void)?

    /// Whether pointer strokes are drawn here.
    private(set) var isActive = false
    /// A stroke is being drawn now.
    var isDrawing: Bool { filter != nil }

    func attach(to canvas: PKCanvasView) {
        self.canvas = canvas
        gesture.addTarget(self, action: #selector(dragged(_:)))
        gesture.allowedTouchTypes = MouseSmoothing.touchTypes
        gesture.delegate = self
        gesture.isEnabled = false
        canvas.addGestureRecognizer(gesture)
        preview.fillColor = nil
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.zPosition = 1_000
        canvas.layer.addSublayer(preview)
    }

    /// Turns pointer drawing on or off. While on, the pointer does not drag
    /// the canvas (a two-finger scroll still does).
    func setActive(_ active: Bool) {
        guard let canvas, active != isActive else { return }
        isActive = active
        gesture.isEnabled = active
        let pan = canvas.panGestureRecognizer
        if active {
            savedPanTouchTypes = pan.allowedTouchTypes
            pan.allowedTouchTypes = pan.allowedTouchTypes.filter { $0.intValue != UITouch.TouchType.indirectPointer.rawValue }
        } else {
            if let saved = savedPanTouchTypes { pan.allowedTouchTypes = saved }
            savedPanTouchTypes = nil
            cancelStroke()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === canvas?.pinchGestureRecognizer || other === canvas?.panGestureRecognizer
    }

    @objc private func dragged(_ g: PointerInkGesture) {
        let samples = g.takePending()
        switch g.state {
        case .began, .changed, .ended:
            var rest = samples[...]
            // A quick click may report its end without its beginning.
            if g.state == .began || !gestureStarted, let first = rest.first {
                gestureStarted = true
                begin(at: first)
                rest = rest.dropFirst()
            }
            add(rest)
            if g.state == .ended {
                end()
                gestureStarted = false
            }
        default:
            cancelStroke()
            gestureStarted = false
        }
    }
    /// The gesture's beginning was handled (the stroke may still have been refused).
    private var gestureStarted = false

    /// The pointer went down at `s` (canvas content coordinates). Nothing
    /// happens without an ink tool or with smoothing switched off meanwhile.
    func begin(at s: StrokeSmoothing.Sample) {
        cancelStroke()
        guard let canvas, let tool = canvas.tool as? PKInkingTool,
              let parameters = MouseSmoothing.load().parameters else { return }
        self.tool = tool
        started = Date()
        filter = StrokeSmoothing.StreamlineFilter(parameters: parameters)
        let z = canvas.zoomScale
        preview.lineWidth = max(tool.width * z, 1)
        preview.strokeColor = (tool.inkType == .marker ? tool.color.withAlphaComponent(0.5) : tool.color).cgColor
        add([s])
        onBegin?()
    }

    /// More samples of the stroke under way.
    func add<C: Collection>(_ samples: C) where C.Element == StrokeSmoothing.Sample {
        guard filter != nil else { return }
        for s in samples where raw.count < StrokeSmoothing.maxRawSamples {
            raw.append(s)
            if let f = filter?.add(s) { shown.append(CGPoint(x: f.x, y: f.y)) }
        }
        let path = CGMutablePath()
        if let first = shown.first {
            path.move(to: first)
            if shown.count == 1 { path.addLine(to: first) }   // a dot
            for p in shown.dropFirst() { path.addLine(to: p) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = path
        CATransaction.commit()
    }

    /// The pointer went up: the finished stroke goes onto the page, one undo step.
    func end() {
        defer { cancelStroke() }
        guard let canvas, let tool, let started, let parameters = filter?.parameters,
              let stroke = MouseSmoothing.stroke(samples: raw, zoom: canvas.zoomScale, tool: tool,
                                                 parameters: parameters, creationDate: started)
        else { return }
        let before = canvas.drawing
        var after = before
        after.strokes.append(stroke)
        canvas.drawing = after
        registerUndo(restoring: DrawingBox(before), redoing: DrawingBox(after))
    }

    /// Drops the stroke under way without touching the canvas (the drawing is
    /// being replaced, or pointer drawing was switched off).
    func cancelStroke() {
        raw = []
        shown = []
        filter = nil
        tool = nil
        started = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = nil
        CATransaction.commit()
    }

    /// The streamlined line on screen now (canvas content coordinates), for tests.
    var previewPoints: [CGPoint] { shown }

    private func registerUndo(restoring: DrawingBox, redoing: DrawingBox) {
        guard let undo = canvas?.undoManager else { return }
        let action = String(localized: "Draw", comment: "Undo action name (Edit menu: Undo …) for a mouse stroke")
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.canvas?.drawing = restoring.drawing
                target.registerUndo(restoring: redoing, redoing: restoring)
            }
        }
        undo.setActionName(action)
    }
}
