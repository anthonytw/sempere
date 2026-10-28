import Sempere

/// `markersBehindText` (format.md §5.4, §8.2.3) on the canvas. PencilKit
/// draws all ink in one layer above the item layer, so marker strokes cannot
/// sit between the page's items. Instead the text boxes of content layers are
/// drawn a second time above the ink, multiplied onto it
/// (`PageCanvasHost.textOverlay`): their glyphs stay dark over a highlighter,
/// as if it were behind them, and over dark ink; where a glyph has no pixel
/// the overlay changes nothing. Exports draw the format's order exactly.
/// Images stay under the ink (a multiplied copy would let ink show through).
enum MarkerOrder {
    /// The items to draw above the ink for a note with `meta`: none unless it
    /// draws markers behind text.
    static func textOverlay(_ items: [Item], meta: NoteMeta) -> [Item] {
        guard meta.markersBehindText else { return [] }
        return items.filter { $0.kind == .text && !$0.layer.isBackground }
    }
}
