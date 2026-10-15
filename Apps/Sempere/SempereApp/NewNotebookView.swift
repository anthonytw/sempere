import Sempere
import SwiftUI

/// What opens the New Notebook sheet: File ▸ New Notebook… (⌃⌘N), the sidebar's
/// New Notebook button and the notebook rows' New Notebook Inside….
struct NewNotebookRequest: Identifiable, Equatable {
    let id = UUID()
    /// The notebook the new one goes into; nil: the top level.
    var parent: String?
}

/// Names a new, empty notebook (format.md §14): one notebook record, kept while
/// no note is in it. `/` makes levels; the field starts inside `request.parent`.
struct NewNotebookView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    init(request: NewNotebookRequest) {
        _name = State(initialValue: request.parent.map { $0 + "/" } ?? "")
    }

    /// The canonical path the field names; nil while it names none.
    private var path: String? { NotebookPath.canonical(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Notebook name", text: $name, selection: $selection)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("new-notebook-name")
                        // Return picks a suggested emoji while the list is open (":smile" -> 😄), else creates.
                        .emojiCompletion(text: $name, onSubmit: create, selection: $selection)
                } footer: {
                    Text("Use / for levels, e.g. School/Math. An empty notebook stays in the sidebar until you delete it.")
                }
                if let path, model.notebooks.contains(path) {
                    Text("“\(path)” exists already: it will be selected.").foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("New Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(path == nil || model.isEditing)
                        .accessibilityIdentifier("new-notebook-create")
                }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        guard path != nil else { return }
        let typed = name
        Task {
            #if DEBUG
            DropTrace.note("newNotebook start")
            #endif
            do {
                try await model.createNotebook(typed)
                #if DEBUG
                DropTrace.note("newNotebook done declared=\(model.declaredNotebooks.count)")
                #endif
                dismiss()
            } catch {
                #if DEBUG
                DropTrace.note("newNotebook failed \(type(of: error))")
                #endif
                failure = "\(error)"
            }
        }
    }
}
