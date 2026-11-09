import Foundation
import Sempere
import SempereAppCore

// The app's half of the sidebar's drags (the moves, the drag state and the rules are the core's: `AppModel+Drags.swift`
// and `SidebarDrop.swift` in SempereAppCore): the item provider a drag starts with, the undo step of a drop in its own
// window, and the debug drop trace.

extension AppModel {
    /// Starts a drag of `payload` (nil: a drag that moves nothing, a note in
    /// Recently Deleted) and returns `provider`.
    func beginDrag(_ payload: DragPayload?, provider: NSItemProvider) -> NSItemProvider {
        #if DEBUG
        DropTrace.note("begin \(payload.map { "\($0)" } ?? "nil")")
        #endif
        beginDrag(payload)
        return provider
    }

    /// A drop (or "Move Notebook To…"): makes the move (`move(_:to:)`: a failure is reported, the row flashes) and
    /// registers one undo step that puts the notes back with `undoManager`, the undo manager of the window it
    /// happened in (the model is shared by every window on a Mac, so it keeps none of its own).
    func move(_ payload: DragPayload, to target: DropTarget, undoManager: UndoManager?) async {
        guard let record = await move(payload, to: target) else { return }
        #if DEBUG
        DropTrace.note("landed target=\(target)")
        #endif
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in
                await model.report { try await model.restoreNotebooks(record) }
            }
        }
        undoManager?.setActionName(record.actionName)
    }
}
