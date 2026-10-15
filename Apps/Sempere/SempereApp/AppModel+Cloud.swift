import Sempere
import Foundation

/// Vaults in iCloud Drive (docs/io.md): fetch placeholder files before
/// reading, show progress, and let the user cancel the wait.
extension AppModel {
    /// The URL to coordinate vault reads and writes on: the vault folder
    /// when it is in iCloud Drive, nil otherwise.
    var coordinationURL: URL? {
        isCloudVault ? vaultURL : nil
    }

    /// Downloads the files of the vault at `url` (by default only those needed
    /// to unlock; the notes follow progressively, `loadNotes`) that iCloud Drive holds
    /// only as a placeholder, publishing `cloudProgress` while it waits.
    /// Security-scoped access to `url` must be active.
    ///
    /// - Returns: whether the vault is in iCloud Drive (false: nothing done).
    /// - Throws: `CancellationError` after `cancelCloudDownload()`;
    ///   `CloudVault.CloudError` on a stall or download error.
    func fetchFromICloud(_ url: URL, scope: CloudVault.Scope = .essentials) async throws -> Bool {
        cloudTask?.cancel()
        let hooks = cloudHooks
        let task = Task.detached(priority: .userInitiated) {
            try await CloudVault.download(vault: url, scope: scope, hooks: hooks) { progress in
                await self.showCloudProgress(progress)
            }
        }
        cloudTask = task
        defer {
            if cloudTask == task {
                cloudTask = nil
                cloudProgress = nil
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Stops waiting for iCloud; the open or reload that waited fails
    /// silently with `CancellationError`.
    func cancelCloudDownload() {
        cloudTask?.cancel()
        cloudTask = nil
        cloudProgress = nil
    }

    private func showCloudProgress(_ progress: CloudProgress) {
        guard cloudTask != nil else { return }
        cloudProgress = progress
    }
}

// MARK: - Progressive note loading

/// What the note list shows while an iCloud vault syncs: notes and files
/// that are local out of those listed, and why it stopped, if it did.
struct CloudSyncStatus: Equatable, Sendable {
    var notes = 0
    var readyNotes = 0
    var files = 0
    var localFiles = 0
    /// Notes whose folder iCloud has not listed yet.
    var unlistedNotes = 0
    /// Set when nothing arrived for the stall timeout, or iCloud reported an
    /// error; cleared when files arrive again.
    var problem: String?
    /// The WebDAV server (host) a partial copy downloads from; nil for iCloud Drive.
    var serverName: String?

    init(notes: Int = 0, readyNotes: Int = 0, files: Int = 0, localFiles: Int = 0, unlistedNotes: Int = 0,
         problem: String? = nil) {
        self.notes = notes
        self.readyNotes = readyNotes
        self.files = files
        self.localFiles = localFiles
        self.unlistedNotes = unlistedNotes
        self.problem = problem
    }

    init(pass: ProgressiveLoad.Pass) {
        self.init(notes: pass.all.count, readyNotes: pass.ready.count, files: pass.files, localFiles: pass.localFiles,
                  unlistedNotes: pass.unlisted.count)
    }

    var pendingNotes: Int { notes - readyNotes }
    /// Something is still to arrive: the progress bar is shown.
    var isDownloading: Bool { pendingNotes > 0 }
    /// The bar is on screen: a bulk transfer (`SyncBarPolicy`), latched by `carryBarState`.
    /// A few notes arriving after an edit are not announced with a bar.
    private(set) var showsBar = false

    /// Decides `showsBar` for the pass after `previous`.
    mutating func carryBarState(from previous: CloudSyncStatus?) {
        showsBar = SyncBarPolicy.shows(pending: pendingNotes, wasShown: previous?.showsBar ?? false)
    }
    var fractionCompleted: Double { notes == 0 ? 1 : Double(readyNotes) / Double(notes) }

    /// "Downloading from iCloud: 37 of 128 notes" (or from a WebDAV server, `CloudSource`).
    var headline: String {
        let allNotes = String(localized: "\(notes) notes", comment: "A number of notes")
        if let server = serverName {
            return String(localized: "Downloading from \(server): \(readyNotes) of \(allNotes)",
                          comment: "Progress; first %@ is a server's host name, second a number of notes, e.g. “37 of 128 notes”")
        }
        return String(localized: "Downloading from iCloud: \(readyNotes) of \(allNotes)",
                      comment: "Progress; %@ is a number of notes, e.g. “37 of 128 notes”")
    }

    /// "212 of 277 files", plus the notes not listed yet.
    var detail: String {
        let allFiles = String(localized: "\(files) files", comment: "A number of files")
        guard unlistedNotes > 0 else {
            return String(localized: "\(localFiles) of \(allFiles)", comment: "Download progress; %@ is a number of files, e.g. “212 of 277 files”")
        }
        let unlisted = String(localized: "\(unlistedNotes) note folders not listed yet",
                              comment: "iCloud Drive has not listed these note folders yet")
        return String(localized: "\(localFiles) of \(allFiles), \(unlisted)",
                      comment: "Download progress; first %@ is a number of files, second “2 note folders not listed yet”")
    }
}

extension AppModel {
    /// One pass over the notes (`reconcile`): reads the notes whose revision
    /// names changed since their shown summary was made and whose files are
    /// local; the rest of the changed notes are listed with their cached
    /// summary if there is one, else as placeholders (`placeholderNoteIDs`),
    /// until their files arrive. `full` also re-reads notes the index does
    /// not hold (a reload). While the vault is locked only the downloads are
    /// requested (none when this device has an index of the vault) and the
    /// progress updated. Passes never overlap (`loadGate`).
    ///
    /// - Returns: how many notes are still downloading.
    @discardableResult
    func loadNotes(full: Bool) async throws -> Int {
        try await reconcile(full: full)
    }

    /// Keeps the open iCloud vault in step, change-driven: a pass
    /// (`reconcile`) lists the note folders by name and reads only notes
    /// whose names changed. While notes are downloading, the loop re-checks
    /// just those every `cloudPollInterval` (with a full listing every
    /// `cloudIdleInterval`); once settled it lists everything every
    /// `cloudIdleInterval`, doubling while nothing changes up to
    /// `cloudMaxIdleInterval` (`idleInterval`), for as long as the vault is
    /// open, so revisions other devices write arrive without a pull to
    /// refresh. A change the file presenter reports (`noteFoldersChanged`)
    /// wakes it early for those notes only. Once settled, and then every
    /// `cloudValidationInterval`, a low-priority full validation runs
    /// (`validateVault`). Paused while the app is in the background
    /// (`pauseCloudSync`), once a sync in flight has finished there (`enterBackground`). Nothing arriving for `cloudStallTimeout` sets
    /// `cloudSync.problem` (shown in the list) and slows to the idle pace;
    /// the problem clears when files arrive again. Starts when the vault
    /// opens (still locked: downloads are requested before the key is
    /// entered when this device has no index of the vault) and is restarted
    /// by unlocking, reloading and the app becoming active. Replaces a loop
    /// already running.
    func startCloudSync() {
        guard isCloudVault else { return }
        cloudSyncTask?.cancel()
        syncWakeup.reset()
        startWatchingNotes()
        let gen = generation
        cloudSyncTask = Task { [weak self] in
            var quiet = 0
            var idlePasses = 0
            var lastLocal = -1
            var lastKnown = -1
            let clock = ContinuousClock()
            var lastChange = clock.now
            var lastFullPass: ContinuousClock.Instant?
            var scope: Set<UUID>?
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                var interval = self.cloudPollInterval
                do {
                    // Conflict versions of the vault's own files: merged before the folders are listed,
                    // so a note only another version held is listed by this very pass.
                    if scope == nil { await self.resolveCloudConflicts() }
                    let pending = try await self.reconcile(scope: scope)
                    if scope == nil { lastFullPass = clock.now }
                    // Index-first: notes still to arrive are listed from the devices' published
                    // summaries; once nothing is pending, this device publishes its own.
                    if !self.pendingNoteIDs.isEmpty { await self.refreshPublishedRows() }
                    if pending == 0 { await self.publishOwnSummariesIfDue() }
                    let known = self.cloudSync?.notes ?? 0
                    let local = self.cloudSync?.localFiles ?? 0
                    if local != lastLocal || known != lastKnown {
                        lastChange = clock.now
                        if lastLocal >= 0, self.cloudSync?.problem != nil, pending > 0 || local > lastLocal {
                            self.cloudSync?.problem = nil   // moving again
                        }
                    }
                    quiet = (pending == 0 && known == lastKnown) ? quiet + 1 : 0
                    lastLocal = local
                    lastKnown = known
                    if pending == 0 { self.cloudSync?.problem = self.conflictProblem }
                    // Off screen: done once nothing is pending (`enterBackground`).
                    if pending == 0, self.syncingInBackground, !self.syncInFlight {
                        self.finishBackgroundSync()
                        return
                    }
                    if quiet >= self.cloudSettlePasses {
                        interval = Self.idleInterval(base: self.cloudIdleInterval, max: self.cloudMaxIdleInterval,
                                                     idlePasses: idlePasses)
                        idlePasses += 1
                        self.validateIfDue()
                    } else {
                        idlePasses = 0
                    }
                    if pending > 0, clock.now - lastChange > self.cloudStallTimeout {
                        let late = String(localized: "\(pending) notes", comment: "A number of notes")
                        let wait = String(localized: "\(Int(self.cloudStallTimeout.components.seconds)) seconds",
                                          comment: "A number of seconds")
                        if let server = self.cloudSource.serverName {
                            self.cloudSync?.problem = String(localized: "\(server) has not delivered \(late) for \(wait). Check that this device is online. Sempere keeps trying.",
                                                             comment: "First %@ is a server's host name, second a number of notes, third a number of seconds")
                        } else {
                            self.cloudSync?.problem = String(localized: "iCloud Drive has not delivered \(late) for \(wait). Check that this device is online and signed in to iCloud Drive. Sempere keeps trying.",
                                                             comment: "First %@ is a number of notes, second a number of seconds")
                        }
                        interval = self.cloudIdleInterval
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.cloudSync?.problem = "\(error)"
                    interval = self.cloudIdleInterval
                }
                // At least one poll interval between passes, however many changes are reported.
                let poll = min(interval, self.cloudPollInterval)
                do {
                    try await Task.sleep(for: poll)
                    try await self.syncWakeup.sleep(for: interval - poll)
                } catch { return }
                scope = self.nextSyncScope(lastFullPass: lastFullPass)
            }
        }
    }

    /// The notes the loop's next pass looks at: nil (every folder) when a
    /// change could not be placed or a full listing is due, else the notes
    /// reported changed plus those still downloading.
    func nextSyncScope(lastFullPass: ContinuousClock.Instant?) -> Set<UUID>? {
        defer {
            reportedNoteIDs.formUnion(dirtyNoteIDs)
            dirtyNoteIDs = []
            dirtyAll = false
        }
        guard !dirtyAll, let last = lastFullPass, ContinuousClock.now - last < cloudIdleInterval else { return nil }
        let scope = dirtyNoteIDs.union(pendingNoteIDs)
        return scope.isEmpty ? nil : scope
    }

    /// A change below `notes/` was reported (`NotesFolderPresenter`): the
    /// loop looks at those notes now (nil: at every note).
    func noteFoldersChanged(_ ids: Set<UUID>?) {
        Perf.event(.changeNotified, ids.map { "notes=\($0.count)" } ?? "folder")
        if let ids { dirtyNoteIDs.formUnion(ids) } else { dirtyAll = true }
        syncWakeup.wake()
    }

    /// Registers the file presenter on the open vault's `notes/` folder.
    func startWatchingNotes() {
        guard notesPresenter == nil, let url = vaultURL else { return }
        let gen = generation
        let presenter = NotesFolderPresenter(vault: url) { [weak self] ids in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.noteFoldersChanged(ids)
            }
        }
        presenter.start()
        notesPresenter = presenter
    }

    func stopWatchingNotes() {
        notesPresenter?.stop()
        notesPresenter = nil
    }

    /// Starts the background validation when it is due and not running.
    func validateIfDue() {
        guard validationTask == nil, phase == .unlocked else { return }
        if let last = lastValidation, ContinuousClock.now - last < cloudValidationInterval { return }
        let gen = generation
        validationRun &+= 1
        let run = validationRun
        validationTask = Task(priority: .background) { [weak self] in
            try? await self?.validateVault()
            // A newer validation (after a pause and resume) is not this one's to clear.
            guard let self, self.generation == gen, self.validationRun == run else { return }
            self.validationTask = nil
        }
    }

    /// The pause after the `idlePasses`-th unchanged pass at the idle pace:
    /// `base`, doubled per unchanged pass, at most `max`.
    nonisolated static func idleInterval(base: Duration, max: Duration, idlePasses: Int) -> Duration {
        var interval = base
        for _ in 0..<Swift.max(0, Swift.min(idlePasses, 32)) where interval < max { interval = interval * 2 }
        return Swift.min(interval, max)
    }

    /// Stops the loop without forgetting what it found (the app went to the
    /// background); `startCloudSync` resumes it.
    func pauseCloudSync() {
        saveSummaryCacheIfDue(force: true)   // the app may not come back
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        validationTask?.cancel()
        validationTask = nil
        stopWatchingNotes()
    }

    func stopCloudSync() {
        pauseCloudSync()
        pendingNoteIDs = []
        placeholderNoteIDs = []
        unlistedSince = [:]
        emptyNoteFolders = []
        conflictProblem = nil
        cloudSync = nil
    }

    /// Makes every revision file of note `id` local before it is opened on
    /// the canvas or edited from the browser: a delta written on top of a
    /// partial log would be stamped and sequenced without the missing
    /// revisions, and an edit computed from a placeholder's empty summary
    /// (tags, title) would overwrite the real values. Not gated on
    /// `pendingNoteIDs`, which can be out of date (another device may have
    /// added a revision since the last pass): the note's folder is listed
    /// fresh, the missing files are fetched ahead of the rest of the vault,
    /// and the folder is listed again until a listing shows nothing missing.
    /// A folder that lists no file at all is not an empty note (every note
    /// has a revision) but one iCloud has not listed yet: it is waited for
    /// too. The note's summary is then re-read. No-op outside iCloud Drive.
    ///
    /// - Throws: `CloudVault.CloudError` on a stall or download error,
    ///   `ModelError.noteNotDownloaded` when new files keep appearing or the
    ///   folder stays unlisted, `CancellationError` when the vault closed meanwhile.
    func downloadNote(_ id: UUID) async throws {
        guard isCloudVault, let url = vaultURL else { return }
        let gen = generation
        let hooks = cloudHooks
        let stall = cloudStallTimeout
        let poll = cloudPollInterval
        var fetched = pendingNoteIDs.contains(id) || placeholderNoteIDs.contains(id)
        var rounds = 0
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            // Each file's state is a file-system query (resource values): with
            // hundreds of revisions, asked on the main actor it was a visible hitch.
            let (items, missing) = try await offMain {
                let items = try CloudScan.noteItems(inVault: url, id: id)
                return (items, items.filter { !hooks.state($0).isSettled })
            }
            try ensureCurrent(gen)
            #if DEBUG
            NSLog("SempereProbe downloadNote %@ listed=%d missing=%d", String(id.uuidString.prefix(8)), items.count, missing.count)
            #endif
            if !items.isEmpty && missing.isEmpty { break }
            fetched = true
            if items.isEmpty {
                // Not listed yet: ask for the folder and look again.
                guard clock.now - started < stall else { throw noteNotDownloadedError }
                let folder = CloudScan.Item(url: CloudScan.noteFolder(inVault: url, id: id), placeholder: false)
                try? hooks.request(folder)
                try await Task.sleep(for: poll)
                try ensureCurrent(gen)
                continue
            }
            rounds += 1
            guard rounds <= Self.noteListingRounds else { throw noteNotDownloadedError }
            noteDownload = (id, CloudProgress(total: missing.count, downloaded: 0))
            defer { if noteDownload?.id == id { noteDownload = nil } }
            try await CloudVault.download(items: missing, hooks: hooks, stallTimeout: stall, pollInterval: poll) { progress in
                await self.showNoteDownload(id, progress)
            }
            try ensureCurrent(gen)
        }
        guard fetched else { return }
        try await refresh([id])
        pendingNoteIDs.remove(id)
        placeholderNoteIDs.remove(id)
    }

    private func showNoteDownload(_ id: UUID, _ progress: CloudProgress) {
        if noteDownload?.id == id { noteDownload = (id, progress) }
    }

    /// How often `downloadNote` downloads a note's newly listed files before
    /// giving up on it settling.
    static let noteListingRounds = 5
}
