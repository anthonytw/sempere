import Foundation
import CoreGraphics
import Sempere
import SempereAppCore

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

extension UndoAvailability {
    /// A manager's state, with its action names ("Move", "Typing"); nil manager: nothing to undo.
    init(_ manager: UndoManager?) {
        guard let manager else { self.init(); return }
        self.init(canUndo: manager.canUndo, canRedo: manager.canRedo,
                  undoName: manager.undoActionName, redoName: manager.redoActionName)
    }
}

extension NoteEditor {
    /// Writes the focused canvas's undo state to `undoAvailability` (the toolbar's buttons), only when it changed.
    func refreshUndoAvailability() {
        let state = canvasTarget?.undoState ?? UndoAvailability()
        if state != undoAvailability { undoAvailability = state }
    }
}

/// Calls `handler` with the manager of every `UndoManager` close-group, undo and redo notification. The
/// manager's `removeAllActions()` posts none: callers refresh after it themselves.
final class UndoChangeObserver {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    init(handler: @escaping @MainActor (UndoManager) -> Void) {
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                // Synchronous, on the posting thread: undo managers are used on the main thread.
                guard Thread.isMainThread, let manager = note.object as? UndoManager else { return }
                MainActor.assumeIsolated { handler(manager) }
            }
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
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
    /// What the manager that Undo and Redo act on can do now (the note toolbar's buttons follow it).
    var undoState: UndoAvailability { get }
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
