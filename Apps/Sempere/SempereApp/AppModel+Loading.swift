import Foundation
import Sempere

/// How far a listing of the open vault has got, for "Opening vault: 120 of 640".
/// When the status bar under the note list is worth showing for a sync (as opposed to flashing
/// for every edit): only for a bulk transfer of at least `minimumNotes` notes. Once a bulk
/// transfer is showing it stays until it finishes, so it does not blink off at the last few notes.
enum SyncBarPolicy {
    static let minimumNotes = 5

    static func isBulk(_ notes: Int) -> Bool { notes >= minimumNotes }

    /// Whether to show the bar for `pending` notes still to arrive; `wasShown`: it was showing on the previous pass.
    static func shows(pending: Int, wasShown: Bool) -> Bool {
        pending > 0 && (isBulk(pending) || wasShown)
    }
}

struct NoteLoading: Equatable, Sendable {
    /// Notes whose summary is in (from the cache or read).
    var done = 0
    /// Notes to summarize in this pass.
    var total = 0
    /// True when the list already shows every note (from the cache or a
    /// previous listing) and this pass only picks up changes.
    var refreshing = false

    var fractionCompleted: Double { total == 0 ? 1 : min(1, Double(done) / Double(total)) }

    /// Whether the status bar shows this pass. Opening a vault always does; a refresh of notes
    /// already listed (every edit, and every change another device syncs, causes one) only when it
    /// is a real bulk update (`SyncBarPolicy`), so a one-note edit does not flash a bar.
    var showsBar: Bool { !refreshing || SyncBarPolicy.isBulk(total) }

    /// "Opening vault: 120 of 640 notes", or "Updating 640 changed notes: 120 done"
    /// over a list already shown.
    var headline: String {
        if refreshing {
            let changed = String(localized: "\(total) changed notes", comment: "A number of notes that changed")
            return String(localized: "Updating \(changed): \(done) done",
                          comment: "Progress; %@ is a number of changed notes, the number is how many are done")
        }
        let notes = String(localized: "\(total) notes", comment: "A number of notes")
        return String(localized: "Opening vault: \(done) of \(notes)",
                      comment: "Progress; %@ is a number of notes, e.g. “120 of 640 notes”")
    }
}

/// Why the note list is empty; shown instead of a blank list
/// (`AppModel.emptyListReason`).
enum EmptyListReason: Equatable, Sendable {
    /// Notes are being read; nothing to show yet.
    case loading(NoteLoading?)
    /// Notes are still downloading from iCloud Drive.
    case downloading(CloudSyncStatus)
    /// The listing failed or iCloud stalled; the text says why.
    case failed(String)
    /// The search matches nothing among the notes shown.
    case noMatches(String)
    /// The sidebar selection (a notebook, a tag, Recently Deleted) has no notes.
    case emptySelection
    /// The vault holds no notes.
    case emptyVault
}

/// A summary and the sorted revision file names it was made from.
struct NamedSummary: Sendable {
    var summary: NoteSummary
    var revisions: [String]
}

extension AppModel {
    /// Summary caches of every vault this install opened: one encrypted file
    /// per vault secret in Application Support (`format.md` §10). Not backed up.
    /// Where the app keeps its trust records of vault recipients lists
    /// (format.md §2.1), next to the device clock.
    nonisolated static var defaultTrustDirectory: URL {
        DeviceClock.defaultURL.deletingLastPathComponent().appendingPathComponent("Trust", isDirectory: true)
    }

    /// This install's trust records (format.md §2.1), in `defaultTrustDirectory`,
    /// excluded from backups: they hold only public keys, but they name the
    /// vault and its devices, and a backup may be readable by the same provider
    /// that stores the vault.
    nonisolated static var defaultRecipientsTrust: any RecipientsTrustStore {
        prepareCacheDirectory(defaultTrustDirectory)
        return FileRecipientsTrustStore(directory: defaultTrustDirectory)
    }

    nonisolated static var defaultSummaryCacheDirectory: URL? {
        DeviceClock.defaultURL.deletingLastPathComponent().appendingPathComponent("SummaryCache")
    }

    /// False in debug runs launched with `SEMPERE_DEBUG_DRAWING_CACHE=0`, to
    /// time note opens without the drawing cache.
    nonisolated static var drawingCacheEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SEMPERE_DEBUG_DRAWING_CACHE"] != "0"
        #else
        return true
        #endif
    }

    /// Why the note list shows nothing, or nil when it shows something.
    var emptyListReason: EmptyListReason? {
        guard phase == .unlocked, visibleNotes.isEmpty else { return nil }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveNotes = notes.contains { !$0.deleted }
        if loading != nil || (!listLoaded && loadFailure == nil) {
            // A search over a list still filling in may match later.
            if !query.isEmpty && liveNotes { return .noMatches(query) }
            return .loading(loading)
        }
        if let sync = cloudSync, sync.isDownloading, !(liveNotes && !query.isEmpty) { return .downloading(sync) }
        if let failure = loadFailure { return .failed(failure) }
        if let problem = cloudSync?.problem, notes.isEmpty { return .failed(problem) }
        if !query.isEmpty { return .noMatches(query) }
        if notes.isEmpty { return .emptyVault }
        return .emptySelection
    }

    /// Lists the notes in a task the model owns. The previous listing, if
    /// any, finishes first (`loadGate`).
    ///
    /// - Parameter reportErrors: put a failure in `errorMessage` (nobody
    ///   awaits the task) rather than only rethrowing it from `notesLoaded`.
    func startLoadingNotes(reportErrors: Bool) {
        let gen = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.reload()
                if self.generation == gen { self.thinIfDue() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if reportErrors, self.generation == gen { self.errorMessage = "\(error)" }
                throw error
            }
        }
    }

    /// Waits for the listing `unlock` started.
    func notesLoaded() async throws {
        try await loadTask?.value
    }

    /// Opens the open vault's `SummaryCache` (decrypting its file) once: the
    /// local index. Its summaries are shown at once, as they are (the list's
    /// source of truth on open), and the revision names they were made from
    /// become `indexedNames`, so a pass reads only notes whose names changed.
    ///
    /// Callers share one load: a sync pass that starts while `reload` is
    /// decrypting the index waits for it rather than treating every note as
    /// changed.
    func openSummaryCache() async throws {
        if let opening = summaryCacheOpening {
            try await opening.value
            return
        }
        guard summaryCache == nil, summaryCacheDirectory != nil, let vault, vault.canRead else { return }
        let task = Task { try await self.loadSummaryCache() }
        summaryCacheOpening = task
        defer { if summaryCacheOpening == task { summaryCacheOpening = nil } }
        try await task.value
    }

    private func loadSummaryCache() async throws {
        guard summaryCache == nil, let dir = summaryCacheDirectory, let vault, vault.canRead else { return }
        let gen = generation
        let cache = try? await offMain { () throws -> SummaryCache in
            try Perf.measure(.indexLoad, "") {
                Self.prepareCacheDirectory(dir)
                return try SummaryCache(directory: dir, vault: vault)
            }
        }
        try ensureCurrent(gen)
        #if DEBUG
        if let problem = cache?.loadProblem { NSLog("SempereProbe summary cache ignored: %@", problem) }
        #endif
        summaryCache = cache
        guard let cache else { return }
        // Shown at once; the listing then corrects what changed.
        if notes.isEmpty, !listLoaded {
            let cached = cache.storedSummaries
            if !cached.isEmpty {
                Perf.measure(.listUpdate, "index notes=\(cached.count)") { notes = Self.byTitle(cached) }
                indexedNames = cache.storedRevisionNames
            }
        }
    }

    /// A listing of a vault outside iCloud Drive: every note folder by name,
    /// reading only notes whose names changed (`reconcile`).
    func listLocalNotes() async throws {
        try await reconcile(full: true)
    }

    /// Reads the summaries of `ids` in batches of `loadBatchSize` (up to
    /// `loadBatchLimit` when there are many: an eighth of them) on
    /// `loadConcurrency` threads, queueing each batch for the list as it
    /// finishes (`queueListUpdate`) and counting in `loading`. Cached
    /// summaries (unchanged revision files) cost no decryption. Records the
    /// names each summary was made from (`indexedNames`; `listedNames` when
    /// the index file does not have the note). Publishes nothing once the
    /// vault closed (`CancellationError`) or, for the sync loop, once its task
    /// is canceled.
    func readSummaries(_ ids: [UUID], listedNames: [UUID: [String]] = [:],
                       onBatch: (([NoteSummary]) -> Void)? = nil) async throws {
        guard let vault else { throw ModelError.noVaultOpen }
        guard !ids.isEmpty else { return }
        let gen = generation
        let cache = summaryCache
        let coordinate = coordinationURL
        let width = max(1, loadConcurrency)
        let known = Set(notes.map(\.id)).subtracting(placeholderNoteIDs)
        loading = NoteLoading(done: 0, total: ids.count, refreshing: ids.allSatisfy(known.contains))
        defer { if gen == generation { loading = nil } }
        // Many changed notes (a mass re-import seen by another device): bigger batches, so the
        // threads wait less on each batch's slowest note and the list is updated fewer times.
        let batchSize = max(1, loadBatchSize, min(ids.count / 8, loadBatchLimit))
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(ids.count, start + batchSize)])
            let epochs = summaryEpochs
            // The cache file is written once per listing (`saveSummaryCache`), not per batch.
            let entries = try await offMain {
                try Perf.measure(.reconcileRead, "notes=\(batch.count)") {
                    try CloudVault.coordinatedRead(coordinate) {
                        try vault.summaryEntries(of: batch, cache: cache, maxConcurrency: width, saveCache: false)
                            .map { NamedSummary(summary: $0.summary, revisions: $0.revisions) }
                    }
                }
            }
            let read = entries.map(\.summary)
            let readNames = Dictionary(entries.map { ($0.summary.id, $0.revisions) }, uniquingKeysWith: { a, _ in a })
            try ensureCurrent(gen)
            try Task.checkCancellation()
            onSummaryRead?(batch.count)
            // An edit re-read a note while this batch was being read: its summary is newer.
            let current = read.filter { summaryEpochs[$0.id] == epochs[$0.id] }
            // The names this read used, not the listing's or the shared cache's (another read may have stored newer ones).
            // A summary with a `problem` is not indexed: the next pass reads the
            // note again (a transient failure clears; the cache never stores it either).
            for s in current { indexedNames[s.id] = s.problem == nil ? readNames[s.id] ?? listedNames[s.id] : nil }
            queueListUpdate(upserts: current)
            summariesRead(current)   // their revisions changed: re-index their attachments
            verifiedNoteIDs.formUnion(current.map(\.id))
            onBatch?(read)
            start += batch.count
            loading?.done = start
        }
    }

    /// Puts `summaries` into `notes` now, replacing older ones of the same
    /// notes (an edit's own re-read: shown at once, and newer than anything
    /// a listing has queued for them). Nothing is published when every one
    /// is already there unchanged.
    func merge(_ summaries: [NoteSummary]) {
        guard !summaries.isEmpty else { return }
        for s in summaries { listUpserts[s.id] = nil }
        applyListChanges(upserts: summaries, removals: [])
    }

    /// Re-reads note `id` when its summary was not read in this session
    /// (`verifiedNoteIDs`), so an edit never decides from an earlier launch's
    /// cache or a summary still being listed.
    /// A note not in the list is left to the caller (`noteNotFound`): reading
    /// an unknown id would list it as an empty note with a problem.
    func verifySummary(_ id: UUID) async throws {
        guard !verifiedNoteIDs.contains(id), notes.contains(where: { $0.id == id }) else { return }
        try await refresh([id])
    }

    /// `saveSummaryCache` unless the last save was less than
    /// `summaryCacheSaveInterval` ago (and not `force`): a pass that reads a
    /// few of many arriving notes does not re-encrypt the whole index each time.
    func saveSummaryCacheIfDue(force: Bool) {
        let now = ContinuousClock.now
        if !force, let last = lastSummaryCacheSave, now - last < summaryCacheSaveInterval { return }
        guard summaryCache?.hasChanges == true else { return }
        lastSummaryCacheSave = now
        saveSummaryCache()
    }

    /// Writes the summary cache in the background; a failure only costs the
    /// next launch time.
    /// Saves run one after another (`summaryCacheSave`, awaited by tests).
    func saveSummaryCache() {
        guard let cache = summaryCache, cache.hasChanges else { return }
        let previous = summaryCacheSave
        summaryCacheSave = Task.detached(priority: .utility) {
            await previous?.value
            try? cache.save()
        }
    }

    /// Creates the cache folder, excluded from device backups (the cache is
    /// rebuilt from the vault whenever it is missing).
    nonisolated static func prepareCacheDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
    }

    nonisolated static func byTitle(_ list: [NoteSummary]) -> [NoteSummary] {
        list.sorted { ($0.title.lowercased(), $0.id.uuidString) < ($1.title.lowercased(), $1.id.uuidString) }
    }
}
