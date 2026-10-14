import Foundation
import Sempere

/// Revisions written elsewhere (another device through iCloud Drive, the CLI,
/// or this device's browser edits) reach a note that is open in an editor
/// without reopening it (`NoteEditor.mergeRevisions`).
///
/// Detection is the change-driven listing (`reconcile`): a pass lists each
/// note folder by name, and an open editor whose folder holds a revision name
/// it has neither read nor written (`NoteEditor.hasUnmergedRevisions`) gets a
/// merge. The file presenter wakes the iCloud sync loop for that note, so a
/// revision another device writes is merged within a poll interval of iCloud
/// delivering it. Before the merge every revision of the note is made local
/// (`downloadNote`): an editor never writes while any revision is missing.
extension AppModel {
    /// The editors showing a note now: the library window's and note windows'.
    var openEditors: [NoteEditor] {
        ([editor] + Array(windowEditors.values)).compactMap { $0 }
    }

    /// Starts a merge for every open editor whose note folder, as just listed
    /// (`listedNames`: note id → revision file names), holds revisions it
    /// does not have.
    func mergeIntoOpenEditors(listedNames: [UUID: [String]]) {
        for open in openEditors {
            guard let names = listedNames[open.noteID], open.hasUnmergedRevisions(names) else { continue }
            if let unreadable = unreadableMergeNames[open.noteID], unreadable == names.sorted() { continue }
            scheduleRemoteMerge(open)
        }
    }

    /// Merges revisions written elsewhere into `open` in the background; at
    /// most one merge per note runs (a revision arriving meanwhile is picked
    /// up by the next pass, whose listing still shows it unknown).
    func scheduleRemoteMerge(_ open: NoteEditor) {
        let id = open.noteID
        guard remoteMerges[id] == nil else { return }
        let gen = generation
        let task = Task { [weak self, weak open] in
            guard let self, let open else { return }
            defer { if self.generation == gen { self.remoteMerges[id] = nil } }
            do {
                _ = try await self.mergeRemoteRevisions(into: open)
            } catch is CancellationError {
            } catch {
                #if DEBUG
                NSLog("SempereProbe remote merge %@ failed: %@", Perf.short(id), "\(error)")
                #endif
            }
        }
        remoteMerges[id] = task
    }

    /// Whether `open` is still the editor of its note.
    func isOpenEditor(_ open: NoteEditor) -> Bool {
        editor === open || windowEditors[open.noteID] === open
    }

    /// Downloads note `open.noteID` and merges what is new into `open`; a
    /// read-only editor (nothing unsaved) is reopened instead. The note's
    /// summary is re-read when anything changed.
    @discardableResult
    func mergeRemoteRevisions(into open: NoteEditor) async throws -> NoteEditor.RemoteMergeOutcome {
        let id = open.noteID
        let gen = generation
        let interval = Perf.begin(.remoteMerge)
        var result = "skipped"
        defer { Perf.end(interval, "\(Perf.short(id)) \(result)") }
        await open.loaded()
        try await downloadNote(id)
        try ensureCurrent(gen)
        guard let vault, phase == .unlocked, isOpenEditor(open), !open.isShutDown else { return .skipped }
        guard open.mergesInPlace else {
            result = "reopened"
            try await reopenEditor(ifShowing: id)
            return .skipped
        }
        let clock = try deviceClockForWriting()
        var verify: (@Sendable () throws -> Void)?
        if isCloudVault, let url = vaultURL {
            let hooks = cloudHooks
            verify = { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) }
        }
        let outcome = try await open.mergeRevisions(vault: vault, clock: clock, coordinated: isCloudVault, verify: verify)
        try ensureCurrent(gen)
        switch outcome {
        case .merged(let other):
            result = other ? "merged from another device" : "merged"
            unreadableMergeNames[id] = nil
            try await refresh([id])   // the list's row follows
        case .unchanged:
            result = "unchanged"
            unreadableMergeNames[id] = nil
        case .unreadable:
            result = "unreadable"
            let url = vault.url
            unreadableMergeNames[id] = try? await offMain {
                try VaultEnumeration.listNotes(vault: url, only: [id]).first?.names.sorted()
            }
        case .skipped:
            break
        }
        return outcome
    }

    /// Stops merges in flight (the vault closes).
    func cancelRemoteMerges() {
        for task in remoteMerges.values { task.cancel() }
        remoteMerges = [:]
        unreadableMergeNames = [:]
    }
}
