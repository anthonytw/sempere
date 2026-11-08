import Foundation
import Sempere
import SempereAppCore

// The sidebar's drags and drops. Opening a recent vault (`open(recent:)`) and the edits themselves are the library's
// (`AppModel+VaultStore.swift`, `AppModel+Edits.swift` in SempereAppCore).

// MARK: - Moving notes and notebooks (drag and drop, Move Notebook To…)

extension AppModel {
    /// Puts every note of `ids` that is not there already into the notebook
    /// path `notebook` (nil or blank: none), as ONE commit: a `setMeta`
    /// delta per note, each decided from the note as it is on disk. Deleted notes
    /// and ids the vault does not list are left alone. Returns where the moved
    /// notes were, nil when nothing moved.
    @discardableResult
    func moveNotes(_ ids: [UUID], toNotebook notebook: String?) async throws -> NotebookMoveRecord? {
        let target = NotebookPath.canonical(notebook)
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let gen = generation
        for id in unique where notes.contains(where: { $0.id == id }) {
            try await downloadNote(id)
            try ensureCurrent(gen)
            try await verifySummary(id)
        }
        var previous: [UUID: String?] = [:]
        var moving: [UUID] = []
        for id in unique {
            guard let note = notes.first(where: { $0.id == id }), !note.deleted,
                  NotebookPath.canonical(note.notebook) != target else { continue }
            moving.append(id)
            previous[id] = note.notebook
        }
        guard !moving.isEmpty else { return nil }
        let batch = moving
        try await commit(ids: batch) { vault, clock, verifier in
            for id in batch {
                try await NoteWriter.append(to: id, vault: vault, clock: clock, detail: .withoutStrokePoints,
                                            verify: verifier(id)) { state in
                    state.map { NoteOps.move(toNotebook: target, state: $0) } ?? [.setMeta(.notebook(target))]
                }
            }
        }
        return NotebookMoveRecord(previous: previous, actionName: batch.count == 1
                                  ? String(localized: "Move Note", comment: "Undo action name: one note moved to a notebook")
                                  : String(localized: "Move Notes", comment: "Undo action name: several notes moved to a notebook"))
    }

    /// Moves the notebook `path`, with everything below it, into the notebook
    /// `parent` (nil or blank: the top level): it keeps its last level
    /// (`NotebookPath.moved`) and the move is the existing prefix rename
    /// (`renameNotebook`, which downloads the affected notes first, one
    /// commit). Returns where the notes were, nil when it is there already.
    ///
    /// - Throws: `ModelError.invalidNotebookMove` for a move into itself or a descendant.
    @discardableResult
    func moveNotebook(_ path: String, into parent: String?) async throws -> NotebookMoveRecord? {
        guard let from = NotebookPath.canonical(path), let target = NotebookPath.moved(from, into: parent) else {
            throw ModelError.invalidNotebookMove
        }
        guard target != from else { return nil }
        let carriesEmpty = declaredNotebooks.contains { NotebookPath.name($0, isWithin: from) }
        let previous = try await renameNotebook(from, to: target)
        guard !previous.isEmpty || carriesEmpty else { return nil }
        return NotebookMoveRecord(previous: previous, actionName: String(localized: "Move Notebook", comment: "Undo action name"),
                                  emptyNotebooks: carriesEmpty ? NotebookPathMove(from: from, to: target) : nil)
    }

    /// Puts the notes of `record` back where they were (undo of a move), one commit,
    /// and the empty notebooks it moved (one notebook record).
    func restoreNotebooks(_ record: NotebookMoveRecord) async throws {
        if let moved = record.emptyNotebooks, let to = moved.to {
            try await writeNotebookRecords { vault in _ = try vault.renameNotebookRecords(to, to: moved.from) }
        }
        let batch = Array(record.previous.keys).filter { id in notes.contains { $0.id == id } }
        guard !batch.isEmpty else { return }
        let gen = generation
        for id in batch {
            try await downloadNote(id)
            try ensureCurrent(gen)
        }
        let previous = record.previous
        try await commit(ids: batch) { vault, clock, verifier in
            for id in batch {
                let target = NotebookPath.canonical(previous[id] ?? nil)
                try await NoteWriter.append(to: id, vault: vault, clock: clock, detail: .withoutStrokePoints,
                                            verify: verifier(id)) { state in
                    state.map { NoteOps.move(toNotebook: target, state: $0) } ?? [.setMeta(.notebook(target))]
                }
            }
        }
    }

    /// A drop (or "Move Notebook To…"): makes the move, reports a failure, and
    /// registers one undo step that puts the notes back with `undoManager`, the
    /// undo manager of the window it happened in (the model is shared by every
    /// window on a Mac, so it keeps none of its own).
    func move(_ payload: DragPayload, to target: DropTarget, undoManager: UndoManager?) async {
        guard phase == .unlocked, SidebarDrop.accepts(payload, on: target, notes: notes) else { return }
        var record: NotebookMoveRecord?
        await report {
            switch payload {
            case .notes(let ids): record = try await self.moveNotes(ids, toNotebook: target.path)
            case .notebook(let path): record = try await self.moveNotebook(path, into: target.path)
            }
        }
        guard let record else { return }
        flashLandedDrop(target)
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in
                await model.report { try await model.restoreNotebooks(record) }
            }
        }
        undoManager?.setActionName(record.actionName)
    }
}

// MARK: - Drags inside the app

extension AppModel {
    /// Starts a drag of `payload` (nil: a drag that moves nothing, a note in
    /// Recently Deleted) and returns `provider`.
    func beginDrag(_ payload: DragPayload?, provider: NSItemProvider) -> NSItemProvider {
        #if DEBUG
        DropTrace.note("begin \(payload.map { "\($0)" } ?? "nil")")
        #endif
        draggedPayload = payload
        return provider
    }

    /// Highlights `target` (nil: no row) while a drag is over it. Unchanged
    /// values are not written again: the sidebar would be rebuilt on every
    /// `dropUpdated` while the finger moves.
    func setDropTarget(_ target: DropTarget?) {
        if dropTarget != target { dropTarget = target }
    }

    /// Whether a drag over `target` would be accepted: the drag this model
    /// started, by the rules (`SidebarDrop.accepts`); a drag it does not know
    /// (nothing started here) is left to the drop. A drag that does not carry
    /// the app's own types (`carriesAppTypes` false: a photo, text from
    /// another app) is never one: `draggedPayload` may be left over from a
    /// canceled drag, since `onDrag` reports no end.
    func acceptsDrop(on target: DropTarget, carriesAppTypes: Bool = true) -> Bool {
        guard carriesAppTypes else { return false }
        return draggedPayload.map { SidebarDrop.accepts($0, on: target, notes: notes) } ?? true
    }

    /// The drop on `target` of the drag this model started: its payload when
    /// the drop is accepted, nil otherwise. Ends the drag either way. A drop
    /// inside the app never depends on the item provider's data; only a drag
    /// the model did not start is decoded from it.
    func takeDrop(on target: DropTarget, carriesAppTypes: Bool = true) -> DragPayload? {
        let payload = draggedPayload
        endDrag()
        guard carriesAppTypes, let payload, phase == .unlocked, SidebarDrop.accepts(payload, on: target, notes: notes) else { return nil }
        return payload
    }

    /// Forgets the drag in progress (dropped, or the vault closed).
    func endDrag() {
        draggedPayload = nil
        setDropTarget(nil)
    }

    /// Flashes `target`'s sidebar row after a drop moved something there (`landedDrop`), until
    /// `landedDropDuration` has passed or another drop lands.
    func flashLandedDrop(_ target: DropTarget) {
        let landed = LandedDrop(target: target)
        landedDrop = landed
        #if DEBUG
        DropTrace.note("landed target=\(target)")
        #endif
        let duration = landedDropDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            if self?.landedDrop == landed { self?.landedDrop = nil }
        }
    }
}

/// A drop that just landed on a sidebar row (`AppModel.landedDrop`); each drop is a new value.
struct LandedDrop: Equatable, Sendable {
    let target: DropTarget
    let id = UUID()
}
