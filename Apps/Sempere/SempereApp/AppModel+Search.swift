import Foundation
import Sempere

/// Where a search looks.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    /// Every note (Recently Deleted only while it is the sidebar selection).
    case everywhere = "All Notes"
    /// The notes the sidebar selection shows.
    case list = "This List"

    var id: String { rawValue }

    /// The scope bar's label: the list's is the sidebar row it searches
    /// ("In “Math”", "In #todo"), so the bar says what the results cover.
    func title(for selection: SidebarItem?) -> String {
        guard self == .list else { return String(localized: "All Notes", comment: "Search scope: every note") }
        switch selection ?? .allNotes {
        case .allNotes: return String(localized: "This List", comment: "Search scope: the notes the sidebar selection shows")
        case .notebook(let n):
            let name = NotebookPath.components(n).last ?? n
            return String(localized: "In “\(name)”", comment: "Search scope: the notes of one notebook (its name)")
        case .tag(let t): return String(localized: "In #\(t)", comment: "Search scope: the notes with one tag")
        case .deleted: return String(localized: "In Recently Deleted", comment: "Search scope")
        case .favorites: return String(localized: "In Favorites", comment: "Search scope")
        case .recentlyRecognized: return String(localized: "In Recently Recognized", comment: "Search scope")
        }
    }
}

/// A page to show once its note is open.
struct PageJump: Equatable, Sendable {
    var note: UUID
    var page: UUID
    /// The search the page was found with: its words are highlighted on the
    /// canvas (`NoteEditor.highlightSearch`). Nil: just show the page.
    var query: String? = nil
}

/// "Recognise All Notes" while it runs.
struct RecognitionProgress: Equatable, Sendable {
    var done = 0
    var total: Int
    /// Notes that could not be read or written.
    var failed = 0
}

/// The notes a "Recognize All Notes" run changed, as it goes and after it
/// ends (this session; "Recently Recognized" lists them for 7 days on every device, `meta.recognized`).
struct RecognitionResults: Equatable, Sendable {
    /// In the order they were read.
    var notes: [RecognizedNote] = []
    /// Notes that could not be read or written.
    var failed = 0
    /// False while the run goes on.
    var finished = false
    /// The run was stopped before every note was read.
    var stopped = false

    /// "Recognized 12 notes".
    var headline: String { String(localized: "Recognized \(notes.count) notes", comment: "Result of a Recognize All Notes run") }

    /// The entry for a note, for its row's "Read 2 of 5 pages".
    func entry(for id: UUID) -> RecognizedNote? { notes.first { $0.id == id } }
}

extension AppModel {
    // MARK: - Search

    /// The notes a search looks through.
    var searchCandidates: [NoteSummary] {
        switch searchScope {
        case .list: return notesInSelection
        case .everywhere:
            if case .deleted? = sidebarSelection { return notes.filter(\.deleted) }
            return notes.filter { !$0.deleted }
        }
    }

    /// True while the note list shows search results rather than the list.
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The summary of a hit's note.
    func note(for hit: NoteSearchHit) -> NoteSummary? {
        notes.first { $0.id == hit.note }
    }

    /// Re-runs the search after `searchDebounce`, off the main actor; an
    /// older search still running is dropped. Called whenever the query, the
    /// scope, the selection or the notes change.
    func updateSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchTask = nil
            isSearching = false
            if !searchResults.isEmpty { searchResults = [] }
            if !transcriptHits.isEmpty { transcriptHits = [] }
            transcriptSearchProblems = 0
            return
        }
        isSearching = true
        let candidates = searchCandidates
        let gen = generation
        let delay = searchDebounce
        let withTranscripts = searchTranscripts
        if !withTranscripts, !transcriptHits.isEmpty { transcriptHits = [] }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let hits = await Task.detached(priority: .userInitiated) { NoteSearch.search(query, in: candidates) }.value
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.searchResults = hits
            if withTranscripts {
                self.transcriptHits = []
                // The notes' hits are in; the transcripts follow as they are read.
                await self.runTranscriptSearch(query, in: candidates, generation: gen)
                guard !Task.isCancelled, gen == self.generation else { return }
            }
            self.isSearching = false
        }
    }

    /// Opens the note of `hit` on the page that matched.
    func openSearchHit(_ hit: NoteSearchHit) {
        recordSearch()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingJump = hit.page.map { PageJump(note: hit.note, page: $0.pageId, query: query.isEmpty ? nil : query) }
        selectedNoteID = hit.note
        applyPendingJump()
    }

    /// Shows the pending page when its note is the one on the canvas; drops
    /// a jump that belongs to another note.
    func applyPendingJump() {
        applyPendingRecordingJump()
        guard let jump = pendingJump, let editor else { return }
        guard editor.noteID == jump.note else {
            if selectedNoteID != jump.note { pendingJump = nil }
            return
        }
        pendingJump = nil
        editor.showPage(id: jump.page)
        if let query = jump.query { editor.highlightSearch(query: query, page: jump.page) }
    }

    // MARK: - Recognition

    /// Turns handwriting recognition on or off (remembered), for the open
    /// note and every note opened from now on.
    func setHandwritingRecognition(_ on: Bool) {
        RecognitionPreference.enabled = on
        recognizer = on ? VisionPageRecognizer() : nil
        if !on { cancelRecognizingNotes() }
    }

    /// Notes with pages never read (or changed since), that "Recognise All"
    /// would read. Open notes (the library's and note windows') and notes still downloading are
    /// left to their editors and the sync.
    var notesNeedingRecognition: [NoteSummary] {
        notes.filter {
            !$0.deleted && $0.problem == nil && $0.pagesNeedingRecognition > 0 && $0.id != editor?.noteID
                && !windowClaims.contains($0.id)
                && !pendingNoteIDs.contains($0.id) && !placeholderNoteIDs.contains($0.id)
        }
    }

    /// Reads the handwriting of every note in `notesNeedingRecognition`, one
    /// note at a time, one delta per note.
    func startRecognizingNotes() {
        guard recognitionTask == nil, phase == .unlocked, let recognizer else { return }
        let ids = notesNeedingRecognition.map(\.id)
        guard !ids.isEmpty else { return }
        let gen = generation
        recognitionProgress = RecognitionProgress(total: ids.count)
        recognitionResults = RecognitionResults()   // the previous run's list is replaced now
        recognitionTask = Task { [weak self] in
            await self?.recognizeNotes(ids, with: recognizer, generation: gen)
            guard let self, gen == self.generation else { return }
            self.recognitionResults?.finished = true
            self.recognitionResults?.stopped = (self.recognitionProgress?.done ?? 0) < ids.count
            self.recognitionTask = nil
            self.recognitionProgress = nil
        }
    }

    func cancelRecognizingNotes() {
        recognitionTask?.cancel()
    }

    func recognizeNotes(_ ids: [UUID], with recognizer: any PageRecognizing, generation gen: Int) async {
        for id in ids {
            guard !Task.isCancelled, gen == generation else { return }
            do {
                // The delta also sets the note's `meta.recognized`: "Recently Recognized" on every device.
                if let done = try await recognizeNote(id, with: recognizer) { recognitionResults?.notes.append(done) }
            } catch is CancellationError {
                return
            } catch {
                recognitionProgress?.failed += 1
                recognitionResults?.failed += 1
            }
            recognitionProgress?.done += 1
        }
    }

    /// Reads the pages of note `id` that need it and writes their text in one
    /// delta. Each page is written only if its strokes are still the ones
    /// that were read when the delta is made (another device may have edited the note).
    /// Returns what was written (nil: nothing needed or still matched).
    @discardableResult
    func recognizeNote(_ id: UUID, with recognizer: any PageRecognizing) async throws -> RecognizedNote? {
        let gen = generation
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        try await downloadNote(id)
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let state: NoteState? = try await offMain {
            try CloudVault.coordinatedRead(coordinate) { () throws -> NoteState? in
                let loaded = try vault.loadNote(id)
                guard loaded.failures.isEmpty, !loaded.revisions.isEmpty else { return nil }   // read-only
                let state = try NoteReducer.reconstruct(loaded.revisions)
                return state.deleted ? nil : state
            }
        }
        try ensureCurrent(gen)
        guard let state else { return nil }
        var jobs: [RecognitionJob] = []
        for page in state.pages where RecognitionPolicy.needsRecognition(page) {
            let digest = RecognitionBasis.digest(of: page)
            var result: Recognition?
            if !page.strokes.isEmpty {
                var r = try await recognizer.recognize(strokes: page.strokes, language: state.meta.lang)
                r.basis = digest
                result = r
            }
            try Task.checkCancellation()
            try ensureCurrent(gen)
            jobs.append(RecognitionJob(page: page.id, digest: digest, recognition: result))
        }
        guard !jobs.isEmpty else { return nil }
        let planned = jobs
        let written = WrittenCount()
        let now = activityNow()
        try await commit(id) { current in
            // Deleted meanwhile (another device): no writes into Recently Deleted.
            written.value = RecognitionJob.ops(for: planned, in: current).count
            // With the `setMeta` of `meta.recognized`: listed in "Recently Recognized" on every device.
            return RecognitionJob.ops(for: planned, in: current, recordedAt: now)
        }
        guard written.value > 0 else { return nil }
        let summary = notes.first { $0.id == id }
        return RecognizedNote(id: id, title: summary?.title ?? state.meta.title,
                              pages: summary?.pages ?? state.pages.count, pagesRecognized: written.value)
    }
}

/// How many ops a `commit` closure produced, read once the commit has finished.
final class WrittenCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }
}

