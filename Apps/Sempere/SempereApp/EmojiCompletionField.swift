import Sempere
import SwiftUI

/// `:name` emoji completion for a naming `TextField` (titles, notebooks, tags),
/// Slack and GitHub style, on the package's `EmojiCompletion`: typing `:` and
/// two or more letters opens a short list under the field; ↑ and ↓ move through
/// it, Return or Tab puts the emoji in place of `:name`, Escape closes it, and
/// a click or tap picks a row. A closed `:name:` turns into its emoji as it is
/// typed. Plain views in the field's own flow (as `NotebookField`'s list), so
/// it behaves the same on an iPad, an iPhone and a Mac.
///
/// Fields inside an `.alert` cannot show a list: give those
/// `$text.replacingEmojiShortcodes()` instead.
struct EmojiCompletionModifier: ViewModifier {
    @Binding var text: String
    /// What Return does when no suggestion is shown (the field's own `onSubmit`): Return with
    /// suggestions on screen inserts the highlighted emoji instead, so a field that offers
    /// completion passes its submit action here rather than adding its own `onSubmit`.
    var onSubmit: (() -> Void)?
    /// The field's selection, when the caller has one (its `TextField(…, selection:)`): after an emoji goes in,
    /// the insertion point is put back at the end (a Mac field selects all of its text when it
    /// takes the focus again after Return, and the next key replaced it).
    var selection: Binding<TextSelection?>?
    @FocusState private var fieldFocused: Bool
    /// The query Escape closed the list for; the list stays closed until the query changes.
    @State private var dismissedQuery: String?
    @State private var highlighted = 0

    static let shown = 6

    private var query: String? { EmojiCompletion.activeQuery(in: text) }

    private var suggestions: [EmojiCompletion.Suggestion] {
        guard let query, query != dismissedQuery else { return [] }
        return EmojiCompletion.suggestions(for: query, limit: Self.shown)
    }

    func body(content: Content) -> some View {
        let rows = suggestions
        VStack(alignment: .leading, spacing: 4) {
            content
                .onKeyPress(.downArrow) { move(1, rows) }
                .onKeyPress(.upArrow) { move(-1, rows) }
                .onKeyPress(.escape) {
                    guard !rows.isEmpty else { return .ignored }
                    dismissedQuery = query
                    return .handled
                }
                .onKeyPress(.tab) { accept(rows) }
                .onKeyPress(.return) { accept(rows) }
                // A Mac text field handles Return itself (it submits); the key press above
                // never sees it there, so the submit takes the highlighted row too.
                .onSubmit {
                    if accept(rows) == .ignored { onSubmit?() }
                }
                .focused($fieldFocused)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button {   // help-lint: ignore (a row of the list: the emoji and its name are its title)
                            pick(row)
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: row.emoji)
                                Text(verbatim: ":\(row.name):")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == min(highlighted, rows.count - 1)
                                        ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("emojiSuggestion")
                        .accessibilityAddTraits(index == min(highlighted, rows.count - 1) ? .isSelected : [])
                        .accessibilityLabel(Text(verbatim: "\(row.emoji) :\(row.name):"))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Emoji Suggestions")
            }
        }
        .onChange(of: text) { _, new in
            if let replaced = EmojiCompletion.replacingClosedShortcodes(in: new) { text = replaced }
            if EmojiCompletion.activeQuery(in: text) != dismissedQuery { dismissedQuery = nil }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func move(_ step: Int, _ rows: [EmojiCompletion.Suggestion]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        highlighted = (min(highlighted, rows.count - 1) + step + rows.count) % rows.count
        return .handled
    }

    @discardableResult
    private func accept(_ rows: [EmojiCompletion.Suggestion]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        pick(rows[min(highlighted, rows.count - 1)])
        return .handled
    }

    private func pick(_ row: EmojiCompletion.Suggestion) {
        text = EmojiCompletion.accept(row.emoji, in: text)
        highlighted = 0
        // Submitting ends editing on a Mac: keep typing in the field.
        let end = text.endIndex
        fieldFocused = true
        selection?.wrappedValue = TextSelection(insertionPoint: end)
        Task { @MainActor in
            fieldFocused = true
            selection?.wrappedValue = TextSelection(insertionPoint: text.endIndex)
        }
    }
}

extension View {
    /// Offers `:name` emoji completion under this text field (`EmojiCompletionModifier`).
    ///
    /// - Parameter onSubmit: the field's submit action, run by Return when no suggestion shows.
    func emojiCompletion(text: Binding<String>, onSubmit: (() -> Void)? = nil,
                         selection: Binding<TextSelection?>? = nil) -> some View {
        modifier(EmojiCompletionModifier(text: text, onSubmit: onSubmit, selection: selection))
    }
}

extension Binding where Value == String {
    /// This binding with closed shortcodes (`:smile:`) turned into their emoji as
    /// they are typed: for fields that cannot show the suggestion list (an alert's).
    func replacingEmojiShortcodes() -> Binding<String> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = EmojiCompletion.replacingClosedShortcodes(in: $0) ?? $0 })
    }
}

