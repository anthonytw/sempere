import Sempere
import SempereAppCore
import SwiftUI

/// Select mode's bulk actions on the note list: the Move To… sheet and the Delete confirmation, and the Restore
/// that follows from the toolbar, the context menu or the menu bar (`WindowUICore.bulkNoteAction`). They live in
/// `WindowSheets`, on a view that is always on screen, because the menu bar opens them with the note list hidden.
struct BulkNoteSheets: ViewModifier {
    @AppModelEnvironment private var model
    @Environment(\.undoManager) private var undoManager
    let ui: WindowUI

    private var moving: [UUID]? {
        if case .move(let ids)? = ui.bulkNoteAction { return ids }
        return nil
    }

    private var deleting: [UUID]? {
        if case .delete(let ids)? = ui.bulkNoteAction { return ids }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0, moving != nil { ui.bulkNoteAction = nil } })) {
                if let ids = moving { MoveNotesView(ids: ids, undoManager: undoManager).onDisappear { ui.bulkNoteAction = nil } }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil },
                                                                   set: { if !$0, deleting != nil { ui.bulkNoteAction = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let ids = deleting {
                        let undo = undoManager
                        Task { await model.deleteSelectedNotes(ids, undoManager: undo) }
                    }
                    ui.bulkNoteAction = nil
                }
                .accessibilityIdentifier("bulk.confirmDelete")
                Button("Cancel", role: .cancel) { ui.bulkNoteAction = nil }
            } message: {
                Text("They move to Recently Deleted, where they can be restored.")
            }
            .onChange(of: ui.bulkNoteAction) { _, request in
                guard case .restore(let ids)? = request else { return }
                ui.bulkNoteAction = nil
                let undo = undoManager
                Task { await model.restoreSelectedNotes(ids, undoManager: undo) }
            }
    }

    private var deleteTitle: String {
        String(localized: "Delete \(deleting?.count ?? 0) Notes?",
               comment: "Confirmation title: move this many selected notes to Recently Deleted (plural: one, many, other)")
    }
}

/// Move To… for the ticked notes: the single-note sheet's combo box, "No Notebook" and Move, for several notes at
/// once (one commit, one undo step: `AppModel.moveSelectedNotes`).
struct MoveNotesView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [UUID]
    let undoManager: UndoManager?
    @State private var notebook = ""

    private var picked: [NoteSummary] {
        let wanted = Set(ids)
        return model.notes.filter { wanted.contains($0.id) }
    }

    /// The notebook every picked note is in, when it is one (not offered again).
    private var common: String? {
        let paths = Set(picked.map { NotebookPath.canonical($0.notebook) })
        guard paths.count == 1, let only = paths.first else { return nil }
        return only
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        NotebookField(title: "Notebook (School/Math for levels)", text: $notebook,
                                      notebooks: model.notebooks, excluding: common, reveal: proxy)
                    } header: {
                        Text("\(ids.count) Notes", comment: "Header of the Move To sheet: how many notes are being moved (plural)")
                    }
                    if picked.contains(where: { $0.notebook != nil }) {
                        Button("No Notebook", role: .destructive) { move(to: nil) }
                    }
                }
            }
            .navigationTitle("Move To…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { move(to: notebook) }
                        .disabled(NotebookPath.canonical(notebook) == nil)
                        .help("Move to this notebook")
                        .accessibilityIdentifier("bulk.moveConfirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to target: String?) {
        let ids = ids, undo = undoManager
        dismiss()
        Task { await model.moveSelectedNotes(ids, to: target, undoManager: undo) }
    }
}
