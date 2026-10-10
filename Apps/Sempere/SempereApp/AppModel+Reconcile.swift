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
/// decrypted for those notes. Only changed notes are checked with iCloud,
/// downloaded and read, and their summaries reach the list in throttled
/// batches (`queueListUpdate`).
extension AppModel {
    /// One pass over the note folders: every folder, or only `scope`.
    ///
    /// - Parameters:
    ///   - scope: the notes to look at (a change notification names them);
    ///     nil lists every note folder.
    ///   - full: also re-read notes whose summary is not backed by the index
    ///     file (a summary with a problem, or no index at all): a reload
    ///     ("pull to refresh") gives such notes another chance.
    /// - Returns: how many notes are still downloading.
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
        let cloud = isCloudVault
        let hooks = cloudHooks
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
        let reported = reportedNoteIDs
        reportedNoteIDs = []

        // 1. Names only.
        let listings = try await offMain(priority: .utility) {
            try Perf.measure(.reconcileEnumerate, "") { try VaultEnumeration.listNotes(vault: url, only: scope) }
        }
        try ensureCurrent(gen)
        try Task.checkCancellation()
        let diff = IndexDiff.compute(listings: listings, indexed: indexed, known: known, scope: scope)
        let present = Set(listings.map(\.id))
        let names = Dictionary(listings.map { ($0.id, $0.names) }, uniquingKeysWith: { a, _ in a })
        #if DEBUG
        NSLog("SempereProbe reconcile listed=%d unchanged=%d changed=%d removed=%d", listings.count,
              diff.unchanged.count, diff.changed.count, diff.removed.count)
        #endif

        // 2. iCloud state, only for notes that must be read (or are still arriving).
        var ready: [UUID]
        var pending: [UUID] = []
        if cloud {
            var focus: Set<UUID> = []
            if canRead || !hasLocalIndex {
                // Asking iCloud for a file's state costs a round trip on a device. A note seen
                // for the first time (or reported changed) is checked now; notes already known
                // to be arriving are re-checked `cloudCheckLimit` at a time, in rotation, so a
                // pass over N arriving notes costs O(limit), not O(N), and N notes arriving
                // over many passes cost O(N + passes × limit) in all, not O(N × passes).
                let arriving = pendingNoteIDs.intersection(present)
                let fresh = Set(diff.changed).subtracting(arriving).union(reported.intersection(present))
                let rotation = nextPendingChecks(arriving.subtracting(fresh), limit: cloudCheckLimit)
                focus = fresh.union(rotation)
                if let selected = selectedNoteID, arriving.contains(selected) { focus.insert(selected) }
                pendingElsewhere.formUnion(arriving.subtracting(focus))
            }   // else locked, with an index: nothing to fetch before the key shows what changed
            let toCheck = focus
            let priority = selectedNoteID
            let window = cloudWindow
            let pass = toCheck.isEmpty ? ProgressiveLoad.Pass() : try await offMain(priority: .utility) {
                try Perf.measure(.reconcileDownload, "notes=\(toCheck.count)") {
                    try ProgressiveLoad.pass(vault: url, notes: toCheck, priority: priority, window: window, hooks: hooks)
                }
            }
            try ensureCurrent(gen)
            // A replaced (or paused) sync loop's pass is stale: never publish it over a newer one.
            try Task.checkCancellation()
            ready = pass.ready
            pending = pass.pending
            let total = scope == nil ? listings.count : max(cloudSync?.notes ?? 0, notes.count)
            let arriving = pendingElsewhere.union(pending).count
            var status = CloudSyncStatus(notes: total, readyNotes: max(0, total - arriving), files: pass.files,
                                         localFiles: pass.localFiles, unlistedNotes: pass.unlisted.count)
            status.problem = cloudSync?.problem
            if let failure = pass.failures.first?.value { status.problem = "iCloud Drive: \(failure)" }
            cloudSync = status
        } else {
            ready = diff.changed
        }
        // Locked, or migrate-only (a legacy vault's notes are never read):
        // the downloads are requested and the progress shown, nothing is read.
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
            if let c = summaryCache?.storedSummary(of: id) { added.append(c) } else {
                added.append(Self.placeholderSummary(id))
                placeholders.insert(id)
            }
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
        return pendingNoteIDs.count
    }

    /// Up to `limit` of `arriving`, continuing in id order from where the
    /// previous pass stopped (`pendingCheckCursor`), so every arriving note is
    /// checked once every `arriving.count / limit` passes.
    func nextPendingChecks(_ arriving: Set<UUID>, limit: Int) -> Set<UUID> {
        guard arriving.count > limit else { return arriving }
        let order = arriving.sorted { $0.uuidString < $1.uuidString }
        let start = order.firstIndex { $0.uuidString > pendingCheckCursor } ?? 0
        var out: [UUID] = []
        out.reserveCapacity(limit)
        var i = start
        while out.count < max(1, limit) {
            out.append(order[i])
            i = (i + 1) % order.count
        }
        pendingCheckCursor = out.last?.uuidString ?? ""
        return Set(out)
    }

    /// The row of a note iCloud has not delivered and nothing is known about.
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

    // MARK: - Background validation

    /// One background validation in this many asks iCloud about every
    /// file; the others skip notes an earlier one saw entirely local.
    static let fullValidationEvery = 6

    /// The low-priority full pass: asks iCloud for the state of every file
    /// of every note (slow on a device, one round trip per file; except, in
    /// all but every `fullValidationEvery`-th pass, the notes the last pass
    /// saw entirely local whose listing did not change), refreshes
    /// local copies iCloud reports out of date, reports download errors in
    /// the status bar, and drops index entries of notes that are gone.
    /// Evicted notes are not downloaded: their rows come from the index, and
    /// opening one downloads it (`downloadNote`). Never blocks the list: it
    /// runs at background priority, outside `loadGate`, and publishes only
    /// the status and what a following `reconcile` reads.
    func validateVault() async throws {
        guard let vault, isCloudVault, phase == .unlocked else { return }
        let gen = generation
        let url = vault.url
        let hooks = cloudHooks
        // Every `fullValidationEvery`-th pass (and the first) asks about every
        // file, so an eviction that keeps a note's listing the same is seen too.
        let full = validationsSinceFull == 0 || validationsSinceFull >= Self.fullValidationEvery
        let settled = full ? [:] : settledCloudNotes
        let pass = try await offMain(priority: .background) {
            try Perf.measure(.reconcileValidate, "") {
                try ProgressiveLoad.pass(vault: url, requestMissing: false, settled: settled, hooks: hooks)
            }
        }
        try ensureCurrent(gen)
        try Task.checkCancellation()
        settledCloudNotes = pass.settled
        validationsSinceFull = full ? 1 : validationsSinceFull + 1
        if var status = cloudSync {
            status.files = pass.files
            status.localFiles = pass.localFiles
            if let failure = pass.failures.first?.value { status.problem = "iCloud Drive: \(failure)" }
            cloudSync = status
        }
        // Folders the index does not list as they are on disk are read by the next pass.
        let present = Set(pass.all)
        summaryCache?.retain(only: present.union(notes.map(\.id)))
        saveSummaryCache()
        lastValidation = .now
    }
}
