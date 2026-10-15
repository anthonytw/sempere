import Foundation
import os
import Sempere

private let notebookLog = Logger(subsystem: "io.github.anthonytw.sempere", category: "notebooks")

/// Empty notebooks (format.md §14): the notebook records of the open vault, read into
/// `declaredNotebooks` and written by New Notebook, Delete Notebook and the notebook
/// renames and moves. The rules and the files are the package's (`NotebookRecords`,
/// `Vault.createNotebook`, the CLI's `notebooks create|delete`); this only runs them
/// off the main actor, coordinated in iCloud Drive, under the edit gate.
extension AppModel {
    /// Reads the notebook records and publishes `declaredNotebooks`. In iCloud Drive the
    /// record files are downloaded first. Nothing is read when the folder lists the names
    /// read last (unless `force`). Failures are logged, never shown: the notebooks notes
    /// name are still listed.
    func refreshNotebookRecords(force: Bool = false) async {
        guard phase == .unlocked, let vault, vault.canRead else { return }
        let gen = generation
        let cloud = isCloudVault
        let hooks = cloudHooks
        let coordinate = coordinationURL
        let url = vault.url
        do {
            if cloud {
                let items = try await offMain { try CloudScan.notebookItems(inVault: url) }
                try await CloudVault.download(items: items, hooks: hooks, stallTimeout: .seconds(30)) { _ in }
            }
            let names = try await offMain { try CloudVault.coordinatedRead(coordinate) { try vault.notebookRecordNames() } }
            try ensureCurrent(gen)
            if !force, names == notebookRecordNamesRead { return }
            let set = try await offMain { try CloudVault.coordinatedRead(coordinate) { try vault.readNotebookRecords() } }
            try ensureCurrent(gen)
            notebookRecordNamesRead = names
            declaredNotebooks = set.declared
            if !set.problems.isEmpty {
                notebookLog.warning("\(set.problems.count, privacy: .public) notebook records skipped")
            }
        } catch is CancellationError {
        } catch {
            notebookLog.error("notebook records not read: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// File ▸ New Notebook…: declares the notebook `path` (`/` for levels) so it is
    /// listed while it is empty, and selects it. Returns its canonical path; nil for a
    /// name that names no notebook. A notebook that exists already is only selected.
    @discardableResult
    func createNotebook(_ path: String) async throws -> String? {
        guard let canonical = NotebookPath.canonical(path) else { return nil }
        guard canonical.unicodeScalars.count <= NotebookRecords.maxPathScalars else { throw ModelError.notebookNameTooLong }
        if !declaredNotebooks.contains(canonical) {
            try await writeNotebookRecords { vault in _ = try vault.createNotebook(canonical) }
        }
        sidebarSelection = .notebook(canonical)
        return canonical
    }

    /// The notebook the sidebar shows, nil for anything else (All Notes, a tag…).
    var selectedNotebook: String? {
        if case .notebook(let path)? = sidebarSelection { return path }
        return nil
    }

    /// Whether the sidebar offers Delete Notebook for `path`: it is declared (or holds
    /// a declared notebook) and no live note is in it or below it.
    func canDeleteNotebook(_ path: String) -> Bool {
        guard let p = NotebookPath.canonical(path) else { return false }
        return declaredNotebooks.contains { NotebookPath.name($0, isWithin: p) }
            && !notes.contains { !$0.deleted && NotebookPath.name($0.notebook, isWithin: p) }
    }

    /// Deletes the empty notebook `path` and the empty notebooks inside it (one record).
    /// Notes are never touched: refused (`notebookNotEmpty`) while a live note is in it.
    func deleteNotebook(_ path: String) async throws {
        guard let p = NotebookPath.canonical(path) else { return }
        guard !notes.contains(where: { !$0.deleted && NotebookPath.name($0.notebook, isWithin: p) }) else {
            throw ModelError.notebookNotEmpty
        }
        try await writeNotebookRecords { vault in _ = try vault.deleteNotebookRecords(p) }
        if case .notebook(let selected)? = sidebarSelection, NotebookPath.name(selected, isWithin: p) {
            sidebarSelection = .allNotes
        }
    }

    /// Writes notebook records with `write` under the edit gate (no note edit runs
    /// meanwhile), coordinated in iCloud Drive, then re-reads them.
    func writeNotebookRecords(_ write: @escaping @Sendable (Vault) throws -> Void) async throws {
        await editGate.acquire()
        defer { editGate.release() }
        guard let vault else { throw ModelError.noVaultOpen }
        guard vault.canRead else { throw vault.isLocked ? VaultError.locked : VaultError.noIdentities }
        try requireWritableVault()   // format.md §7.3
        let gen = generation
        let coordinate = coordinationURL
        try await offMain { try CloudVault.coordinatedWrite(coordinate) { try write(vault) } }
        try ensureCurrent(gen)
        await refreshNotebookRecords(force: true)
    }
}
