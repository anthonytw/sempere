import PencilKit
import UIKit

/// The lasso of "Convert to Math" (docs/attachments.md §14 G1 part 2): while
/// the editor picks ink (`NoteEditor.mathLassoActive`), `PageCanvasHost`
/// turns PencilKit's drawing gesture off and this controller's pan takes the
/// Pencil, one finger and the pointer: the loop is drawn dashed over the ink
/// and handed over in page points when it ends. Two fingers still scroll and
/// zoom. PencilKit's lasso is not used: its selection (`PKCanvasView.selection`,
/// iOS 27) gives only the ids of the strokes PencilKit's own rule picked,
/// while this loop goes to `InkLasso`, the rule `sempere recognize-math`
/// uses, and works the same with the Pencil, a finger and the pointer on the
/// iPad and the Mac.
@MainActor
final class MathLassoController: NSObject, UIGestureRecognizerDelegate {
    private weak var canvas: PKCanvasView?
    private let pan = UIPanGestureRecognizer()
    private let shape = CAShapeLayer()
    /// The loop so far, in the canvas's content coordinates.
    private var points: [CGPoint] = []
    private var savedMinimumTouches: Int?
    private var savedPanTouchTypes: [NSNumber]?
    /// Most points kept for one loop (the core thins further, `InkLasso.maxVertices`).
    static let maxPoints = 4_096

    /// Called with the loop in page points when a lasso ends.
    var onFinish: (([CGPoint]) -> Void)?
    private(set) var isActive = false

    func attach(to canvas: PKCanvasView) {
        self.canvas = canvas
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.isEnabled = false
        canvas.addGestureRecognizer(pan)
        shape.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        shape.strokeColor = UIColor.systemBlue.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [6, 4]
        shape.zPosition = 1_000
        canvas.layer.addSublayer(shape)
    }

    /// The touches that draw the loop: the Pencil, a finger and the pointer.
    static let touchTypes: [NSNumber] = [UITouch.TouchType.pencil, .direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }

    func setActive(_ active: Bool) {
        guard let canvas, active != isActive else { return }
        isActive = active
        pan.isEnabled = active
        if active {
            pan.allowedTouchTypes = Self.touchTypes
            savedMinimumTouches = canvas.panGestureRecognizer.minimumNumberOfTouches
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
            savedPanTouchTypes = canvas.panGestureRecognizer.allowedTouchTypes
            canvas.panGestureRecognizer.allowedTouchTypes = ObjectEraserController.panTouchTypesWithoutPencil(
                canvas.panGestureRecognizer.allowedTouchTypes)
        } else {
            if let saved = savedMinimumTouches { canvas.panGestureRecognizer.minimumNumberOfTouches = saved }
            if let saved = savedPanTouchTypes { canvas.panGestureRecognizer.allowedTouchTypes = saved }
            savedMinimumTouches = nil
            savedPanTouchTypes = nil
            clear()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === canvas?.pinchGestureRecognizer
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let canvas else { return }
        let p = g.location(in: canvas)
        switch g.state {
        case .began:
            points = [p]
        case .changed:
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 2, points.count < Self.maxPoints {
                points.append(p)
            }
        case .ended:
            points.append(p)
            let z = max(canvas.zoomScale, 0.0001)
            let loop = points.map { CGPoint(x: $0.x / z, y: $0.y / z) }
            clear()
            onFinish?(loop)
            return
        default:
            clear()
            return
        }
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for q in points.dropFirst() { path.addLine(to: q) }
            path.close()
        }
        shape.path = path.cgPath
    }

    private func clear() {
        points = []
        shape.path = nil
    }
}
