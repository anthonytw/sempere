import Foundation
import Sempere

/// Keeping the note list in step with the vault folder, change-driven
/// (docs/io.md "Opening a vault fast").
///
/// The list opens from the local index (the encrypted `SummaryCache`): those
/// summaries are what the list shows, at once, with nothing read. A pass then
/// lists the note folders BY NAME only (`VaultEnumeration`) and compares each
/// note's revision file names with the names its shown summary was made from
/// (`indexedNames`, `IndexDiff`). Revision files are write-once, so equal
/// names mean an equal summary: nothing is downloaded, coordinated or
/// decrypted for those notes. Only changed notes are read, and their
/// summaries reach the list in throttled batches (`queueListUpdate`). In a
/// partial copy (a join, `AppModel+Join`) notes marked incomplete are pending.
extension AppModel {
    /// One pass over the note folders: every folder, or only `scope`.
    ///
    /// - Parameters:
    ///   - scope: the notes to look at (a change notification names them);
    ///     nil lists every note folder.
    ///   - full: also re-read notes whose summary is not backed by the index
    ///     file (a summary with a problem, or no index at all): a reload
    ///     ("pull to refresh") gives such notes another chance.
    /// - Returns: how many notes are still pending (a partial copy).
    @discardableResult
    func reconcile(scope: Set<UUID>? = nil, full: Bool = false) async throws -> Int {
        guard let vault else { throw ModelError.noVaultOpen }
        let gen = generation
        await loadGate.acquire()
        defer { loadGate.release() }
        try ensureCurrent(gen)
        try Task.checkCancellation()
        let interval = Perf.begin(.reconcile)
        var readCount = 0
        defer { Perf.end(interval, "scope=\(scope.map { "\($0.count)" } ?? "all") read=\(readCount)") }

        let url = vault.url
        let partialRoot = partialCopyRoot
        let canRead = vault.canRead && phase == .unlocked
        // Changes are judged against the index: never before it is loaded.
        if canRead {
            try await openSummaryCache()
            try ensureCurrent(gen)
        }
        // Only notes listed before the scan can be gone: one created meanwhile
        // (`createNote`) is not in the scan but must stay, and stay selected.
        let before = Set(notes.map(\.id))
        var indexed = indexedNames
        if full {
            let backed = summaryCache?.storedRevisionNames ?? [:]
            indexed = indexed.filter { backed[$0.key] == $0.value }
        }
        let known = before.union(indexed.keys)
        // Notes still arriving that this pass does not look at stay pending.
        var pendingElsewhere = scope.map { pendingNoteIDs.subtracting($0) } ?? []

        // 1. Names only.
        let listings = try await offMain(priority: .utility) {
            try Perf.measure(.reconcileEnumerate, "") { try VaultEnumeration.listNotes(vault: url, only: scope) }
        }
        try ensureCurrent(gen)
        try Task.checkCancellation()
        var diff = IndexDiff.compute(listings: listings, indexed: indexed, known: known, scope: scope)
        let present = Set(listings.map(\.id))
        let names = Dictionary(listings.map { ($0.id, $0.names) }, uniquingKeysWith: { a, _ in a })
        #if DEBUG
        NSLog("SempereProbe reconcile listed=%d unchanged=%d changed=%d removed=%d", listings.count,
              diff.unchanged.count, diff.changed.count, diff.removed.count)
        #endif

        // 2. A partial copy's notes still arriving: pending, never read.
        var ready: [UUID]
        var pending: [UUID] = []
        if let partialRoot {
            // A partial copy (a join, `AppModel+Join`): a note marked incomplete is never read; it is
            // pending, listed from the server's summaries, until a run or an open completes it.
            let incomplete = try await offMain(priority: .utility) { Self.incompleteNoteIDs(partialRoot) }
            try ensureCurrent(gen)
            diff.unchanged.removeAll { incomplete.contains($0) }
            ready = diff.changed.filter { !incomplete.contains($0) }
            pending = (scope.map { incomplete.intersection($0) } ?? incomplete).sorted { $0.uuidString < $1.uuidString }
            pendingElsewhere.subtract(present.subtracting(incomplete))
            // The bar's fill line (`JoinProgress`): every note listed, how many are still to come.
            let total = scope == nil ? listings.count : max(joinProgress?.notes ?? 0, notes.count, incomplete.count)
            joinProgress = incomplete.isEmpty ? nil
                : JoinProgress(notes: total, pending: incomplete.count, server: joinLocation?.host ?? "")
        } else {
            ready = diff.changed
            joinProgress = nil
        }
        // Locked, or a key change unfinished (no note is read before it is): nothing is read.
        guard canRead else {
            pendingNoteIDs = pendingElsewhere.union(pending)
            return pendingNoteIDs.count
        }

        // Open notes another writer changed take the new revisions in place.
        mergeIntoOpenEditors(listedNames: names)

        // 3. What the list shows before anything is read.
        let gone = Set(diff.removed).subtracting(present)
        if !gone.isEmpty {
            queueListUpdate(removals: gone)
            for id in gone { indexedNames[id] = nil }
            forgetAttachmentIndex(gone)
        }
        verifiedNoteIDs.formUnion(diff.unchanged)
        let shown = before.subtracting(gone)
        var added: [NoteSummary] = []
        var placeholders = placeholderNoteIDs.intersection(present)
        for id in diff.unchanged where !shown.contains(id) {
            // Indexed but not shown yet: its summary is current.
            if let s = summaryCache?.summary(for: id, names: names[id] ?? []) { added.append(s) }
        }
        for id in pending where !shown.contains(id) {
            // Not downloaded yet: its row from published summaries (a WebDAV server's, or other devices').
            if let c = summaryCache?.storedSummary(of: id) ?? publishedRows[id] { added.append(c) } else {
                added.append(Self.placeholderSummary(id))
                placeholders.insert(id)
            }
        }
        // A placeholder listed before the published summaries were opened (a pass right after the
        // unlock) gets its row from them now.
        for id in Array(placeholders) {
            guard let row = publishedRows[id] else { continue }
            added.append(row)
            placeholders.remove(id)
        }
        if !added.isEmpty { queueListUpdate(upserts: added) }
        // A placeholder stays pending until its summary is in, so a note is
        // never "not pending" while still a placeholder.
        let stillPending = Set(pending).union(pendingElsewhere)
        placeholderNoteIDs = placeholders
        // A note that arrived stays "downloading" until its new summary is in (`onBatch`).
        pendingNoteIDs = stillPending.union(placeholders).union(pendingNoteIDs.intersection(ready))

        // 4. Read what changed and is local.
        readCount = ready.count
        try await readSummaries(ready, listedNames: names) { [weak self] batch in
            guard let self else { return }
            for s in batch where !stillPending.contains(s.id) {
                self.placeholderNoteIDs.remove(s.id)
                self.pendingNoteIDs.remove(s.id)
            }
        }
        try ensureCurrent(gen)
        try Task.checkCancellation()
        flushListUpdates()
        placeholderNoteIDs.subtract(ready)
        pendingNoteIDs = stillPending.union(placeholderNoteIDs)
        if scope == nil { summaryCache?.retain(only: present.union(notes.map(\.id))) }
        // The whole index is re-encrypted on every save: while notes keep arriving, at most
        // once per `summaryCacheSaveInterval`, and once they have all arrived.
        saveSummaryCacheIfDue(force: pendingNoteIDs.isEmpty)
        markIndexed()
        listLoaded = true
        loadFailure = nil
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = nil }
        // Empty notebooks (format.md §14): read again only when the record names changed.
        if canRead { await refreshNotebookRecords() }
        return pendingNoteIDs.count
    }

    /// The row of a pending note nothing is known about yet (no published summary).
    nonisolated static func placeholderSummary(_ id: UUID) -> NoteSummary {
        NoteSummary(id: id, title: "", tags: [], notebook: nil, deleted: false, pages: 0, strokes: 0, modified: nil,
                    problem: nil)
    }

    // MARK: - The index on this device

    /// True when this device kept an index of the open vault on an earlier
    /// launch (`markIndexed`), known before the vault is unlocked: a locked
    /// pass then fetches nothing, since the index will show the notes and
    /// say which changed. Without one (the vault is new on this device) the
    /// notes are downloaded while the key is typed.
    var hasLocalIndex: Bool {
        guard let marker = indexMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// `<summary cache dir>/indexed-<SHA-256 of the vault id>`: an empty file
    /// saying an index of this vault exists (the index's own name needs the
    /// vault secret). Nil without a cache directory (tests).
    var indexMarkerURL: URL? {
        guard let dir = summaryCacheDirectory, let vault else { return nil }
        return dir.appendingPathComponent("indexed-" + LocalCacheKey.digestHex(vault.vaultId.uuidString.lowercased()))
    }

    /// Records that the open vault has an index on this device.
    func markIndexed() {
        guard summaryCache != nil, let marker = indexMarkerURL, !FileManager.default.fileExists(atPath: marker.path) else { return }
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
}
