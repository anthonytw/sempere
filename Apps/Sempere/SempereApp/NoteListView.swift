import Sempere
import SwiftUI
import UniformTypeIdentifiers
import SempereImport

/// The notes matching the sidebar selection, with title search, sorting and
/// per-note actions.
struct NoteListView: View {
    /// Whether the list's import buttons (PDF, other apps) can be used: the
    /// same rule as File > Import… (`MenuCommand.importPDF`), an unlocked vault
    /// that can be written.
    static func importsEnabled(_ model: AppModel) -> Bool {
        model.phase == .unlocked && !model.isVaultReadOnly
    }

    @AppModelEnvironment private var model
    @Environment(WindowUI.self) private var ui
    @Environment(\.openWindow) private var openWindow
    @State private var prompt: Prompt?
    @State private var promptText = ""
    /// The note being moved to a notebook (`MoveNoteView`).
    @State private var movingNote: MovingNote?

    private struct MovingNote: Identifiable {
        let note: NoteSummary
        var id: UUID { note.id }
    }

    /// A text prompt for one note.
    private struct Prompt: Identifiable {
        enum Kind { case tag, rename }
        let kind: Kind
        let note: UUID
        var id: String { "\(kind)-\(note)" }
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var ui = ui
        Group {
            if model.isSearchActive {
                SearchResultsList()
            } else {
                notesList
            }
        }
        .environment(\.editMode, Binding<EditMode>(get: { model.isSelectingNotes ? .active : .inactive },
                                         set: { setSelecting($0.isEditing) }))
        .navigationTitle(title)
        .searchable(text: $model.searchText, isPresented: $ui.searchPresented, prompt: "Search notes and handwriting")
        .searchSuggestions {
            // Recent searches while the field is empty: tap one to search it again.
            if model.searchText.isEmpty, !model.recentSearches.isEmpty {
                Section {
                    ForEach(model.recentSearches, id: \.self) { query in
                        Label(query, systemImage: "clock.arrow.circlepath").searchCompletion(query)
                    }
                    Button("Clear Recent Searches", systemImage: "xmark.circle", role: .destructive) {
                        model.clearRecentSearches()
                    }
                } header: {
                    Text("Recent Searches")
                }
            }
        }
        .onSubmit(of: .search) { model.recordSearch() }
        .searchScopes($model.searchScope) {
            ForEach(SearchScope.allCases) { Text($0.title(for: model.sidebarSelection)).tag($0) }
        }
        .toolbar {
            if model.isSelectingNotes {
                ToolbarItem(placement: secondary) { ExportMenu(ids: model.exportTargetIDs) }
            }
            ToolbarItem(placement: secondary) {
                Button(model.isSelectingNotes ? "Done" : "Select") { setSelecting(!model.isSelectingNotes) }
                    .disabled(model.phase != .unlocked)
            }
            ToolbarItem(placement: secondary) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort By", selection: $model.sortOrder) {
                        ForEach(NoteSort.allCases) { Text($0.title).tag($0) }
                    }
                }
                .help("Sort the notes by date or title")
            }
            ToolbarItem(placement: secondary) {
                Menu("Handwriting", systemImage: "text.viewfinder") {
                    Toggle("Recognize Handwriting", isOn: Binding(get: { model.recognizer != nil },
                                                                  set: { model.setHandwritingRecognition($0) }))
                    let waiting = model.notesNeedingRecognition.count
                    Button("Recognize \(waiting) Notes Now", systemImage: "wand.and.stars") {
                        model.startRecognizingNotes()
                    }
                    .disabled(waiting == 0 || model.recognizer == nil || model.recognitionProgress != nil || model.isVaultReadOnly)
                    Text("Handwriting is read on this device; the text is saved, encrypted, in the vault so every device can search it.")
                }
                .help("Handwriting recognition: read notes so their handwriting can be searched")
            }
            ToolbarItem(placement: secondary) {
                Button("Import PDF…", systemImage: "doc.richtext") { ui.importingPDF = true }
                    .disabled(!Self.importsEnabled(model))
                    .help("Make a note from a PDF: one page per PDF page, to write on")
            }
            // The iPad has no File menu: the importer from another app is here too (the Mac's File menu has it as well).
            if let importer = AppImporters.primary {
                ToolbarItem(placement: secondary) {
                    Button(String(localized: "Import from \(importer.displayName)…", comment: "Toolbar: import notes from another app (its name)"),
                           systemImage: "square.and.arrow.down.on.square") {
                        ui.importingFromApp = true
                    }
                    .disabled(!Self.importsEnabled(model) || model.isImporting)
                    .help(String(localized: "Import notes or a backup from \(importer.displayName) (files, folders or zip archives) into this vault",
                                 comment: "Tooltip of the import-from-another-app button (its name)"))
                }
            }
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") { ui.creatingNote = true }
                    .disabled(model.phase != .unlocked || model.isVaultReadOnly)
                    .help("New note (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // The run's progress only; its results are the sidebar's "Recently Recognized",
                // never a bar over the list (TestFlight build 6).
                if let progress = model.recognitionProgress {
                    RecognitionBar(progress: progress) { model.cancelRecognizingNotes() }
                }
                VaultStatusBar(loading: model.loading, sync: model.cloudSync) { model.startCloudSync() }
                if let session = model.webdav { WebDAVStatusBar(session: session) }
            }
        }
        .refreshable {
            await model.report { try await model.reload() }
        }
        .sheet(item: $movingNote) { MoveNoteView(note: $0.note) }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(promptField, text: $promptText)
            Button("OK") {
                if let p = prompt {
                    let text = promptText
                    switch p.kind {
                    case .tag: run { try await model.addTag(text, to: p.note) }
                    case .rename: run { try await model.renameNote(p.note, to: text) }
                    }
                }
                prompt = nil
            }
            Button("Cancel", role: .cancel) { prompt = nil }
        }
    }

    /// On an iPhone the list's bar keeps New Note and moves the rest into the overflow menu.
    private var secondary: ToolbarItemPlacement {
        Platform.isPhone ? .secondaryAction : .automatic
    }

    private var notesList: some View {
        List(model.visibleNotes, id: \.id, selection: listSelection) { note in
            NoteRow(note: note, placeholder: model.placeholderNoteIDs.contains(note.id),
                    downloading: model.pendingNoteIDs.contains(note.id),
                    recognized: model.sidebarSelection == .recentlyRecognized ? model.recognizedEntry(of: note) : nil)
                .modifier(NoteDragOut(note: note, enabled: model.phase == .unlocked
                                      && !model.placeholderNoteIDs.contains(note.id)))
                // Mac: a double-click opens the note in its own window, like the context menu's item.
                .modifier(OpenOnDoubleClick(enabled: Platform.isMac) {
                    if let value = model.noteWindowValue(for: note.id) { openWindow(id: NoteWindowValue.sceneID, value: value) }
                })
                // A placeholder's summary is empty: nothing to act on until it arrives
                // (the model downloads a note before any edit anyway).
                .contextMenu { if !model.placeholderNoteIDs.contains(note.id) { actions(for: note) } }
                .swipeActions(edge: .trailing) {
                    if model.placeholderNoteIDs.contains(note.id) {
                        EmptyView()
                    } else if note.deleted {
                        Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
                            .tint(.green)
                    } else {
                        Button("Delete", systemImage: "trash", role: .destructive) { run { try await model.deleteNote(note.id) } }
                    }
                }
        }
        .overlay {
            if let reason = model.emptyListReason {
                EmptyListView(reason: reason) { run { try await model.reload() } }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let banner = model.readOnlyBanner {
                    // A vault of a newer format version (format.md §7.3): shown, never changed.
                    Label(banner, systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
                if model.sidebarSelection == .recentlyRecognized {
                    RecognitionResultsHeader(results: model.recognitionResults, running: model.recognitionProgress != nil)
                }
            }
        }
    }

    /// The list's selection: the open note, or the ticked notes while selecting. A
    /// command-click or shift-click on a keyboard selects several and starts selecting.
    private var listSelection: Binding<Set<UUID>> {
        Binding(
            get: { model.isSelectingNotes ? model.multiSelection : Set(model.selectedNoteID.map { [$0] } ?? []) },
            set: { picked in
                if model.isSelectingNotes || picked.count > 1 {
                    model.isSelectingNotes = true
                    model.multiSelection = picked
                } else {
                    model.selectedNoteID = picked.first
                }
            })
    }

    private func setSelecting(_ on: Bool) {
        guard on != model.isSelectingNotes else { return }
        model.isSelectingNotes = on
        // Start from the open note; leaving keeps it open and drops the ticks.
        model.multiSelection = on ? Set(model.selectedNoteID.map { [$0] } ?? []) : []
    }

    /// The notes a context-menu export acts on: the ticked ones when `note` is among them.
    private func exportIDs(for note: NoteSummary) -> [UUID] {
        model.isSelectingNotes && model.multiSelection.contains(note.id) ? model.exportTargetIDs : [note.id]
    }

    private var title: String {
        switch model.sidebarSelection ?? .allNotes {
        case .allNotes: return String(localized: "Notes", comment: "Note list title: all notes")
        case .notebook(let n): return NotebookPath.components(n).last ?? n
        case .tag(let t): return "#\(t)"
        case .deleted: return String(localized: "Recently Deleted", comment: "Sidebar row: deleted notes")
        case .favorites: return String(localized: "Favorites", comment: "Sidebar row: notes marked as favorites")
        case .recentlyRecognized: return String(localized: "Recently Recognized", comment: "Sidebar row: notes whose handwriting was recognized in the last 7 days")
        }
    }

    private var promptTitle: String {
        switch prompt?.kind {
        case .tag: return String(localized: "Add Tag", comment: "Alert title: add a tag to a note")
        default: return String(localized: "Rename Note", comment: "Alert title: rename a note")
        }
    }

    private var promptField: String {
        switch prompt?.kind {
        case .tag: return String(localized: "Tag", comment: "Text field placeholder: a tag name")
        default: return String(localized: "Title", comment: "Text field placeholder: a note title")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { await model.report(action) }
    }

    /// The row's context menu (titles shown).
    @ViewBuilder
    // help-lint: titled
    private func actions(for note: NoteSummary) -> some View {
        if note.deleted {
            Button("Restore", systemImage: "arrow.uturn.backward") { run { try await model.restoreNote(note.id) } }
            ExportMenu(ids: exportIDs(for: note))
        } else {
            if Platform.isMac, let value = model.noteWindowValue(for: note.id) {
                Button("Open in New Window", systemImage: "macwindow") {
                    openWindow(id: NoteWindowValue.sceneID, value: value)
                }
            }
            Button("Rename…", systemImage: "pencil") {
                promptText = note.title; prompt = Prompt(kind: .rename, note: note.id)
            }
            Button(LocalizedStringKey(note.favorite ? "Remove from Favorites" : "Add to Favorites"),
                   systemImage: note.favorite ? "star.slash" : "star") {
                run { try await model.setFavorite(!note.favorite, for: note.id) }
            }
            Button("Add Tag…", systemImage: "tag") { promptText = ""; prompt = Prompt(kind: .tag, note: note.id) }
            if !note.tags.isEmpty {
                Menu("Remove Tag", systemImage: "tag.slash") {
                    ForEach(note.tags, id: \.self) { tag in
                        Button(tag) { run { try await model.removeTag(tag, from: note.id) } }
                    }
                }
            }
            Button("Move to Notebook…", systemImage: "book.closed") { movingNote = MovingNote(note: note) }
            ExportMenu(ids: exportIDs(for: note))
            Button("Delete", systemImage: "trash", role: .destructive) { run { try await model.deleteNote(note.id) } }
        }
    }
}

/// Drag a note from the list. Dropped on a notebook in the sidebar (or on All
/// Notes) it moves there, and so do the other ticked notes when it is one of
/// several selected: its ids go as a payload that stays in this app
/// (`DragPayload`). On the Mac it is also dragged out to the Finder (or any
/// app) as a PDF (`NoteFileDrag`): prepared when the drag starts, rendered
/// when the drop asks for it.
private struct NoteDragOut: ViewModifier {
    @AppModelEnvironment private var model
    let note: NoteSummary
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { provider() }
        } else {
            content
        }
    }

    private func provider() -> NSItemProvider {
        // The ticked notes go together when this one is among them.
        let ids = model.isSelectingNotes && model.multiSelection.contains(note.id) ? model.exportTargetIDs : [note.id]
        let payload = DragPayload.notes(ids)
        // Notes in Recently Deleted are not moved by a drop (the drag still carries a PDF out on the Mac).
        return model.beginDrag(note.deleted ? nil : payload, provider: payload.provider { provider in
            guard Platform.isMac else { return }
            NoteFileDrag.register(on: provider, title: note.title, prepare: NoteFileDrag.prepare(note.id, model: model))
        })
    }
}

/// A double-click on a row runs `action` (`DoubleClickAttacher`, on the
/// row's cell, alongside the list's own selection). Attached on the Mac only;
/// the iPad's rows keep exactly their touch handling.
private struct OpenOnDoubleClick: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.background(DoubleClickAttacher(action: action))
        } else {
            content
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary
    /// Not downloaded from iCloud yet: nothing is known about it but its id.
    var placeholder = false
    /// Files are (still) downloading; the summary may be out of date.
    var downloading = false
    /// In "Recently Recognized": what the run read in this note.
    var recognized: RecognizedNote?

    var body: some View {
        if placeholder {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading from iCloud…").foregroundStyle(.secondary)
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note downloading from iCloud")
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(note.title.isEmpty ? String(localized: "Untitled", comment: "Shown for a note without a title") : note.title)
                    .font(.headline)
                if downloading {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating from iCloud")
                }
            }
            HStack(spacing: 6) {
                if let modified = note.modified {
                    Text(modified, format: .dateTime.year().month().day())
                }
                Text("\(note.pages) pages")
                if let recognized {
                    Label(RecognitionResultsText.pagesRead(recognized.pagesRecognized, of: note.pages), systemImage: "text.viewfinder")
                }
                if note.problem != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Some revisions could not be read")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Its own line: beside the date and page count it was squeezed to a few points in
            // right-to-left and double-length layouts (PseudoLanguageUITests); here it wraps instead.
            if let notebook = NotebookPath.canonical(note.notebook) {
                Label(NotebookPath.components(notebook).joined(separator: " › "), systemImage: "book.closed")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    // One chip per tag key: older notes may store two spellings.
                    let tags = NoteOps.normalizedTags(note.tags)
                    ForEach(tags.prefix(4), id: \.self) { TagChip(tag: $0) }
                    if tags.count > 4 { Text("+\(tags.count - 4)").font(.caption2).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Why the list is empty: notes loading (with "Opening vault: N of M"),
/// downloading from iCloud, a failure with a retry, no search match, or
/// genuinely nothing there.
struct EmptyListView: View {
    let reason: EmptyListReason
    let retry: () -> Void

    var body: some View {
        switch reason {
        case .loading(let loading):
            VStack(spacing: 12) {
                ProgressView()
                Text(loading?.headline ?? String(localized: "Opening vault…", comment: "Progress: the note list is being read")).font(.headline).monospacedDigit()
                Text("Notes appear here as they are read.").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .downloading(let sync):
            VStack(spacing: 12) {
                ProgressView(value: sync.fractionCompleted).frame(maxWidth: 240)
                Text(sync.headline).font(.headline).monospacedDigit()
                Text("Notes appear here as iCloud Drive delivers them.").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            ContentUnavailableView {
                Label("Notes Could Not Be Listed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .noMatches(let query):
            ContentUnavailableView.search(text: query)
        case .emptySelection:
            ContentUnavailableView("No Notes Here", systemImage: "note.text",
                                   description: Text("Nothing in this notebook, tag or list."))
        case .emptyVault:
            ContentUnavailableView("No Notes", systemImage: "note.text",
                                   description: Text("This vault has no notes yet. Create one with the New Note button."))
        }
    }
}

/// Below the note list: reading notes ("Opening vault: 120 of 640 notes",
/// or "Updating notes" over a list already shown) and iCloud downloads, in
/// one place. Hidden when there is nothing to report.
struct VaultStatusBar: View {
    let loading: NoteLoading?
    let sync: CloudSyncStatus?
    let retry: () -> Void

    var body: some View {
        let showSync = sync.map { $0.isDownloading || $0.problem != nil } ?? false
        if loading != nil || showSync {
            VStack(alignment: .leading, spacing: 10) {
                if let loading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loading.headline).font(.footnote.weight(.semibold)).monospacedDigit()
                        ProgressView(value: loading.fractionCompleted)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let sync, showSync {
                    CloudSyncBar(status: sync, retry: retry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// The iCloud part of `VaultStatusBar`: "Downloading from iCloud: 37 of 128
/// notes" over a bar, files below; or why it stopped, with a retry. Hidden
/// once everything is local.
struct CloudSyncBar: View {
    let status: CloudSyncStatus
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.isDownloading {
                Text(status.headline).font(.footnote.weight(.semibold)).monospacedDigit()
                ProgressView(value: status.fractionCompleted)
                Text(status.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let problem = status.problem {
                HStack(alignment: .firstTextBaseline) {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry", action: retry).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Notes matching the search, each with the page and the words that matched;
/// a tap opens the note on that page.
private struct SearchResultsList: View {
    @AppModelEnvironment private var model

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Search Recording Transcripts", isOn: Binding(get: { model.searchTranscripts },
                                                                 set: { model.setSearchTranscripts($0) }))
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("searchTranscriptsToggle")
            if model.searchTranscripts {
                Text("Reads and decrypts every transcript of the notes searched, on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.searchTranscripts, model.transcriptSearchProblems > 0, !model.isSearching {
                Text("\(model.transcriptSearchProblems) transcripts could not be read")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                ForEach(model.searchResults) { hit in
                    if let note = model.note(for: hit) {
                        Button { model.openSearchHit(hit) } label: { SearchRow(hit: hit, note: note) }
                            .buttonStyle(.plain)
                            .listRowBackground(model.selectedNoteID == note.id ? SwiftUI.Color.accentColor.opacity(0.15) : nil)
                    }
                }
                if model.searchTranscripts, !model.transcriptHits.isEmpty {
                    Section("In Recordings") {
                        ForEach(model.transcriptHits) { hit in
                            if let note = model.notes.first(where: { $0.id == hit.note }) {
                                Button { model.openTranscriptHit(hit) } label: { TranscriptHitRow(hit: hit, note: note, query: model.searchText) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .overlay {
                let empty = model.searchResults.isEmpty && (!model.searchTranscripts || model.transcriptHits.isEmpty)
                if model.isSearching && empty {
                    ProgressView()
                } else if !model.isSearching && empty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
        }
    }
}

/// A transcript segment that matched: the note, the recording and the time in it.
private struct TranscriptHitRow: View {
    let hit: TranscriptSearchHit
    let note: NoteSummary
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(NoteTitle.display(note.title)).font(.headline)
                Label(hit.timeText, systemImage: "waveform")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Text(Self.highlighted(hit.snippet, query: query)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            if let title = hit.recordingTitle, !title.isEmpty {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// The snippet with the phrase in bold (the CLI's rules: the whole query, ignoring case and accents).
    static func highlighted(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        for range in RecognitionSearch.ranges(of: needle, in: snippet) {
            if let r = Range(range, in: text) {
                text[r].font = .callout.bold()
                text[r].foregroundColor = .primary
            }
        }
        return text
    }
}

/// What a search result's snippet says when the match is inside an equation (tested).
enum SearchSnippetText {
    static var equationMarker: String {
        String(localized: "[equation]", comment: "Search result: the match is inside an equation (its source is not quoted)")
    }

    /// The snippet as a plain string: the localized marker for an equation, else its text.
    static func display(_ snippet: NoteSearchHit.Snippet) -> String {
        snippet.isEquation ? equationMarker : snippet.text
    }
}

private struct SearchRow: View {
    let hit: NoteSearchHit
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(NoteTitle.display(note.title)).font(.headline)
                if let page = hit.page, note.pages > 1 {
                    Text("Page \(page.number)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if hit.matchedPages > 1 {
                    Text("+\(hit.matchedPages - 1) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snippet = hit.snippet {
                if snippet.isEquation {
                    // The match is in an equation's LaTeX source: the marker, not the source (core: `NoteSearch.equationMarker`).
                    Text(SearchSnippetText.equationMarker).font(.callout.italic()).foregroundStyle(.secondary)
                } else {
                    Text(Self.highlighted(snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            HStack(spacing: 6) {
                if let notebook = NotebookPath.canonical(note.notebook) {
                    Label(NotebookPath.components(notebook).joined(separator: " › "), systemImage: "book.closed")
                }
                if hit.fields.contains(.tag) {
                    Label(NoteOps.normalizedTags(note.tags).joined(separator: ", "), systemImage: "tag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    static func highlighted(_ snippet: NoteSearchHit.Snippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.matches {
            if let r = Range(range, in: text) {
                text[r].font = .callout.bold()
                text[r].foregroundColor = .primary
            }
        }
        return text
    }
}

/// "Recognizing handwriting: 12 of 80 notes" with a cancel button.
struct RecognitionBar: View {
    let progress: RecognitionProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                let notes = String(localized: "\(progress.total) notes", comment: "A number of notes")
                Text("Reading handwriting: \(progress.done) of \(notes)")
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                Spacer()
                Button("Stop", action: cancel).font(.footnote)
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            if progress.failed > 0 {
                Text("\(progress.failed) could not be read").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// Wording of the recognition results (tested).
enum RecognitionResultsText {
    static let sectionHeadline = String(localized: "Read by Recognize All in the last 7 days", comment: "Header above the Recently Recognized list")

    /// "Read 2 of 5 pages", "Read 1 page".
    static func pagesRead(_ read: Int, of pages: Int) -> String {
        read >= pages ? String(localized: "Read \(read) pages", comment: "Pages of a note whose handwriting was read")
            : String(localized: "Read \(read) of \(String(localized: "\(pages) pages", comment: "A number of pages"))", comment: "%@ is a number of pages, e.g. “5 pages”")
    }

    /// The line under the headline: what is still going on, or what went wrong.
    static func detail(_ results: RecognitionResults, running: Bool) -> String? {
        var parts: [String] = []
        if running { parts.append(String(localized: "Still reading…", comment: "Recognize All is still running")) }
        if results.failed > 0 { parts.append(String(localized: "\(results.failed) could not be read", comment: "A number of notes whose handwriting could not be read")) }
        if results.stopped { parts.append(String(localized: "Stopped early", comment: "Recognize All was stopped before the end")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Above the list in "Recently Recognized": what it is, and how this
/// session's run went ("Still reading…", "2 could not be read").
private struct RecognitionResultsHeader: View {
    let results: RecognitionResults?
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(RecognitionResultsText.sectionHeadline).font(.footnote.weight(.semibold))
            if let results, let detail = RecognitionResultsText.detail(results, running: running) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
