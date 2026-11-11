import Foundation
import Sempere

/// Note windows (Mac): one note per window, each with its own editor (`windowEditors`).
///
/// The vault, the device clock and the edit gate stay the model's, shared by
/// every window, so a delta from any window ticks the one clock. A note has
/// at most one editor at a time: while a window shows a note (`claimNote`),
/// the library window's detail pane does not open an editor for it (two
/// editors on one note would each keep their own stroke ledger and write
/// diverging deltas); it shows a placeholder instead. Rendering a note dragged
/// out to the Finder stays in the app (`AppModel+DragExport.swift`).
extension AppModelCore {

    /// The window to open for note `id` (File > Open Note in New Window, the
    /// list's context menu, a double-click on a row): nil without an unlocked
    /// vault, for a note not (yet) listed, still downloading or in Recently Deleted.
    public func noteWindowValue(for id: UUID?) -> NoteWindowValue? {
        guard let id, phase == .unlocked, let vault = vault?.vaultId, !placeholderNoteIDs.contains(id),
              let note = notes.first(where: { $0.id == id }), !note.deleted else { return nil }
        return NoteWindowValue(vaultID: vault, noteID: id)
    }

    /// Takes `noteID` for a note window: an editor the library window has open
    /// on it is saved and closed first.
    public func claimNote(_ noteID: UUID) async {
        windowClaims.insert(noteID)
        if editor?.noteID == noteID {
            try? await openEditor(for: nil)
        }
    }

    /// Gives `noteID` back (its window closed): saves and closes the window's
    /// editor; the library window opens it again if it is selected. The claim
    /// ends only once the last save is written, so the library never reads
    /// the note before it (and stays if a window took the note again meanwhile).
    public func releaseNote(_ noteID: UUID) async {
        let editor = windowEditors.removeValue(forKey: noteID)
        await editor?.close()
        if windowEditors[noteID] == nil { windowClaims.remove(noteID) }
    }

    /// Opens the editor of a note window. Needs an unlocked vault. A second
    /// call for the same note returns the editor already open.
    public func openWindowNote(_ noteID: UUID) async throws -> Editor {
        if let open = windowEditors[noteID] { return open }
        guard !isChangingKeys else { throw CancellationError() }   // reopened after the change (`keyEpoch`)
        let gen = generation
        let epoch = keyEpoch
        await closingEditor?.value
        try ensureCurrent(gen)
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        guard notes.contains(where: { $0.id == noteID }) else { throw ModelError.noteNotFound }
        try await downloadNote(noteID)
        let clock = try deviceClockForWriting()
        let opened = try await Editor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                           recognizer: recognizer, recognitionDelay: recognitionDelay,
                                           verify: partialNoteVerifier(noteID),
                                           describeError: services.describeError, perf: services.perf)
        try ensureCurrent(gen)
        if let open = windowEditors[noteID] {   // a concurrent call won
            Task { await opened.close() }
            return open
        }
        // The window closed meanwhile (no claim: the library may open the note
        // itself), or the keys changed under the vault copy it was opened with.
        guard windowClaims.contains(noteID), !Task.isCancelled, !isChangingKeys, epoch == keyEpoch else {
            Task { await opened.close() }
            throw CancellationError()
        }
        opened.prepareBlobWrite = blobWritePreparer(note: noteID)
        configureRecordings(opened)
        holdRecognitionWhileSuspended(opened)
        opened.onRecognized = { [weak self] id in
            guard let self else { return }
            Task { try? await self.refresh([id]) }   // search sees the new text
        }
        windowEditors[noteID] = opened
        return opened
    }

    /// Reloads a note window's editor after the note was deleted or restored
    /// (it opens read-only or editable); pending ink is saved first.
    func reopenWindowNote(_ noteID: UUID) async {
        guard let old = windowEditors.removeValue(forKey: noteID) else { return }
        await old.close()
        _ = try? await openWindowNote(noteID)
    }

    /// Saves and closes every note window's editor (the vault is about to
    /// change under them, `AppModel+Keys`).
    func closeWindowEditors() async {
        let all = Array(windowEditors.values)
        windowEditors = [:]
        for editor in all { await editor.close() }
    }

    /// Whether a note window should open a library window now: none is on
    /// screen and none was asked for in the last few seconds (several note
    /// windows restored at launch each ask, before the first one appears).
    public func shouldOpenLibraryWindow(now: Date = Date()) -> Bool {
        guard libraryWindowCount == 0 else { return false }
        if let last = libraryWindowRequested, now.timeIntervalSince(last) < 5 { return false }
        libraryWindowRequested = now
        return true
    }

    // MARK: - State restoration

    /// The keyed digest a saved selection names a notebook or tag by
    /// (`RestorableSelection`): `LocalCacheKey` purpose `selection` of the open
    /// vault's secret, so the window state the system keeps in plaintext names
    /// none. Nil while the vault is locked.
    func selectionDigest() -> ((String) -> String)? {
        guard phase == .unlocked, let vault,
              let key = try? LocalCacheKey(vault: vault, purpose: "selection", magic: [0x53, 0x4D, 0x50, 0x53, 0x01])
        else { return nil }
        return { key.entryName($0) }
    }

    /// The library window's selection to save, or nil while no vault is unlocked.
    public func restorableSelection() -> RestorableSelection? {
        guard let id = vault?.vaultId, let digest = selectionDigest() else { return nil }
        return RestorableSelection(sidebar: sidebarSelection, note: selectedNoteID, vault: id, digest: digest)
    }

    /// Applies a selection saved with the library window (`RestorableSelection`):
    /// its notebook or tag if the vault still has it (else All Notes), and its
    /// note if the vault still has it. Ignored for another vault.
    @discardableResult
    public func restore(_ saved: RestorableSelection) -> Bool {
        guard phase == .unlocked, saved.vault == vault?.vaultId else { return false }
        var item: SidebarItem
        switch saved.sidebarRef {
        case .item(let plain):
            item = plain
        case .notebook(let wanted):
            let digest = selectionDigest()
            item = notebooks.first { digest?(RestorableSelection.digestLabel(notebook: $0)) == wanted }
                .map { .notebook($0) } ?? .allNotes
        case .tag(let wanted):
            let digest = selectionDigest()
            item = tags.first { digest?(RestorableSelection.digestLabel(tag: $0)) == wanted }.map { .tag($0) } ?? .allNotes
        }
        switch item {
        case .notebook(let path):
            let wanted = NotebookPath.canonical(path)
            if !notebooks.contains(where: { NotebookPath.canonical($0) == wanted }) { item = .allNotes }
        case .tag(let tag):
            if !tags.contains(where: { NoteOps.tagKey($0) == NoteOps.tagKey(tag) }) { item = .allNotes }
        case .recentlyRecognized:
            if recentlyRecognizedNotes.isEmpty { item = .allNotes }
        case .allNotes, .deleted, .favorites:
            break
        }
        sidebarSelection = item
        if let id = saved.note, notes.contains(where: { $0.id == id }) { selectedNoteID = id }
        return true
    }

    // MARK: - Last place

    /// Remembers where the user is (sidebar item and note) on this device, per vault (`LastPlace`), so the next
    /// launch, which the system's scene state does not survive, opens there. Nothing for a locked vault, and nothing
    /// while the phone shows its notebook list (no sidebar item): the place before it stays.
    public func saveLastPlace() {
        guard sidebarSelection != nil, let id = vault?.vaultId, let place = restorableSelection() else { return }
        LastPlace.save(place, vault: id, in: deviceMemory)
    }

    /// Applies what the window state holds for this vault (`scene`, `RestorableSelection.stored`) when it names this
    /// vault, else the device's last place. Does nothing for a locked vault, so a note never opens before the unlock.
    /// A note or notebook that is gone falls back to the notebook alone, then All Notes (`restore`).
    @discardableResult
    public func restoreOnLaunch(scene stored: String) -> Bool {
        guard phase == .unlocked, let id = vault?.vaultId else { return false }
        if let saved = RestorableSelection(stored: stored), saved.vault == id { return restore(saved) }
        guard let place = LastPlace.load(vault: id, from: deviceMemory) else { return false }
        return restore(place)
    }
}
