import Foundation
import CoreGraphics
import Sempere

/// A tool the Tools menu selects.
enum ToolChoice: String, CaseIterable, Sendable {
    case pen, marker, pencil, eraser, lasso

    /// The palette's tool (`DrawingToolbox`).
    var drawingTool: DrawingTool {
        switch self {
        case .pen: return .pen
        case .marker: return .marker
        case .pencil: return .pencil
        case .eraser: return .eraser
        case .lasso: return .lasso
        }
    }

    /// The Tools menu's command for this tool (its title and shortcut).
    var command: MenuCommand {
        switch self {
        case .pen: return .toolPen
        case .marker: return .toolMarker
        case .pencil: return .toolPencil
        case .eraser: return .toolEraser
        case .lasso: return .toolLasso
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
    /// Picks `tool` for every canvas (`DrawingToolbox`) and ends this canvas's selection, text tool or
    /// math lasso (picking a tool is drawing); false for a read-only note.
    @discardableResult func select(drawingTool tool: DrawingTool) -> Bool
    /// One zoom step in or out (`ZoomSteps`).
    func zoom(in zoomingIn: Bool)
    func zoomToFit()
    func zoomToActualSize()
    /// Undoes or redoes the last change of the canvas with the focus (the iPhone palette's buttons).
    func undo()
    func redo()
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
    /// A tool of the Tools menu (`ToolChoice`).
    @discardableResult func select(tool: ToolChoice) -> Bool { select(drawingTool: tool.drawingTool) }

    /// The one-page canvas shows only the current page.
    func visibleRect(ofPage id: UUID) -> CGRect? { visiblePageRect }
}
