import Foundation
import CoreGraphics
import PencilKit

/// A tool the Tools menu selects.
enum ToolChoice: String, CaseIterable, Sendable {
    case pen, marker, pencil, eraser, lasso

    /// Whether `item` of the tool picker is this tool.
    @MainActor
    func matches(_ item: PKToolPickerItem) -> Bool {
        switch self {
        case .pen: return (item as? PKToolPickerInkingItem)?.inkingTool.inkType == .pen
        case .marker: return (item as? PKToolPickerInkingItem)?.inkingTool.inkType == .marker
        case .pencil: return (item as? PKToolPickerInkingItem)?.inkingTool.inkType == .pencil
        case .eraser: return item is PKToolPickerEraserItem
        case .lasso: return item is PKToolPickerLassoItem
        }
    }

    /// The tool a menu command selects.
    init?(_ command: MenuCommand) {
        switch command {
        case .toolPen: self = .pen
        case .toolMarker: self = .marker
        case .toolPencil: self = .pencil
        case .toolEraser: self = .eraser
        case .toolLasso: self = .lasso
        default: return nil
        }
    }
}

/// What the menu bar can ask of the canvas on screen (`PageCanvasHost`).
/// A note editor remembers its canvas as its target; the Mac menus reach the
/// canvas of the focused window through it.
@MainActor
protocol CanvasCommandTarget: AnyObject {
    /// Selects the tool in the palette; false when the palette does not have it
    /// (the compact palette has no pencil).
    @discardableResult func select(tool: ToolChoice) -> Bool
    /// One zoom step in or out (`ZoomSteps`).
    func zoom(in zoomingIn: Bool)
    func zoomToFit()
    func zoomToActualSize()
    /// Shows or hides PencilKit's ruler (straight lines with a mouse).
    func toggleRuler()
    /// Runs an item command (`duplicateItem`, `bringItemToFront`, `deleteItem`) on the
    /// selected item; false when none is selected or it is not an item command.
    @discardableResult func perform(itemCommand: MenuCommand) -> Bool
    /// The part of the page on screen, in page points (nil before layout):
    /// where inserted images go.
    var visiblePageRect: CGRect? { get }
    /// The part of page `id` on screen, in its page points (nil when it is
    /// not on screen or before layout): where images dropped on it go.
    func visibleRect(ofPage id: UUID) -> CGRect?
}

extension CanvasCommandTarget {
    /// The one-page canvas shows only the current page.
    func visibleRect(ofPage id: UUID) -> CGRect? { visiblePageRect }
}
