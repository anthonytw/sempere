import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Recognises the second click of a double-click: a touch that ends with
/// `UITouch.tapCount` 2 or more. The system counts the clicks from their own
/// timestamps (on a Mac, the event's click count), so a main thread kept busy
/// by the first click (it selects the row and opens the note) changes nothing,
/// where a two-tap `UITapGestureRecognizer`'s timer might. It never cancels or
/// delays touches and recognises alongside everything else, so the list's own
/// selection works as before.
final class DoubleClickRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// What a double-click does; replaced when the cell shows another row.
    var handler: () -> Void = {}

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
        // A Mac's mouse and trackpad clicks are pointer touches (as for the object eraser).
        allowedTouchTypes = Self.touchTypes.map { NSNumber(value: $0.rawValue) }
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() { handler() }

    /// The touches it watches: the pointer as well as fingers.
    nonisolated static let touchTypes: [UITouch.TouchType] = [.indirectPointer, .direct, .indirect]

    /// Whether a touch ending with `tapCount` is a double-click.
    nonisolated static func isDoubleClick(tapCount: Int) -> Bool { tapCount >= 2 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.count != 1 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = touches.contains { Self.isDoubleClick(tapCount: $0.tapCount) } ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Puts a `DoubleClickRecognizer` running `action` on the list cell that shows
/// this view (one per cell, whose handler follows the row the cell shows now).
/// A SwiftUI tap gesture on the row never sees the clicks the list's
/// collection view takes for selection (TestFlight build 7).
struct DoubleClickAttacher: UIViewRepresentable {
    let action: () -> Void

    final class Probe: UIView {
        var action: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            var view = superview
            while let v = view, !(v is UICollectionViewCell) { view = v.superview }
            // Outside a list (no cell): the nearest ancestor that takes touches.
            guard let host = view ?? superview else { return }
            let recognizer = host.gestureRecognizers?.lazy.compactMap { $0 as? DoubleClickRecognizer }.first
                ?? { let r = DoubleClickRecognizer(); host.addGestureRecognizer(r); return r }()
            recognizer.handler = action
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        probe.action = action
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.action = action
        probe.attach()
    }
}
