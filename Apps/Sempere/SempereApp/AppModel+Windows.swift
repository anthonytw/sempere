import Foundation
import Sempere
import SempereRender

/// Note windows (Mac): one note per window, each with its own `NoteEditor`.
///
/// The vault, the device clock and the edit gate stay the model's, shared by
/// every window, so a delta from any window ticks the one clock. A note has
/// at most one editor at a time: while a window shows a note (`claimNote`),
/// the library window's detail pane does not open an editor for it (two
/// editors on one note would each keep their own stroke ledger and write
/// diverging deltas); it shows a placeholder instead.
extension AppModel {

    /// The window to open for note `id` (File > Open Note in New Window, the
    /// list's context menu, a double-click on a row): nil without an unlocked
    /// vault, for a note not (yet) listed, still downloading or in Recently Deleted.
    func noteWindowValue(for id: UUID?) -> NoteWindowValue? {
        guard let id, phase == .unlocked, let vault = vault?.vaultId, !placeholderNoteIDs.contains(id),
              let note = notes.first(where: { $0.id == id }), !note.deleted else { return nil }
        return NoteWindowValue(vaultID: vault, noteID: id)
    }

    /// Takes `noteID` for a note window: an editor the library window has open
    /// on it is saved and closed first.
    func claimNote(_ noteID: UUID) async {
        windowClaims.insert(noteID)
        if editor?.noteID == noteID {
            try? await openEditor(for: nil)
        }
    }

    /// Gives `noteID` back (its window closed): saves and closes the window's
    /// editor; the library window opens it again if it is selected. The claim
    /// ends only once the last save is written, so the library never reads
    /// the note before it (and stays if a window took the note again meanwhile).
    func releaseNote(_ noteID: UUID) async {
        let editor = windowEditors.removeValue(forKey: noteID)
        await editor?.close()
        if windowEditors[noteID] == nil { windowClaims.remove(noteID) }
    }

    /// Opens the editor of a note window. Needs an unlocked vault. A second
    /// call for the same note returns the editor already open.
    func openWindowNote(_ noteID: UUID) async throws -> NoteEditor {
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
        var verify: (@Sendable () throws -> Void)?
        if isCloudVault, let url = vaultURL {
            let hooks = cloudHooks
            verify = { try CloudVault.requireLocal(note: noteID, vault: url, hooks: hooks) }
        }
        let opened = try await NoteEditor.open(vault: vault, noteID: noteID, clock: clock, debounce: editorDebounce,
                                               recognizer: recognizer, recognitionDelay: recognitionDelay,
                                               coordinated: isCloudVault, verify: verify)
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
    func shouldOpenLibraryWindow(now: Date = Date()) -> Bool {
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
    func restorableSelection() -> RestorableSelection? {
        guard let id = vault?.vaultId, let digest = selectionDigest() else { return nil }
        return RestorableSelection(sidebar: sidebarSelection, note: selectedNoteID, vault: id, digest: digest)
    }

    /// Applies a selection saved with the library window (`RestorableSelection`):
    /// its notebook or tag if the vault still has it (else All Notes), and its
    /// note if the vault still has it. Ignored for another vault.
    @discardableResult
    func restore(_ saved: RestorableSelection) -> Bool {
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

    // MARK: - PDF export

    enum ExportError: Error, Equatable, CustomStringConvertible {
        case unreadableRevisions(Int)

        var description: String {
            switch self {
            case .unreadableRevisions(let n):
                return String(localized: "\(n) revisions of this note could not be read, so it cannot be exported completely.")
            }
        }
    }

    /// Renders a note to a PDF in a fresh folder under the temporary
    /// directory and returns its URL (named after the title, `ExportFileName`).
    /// Pending ink of the note, wherever it is open, is saved first so the PDF
    /// shows what is on screen. The file is plaintext: it is for the Finder
    /// drop that asked for it, and `NotePDFExport.purge` removes it later.
    func exportPDF(noteID: UUID) async throws -> URL {
        let prepared = try await prepareExport(noteID: noteID)
        let url = try await offMain { try prepared.write() }
        try ensureCurrent(prepared.generation)
        return url
    }

    /// The main-actor part of `exportPDF`: saves the note's pending ink and
    /// makes it local (iCloud Drive). What it returns renders and writes the
    /// PDF on any thread, without the main actor, so a drop that asks for the
    /// file while the main thread waits (a Mac file promise) still gets it.
    func prepareExport(noteID: UUID) async throws -> PreparedExport {
        guard let vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        let gen = generation
        if editor?.noteID == noteID { await editor?.flush() }
        await windowEditors[noteID]?.flush()
        try ensureCurrent(gen)
        try await downloadNote(noteID)
        try ensureCurrent(gen)
        return PreparedExport(vault: vault, noteID: noteID, coordinate: coordinationURL, folder: exportFolder,
                              epoch: exportEpoch, generation: gen, startEpoch: exportEpoch.value)
    }
}

/// A vault generation readable from any thread: `AppModel.close` bumps it, and
/// an export prepared before then writes nothing (`PreparedExport.write`).
final class ExportEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    var value: Int { lock.withLock { current } }

    func bump() { lock.withLock { current += 1 } }
}

/// A note ready to be rendered to a PDF (`AppModel.prepareExport`).
struct PreparedExport: Sendable {
    let vault: Vault
    let noteID: UUID
    /// The vault folder to read under coordination (iCloud Drive), nil otherwise.
    let coordinate: URL?
    let folder: URL
    let epoch: ExportEpoch
    /// The model's generation when prepared (`ensureCurrent`).
    let generation: Int
    let startEpoch: Int

    /// Renders the note and writes `<folder>/<uuid>/<title>.pdf`. Blocking:
    /// call it off the main actor. Throws `CancellationError` once the vault
    /// that prepared it has closed.
    func write() throws -> URL {
        guard epoch.value == startEpoch else { throw CancellationError() }
        let rendered = try CloudVault.coordinatedRead(coordinate) { try NotePDFExport.render(vault: vault, noteID: noteID) }
        guard epoch.value == startEpoch else { throw CancellationError() }
        NotePDFExport.purge(olderThan: 3600)   // folders of earlier runs that never closed a vault
        let url = try NotePDFExport.write(rendered, in: folder)
        guard epoch.value == startEpoch else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw CancellationError()
        }
        return url
    }
}

/// Rendering a note to a PDF file outside the vault (Mac drag and drop).
enum NotePDFExport {
    struct Rendered: Sendable {
        var title: String
        var pdf: Data
    }

    /// The note's PDF. A note with unreadable revisions is refused rather
    /// than exported with pages missing.
    static func render(vault: Vault, noteID: UUID) throws -> Rendered {
        let loaded = try vault.loadNote(noteID)
        guard loaded.failures.isEmpty else { throw AppModel.ExportError.unreadableRevisions(loaded.failures.count) }
        let state = try NoteReducer.reconstruct(loaded.revisions)
        // PDF page backgrounds are copied from the note's attachments (docs/attachments.md §10);
        // text boxes are laid out as the canvas shows them.
        let options = RenderOptions(blobs: vault.blobSource(note: noteID), pdfRasterizer: PDFKitRasterizer(),
                                    shaper: CoreTextShaper())
        return Rendered(title: state.meta.title, pdf: try PDFWriter.render(note: state, options: options))
    }

    /// Folder under the temporary directory holding exported files, one
    /// sub-folder per export so equal titles never collide.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SempereExport", isDirectory: true)
    }

    /// Writes `rendered` to `<folder>/<uuid>/<title>.pdf`, old exports removed first.
    static func write(_ rendered: Rendered, in folder: URL = NotePDFExport.folder) throws -> URL {
        purge(in: folder)
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ExportFileName.pdf(title: rendered.title))
        try rendered.pdf.write(to: url, options: .atomic)
        return url
    }

    /// Removes exports older than `age` seconds (all of them with 0).
    static func purge(in folder: URL = NotePDFExport.folder, olderThan age: TimeInterval = 600, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if age <= 0 || modified.map({ now.timeIntervalSince($0) > age }) ?? true {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
