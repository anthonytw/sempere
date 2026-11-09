import Foundation

/// What the focused canvas's undo manager can do now: the note toolbar's Undo and Redo buttons follow it
/// (`NoteToolbar.isEnabled`). The app's canvas glue is the only writer (`NoteEditorModel.undoAvailability`).
public struct UndoAvailability: Equatable, Sendable {
    public var canUndo = false, canRedo = false
    /// The manager's action names, as the app localizes them (empty: unnamed). Display only: the library holds
    /// no user-facing text.
    public var undoName = "", redoName = ""

    public init(canUndo: Bool = false, canRedo: Bool = false, undoName: String = "", redoName: String = "") {
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoName = undoName
        self.redoName = redoName
    }
}
