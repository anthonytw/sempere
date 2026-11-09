import Foundation
import Sempere

/// What selecting items does, decided without UIKit (tested): which item a
/// touch picks, what a tap does, whether a drag moves or resizes, and the
/// frame it leads to. One model for every kind (text boxes, images, PDF
/// pages, videos, math and kinds this version does not know) and every way
/// of selecting (selection mode, the lasso, a finger held on an item, a
/// secondary click, the text tool): docs/attachments.md §13 "Selecting items".
public struct ItemSelectionModel {
    /// Handle radius on screen, in points; touches this close to a handle resize.
    public static let handleRadius = 22.0
    /// Extra room around an item that still selects it, on screen.
    public static let slop = 8.0

    /// Which items a selection can pick.
    public enum Scope: Equatable {
        /// Every item (selection mode, the lasso, a held finger, a secondary click).
        case all
        /// Text boxes only (the text tool: a tap elsewhere starts a new box).
        case textBoxes

        public func includes(_ item: Item) -> Bool {
            switch self {
            case .all: return true
            case .textBoxes: return item.kind == .text && item.text != nil
            }
        }
    }

    /// The selected item, if any.
    public var selected: UUID?
    public var scope = Scope.all

    public init(selected: UUID? = nil, scope: Scope = .all) {
        self.selected = selected
        self.scope = scope
    }

    /// What a drag starting at a page point does.
    public enum Drag: Equatable {
        case move(UUID)
        case resize(UUID, ItemFrames.Handle)
    }

    /// What a tap does. A tap never shows the item's menu: that is a held
    /// finger's, a secondary click's or the selection's menu button's
    /// (TestFlight 1.0.0: a menu that came up on every tap floated over the
    /// page and came back at the next tap).
    public enum Tap: Equatable {
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
    public func candidates(_ items: [Item]) -> [Item] { items.filter(scope.includes) }

    /// The item a tap at `p` (page points) selects, at `zoom`.
    public static func hit(_ p: ItemFrames.Point, items: [Item], zoom: Double) -> Item? {
        ItemFrames.item(at: p, in: items, slop: slop / max(zoom, 0.01))
    }

    /// What a tap at `p` does: the first tap on an item selects it, a tap
    /// on the selected one edits a text box (so a double tap edits it from
    /// scratch) and keeps any other kind selected; a tap beside the
    /// selection clears it, and only a tap with nothing selected and no item
    /// under it is the page's. `editable` false (a read-only note) never edits.
    public func tap(at p: ItemFrames.Point, items: [Item], zoom: Double, editable: Bool = true) -> Tap {
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
    public static func handles(for item: Item) -> [ItemFrames.Handle] { ItemFrames.handles(for: item.kind) }

    /// What a drag from `p` does: a handle of the selected item resizes it,
    /// the inside of an item (the selected one first) moves it; nil leaves
    /// the drag to scrolling. A background item (a full-page PDF page) moves
    /// only once it is selected, so dragging over it scrolls.
    public func drag(at p: ItemFrames.Point, items: [Item], zoom: Double) -> Drag? {
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
    public static func frame(for drag: Drag, item: Item, dx: Double, dy: Double) -> Rect {
        switch drag {
        case .move:
            return ItemFrames.moved(item.frame, dx: dx, dy: dy)
        case .resize(_, let handle):
            // Pictures keep their proportions; a text box re-wraps (its height follows its lines).
            return ItemFrames.resized(item.frame, rotation: item.rotation, handle: handle, dx: dx, dy: dy,
                                      keepAspect: ItemFrames.keepsAspect(item.kind))
        }
    }

    public static func distance(_ a: ItemFrames.Point, _ b: ItemFrames.Point) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
