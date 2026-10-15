import Foundation

extension NoteOps {
    /// Space between a new item and the item above it, page points.
    public static let stackGap = 12.0

    /// `frame` moved down until it covers none of `items` (background items,
    /// such as a PDF page under the ink, do not count): below the lowest item
    /// it would cover, then below the next one it reaches, and so on, so a new
    /// item lands under the last one rather than on top of it. Used where the
    /// app and the CLI pick a frame by themselves (a picture, a clip, a
    /// recording's card or an equation added without a frame, a position or a
    /// drop point); a frame the user chose is never moved.
    ///
    /// On a finite page whose bottom the moved frame would pass, and past the
    /// format's extent, there is no free room below: `frame` is returned as it
    /// was (it may overlap). The work is bounded by the item count: each step
    /// moves past an item for good.
    public static func unoccupied(_ frame: Rect, among items: [Item], pageSize: PageSize) -> Rect {
        guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return frame }
        let obstacles = items.lazy.filter { !$0.layer.isBackground }
            .map { ItemFrames.bounds($0.frame, rotation: $0.rotation) }
            .filter { [$0.x, $0.y, $0.w, $0.h].allSatisfy(\.isFinite) && $0.w > 0 && $0.h > 0 }
        let boxes = Array(obstacles)
        var r = frame
        for _ in 0...boxes.count {
            let hits = boxes.filter { Self.overlaps(r, $0) }
            guard let lowest = hits.max(by: { $0.y + $0.h < $1.y + $1.h }) else { break }
            r.y = lowest.y + lowest.h + stackGap
        }
        let bottom = r.y + r.h
        if !bottom.isFinite || bottom > Limits.extent || (!pageSize.infinite && bottom > pageSize.height) { return frame }
        return r.rounded
    }

    /// Whether two rectangles share some area (touching edges do not count).
    static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }
}
