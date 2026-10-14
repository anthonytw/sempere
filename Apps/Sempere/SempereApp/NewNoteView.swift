import Sempere
import SwiftUI

/// Title, paper and notebook for a new note.
struct NewNoteView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper = PaperPreference.load()
    @State private var layout = NewNoteLayout.load()
    @State private var choosingPaper = false
    @Environment(\.displayScale) private var displayScale
    @State private var notebook: String
    @State private var failure: String?
    /// What an empty title becomes, shown as the field's placeholder.

    init(notebook: String?) {
        _notebook = State(initialValue: notebook ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    TextField(NewNoteSettings.defaultTitle().isEmpty ? String(localized: "Title", comment: "Text field placeholder: a note title") : NewNoteSettings.defaultTitle(), text: $title)
                    Button { choosingPaper = true } label: {
                        HStack(spacing: 12) {
                            Image(uiImage: PaperImage.image(for: paper, size: CGSize(width: 44, height: 57), scale: displayScale))
                                .resizable()
                                .aspectRatio(612.0 / 792.0, contentMode: .fit)
                                .frame(height: 57)
                                .overlay(Rectangle().stroke(SwiftUI.Color.secondary.opacity(0.5), lineWidth: 1))
                            VStack(alignment: .leading) {
                                Text("Paper").foregroundStyle(.primary)
                                Text(paper.kind.localizedTitle).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .sheet(isPresented: $choosingPaper) {
                        PaperPickerView(paper: paper, purpose: .newNote) { chosen, _ in paper = chosen }
                    }
                    Picker("Layout", selection: $layout) {
                        ForEach(NewNoteLayout.allCases) { Text($0.title).tag($0) }
                    }
                    NotebookField(title: "Notebook (optional; School/Math for levels)", text: $notebook,
                                  notebooks: model.notebooks, reveal: proxy)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                try await model.createNote(title: NewNoteSettings.resolvedTitle(typed: title), paper: paper, notebook: notebook,
                                                           pageSize: layout.pageSize)
                                NewNoteLayout.save(layout)
                                dismiss()
                            } catch { failure = "\(error)" }
                        }
                    }
                    .disabled(model.isEditing)
                }
            }
        }
    }
}
