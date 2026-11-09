import Age
import Foundation
import Sempere

/// Vault browsing: creating vaults, and the sidebar's edits.
/// Every edit is one delta per note, written through `NoteWriter` with the
/// same device clock as the canvas; the app never writes vault files itself.
extension AppModelCore {

    // MARK: - Opening and creating

    /// Creates a vault in the in-app store (`VaultLibrary.create`), this device its home, and opens it
    /// unlocked with this device's new key (`CreatedVault.device`).
    ///
    /// When another vault is opened or this one closed meanwhile, the vault
    /// is still created and returned (with its key, which nothing else holds)
    /// but not opened.
    public func createVault(_ request: NewVaultRequest, library: VaultLibrary) async throws -> CreatedVault {
        let gen = generation
        let created = try await library.create(request, trust: trust)
        guard gen == generation else { return created }
        do {
            try await openVault(at: created.url)
            let opened = generation
            try ensureCurrent(opened)
            try await unlock(device: created.device)
            try ensureCurrent(opened)
        } catch is CancellationError {
            return created
        }
        remember(in: library)
        return created
    }

    func remember(in library: VaultLibrary) {
        guard let url = vaultURL else { return }
        library.remember(url)
    }

    // MARK: - Edits

    /// Creates a note with one empty page and selects it.
    @discardableResult
    public func createNote(title: String, paper: Paper, notebook: String?, pageSize: PageSize = .letter) async throws -> UUID {
        let id = UUID()
        let notebook = NotebookPath.canonical(notebook)
        // No title typed: the date (and time), or nothing, as Settings → New Notes says (`NewNoteSettings`).
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? defaultTitle(Date()) : typed
        try await commit([(id: id, ops: NoteOps.newNote(title: title,
                                                        paper: paper, pageSize: pageSize, notebook: notebook))],
                         creating: [id])
        selectNewNote(id, notebook: notebook)
        return id
    }

    /// Selects a note just created in `notebook`, showing all notes when the
    /// sidebar's selection would hide it.
    func selectNewNote(_ id: UUID, notebook: String?) {
        switch sidebarSelection ?? .allNotes {
        case .notebook(let n) where !NotebookPath.name(notebook, isWithin: n): sidebarSelection = .allNotes
        case .tag, .deleted: sidebarSelection = .allNotes
        default: break
        }
        selectedNoteID = id
    }

    /// Renames or moves the notebook `old` (a `/`-separated path, format.md
    /// §5.4) to `new`: every note in it or below it, deleted ones too, gets
    /// the `old` prefix of its notebook replaced by `new` (one `setMeta` per
    /// note). An empty `new` takes the notes directly in `old` out of any
    /// notebook and lifts its sub-notebooks to the top level. Empty notebooks
    /// within `old` (notebook records, format.md §14.4) are renamed too, by one
    /// record written before the notes' deltas.
    ///
    /// Returns the notebook each changed note had before (to undo the rename).
    @discardableResult
    public func renameNotebook(_ old: String, to new: String) async throws -> [UUID: String?] {
        guard let old = NotebookPath.canonical(old) else { return [:] }
        let target = NotebookPath.canonical(new)
        guard target != old else { return [:] }
        // Notes not downloaded, or not read yet in this session (still listing,
        // or shown from an earlier launch's cache), have no known notebook:
        // they would be left behind, or moved by a notebook they left.
        guard pendingNoteIDs.isEmpty, listLoaded, notes.allSatisfy({ verifiedNoteIDs.contains($0.id) }) else {
            throw joinLocation.map { ModelError.notesStillDownloadingFromServer($0.host) } ?? .notesStillDownloading
        }
        let current = Dictionary(notes.map { ($0.id, $0.notebook) }, uniquingKeysWith: { a, _ in a })
        let edits = NoteOps.renameNotebook(old, to: target, notebooks: current)
        // Every note is made complete (a partial copy) before the first delta is written, so a rename
        // never stops halfway.
        let gen = generation
        for edit in edits {
            try await downloadNote(edit.noteId)
            try ensureCurrent(gen)
        }
        if declaredNotebooks.contains(where: { NotebookPath.name($0, isWithin: old) }) {
            try await writeNotebookRecords { vault in _ = try vault.renameNotebookRecords(old, to: target) }
        }
        if !edits.isEmpty { try await commit(edits.map { (id: $0.noteId, ops: $0.ops) }) }
        if case .notebook(let selected)? = sidebarSelection, NotebookPath.name(selected, isWithin: old) {
            sidebarSelection = NotebookPath.renamed(selected, from: old, to: target).map(SidebarItem.notebook) ?? .allNotes
        }
        return Dictionary(edits.map { ($0.noteId, current[$0.noteId] ?? nil) }, uniquingKeysWith: { a, _ in a })
    }

    /// Puts a note into the notebook path `notebook` (nil or blank: none).
    public func moveNote(_ id: UUID, toNotebook notebook: String?) async throws {
        let target = NotebookPath.canonical(notebook)
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).notebook != target else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.map { NoteOps.move(toNotebook: target, state: $0) } ?? [.setMeta(.notebook(target))] }
    }

    /// Renames a note (one `setMeta(.title)` delta). Titles are labels, not keys:
    /// any title, including one another note has, is fine.
    public func renameNote(_ id: UUID, to title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).title != title else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.map { NoteOps.rename(to: title, state: $0) } ?? [.setMeta(.title(title))] }
    }

    /// Marks a note as a favorite, or takes the mark off (one `setMeta` favorite
    /// delta, `NoteOps.setFavorite`; nothing is written when it already is that way).
    public func setFavorite(_ on: Bool, for id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).favorite != on else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.map { NoteOps.setFavorite(on, state: $0) } ?? [.setMeta(.favorite(on))] }
    }

    /// Adds a tag (one `addTag`, format.md §5.4.1). Matching ignores case: a
    /// tag the note has already (in any case) is not added again, and the
    /// spelling of a tag already used in the vault wins over the typed one.
    /// Tags added concurrently on another device all survive the merge.
    public func addTag(_ tag: String, to id: UUID) async throws {
        let typed = NoteOps.normalizedTag(tag)
        guard !typed.isEmpty else { return }
        try await downloadNote(id)
        try await verifySummary(id)
        guard !(try summary(id).tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(typed) }) else { return }
        let spelling = NoteOps.tagSpelling(typed, among: tags)
        try await commit(id, detail: .withoutStrokePoints) { state in
            guard let state else { return [.addTag(spelling)] }
            return NoteOps.addTag(spelling, to: state).map { [$0] } ?? []
        }
    }

    /// Removes a tag in any spelling (one `removeTag` observing every
    /// instance of it on disk, format.md §5.4.1).
    public func removeTag(_ tag: String, from id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(tag) }) else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.flatMap { NoteOps.removeTag(tag, from: $0) }.map { [$0] } ?? [] }
        if case .tag(let selected)? = sidebarSelection, !self.tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(selected) }) {
            sidebarSelection = .allNotes
        }
    }

    /// Moves a note to Recently Deleted; open on the canvas, it reopens read-only.
    public func deleteNote(_ id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard !(try summary(id).deleted) else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.map { NoteOps.delete($0) } ?? [.deleteNote] }
        try await reopenEditor(ifShowing: id)
    }

    /// Restores a note; open on the canvas, it reopens editable.
    public func restoreNote(_ id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).deleted else { return }
        try await commit(id, detail: .withoutStrokePoints) { state in state.map { NoteOps.undelete($0) } ?? [.restoreNote] }
        try await reopenEditor(ifShowing: id)
    }

    private func summary(_ id: UUID) throws -> NoteSummary {
        guard let note = notes.first(where: { $0.id == id }) else { throw ModelError.noteNotFound }
        return note
    }

    /// Writes one delta per entry, one after another, then refreshes just
    /// those summaries. Edits are serialized (`editGate`) so two taps cannot
    /// interleave; the vault is looked up after waiting, so an edit queued
    /// before the vault closed is not written into it afterwards (and
    /// `close()` waits for one being written before access to the folder
    /// ends). Deltas go through `NoteWriter.append` with the canvas's device
    /// clock. Callers that compute ops from a note's summary make the note
    /// complete first (`downloadNote`), so a placeholder's empty summary is never
    /// written back over the real one; in a partial copy each append re-checks
    /// that the note is not marked incomplete (`partialNoteVerifier`) and
    /// refuses to write otherwise.
    private func commit(_ edits: [(id: UUID, ops: [Op])], creating: Set<UUID> = []) async throws {
        let batch = edits
        try await commit(ids: batch.map(\.id), creating: creating) { vault, clock, verifier in
            for edit in batch {
                try await NoteWriter.append(edit.ops, to: edit.id, vault: vault, clock: clock,
                                            verify: verifier(edit.id))
            }
        }
    }

    /// One delta for note `id` whose ops `build` computes from the note as it
    /// is on disk when written (`NoteWriter.append(to:building:)`); nothing
    /// is written when it returns none. `build` gets nil when no revision of
    /// the note is readable: edits whose op does not depend on the note then
    /// write it anyway, so a note that cannot be read can still be renamed,
    /// moved or deleted.
    /// With `detail: .withoutStrokePoints` the note is read without stroke
    /// geometry: for builders of metadata ops only (move, rename, favorite,
    /// tags, delete; `NoteWriter.append(to:detail:building:)`).
    func commit(_ id: UUID, detail: RevisionDetail = .full,
                building build: @escaping @Sendable (NoteState?) -> [Op]) async throws {
        try await commit(ids: [id]) { vault, clock, verifier in
            try await NoteWriter.append(to: id, vault: vault, clock: clock, detail: detail,
                                        verify: verifier(id), building: build)
        }
    }

    /// `write` gets the vault, the clock, whether writes are coordinated (never, since every vault is an
    /// in-app copy; the parameter goes with the rest of the coordination plumbing), and the check each
    /// note's append runs before it writes: in a partial copy, a note still marked incomplete is refused
    /// (`partialNoteVerifier`, review of #75; core refuses such a write too, format.md §1.2). A note in
    /// `creating` is new and is never marked incomplete, so the same check passes for it.
    func commit(ids: [UUID], creating: Set<UUID> = [],
                        write: (Vault, DeviceClock, @Sendable (UUID) -> (@Sendable () throws -> Void)?) async throws -> Void)
        async throws {
        await editGate.acquire()
        defer { editGate.release() }
        guard let vault else { throw ModelError.noVaultOpen }
        guard vault.canRead else { throw VaultError.locked }
        try requireWritableVault()   // format.md §7.3
        let clock = try deviceClockForWriting()
        isEditing = true
        defer { isEditing = false }
        // A partial copy: every note written to must be complete when the delta's seq is picked (a
        // notebook rename does not fetch a pending note first).
        let partial = partialCopyRoot
        let missing = joinNotDownloadedError
        let verifier: @Sendable (UUID) -> (@Sendable () throws -> Void)? = { id in
            guard let partial else { return nil }
            return { if Self.incompleteNoteIDs(partial).contains(id) { throw missing } }
        }
        _ = creating
        do {
            try await write(vault, clock, verifier)
        } catch {
            try? await refresh(ids)   // some deltas may have landed
            throw error
        }
        try await refresh(ids)
    }

    /// Re-reads the summaries of `ids` and merges them into `notes`.
    public func refresh(_ ids: [UUID]) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        let cache = summaryCache
        let entries = try await offMain {
            try vault.summaryEntries(of: ids, cache: cache, saveCache: false)
                .map { NamedSummary(summary: $0.summary, revisions: $0.revisions) }
        }
        try ensureCurrent(gen)
        for id in ids { summaryEpochs[id, default: 0] += 1 }
        let fresh = entries.map(\.summary)
        for e in entries { indexedNames[e.summary.id] = e.revisions }
        merge(fresh)
        summariesRead(fresh)
        verifiedNoteIDs.formUnion(fresh.map(\.id))
        // Each save re-encodes the whole index, and this runs for every
        // recognized page and browser edit: at most once per
        // `summaryCacheSaveInterval`. Background, Cloud pause and close
        // still save; a crash only costs re-reading these notes.
        saveSummaryCacheIfDue(force: false)
    }
}

/// A first-come first-served lock for the main actor: waiters sleep instead
/// of spinning.
@MainActor
final class EditGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are waiting in `acquire`.
    var waiting: Int { waiters.count }

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock to the next waiter, if any.
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
