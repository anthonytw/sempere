import Sempere
import SwiftUI

/// What a notebook combo box offers (pure, tested).
enum NotebookChoices {
    /// How many suggestions show under the field while typing.
    static let shown = 8

    /// The existing notebooks matching `text`, best first (`NotebookPath.suggestions`).
    static func rows(matching text: String, among notebooks: [String], excluding: String? = nil,
                     excludingSubtree: String? = nil, limit: Int = shown) -> [String] {
        NotebookPath.suggestions(matching: text, among: notebooks, excluding: excluding,
                                 excludingSubtree: excludingSubtree, limit: limit)
    }

    /// True when `text` names a notebook that no note has yet (a new one is created by using it).
    static func isNew(_ text: String, among notebooks: [String]) -> Bool {
        guard let typed = NotebookPath.canonical(text) else { return false }
        return !notebooks.contains { NotebookPath.canonical($0) == typed }
    }

    /// A path as shown in a row: `School › Math`.
    static func display(_ path: String) -> String {
        NotebookPath.components(path).joined(separator: " › ")
    }
}

/// A combo box for a notebook path: type a new `/`-separated path, or pick an
/// existing notebook from the list that opens under the field and narrows as
/// you type (the chevron opens it without typing). Plain SwiftUI views in the
/// form's own flow rather than a popover or `Menu`, so it behaves the same on
/// an iPad, an iPhone (software keyboard) and a Mac.
struct NotebookField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    /// Existing notebooks (`AppModel.notebooks`).
    let notebooks: [String]
    /// Never offered (the note's own notebook, when moving).
    var excluding: String?
    /// A notebook and everything below it never offered (where a notebook cannot move to).
    var excludingSubtree: String?
    /// The form's scroll position: when the list opens, the field scrolls to
    /// the top so the list under it is on screen. A Mac shows the sheet in a
    /// small window without visible scroll bars, where the list otherwise
    /// opened below the window's edge (TestFlight build 6).
    var reveal: ScrollViewProxy?
    /// The id the field is scrolled to by (`reveal`).
    static let scrollID = "notebookField"
    @FocusState private var focused: Bool
    @State private var expanded = false

    private var rows: [String] {
        NotebookChoices.rows(matching: text, among: notebooks, excluding: excluding, excludingSubtree: excludingSubtree)
    }

    private var isOpen: Bool { (focused || expanded) && !rows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(title, text: $text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .accessibilityIdentifier("notebookField")
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: isOpen ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isOpen ? "Hide Notebooks" : "Show Notebooks")
                .accessibilityIdentifier("notebookChoices")
                .disabled(notebooks.isEmpty)
                .help("Show the existing notebooks")
            }
            if isOpen {
                ForEach(rows, id: \.self) { path in
                    Button {   // help-lint: ignore (a row of the list: the notebook's name is its title)
                        text = path
                        expanded = false
                        focused = false
                    } label: {
                        Label(NotebookChoices.display(path), systemImage: "book.closed")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if NotebookChoices.isNew(text, among: notebooks) {
                Text("New notebook “\(NotebookChoices.display(NotebookPath.canonical(text) ?? ""))”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .id(Self.scrollID)
        .onChange(of: isOpen) { _, open in
            guard open, let reveal else { return }
            withAnimation { reveal.scrollTo(Self.scrollID, anchor: .top) }
        }
    }
}

/// Moves one note to a notebook: the combo box, "No Notebook" and Move.
struct MoveNoteView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let note: NoteSummary
    @State private var notebook: String

    init(note: NoteSummary) {
        self.note = note
        _notebook = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        NotebookField(title: "Notebook (School/Math for levels)", text: $notebook,
                                      notebooks: model.notebooks, excluding: note.notebook, reveal: proxy)
                    } header: {
                        Text(NoteTitle.display(note.title))
                    } footer: {
                        if let current = NotebookPath.canonical(note.notebook) {
                            Text("Now in \(NotebookChoices.display(current)).")
                        }
                    }
                    if note.notebook != nil {
                        Button("No Notebook", role: .destructive) { move(to: nil) }
                    }
                }
            }
            .navigationTitle("Move to Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { move(to: notebook) }
                        .disabled(NotebookPath.canonical(notebook) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to target: String?) {
        let id = note.id
        dismiss()
        Task { await model.report { try await model.moveNote(id, toNotebook: target) } }
    }
}

/// "Move Notebook To…": the notebook to move, a combo box for the notebook it
/// goes into (blank: the top level) and what it becomes. The same move as
/// dropping the notebook on a row of the sidebar (`AppModel.moveNotebook`).
struct MoveNotebookView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    let path: String
    @State private var parent = ""

    /// What `path` becomes when moved into the notebook typed, nil when that is not allowed or changes nothing.
    static func result(of path: String, into parent: String) -> String? {
        guard let moved = NotebookPath.moved(path, into: parent), moved != NotebookPath.canonical(path) else { return nil }
        return moved
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        NotebookField(title: "Into notebook (blank: top level)", text: $parent, notebooks: model.notebooks,
                                      excludingSubtree: path, reveal: proxy)
                    } header: {
                        Text(NotebookChoices.display(path))
                    } footer: {
                        if let result = Self.result(of: path, into: parent) {
                            Text("Becomes \(NotebookChoices.display(result)), with every notebook and note inside it.")
                        } else if NotebookPath.moved(path, into: parent) == nil {
                            // The model's own refusal of this move, word for word.
                            Text(AppModel.ModelError.invalidNotebookMove.description)
                        } else {
                            Text("It is there already.")
                        }
                    }
                    if NotebookPath.components(path).count > 1 {
                        Button("Move to Top Level") { move(into: "") }
                    }
                }
            }
            .navigationTitle("Move Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { move(into: parent) }
                        .disabled(Self.result(of: path, into: parent) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(into target: String) {
        let from = path, undoManager = undoManager
        dismiss()
        Task {
            await model.move(.notebook(from), to: NotebookPath.canonical(target).map(DropTarget.notebook) ?? .topLevel,
                             undoManager: undoManager)
        }
    }
}
