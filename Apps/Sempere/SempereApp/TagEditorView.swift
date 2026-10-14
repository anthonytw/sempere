import Sempere
import SwiftUI

/// Tags of one note: current tags with remove buttons, and a field to add
/// one with suggestions from the tags already used in the vault.
struct TagEditorView: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID
    @State private var text = ""

    /// One entry per tag key (older notes may store "Math" and "math"; removing
    /// either removes both), so the list never holds duplicate ids.
    private var current: [String] { NoteOps.normalizedTags(model.notesByID[noteID]?.tags ?? []) }

    /// Vault tags this note does not have, matching what was typed.
    private var suggestions: [String] {
        let have = Set(current.map(NoteOps.tagKey))
        let typed = NoteOps.tagKey(text)
        return model.tags.filter { !have.contains(NoteOps.tagKey($0)) && (typed.isEmpty || NoteOps.tagKey($0).contains(typed)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tags on this note") {
                    if current.isEmpty { Text("No tags yet").foregroundStyle(.secondary) }
                    ForEach(current, id: \.self) { tag in
                        HStack {
                            Label(tag, systemImage: "tag")
                            Spacer()
                            Button("Remove \(tag)", systemImage: "minus.circle.fill", role: .destructive) {
                                run { try await model.removeTag(tag, from: noteID) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove this tag from the note")
                        }
                    }
                }
                Section("Add") {
                    HStack {
                        TextField("New tag", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(NoteOps.normalizedTag(text).isEmpty)
                    }
                    ForEach(suggestions.prefix(8), id: \.self) { tag in
                        Button(tag, systemImage: "tag") { run { try await model.addTag(tag, to: noteID) } }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let tag = text
        text = ""
        run { try await model.addTag(tag, to: noteID) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { await model.report(action) }
    }
}

/// A small capsule for one tag.
struct TagChip: View {
    let tag: String
    var body: some View {
        Text(tag)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
