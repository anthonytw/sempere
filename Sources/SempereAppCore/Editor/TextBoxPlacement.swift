import Foundation
import Sempere

/// Where text boxes go and what the style bar offers (pure, tested).
public enum TextBoxPlacement {
    /// Sizes in the size menu.
    public static let sizes: [Double] = [10, 12, 14, 16, 18, 24, 32, 48, 72]
    /// Room kept to the page's right edge.
    public static let margin = 16.0
    /// Width of a new box, at most (page points).
    public static let newBoxWidth = 320.0
    /// Narrowest new box.
    public static let minimumWidth = 60.0

    /// A new box's frame for a tap at `p`: its first line there (the tap is
    /// on the line's middle), as wide as `newBoxWidth` or up to the page's
    /// margin, at least `minimumWidth`, one line tall.
    public static func newFrame(at p: ItemFrames.Point, pageWidth: Double, size: Double) -> Rect {
        let lineHeight = 1.2 * size
        let room = pageWidth - margin - p.x
        let w = max(minimumWidth, min(newBoxWidth, room.isFinite ? room : 0))
        let x = min(p.x, max(0, pageWidth - w))
        return Rect(x: InkJSON.round3(max(0, x)), y: InkJSON.round3(max(0, p.y - lineHeight / 2)), w: InkJSON.round3(w),
                    h: InkJSON.round3(lineHeight))
    }

    /// The text box a tap at `p` lands on (topmost, with the selection's slop).
    public static func textBox(at p: ItemFrames.Point, in items: [Item], zoom: Double) -> Item? {
        let texts = items.filter { $0.kind == .text && $0.text != nil }
        return ItemFrames.item(at: p, in: texts, slop: ItemSelectionModel.slop / max(zoom, 0.01))
    }
}
