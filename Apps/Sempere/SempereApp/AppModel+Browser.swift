import Age
import Foundation
import Sempere

/// Vault browsing: opening and creating vaults, and the sidebar's edits.
/// Every edit is one delta per note, written through `NoteWriter` with the
/// same device clock as the canvas; the app never writes vault files itself.
extension AppModel {

    // MARK: - Opening and creating

    /// Opens what the user picked (a `.sempere` vault, a plain folder, a folder
    /// holding one vault, or a file inside a vault: `VaultLocator`) and
    /// remembers it.
    func open(picked url: URL, library: VaultLibrary) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let vaultURL = try VaultLocator.resolve(url)
        try await openVault(at: vaultURL, accessing: vaultURL == url ? nil : url)
        remember(in: library)
    }

    /// Reopens a recent vault from its bookmark.
    ///
    /// - Throws: `VaultLibrary.LibraryError.cannotResolve` when the bookmark
    ///   is dead (the entry is dropped); otherwise whatever opening throws,
    ///   with the entry kept.
    func open(recent entry: RecentVault, library: VaultLibrary) async throws {
        if let location = entry.webdav {
            guard webdavLocations.location(location) != nil else {
                library.forget(entry)
                throw VaultLibrary.LibraryError.cannotResolve(name: entry.name)
            }
            return try await openWebDAV(location, library: library)
        }
        let url = try library.resolve(entry)
        try await openVault(at: url)
        remember(in: library)
    }

    /// Creates a vault in `parent` and opens it: unlocked when a key was
    /// generated, locked (asking for the key) when only a recipient was given.
    ///
    /// When another vault is opened or this one closed meanwhile, the vault
    /// is still created and returned (with its key, which nothing else holds)
    /// but not opened.
    func createVault(_ request: NewVaultRequest, in parent: URL, library: VaultLibrary) async throws -> CreatedVault {
        let gen = generation
        let created = try await library.create(request, in: parent)
        guard gen == generation else { return created }
        do {
            // The scope on `parent` ended; reopen through the bookmark `create` saved
            // (by id: another recent vault may have the same name).
            if let entry = library.recents.first(where: { $0.id == created.recentID }),
               let url = try? library.resolve(entry) {
                try await openVault(at: url)
            } else {
                try await openVault(at: created.url)
            }
            let opened = generation
            if let secret = created.secretKey {
                try ensureCurrent(opened)
                try await unlock(identityText: secret)
            }
            try ensureCurrent(opened)
        } catch is CancellationError {
            return created
        }
        remember(in: library)
        return created
    }

    private func remember(in library: VaultLibrary) {
        guard let url = vaultURL else { return }
        do { try library.remember(url) } catch {
            errorMessage = String(localized: "The vault opened, but Sempere could not save access to it for next time: \(String(describing: error))")
        }
    }

    // MARK: - Edits

    /// Creates a note with one empty page and selects it.
    @discardableResult
    func createNote(title: String, paper: Paper, notebook: String?, pageSize: PageSize = .letter) async throws -> UUID {
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
    /// notebook and lifts its sub-notebooks to the top level.
    ///
    /// Returns the notebook each changed note had before (to undo the rename).
    @discardableResult
    func renameNotebook(_ old: String, to new: String) async throws -> [UUID: String?] {
        guard let old = NotebookPath.canonical(old) else { return [:] }
        let target = NotebookPath.canonical(new)
        guard target != old else { return [:] }
        // Notes not downloaded, or not read yet in this session (still listing,
        // or shown from an earlier launch's cache), have no known notebook:
        // they would be left behind, or moved by a notebook they left.
        guard pendingNoteIDs.isEmpty, listLoaded, notes.allSatisfy({ verifiedNoteIDs.contains($0.id) }) else {
            throw ModelError.notesStillDownloading
        }
        let current = Dictionary(notes.map { ($0.id, $0.notebook) }, uniquingKeysWith: { a, _ in a })
        let edits = NoteOps.renameNotebook(old, to: target, notebooks: current)
        // iCloud: a note shown from the index may be evicted (its names did not
        // change, so it is not pending). Every note is made local before the
        // first delta is written, so a rename never stops halfway.
        let gen = generation
        for edit in edits {
            try await downloadNote(edit.noteId)
            try ensureCurrent(gen)
        }
        try await commit(edits.map { (id: $0.noteId, ops: $0.ops) })
        if case .notebook(let selected)? = sidebarSelection, NotebookPath.name(selected, isWithin: old) {
            sidebarSelection = NotebookPath.renamed(selected, from: old, to: target).map(SidebarItem.notebook) ?? .allNotes
        }
        return Dictionary(edits.map { ($0.noteId, current[$0.noteId] ?? nil) }, uniquingKeysWith: { a, _ in a })
    }

    /// Puts a note into the notebook path `notebook` (nil or blank: none).
    func moveNote(_ id: UUID, toNotebook notebook: String?) async throws {
        let target = NotebookPath.canonical(notebook)
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).notebook != target else { return }
        try await commit(id) { state in state.map { NoteOps.move(toNotebook: target, state: $0) } ?? [.setMeta(.notebook(target))] }
    }

    /// Renames a note (one `setMeta(.title)` delta). Titles are labels, not keys:
    /// any title, including one another note has, is fine.
    func renameNote(_ id: UUID, to title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).title != title else { return }
        try await commit(id) { state in state.map { NoteOps.rename(to: title, state: $0) } ?? [.setMeta(.title(title))] }
    }

    /// Marks a note as a favorite, or takes the mark off (one `setMeta` favorite
    /// delta, `NoteOps.setFavorite`; nothing is written when it already is that way).
    func setFavorite(_ on: Bool, for id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).favorite != on else { return }
        try await commit(id) { state in state.map { NoteOps.setFavorite(on, state: $0) } ?? [.setMeta(.favorite(on))] }
    }

    /// Adds a tag (one `addTag`, format.md §5.4.1). Matching ignores case: a
    /// tag the note has already (in any case) is not added again, and the
    /// spelling of a tag already used in the vault wins over the typed one.
    /// Tags added concurrently on another device all survive the merge.
    func addTag(_ tag: String, to id: UUID) async throws {
        let typed = NoteOps.normalizedTag(tag)
        guard !typed.isEmpty else { return }
        try await downloadNote(id)
        try await verifySummary(id)
        guard !(try summary(id).tags.contains { NoteOps.tagKey($0) == NoteOps.tagKey(typed) }) else { return }
        let spelling = NoteOps.tagSpelling(typed, among: tags)
        try await commit(id) { state in
            guard let state else { return [.addTag(spelling)] }
            return NoteOps.addTag(spelling, to: state).map { [$0] } ?? []
        }
    }

    /// Removes a tag in any spelling (one `removeTag` observing every
    /// instance of it on disk, format.md §5.4.1).
    func removeTag(_ tag: String, from id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(tag) }) else { return }
        try await commit(id) { state in state.flatMap { NoteOps.removeTag(tag, from: $0) }.map { [$0] } ?? [] }
        if case .tag(let selected)? = sidebarSelection, !self.tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(selected) }) {
            sidebarSelection = .allNotes
        }
    }

    /// Moves a note to Recently Deleted; open on the canvas, it reopens read-only.
    func deleteNote(_ id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard !(try summary(id).deleted) else { return }
        try await commit(id) { state in state.map { NoteOps.delete($0) } ?? [.deleteNote] }
        try await reopenEditor(ifShowing: id)
    }

    /// Restores a note; open on the canvas, it reopens editable.
    func restoreNote(_ id: UUID) async throws {
        try await downloadNote(id)
        try await verifySummary(id)
        guard try summary(id).deleted else { return }
        try await commit(id) { state in state.map { NoteOps.undelete($0) } ?? [.restoreNote] }
        try await reopenEditor(ifShowing: id)
    }

    private func summary(_ id: UUID) throws -> NoteSummary {
        guard let note = notes.first(where: { $0.id == id }) else { throw ModelError.noteNotFound }
        return note
    }

    /// Writes one delta per entry, one after another, then refreshes just
    /// those summaries. Edits are serialised (`editGate`) so two taps cannot
    /// interleave; the vault is looked up after waiting, so an edit queued
    /// before the vault closed is not written into it afterwards (and
    /// `close()` waits for one being written before access to the folder
    /// ends). Deltas go through `NoteWriter.append` with the canvas's device
    /// clock; in iCloud Drive each is a coordinated write on its note's folder.
    /// Callers that compute ops from a note's summary make the note local
    /// first (`downloadNote`), so a placeholder's empty summary is never
    /// written back over the real one; in iCloud Drive each append re-checks
    /// inside its coordinated read that the note is still all local
    /// (`CloudVault.requireLocal`) and refuses to write otherwise.
    private func commit(_ edits: [(id: UUID, ops: [Op])], creating: Set<UUID> = []) async throws {
        let batch = edits
        try await commit(ids: batch.map(\.id), creating: creating) { vault, clock, cloud, verifier in
            for edit in batch {
                try await NoteWriter.append(edit.ops, to: edit.id, vault: vault, clock: clock, coordinated: cloud,
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
    func commit(_ id: UUID, building build: @escaping @Sendable (NoteState?) -> [Op]) async throws {
        try await commit(ids: [id]) { vault, clock, cloud, verifier in
            try await NoteWriter.append(to: id, vault: vault, clock: clock, coordinated: cloud,
                                        verify: verifier(id), building: build)
        }
    }

    /// `write` gets the vault, the clock, whether the vault is in iCloud Drive,
    /// and the check each note's append runs inside its coordinated read.
    /// Notes in `creating` are new: they have no files to be local yet, so
    /// they get no check (requireLocal would refuse an empty, unlisted folder)
    /// as long as their folder lists no revision; one that does (an id that
    /// is not new after all) is checked like any other note.
    func commit(ids: [UUID], creating: Set<UUID> = [],
                        write: (Vault, DeviceClock, Bool, @Sendable (UUID) -> (@Sendable () throws -> Void)?) async throws -> Void)
        async throws {
        await editGate.acquire()
        defer { editGate.release() }
        guard let vault else { throw ModelError.noVaultOpen }
        guard vault.canRead else { throw vault.isLocked ? VaultError.locked : VaultError.noIdentities }
        try requireWritableVault()   // format.md §7.3
        let clock = try deviceClockForWriting()
        isEditing = true
        defer { isEditing = false }
        let cloud = isCloudVault
        let hooks = cloudHooks
        let url = vault.url
        // iCloud: every revision file must still be local when the delta's
        // seq is picked (a file can be evicted, or a new one listed, after
        // `downloadNote`; a notebook rename does not download at all).
        let verifier: @Sendable (UUID) -> (@Sendable () throws -> Void)? = { id in
            guard cloud else { return nil }
            if creating.contains(id) {
                return {
                    let listed = try CloudScan.noteItems(inVault: url, id: id)
                    guard !listed.isEmpty else { return }
                    try CloudVault.requireLocal(note: id, vault: url, hooks: hooks)
                }
            }
            return { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
        }
        do {
            try await write(vault, clock, cloud, verifier)
        } catch {
            try? await refresh(ids)   // some deltas may have landed
            throw error
        }
        try await refresh(ids)
    }

    /// Re-reads the summaries of `ids` and merges them into `notes`.
    func refresh(_ ids: [UUID]) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        let coordinate = coordinationURL
        let cache = summaryCache
        let entries = try await offMain {
            try CloudVault.coordinatedRead(coordinate) {
                try vault.summaryEntries(of: ids, cache: cache, saveCache: false)
                    .map { NamedSummary(summary: $0.summary, revisions: $0.revisions) }
            }
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
        try await commit(ids: batch) { vault, clock, cloud, verifier in
            for id in batch {
                try await NoteWriter.append(to: id, vault: vault, clock: clock, coordinated: cloud, verify: verifier(id)) { state in
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
        let previous = try await renameNotebook(from, to: target)
        return previous.isEmpty ? nil : NotebookMoveRecord(previous: previous, actionName: String(localized: "Move Notebook", comment: "Undo action name"))
    }

    /// Puts the notes of `record` back where they were (undo of a move), one commit.
    func restoreNotebooks(_ record: NotebookMoveRecord) async throws {
        let batch = Array(record.previous.keys).filter { id in notes.contains { $0.id == id } }
        guard !batch.isEmpty else { return }
        let gen = generation
        for id in batch {
            try await downloadNote(id)
            try ensureCurrent(gen)
        }
        let previous = record.previous
        try await commit(ids: batch) { vault, clock, cloud, verifier in
            for id in batch {
                let target = NotebookPath.canonical(previous[id] ?? nil)
                try await NoteWriter.append(to: id, vault: vault, clock: clock, coordinated: cloud, verify: verifier(id)) { state in
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
    /// cancelled drag, since `onDrag` reports no end.
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
}
