import Foundation
import Sempere

/// The pointer over placed items while they can be selected (Mac, docs/mac.md
/// "Placed items"): a four-way arrow over an item a drag would move, a
/// two-way arrow along the drag over a resize handle, and the system arrow
/// elsewhere, so it is plain that a drag moves or resizes. The zone comes from
/// the same rule as the drag (`ItemSelectionModel.drag(at:)`); the outlines
/// (`UIBezierPath`) are the app's.
public enum ItemPointer: Equatable, Sendable {
    case move
    /// A resize handle, its two-way arrow at `degrees` (0: left–right; clockwise, screen axes).
    case resize(degrees: Double)

    /// The pointer for `drag` (`ItemSelectionModel.drag(at:)` at the pointer), nil: none.
    public static func zone(_ drag: ItemSelectionModel.Drag?, items: [Item]) -> ItemPointer? {
        switch drag {
        case nil: return nil
        case .move: return .move
        case .resize(let id, let handle):
            guard let item = items.first(where: { $0.id == id }) else { return .move }
            return .resize(degrees: angle(of: handle, frame: item.frame, rotation: item.rotation))
        }
    }

    /// The direction a handle drags in, degrees: from the frame's centre out
    /// through the handle (a corner of a wide image is not at 45°), turned
    /// with the item, folded into 0..<180 (a two-way arrow).
    public static func angle(of handle: ItemFrames.Handle, frame: Rect, rotation: Double?) -> Double {
        let p = ItemFrames.point(of: handle, frame, rotation: rotation)
        let cx = frame.x + frame.w / 2, cy = frame.y + frame.h / 2
        var a = atan2(p.y - cy, p.x - cx) * 180 / .pi
        a = a.truncatingRemainder(dividingBy: 180)
        if a < 0 { a += 180 }
        return (a * 2).rounded() / 2
    }

    /// A region identifier: UIKit asks for the style again when it changes.
    public var identifier: String {
        switch self {
        case .move: return "item.move"
        case .resize(let d): return "item.resize.\(d)"
        }
    }
}
