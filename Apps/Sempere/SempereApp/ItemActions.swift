import Foundation
import SempereAppCore

/// Item gestures with undo on the app's canvas (`ItemActionsCore`, `SempereAppCore`): the app words the undo steps' names.
typealias ItemActions = ItemActionsCore<PencilCanvas>

extension ItemActionsCore {
    /// The names of the undo steps, in the app's words (Edit menu: Undo …).
    nonisolated static func undoName(_ name: UndoName) -> String {
        switch name {
        case .move: return String(localized: "Move", comment: "Undo action name (Edit menu: Undo …)")
        case .typing: return String(localized: "Typing", comment: "Undo action name (Edit menu: Undo …)")
        case .addText: return String(localized: "Add Text", comment: "Undo action name (Edit menu: Undo …)")
        case .delete: return String(localized: "Delete", comment: "Undo action name (Edit menu: Undo …)")
        case .duplicate: return String(localized: "Duplicate", comment: "Undo action name (Edit menu: Undo …)")
        // Not localized, as it never was (a plain string, not a catalog key).
        case .replaceImage: return "Replace Image"
        case .rotate: return String(localized: "Rotate", comment: "Undo action name (Edit menu: Undo …)")
        case .bringToFront: return String(localized: "Bring to Front", comment: "Undo action name (Edit menu: Undo …)")
        case .paste: return String(localized: "Paste", comment: "Undo action name (Edit menu: Undo …)")
        case .crop: return String(localized: "Crop", comment: "Undo action name (Edit menu: Undo …)")
        }
    }

    /// Item gestures on `editor`, undone on `undoManager`.
    convenience init(editor: Editor, undoManager: UndoManager?) {
        self.init(editor: editor, undoStack: undoManager, wording: Self.undoName)
    }

    /// The canvas's undo manager the steps are registered on.
    var undoManager: UndoManager? { undoStack as? UndoManager }
}

extension UndoManager: @retroactive ItemUndoStack {
    public func registerStep<Target: AnyObject>(for target: Target, name: String,
                                                _ step: @escaping @MainActor @Sendable (Target) -> Void) {
        registerUndo(withTarget: target) { target in MainActor.assumeIsolated { step(target) } }
        setActionName(name)
    }
}
