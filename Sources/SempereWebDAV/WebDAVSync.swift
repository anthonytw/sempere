import Age
import Foundation
import Sempere

/// Knobs for one sync run.
public struct WebDAVSyncOptions: Sendable {
    /// Plan only: no request that changes the server, no local write.
    public var dryRun = false
    /// Names this device in `vault.conflict-<device>-<time>.json`.
    public var deviceLabel = "device"
    /// The clock for conflict file names and compaction checks.
    public var now = Date()
    /// Remote revisions and other files larger than this are reported and skipped.
    public var maxFileBytes = 256 << 20
    /// The limit for attachment blobs (`notes/<id>/att/`), which are
    /// streamed to and from disk: a blob file over it is neither uploaded nor
    /// downloaded, and is reported. The default fits the largest blob the
    /// format allows (1 GiB of content, format.md §8.4) with its padding and
    /// encryption overhead.
    public var maxBlobBytes = WebDAVSyncOptions.defaultMaxBlobBytes

    /// One-way mirror (`sempere sync webdav --push-only`): upload what the
    /// server lacks, replace its `vault.json` / `rewrap-journal.json` with the
    /// local copy and propagate compaction and GC deletions to it, but never
    /// download, never write or delete anything in the local vault. See
    /// `WebDAVSync` and docs/io.md.
    public var pushOnly = false
    /// Push-only: also remove from the server what the local vault does not
    /// have and nothing explains (reported in `SyncReport.extraneous` either way).
    public var deleteExtraneous = false
    /// Push-only: a `vault.json` or `rewrap-journal.json` whose server copy
    /// changed since this device's last sync (another writer, e.g. another
    /// device's key change) is kept there and reported in `conflicts` instead
    /// of being replaced by the local copy. Without a record of a last sync,
    /// any differing server copy is kept. Revisions and blobs still upload.
    public var keepServerChanges = false
    /// Create the server's `sempere-index.json` and `sempere-summaries.sealed`
    /// (format.md §12), what the web viewer lists a vault from, when it has
    /// none; existing ones are kept current either way (the summaries need the
    /// vault unlocked).
    public var publishForWebViewer = false
    /// Where notes are summarized for that file through the summary cache
    /// (format.md §10); nil reads every changed note.
    public var summaryCacheDirectory: URL?

    /// Blob downloads are made of `Range` requests of this size, so memory
    /// stays bounded by one of them however fast the server is.
    public var blobSegmentBytes = WebDAVClient.defaultSegmentBytes

    /// Where downloads that fail the checks before placing are kept
    /// (format.md §9.1); nil: `<state file>.quarantine/` next to the sync state.
    public var quarantineDirectory: URL?
    /// Download again the files an earlier run quarantined, even when
    /// neither they nor the local `vault.json` changed.
    public var retryQuarantined = false
    /// Bounds of the whole run (notes, entries, bytes, time).
    public var limits = SyncLimits()
    /// For a first pull (no local vault to pass as `vault`): identities to
    /// open the pulled `vault.json` with, so the files that follow it are
    /// checked fully rather than for their structure only (format.md §9.1).
    public var firstPullIdentities: [any AgeIdentity] = []

    /// Skip listing a note folder on the server when its ETag in the
    /// `notes/` listing is the one recorded when the last run left the
    /// note in step on both sides, and the local folder holds exactly the
    /// recorded revisions (docs/io.md "Unchanged notes"). Only on a server
    /// seen to change a folder's ETag when this device wrote into it, never
    /// with a weak or missing ETag, and with a run that lists every note at
    /// least every `fullListingInterval`. A note's `att/` is still listed.
    public var skipUnchangedNotes = false
    /// List every note folder and its `att/` with one `PROPFIND` (`Depth:
    /// infinity` on `notes/`) instead of one each, on a server seen to answer
    /// it in full: a run checks it against the one-by-one listings first,
    /// and again every `fullListingInterval`; a server that refuses it is
    /// remembered (`TreeListing.swift`, docs/io.md "One listing for every
    /// note folder"). Only with 8 to 5 000 note folders.
    public var deepListing = true
    /// With `skipUnchangedNotes`: the longest time between two runs that list every note.
    public var fullListingInterval: TimeInterval = 24 * 3600

    /// Two-way sync: how long this device must itself have found a blob
    /// collectable (format.md §8.1.6 rules 1–3) before it follows the
    /// server's deletion of it (rule 4; a collector waited as long). Until
    /// then the blob is kept here and not uploaded again.
    public var blobRetention: TimeInterval = CompactionPlanner.defaultRetention

    /// Transfers at once, `1...TransferPool.maxWidth` (`sempere sync webdav
    /// --jobs`): the listings of note folders and their `att/`, the
    /// downloads of the files the vault lacks (each still checked and
    /// quarantined as one at a time would be; a note's blobs before its
    /// revisions) and the uploads of the files the server lacks (`Preupload.swift`;
    /// a note's blobs before its revisions). Deletions and mutable files stay one at a time.
    public var concurrency = TransferPool.defaultWidth
    /// Called as the run moves on (`WebDAVSyncProgress`): from the run's
    /// threads, one call at a time, so it must return quickly.
    public var progress: (@Sendable (WebDAVSyncProgress) -> Void)?
    /// Asked before each listing, note and download, and between the
    /// segments of a blob download: true stops the run as a run bound does
    /// (`WebDAVError.cancelled` in `errors` and `stoppedEarly`). What was
    /// done is kept, a blob cut short continues on the next run.
    public var isCancelled: (@Sendable () -> Bool)?

    /// A partial pull instead of a sync (format.md §1.2, docs/io.md "Partial
    /// copies"): `.metadata` makes or continues a partial copy, `.fetch`
    /// fetches what one lacks. Nil: an ordinary run.
    public var partial: WebDAVPartialRun?

    /// The largest blob file a reader opens (`BoundedRead.maxBlobFileBytes`,
    /// 1 GiB + 64 MiB).
    public static let defaultMaxBlobBytes = BoundedRead.maxBlobFileBytes

    public init(dryRun: Bool = false, deviceLabel: String = "device", now: Date = Date(), maxFileBytes: Int = 256 << 20,
                maxBlobBytes: Int = WebDAVSyncOptions.defaultMaxBlobBytes,
                blobSegmentBytes: Int = WebDAVClient.defaultSegmentBytes) {
        self.dryRun = dryRun; self.deviceLabel = deviceLabel; self.now = now; self.maxFileBytes = maxFileBytes
        self.maxBlobBytes = maxBlobBytes; self.blobSegmentBytes = blobSegmentBytes
    }
}

/// Mirrors a vault directory to a WebDAV collection and back; the server
/// only stores files (docs/io.md, "WebDAV sync").
///
/// - Revision files under `notes/` are write-once: a file missing on one side
///   is copied there, an existing one is never overwritten on either side.
/// - Each note's attachment blobs (`notes/<id>/att/`) follow the same table,
///   streamed through temporary files on both sides (bounded memory, their
///   own size limit), and a blob is deleted only under the collection rules
///   (format.md §8.1.6) on the side it is deleted from. An interrupted blob
///   download continues where it stopped.
/// - `vault.json` and `rewrap-journal.json` are compared against the state of
///   the last sync; when both sides changed, both copies are kept and the
///   conflict is reported.
/// - Deletions only follow compaction: a file that one side removed since the
///   last sync is removed on the other side only if `CompactionPlanner`
///   (over the revisions this side holds) says it is deletable; otherwise it
///   is restored.
///
/// A run keeps going after a per-file failure and lists it in `errors`.
public final class WebDAVSync {
    static let ageMagic = Data("age-encryption.org/v1\n".utf8)

    let root: URL
    let vault: Vault?
    /// The run's client: `interrupt` set to the run's bound and cancellation (`runLocked`).
    private(set) var client: WebDAVClient
    let stateURL: URL
    let options: WebDAVSyncOptions
    var state = SyncState()
    var report: SyncReport
    /// Collections known to exist on the server (listed, or made this run).
    /// Under `collections` once uploads run on the pool's threads.
    private var madeCollections = Set<[String]>()
    /// Collections a thread is making right now: another thread that needs
    /// one waits for it instead of sending a second MKCOL (two at once make
    /// some servers answer 500, wsgidav among them).
    private var makingCollections = Set<[String]>()
    private let collections = NSCondition()
    /// What the server holds after this run, per note (revision file names):
    /// the listing a server-side `sempere-index.json` must show.
    var remoteRevisions: [String: [String]] = [:]
    /// True when the server holds a `rewrap-journal.json` (format.md §8.1.6 rule 2).
    var remoteJournal = false
    /// Push-only: remote entries that are not vault files (the `ignored` ones), as paths.
    var remoteJunk: [[String]] = []
    /// False on a first sync (no readable state): then nothing on the server
    /// is known to have been synced, so push-only never deletes extraneous files.
    var hadState = false
    /// What this run has used of `options.limits`.
    var budget: RunBudget
    /// SHA-256 of the local `vault.json` when the run started (what `vault` was opened from).
    var checkerBaseManifest: String?
    var checkerCache: (manifest: String?, vault: Vault?)?
    /// `state.fileNamesByNote()` as the note loop started. Each note reads
    /// only its own entry, before it writes any record of its own, and is
    /// synced once per run, so this stays exact without being updated; it
    /// must be rebuilt if a note is ever synced twice in one run.
    var recordedFiles: [String: [String]] = [:]
    /// How many notes this run read through `vault` (decrypted every
    /// revision of) to judge deletions or record snapshot coverage.
    var notesRead = 0
    /// Strong ETags of the note folders in this run's `notes/` listing.
    var noteETags: [String: String] = [:]
    /// Whether this run lists only the notes whose folder ETag changed
    /// (`WebDAVSyncOptions.skipUnchangedNotes`); decided once `notes/` is listed.
    var skipsUnchangedNotes = false
    /// How this run lists the note folders (`TreeListing.swift`), and the
    /// tree it got when it asked for one.
    var treeMode = TreeMode.none
    var notesTree: [[String]: [RemoteEntry]]?
    /// The note folders this run listed one by one, as listed (a `verify` run compares them with the tree).
    var listedOneByOne: [String: [RemoteEntry]] = [:]
    /// Notes whose listing this run skipped.
    var notesNotListed = 0
    /// Note folders on the server whose listing failed this run: nothing is
    /// judged for them, and their records from the last sync are kept.
    var notesNotReadable = Set<String>()
    /// True once every note folder on the server was listed (or there is no
    /// `notes/`): only then does `remoteRevisions` describe the server, and
    /// the web index and summaries are refreshed from it.
    var notesListed = false
    /// `encodedWebIndex()`, once the notes loop is done.
    private var encodedIndex: Data?
    /// The remote `vault.json` as `checkSameVault` fetched it this run, for
    /// the mutable-file sync to compare instead of fetching it again.
    var fetchedManifest: (data: Data, etag: String?)?
    /// Push-only on a partial copy: server files kept because the copy has
    /// not fetched them yet (format.md §1.2).
    var pendingKept = 0

    /// Guards what concurrent listings and downloads share (`TransferPool`):
    /// `state`, `report`, `budget`, `progress`, the checker cache and the
    /// prefetch records. Recursive, so a locked helper may call another.
    let mutex = NSRecursiveLock()
    /// What `options.progress` was last given.
    var progress = WebDAVSyncProgress()
    /// Bytes credited so far to each prefetched download running (by key).
    var credited: [String: Int64] = [:]
    /// The listed size of each prefetched download running that has one (`credit` caps at it).
    var creditCap: [String: Int64] = [:]
    /// The server's `att/` listings, made ahead of the note loop (`listAttachments`).
    var attListings: [String: Result<[RemoteEntry]?, Error>] = [:]
    /// Keys of the downloads the prefetch made (whatever the outcome): the note loop does not repeat them.
    var prefetched = Set<String>()
    /// Notes whose prefetched downloads or pre-uploads reported anything: their folder ETag is not recorded this run.
    var prefetchTroubled = Set<String>()
    /// Keys of the uploads the pre-upload pass tried (`preuploadNewFiles`), whatever the outcome.
    var preuploadTried = Set<String>()
    /// The keys it uploaded, per note: the note loop counts them as its own uploads.
    var preuploaded: [String: Set<String>] = [:]

    /// - Parameters:
    ///   - directory: the local vault; it may be missing or empty for a first pull.
    ///   - vault: the vault opened with identities, so deletions can be checked
    ///     against the compaction rules; nil or locked means no deletion is propagated.
    ///   - stateURL: the sync-state file (outside `notes/`); see `defaultStateURL`.
    public init(directory: URL, vault: Vault?, client: WebDAVClient, stateURL: URL,
                options: WebDAVSyncOptions = WebDAVSyncOptions()) {
        self.root = directory
        self.vault = (vault?.canRead == true) ? vault : nil
        self.client = client
        self.stateURL = stateURL
        self.options = options
        self.report = SyncReport(dryRun: options.dryRun)
        self.budget = RunBudget(options.limits)
    }

    /// `$XDG_STATE_HOME/sempere/sync/<id>.json`, one per (remote, vault) pair.
    public static func defaultStateURL(remote: URL, vault: URL,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        SyncState.defaultURL(remote: remote, vault: vault, environment: environment)
    }

    /// Runs one sync. Runs on the same state file in this process take
    /// turns (`SyncRunLock`): this one waits for one already running.
    ///
    /// - Throws: `WebDAVError.vaultMismatch` before touching anything when the
    ///   two sides are different vaults; `.http`/`.transport` when the server's
    ///   root cannot be listed. Anything per file lands in the report.
    public func run() throws -> SyncReport {
        try SyncRunLock.shared.withLock(stateURL) { try runLocked() }
    }

    private func runLocked() throws -> SyncReport {
        // A request in flight stops at the run's time bound or a cancellation, not only between requests.
        let limits = options.limits, cancelled = options.isCancelled
        let deadline = Date().addingTimeInterval(limits.maxDuration)
        client.interrupt = {
            if cancelled?() == true { return .cancelled }
            if Date() > deadline { return RunBudget.timeExceeded(limits) }
            return nil
        }
        updateProgress { _ in }
        defer { updateProgress { $0.stage = .done } }
        do {
            if let s = try SyncState.load(stateURL) { state = s; hadState = true }
        } catch {
            report.skipped.append(.init(path: stateURL.path, message: "sync state unreadable (\(error.localizedDescription)); treated as a first sync"))
        }
        do {
            // What a killed run left in flight (its state file is that of the run before).
            if let t = try SyncState.loadTransfers(stateURL) { state.merge(t) }
        } catch {
            let path = SyncState.transfersURL(stateURL).path
            report.skipped.append(.init(path: path, message: "unreadable (\(error.localizedDescription)); ignored"))
        }
        if options.pushOnly && !FileManager.default.fileExists(atPath: root.appendingPathComponent(Vault.manifestName).path) {
            // A mirror of nothing would list (and could delete) the whole server.
            throw WebDAVError.io("push-only sync needs a local vault (no \(Vault.manifestName) in \(root.path))")
        }
        if let partial = options.partial {
            guard !options.pushOnly else { throw WebDAVError.io("a partial pull (--metadata-only, --fetch) cannot be push-only") }
            return try runPartial(partial)
        }
        if options.pushOnly, options.deleteExtraneous, PartialCopy.isPartial(root) {
            // What the copy has not fetched yet looks extraneous to a mirror (format.md §1.2).
            throw WebDAVError.io("--delete-extraneous refused: \(root.path) is a partial copy; fetch the rest first (--fetch)")
        }
        checkerBaseManifest = manifestHash()
        budget = RunBudget(options.limits)
        let rootEntries = try client.list([]) ?? []
        try budget.list(rootEntries.count)
        let remoteRoot = Dictionary(rootEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try checkSameVault(remoteRoot)
        remoteJournal = remoteRoot[Vault.journalName] != nil
        if !remoteJournal { state.inFlightJournal = nil }
        removeLeftoverRemoteTemps()

        for name in [Vault.manifestName, Vault.journalName] {
            let remote = remoteRoot[name].flatMap { $0.isCollection ? nil : $0 }
            do { options.pushOnly ? try pushMutable(name, remote: remote) : try syncMutable(name, remote: remote) } catch {
                report.errors.append(.init(path: name, message: Self.describe(error)))
            }
        }

        // Shared settings (format.md §13): merged per key when both sides changed.
        let remoteSettings = remoteRoot[SharedSettings.fileName].flatMap { $0.isCollection ? nil : $0 }
        do { try syncSharedSettings(remote: remoteSettings) } catch {
            report.errors.append(.init(path: SharedSettings.fileName, message: Self.describe(error)))
        }

        // Notebook records (format.md §14): write-once, so the union of both sides.
        do { try syncNotebookRecords(remoteRoot: remoteRoot) } catch {
            try rethrowRunLimit(error)
            report.errors.append(.init(path: NotebookRecords.folderName, message: Self.describe(error)))
        }

        do {
            recordedFiles = state.fileNamesByNote()
            let remoteNotes = try listRemoteNotes(rootEntries)
            let localNotes = try localNoteIDs()
            for (id, entries) in remoteNotes {
                remoteRevisions[id] = entries.compactMap { e in
                    RevisionName(e.name).flatMap { !e.isCollection && $0.filename == e.name ? e.name : nil }
                }
            }
            let all = Set(remoteNotes.keys).union(localNotes).subtracting(notesNotReadable)
            notesListed = notesNotReadable.isEmpty
            try listAttachments(remoteNotes)
            if treeMode == .verify, let tree = notesTree { settleTreeCheck(tree, listed: listedOneByOne) }
            if !options.dryRun && !options.pushOnly { try prefetchDownloads(remoteNotes) }
            if !options.dryRun { try preuploadNewFiles(remoteNotes, localNotes: localNotes) }
            updateProgress { $0.stage = .syncingNotes; $0.notesTotal = all.count }
            for id in all.sorted() {
                // Recorded again below only if the note ends unchanged and in step on both sides.
                state.notes[id] = nil
                do {
                    try checkCancelled()
                    try budget.checkTime()
                    let mark = NoteMark(report)
                    try syncNote(id, remoteEntries: remoteNotes[id])
                    if !prefetchTroubled.contains(id) { recordNoteStamp(id, remoteEntries: remoteNotes[id], since: mark) }
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: "notes/\(id)", message: Self.describe(error)))
                }
                updateProgress { $0.notesSynced += 1 }
            }
            finishNoteStamps(notes: all.union(notesNotReadable))
        } catch let e as WebDAVError where e.isRunLimit {
            // Stop here: what was done is recorded below, the next run continues.
            report.stoppedEarly = Self.describe(e)
            report.errors.append(.init(path: Vault.notesName, message: Self.describe(e)))
        }
        if options.pushOnly { deleteRemoteJunk() }
        let hasIndex = remoteRoot[WebIndex.fileName].map { !$0.isCollection } ?? false
        let hasSummaries = remoteRoot[PublishedSummaries.fileName].map { !$0.isCollection } ?? false
        if !options.dryRun, !notesListed {
            // Published from a partial listing, they would leave notes out.
            for (name, kept) in [(WebIndex.fileName, hasIndex), (PublishedSummaries.fileName, hasSummaries)]
            where kept || options.publishForWebViewer {
                report.skipped.append(.init(path: name, message: "the notes on the server were not all listed; not updated"))
            }
        }
        if !options.dryRun, notesListed, options.publishForWebViewer || hasIndex {
            do { try refreshRemoteWebIndex(remote: remoteRoot[WebIndex.fileName].flatMap { $0.isCollection ? nil : $0 }) } catch {
                report.errors.append(.init(path: WebIndex.fileName, message: Self.describe(error)))
            }
        }
        let incompleteNotes = WebDAVPartialCopy.incompleteNotes(root)
        if !options.dryRun, notesListed, !incompleteNotes.isEmpty, hasSummaries || options.publishForWebViewer {
            // Entries come from the local notes: the ones not fetched yet would be dropped (format.md §1.2).
            report.skipped.append(.init(path: PublishedSummaries.fileName,
                                        message: "\(incompleteNotes.count) notes are not downloaded yet (partial copy); not updated"))
        } else if !options.dryRun, notesListed {
            refreshRemoteSummaries(exists: hasSummaries)
        }
        if PartialCopy.isPartial(root) || pendingKept > 0 {
            if !options.dryRun, !options.pushOnly, notesListed, report.stoppedEarly == nil {
                WebDAVPartialCopy.finishIfComplete(root)
            }
            var status = WebDAVPartialCopy.status(root) ?? .init(completed: true)
            status.keptOnServer = pendingKept
            report.partial = status
        }
        if !options.dryRun {
            do {
                try state.save(stateURL)
                // Only now: until the state holds them, the transfers file is what remembers them.
                SyncState.removeTransfers(stateURL)
            } catch {
                report.errors.append(.init(path: stateURL.path, message: "cannot save sync state: \(Self.describe(error))"))
            }
        }
        report.progress = locked { var p = progress; p.stage = .done; return p }
        return report
    }

    /// Every local write goes through this first: a push-only run never makes one.
    func requireLocalWrite(_ what: String) throws {
        if options.pushOnly { throw WebDAVError.io("push-only run refused to \(what) locally") }
    }

    static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    // MARK: - Same vault?

    func checkSameVault(_ remoteRoot: [String: RemoteEntry]) throws {
        guard remoteRoot[Vault.manifestName] != nil,
              let local = try? localMutable(Vault.manifestName),
              let localId = WebDAVConnection.manifestFields(local)?.vaultId else { return }
        let fetched = try client.get([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
        fetchedManifest = fetched
        let remote = fetched.data
        guard let remoteId = WebDAVConnection.manifestFields(remote)?.vaultId else {
            // A mirror is repaired from the local manifest; a two-way sync has nothing to compare.
            if options.pushOnly { return }
            throw WebDAVError.malformedResponse("remote vault.json is not a vault manifest")
        }
        if localId != remoteId { throw WebDAVError.vaultMismatch(local: localId, remote: remoteId) }
    }

    // MARK: - Mutable files

    /// The local file `name` under the vault root, nil when absent. Present
    /// but unreadable or oversized is an error, not "absent".
    func localMutable(_ name: String) throws -> Data? {
        let url = root.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path)
            ? try BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes) : nil
    }

    func syncMutable(_ name: String, remote: RemoteEntry?) throws {
        let local = try localMutable(name)
        let record = state.mutable[name]

        guard let local else {
            guard let remote else { return }
            // A rewrap journal removed locally is finished business, not a missing file.
            if name == Vault.journalName, let record, record.stamp != nil, record.stamp == remote.stamp {
                try settleRemovedJournal(remote: remote, record: record)
                return
            }
            try pullMutable(name, remote: remote)
            return
        }
        let localHash = FileDigest.sha256(local)

        guard let remote else {
            // A rewrap journal this device synced that is now gone from the server was removed there when its
            // change finished. If this device refuses it too (vault.json no longer binds it), it is finished
            // business here as well: dropped, never put back (putting it back made two devices that had both
            // taken a pending change's journal hand a stale one to each other for ever).
            if name == Vault.journalName, record != nil, let vault, let manifest = try localMutable(Vault.manifestName),
               case .refused? = Vault.incomingJournalProblem(local, local: nil, manifest: manifest, vault: vault) {
                if !options.dryRun {
                    try requireLocalWrite("remove \(name)")
                    try FileManager.default.removeItem(at: root.appendingPathComponent(name))
                    state.mutable[name] = nil
                }
                report.deleted.append(.init(side: "local", path: name))
                return
            }
            // Never on the server, or wiped there: (re)create it, never overwriting.
            if try push(name, local, condition: .create) { try recordMutable(name, hash: localHash) }
            return
        }

        let (remoteData, getETag) = try fetchMutable(name)
        try budget.downloaded(remoteData.count)
        let remoteHash = FileDigest.sha256(remoteData)
        let stamp = remote.etag ?? getETag ?? remote.lastModified
        if remoteHash == localHash {
            state.mutable[name] = .init(hash: localHash, stamp: stamp)
            return
        }
        let localChanged = record.map { $0.hash != localHash } ?? true
        let remoteChanged = record.map { $0.hash != remoteHash } ?? true
        switch (localChanged, remoteChanged) {
        case (false, _):
            // Only the server moved on: take it (an atomic replace, the one in-place write sync makes).
            try accept(name, remoteData, stamp: stamp)
        case (true, false):
            let condition = Self.replaceCondition(etag: remote.etag ?? getETag)
            if try push(name, local, condition: condition) {
                try recordMutable(name, hash: localHash)
            } else {
                try conflict(name, remote: remoteData, detail: "the server copy changed while uploading")
            }
        case (true, true) where name == Vault.manifestName && VaultManifest.sameExceptLabel(local, remoteData):
            // Only the display label differs: the same vault (format.md §1.3). The server's copy is
            // the one every device shares, so it stays, as iCloud Drive's current version does.
            try accept(name, remoteData, stamp: stamp)
        case (true, true):
            try conflict(name, remote: remoteData,
                         detail: record == nil ? "both sides differ and there is no common ancestor" : "changed on both sides since the last sync")
        }
    }

    /// GETs a mutable file, or takes the copy `checkSameVault` fetched
    /// moments ago in this run (once).
    func fetchMutable(_ name: String) throws -> (data: Data, etag: String?) {
        if name == Vault.manifestName, let fetched = fetchedManifest {
            fetchedManifest = nil
            return fetched
        }
        return try client.get([name])
    }

    private func pullMutable(_ name: String, remote: RemoteEntry) throws {
        let (data, etag) = try fetchMutable(name)
        try budget.downloaded(data.count)
        try accept(name, data, stamp: remote.etag ?? etag ?? remote.lastModified)
    }

    private func accept(_ name: String, _ data: Data, stamp: String?) throws {
        try requireLocalWrite("write \(name)")
        if name == Vault.journalName {
            // A local journal may hold the only copy of an unfinished change's outgoing
            // secret, and one this device refuses is never taken (format.md §3.3.1,
            // security review 2026-10, S9, S4).
            let local = try localMutable(name)
            // Judged under the vault.json it belongs with: none here yet (a first pull whose
            // vault.json did not arrive) means it waits, never taken unjudged.
            guard let manifest = try? localMutable(Vault.manifestName) else {
                report.skipped.append(.init(path: name, message: "no local vault.json to judge it under yet; not taken"))
                return
            }
            // A first pull has no opened vault: judge under the pulled vault.json with its identities.
            let judge = vault ?? checker()
            switch Vault.incomingJournalProblem(data, local: local, manifest: manifest, vault: judge) {
            case nil: break
            case .refused(let why)?:
                if holdInFlightJournal(data, manifest: manifest, vault: judge) { return }
                remoteJournal = false
                report.rejected.append(.init(path: name, message: SyncReport.printable(IncomingJournalProblem.refused(why).message)))
                return
            case .keepLocal(let why)?:
                try conflict(name, remote: data, detail: why)
                return
            }
            state.inFlightJournal = nil
        }
        if name == Vault.manifestName {
            // Never let a list nobody with the key wrote replace ours (format.md §2.1).
            let local = try localMutable(name)
            if let why = Vault.incomingManifestProblem(data, local: local, vault: vault) {
                report.rejected.append(.init(path: name, message: SyncReport.printable(why)))
                return
            }
        }
        report.downloaded.append(name)
        guard !options.dryRun else { return }
        try LocalFS.write(data, to: root.appendingPathComponent(name), replacing: true)
        state.mutable[name] = .init(hash: FileDigest.sha256(data), stamp: stamp)
    }

    /// A refused server journal that may be step 1 of a recipient change
    /// whose `vault.json` has not reached the server yet
    /// (`Vault.incomingJournalMayBeInFlight`, format.md §3.3.1 "Refused
    /// journals"): for `Vault.inFlightJournalWindow` from when this device
    /// first saw it, it is not taken and not reported as rejected, still
    /// holds blob collection back (rule 2), and is judged again every run, so
    /// it is taken once its `vault.json` arrives. True while it is so held.
    private func holdInFlightJournal(_ data: Data, manifest: Data, vault judge: Vault?) -> Bool {
        guard Vault.incomingJournalMayBeInFlight(data, manifest: manifest, vault: judge) else {
            state.inFlightJournal = nil
            return false
        }
        let hash = FileDigest.sha256(data)
        if state.inFlightJournal?.hash != hash { state.inFlightJournal = .init(hash: hash, firstSeen: options.now) }
        let since = state.inFlightJournal?.firstSeen ?? options.now
        guard options.now.timeIntervalSince(since) < Vault.inFlightJournalWindow else { return false }
        report.skipped.append(.init(path: Vault.journalName, message: "refused for now: it may belong to a recipient change "
            + "whose vault.json has not reached the server yet (seen since \(Self.compactUTC(since))); judged again next run"))
        return true
    }

    /// The server still holds the rewrap journal this device synced and has
    /// since removed (its change finished here). When this device now refuses
    /// it (format.md §3.3.1: nothing binds it any more) and the server's
    /// `vault.json` is the local one, it is deleted there (only that version:
    /// `If-Match` with its strong ETag), so it holds no device's blob
    /// collection back and no reader has to judge it again. Otherwise it is
    /// left: locked, an accepted journal (unfinished change) or one changed
    /// on the server is never deleted. One this device refuses never holds
    /// its own collection back (S19).
    private func settleRemovedJournal(remote: RemoteEntry, record: SyncState.MutableRecord) throws {
        let name = Vault.journalName
        func leave(_ why: String) {
            report.skipped.append(.init(path: name, message: "removed locally; left on the server (\(why))"))
        }
        guard vault != nil else { return leave("the vault is locked: it cannot be judged") }
        let (data, getETag) = try client.get([name], maxBytes: BoundedRead.maxManifestBytes)
        try budget.downloaded(data.count)
        let manifest = try? localMutable(Vault.manifestName)
        guard case .refused(let why)? = Vault.incomingJournalProblem(data, local: nil, manifest: manifest, vault: vault) else {
            return leave("this device still accepts it: its recipient change is unfinished")
        }
        remoteJournal = false
        guard FileDigest.sha256(data) == record.hash else {
            return leave("refused: \(why); it is not the copy this device synced")
        }
        guard let manifest, state.mutable[Vault.manifestName]?.hash == FileDigest.sha256(manifest) else {
            return leave("refused: \(why); the server's vault.json is not this device's yet")
        }
        if !options.dryRun {
            let etag = (remote.etag ?? getETag).flatMap { Self.isStrong($0) ? $0 : nil }
            guard try client.delete([name], ifMatch: etag) else {
                return leave("it changed on the server while being removed")
            }
            state.mutable[name] = nil
        }
        report.deleted.append(.init(side: "remote", path: name))
    }

    /// The precondition for replacing a server copy that was just fetched
    /// and compared with the record: `If-Match` with its strong ETag, or
    /// none. A weak ETag never matches `If-Match` (RFC 9110 §13.1.1), so
    /// sending one would fail every time.
    static func replaceCondition(etag: String?) -> PutCondition {
        guard let etag, isStrong(etag) else { return .unconditional }
        return .replace(etag: etag)
    }

    /// Uploads a mutable file; false when the precondition failed.
    func push(_ name: String, _ data: Data, condition: PutCondition) throws -> Bool {
        if options.dryRun { report.uploaded.append(name); return true }
        try ensureCollection([])
        guard try client.put([name], data, condition: condition) else { return false }
        report.uploaded.append(name)
        return true
    }

    func recordMutable(_ name: String, hash: String) throws {
        guard !options.dryRun else { return }
        let entry = try client.stat([name])
        state.mutable[name] = .init(hash: hash, stamp: entry?.stamp)
    }

    private func conflict(_ name: String, remote: Data, detail: String) throws {
        try requireLocalWrite("write a conflict copy of \(name)")
        let base = (name as NSString).deletingPathExtension
        var copy: String?
        if !options.dryRun {
            let existing = try LocalFS.entries(root).filter { $0.hasPrefix(base + ".conflict-") }
            let identical = existing.first {
                (try? BoundedRead.contents(of: root.appendingPathComponent($0), maxBytes: BoundedRead.maxManifestBytes)) == remote
            }
            if let identical {
                copy = identical
            } else {
                let ext = (name as NSString).pathExtension
                let fname = "\(base).conflict-\(Self.sanitize(options.deviceLabel))-\(Self.compactUTC(options.now)).\(ext)"
                try LocalFS.write(remote, to: root.appendingPathComponent(fname), replacing: false)
                copy = fname
            }
        }
        report.conflicts.append(.init(path: name, remoteCopy: copy, detail: detail))
    }

    static func sanitize(_ label: String) -> String {
        let s = label.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? String($0) : "-" }.joined()
        return String(s.prefix(32)).isEmpty ? "device" : String(s.prefix(32))
    }

    static func compactUTC(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    // MARK: - Notes

    func localNoteIDs() throws -> [String] {
        try LocalFS.entries(root.appendingPathComponent(Vault.notesName)).filter(Vault.isNoteDirectoryName)
    }

    private func listRemoteNotes(_ rootEntries: [RemoteEntry]) throws -> [String: [RemoteEntry]] {
        guard rootEntries.contains(where: { $0.name == Vault.notesName && $0.isCollection }),
              let dirs = try client.list([Vault.notesName]) else { return [:] }
        try budget.list(dirs.count)
        madeCollections.formUnion([[], [Vault.notesName]])
        let noteDirs = dirs.filter { $0.isCollection && Vault.isNoteDirectoryName($0.name) }.count
        if noteDirs > options.limits.maxNotes {
            throw WebDAVError.limitExceeded("the server lists \(noteDirs) notes, more than \(options.limits.maxNotes) (--max-notes)")
        }
        checkNoteStamps(dirs)
        updateProgress { $0.notesTotal = noteDirs }
        // `Depth: infinity` where the server was seen to answer it in full (`TreeListing.swift`).
        var mode = treeMode(noteDirs: noteDirs)
        if mode != .none {
            notesTree = try fetchNotesTree(dirs: dirs.filter { $0.isCollection && Vault.isNoteDirectoryName($0.name) }.map(\.name))
            if notesTree == nil { mode = .none }
        }
        treeMode = mode
        if mode == .use { skipsUnchangedNotes = false }
        // Collections the listings show need no MKCOL before an upload into them (one request
        // per note uploaded to, every run, otherwise).
        func exists(_ name: String, _ entries: [RemoteEntry]) {
            madeCollections.formUnion([[], [Vault.notesName], [Vault.notesName, name]])
            if entries.contains(where: { $0.name == Vault.attachmentsName && $0.isCollection }) {
                madeCollections.insert([Vault.notesName, name, Vault.attachmentsName])
            }
        }
        var out: [String: [RemoteEntry]] = [:]
        var toList: [String] = []
        for d in dirs {
            guard d.isCollection, Vault.isNoteDirectoryName(d.name) else {
                report.ignored.append(SyncReport.printable("notes/\(d.name)"))
                remoteJunk.append([Vault.notesName, d.name])
                continue
            }
            if let unchanged = unchangedNoteEntries(d) {
                out[d.name] = unchanged
                exists(d.name, unchanged)
                updateProgress { $0.notesListed += 1 }
                continue
            }
            toList.append(d.name)
        }
        if mode == .use, let tree = notesTree {
            for name in toList {
                let entries = tree[[name]] ?? []
                out[name] = entries
                exists(name, entries)
                if entries.contains(where: { $0.name == Vault.attachmentsName && $0.isCollection }) {
                    attListings[name] = .success(tree[[name, Vault.attachmentsName]] ?? [])
                }
            }
            updateProgress { $0.notesListed += toList.count }
            return out
        }
        // One PROPFIND per folder, `concurrency` at a time.
        let listed = try listConcurrently(toList.map { [Vault.notesName, $0] }, notes: true)
        for (name, result) in zip(toList, listed) {
            switch result {
            case .success(let entries):
                out[name] = entries ?? []
                listedOneByOne[name] = entries ?? []
                if let entries { exists(name, entries) }
            case .failure(let error):
                report.errors.append(.init(path: "notes/\(name)", message: Self.describe(error)))
                notesNotReadable.insert(name)
            }
        }
        return out
    }

    func key(_ id: String, _ n: RevisionName) -> String { "\(id)/\(n.filename)" }

    /// The revisions the last sync recorded for a note (keys `<id>/<file name>`).
    func recordedRevisions(_ id: String) -> Set<RevisionName> {
        Set((recordedFiles[id] ?? []).compactMap(RevisionName.init))
    }

    /// The blobs the last sync recorded for a note (keys `<id>/att/<file name>`).
    func recordedBlobs(_ id: String) -> Set<String> {
        let prefix = "\(Vault.attachmentsName)/"
        return Set((recordedFiles[id] ?? []).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    private func syncNote(_ id: String, remoteEntries: [RemoteEntry]?) throws {
        if options.pushOnly { return try syncNotePushOnly(id, remoteEntries: remoteEntries) }
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        var entries: [RevisionName: RemoteEntry] = [:]
        var R = Set<RevisionName>()
        var remoteAtt: RemoteEntry?
        for e in remoteEntries ?? [] {
            if e.name == Vault.attachmentsName && e.isCollection { remoteAtt = e; continue }
            guard !e.isCollection, let n = RevisionName(e.name), n.filename == e.name else {
                report.ignored.append(SyncReport.printable("notes/\(id)/\(e.name)"))
                remoteJunk.append([Vault.notesName, id, e.name])
                continue
            }
            R.insert(n)
            entries[n] = e
        }
        let remoteListed = R
        // Whatever happens below, the server ends up holding R.
        defer { remoteRevisions[id] = R.isEmpty ? nil : R.map(\.filename).sorted() }
        // Blobs go first, so a revision never arrives on either side before
        // the blobs it references (format.md §8.1.4 step 4).
        var blobs = try syncBlobTransfers(id, remoteAtt: remoteAtt)
        var L = Set<RevisionName>()
        for f in try LocalFS.entries(dir) {
            if let n = RevisionName(f), n.filename == f { L.insert(n) }
        }
        let S = recordedRevisions(id)

        let newLocal = L.subtracting(R).subtracting(S)
        let newRemote = R.subtracting(L).subtracting(S)
        let remoteDeleted = L.subtracting(R).intersection(S)
        let localDeleted = R.subtracting(L).intersection(S)

        func attempt(_ n: RevisionName, _ body: () throws -> Void) throws {
            do { try body() } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "notes/\(key(id, n))", message: Self.describe(error)))
            }
        }

        // The prefetch made these already (`prefetchDownloads`); one it placed is in L by now.
        for n in newRemote.sorted() where !prefetched.contains(key(id, n)) {
            try attempt(n) { if try download(id, n, entry: entries[n]) { L.insert(n) } }
        }
        for n in newLocal.sorted() {
            // The pre-upload pass may have made it already (`preuploadNewFiles`), or tried and reported it.
            switch preuploadOutcome(id, key(id, n)) {
            case .uploaded: R.insert(n)
            case .failed: break
            case .notTried: try attempt(n) { try upload(id, n); R.insert(n) }
            }
        }

        // Read (decrypted, decoded) only when a deletion is judged or a shared
        // snapshot's coverage is not recorded yet; once, after the transfers
        // above, as before. An unchanged note is never read.
        lazy var loaded: LoadedNote? = loadForSync(id)
        let epoch = Date(timeIntervalSince1970: 0)

        // The other side deleted these: delete here only if compaction allows it, else put them back.
        // A compaction there kept its covering snapshot there, so only snapshots the server
        // listed count as cover; an emptied or recreated remote folder deletes nothing here.
        if !remoteDeleted.isEmpty {
            let onServer = (loaded?.revisions ?? []).filter { remoteListed.contains($0.name) }
                .compactMap(SnapshotCoverage.init)
            var coverage: [RevisionName: SnapshotCoverage] = [:]
            for r in loaded?.revisions ?? [] { if let c = SnapshotCoverage(r) { coverage[c.name] = c } }
            let readable = Set(loaded?.revisions.map(\.name) ?? [])
            // Only what a compactor or thinner of this format could have deleted (format.md §5.3,
            // §5.8.4; security review 2026-10, stage 4, S2): never a checkpoint or the created
            // anchor, every complete checkpoint still complete afterwards (its positioned snapshots
            // and witnesses kept), and nothing judged from a note with an unreadable revision.
            // Anything else is the server losing (or deleting) files: they are put back.
            var explained = Set<RevisionName>()
            if let loaded, loaded.failures.isEmpty {
                let protected = CompactionPlanner.neverDeleted(loaded.revisions)
                for n in remoteDeleted where readable.contains(n) && !protected.contains(n) {
                    var snaps = onServer
                    if var own = coverage[n] { own.wall = epoch; snaps.append(own) }
                    if CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps,
                                                   retention: 0, now: options.now).contains(n) {
                        explained.insert(n)
                    }
                }
                if !CompactionPlanner.deletionKeepsCheckpoints(explained, from: loaded.revisions, now: options.now) {
                    explained = []
                }
            }
            for n in remoteDeleted.sorted() {
                try attempt(n) {
                    let allowed = explained.contains(n)
                    if allowed {
                        report.deleted.append(.init(side: "local", path: "notes/\(key(id, n))"))
                        try requireLocalWrite("delete notes/\(key(id, n))")
                        if !options.dryRun { try LocalFS.remove(dir.appendingPathComponent(n.filename)) }
                        L.remove(n)
                    } else if loaded != nil && readable.contains(n) {
                        // Not a compaction: the server lost it. Restore it.
                        try upload(id, n); R.insert(n)
                    } else {
                        report.skipped.append(.init(path: "notes/\(key(id, n))", message: loaded == nil
                            ? "deleted on the server; cannot check it against compaction (vault not unlocked)"
                            : "deleted on the server; unreadable here, kept"))
                    }
                }
            }
        }

        // We deleted these: delete remotely only if a snapshot we hold (and the server has) covers them.
        if !localDeleted.isEmpty {
            let cover = (loaded?.revisions ?? []).filter { R.contains($0.name) }.compactMap(SnapshotCoverage.init)
            for n in localDeleted.sorted() {
                try attempt(n) {
                    guard loaded != nil else {
                        report.skipped.append(.init(path: "notes/\(key(id, n))",
                                                    message: "deleted locally; cannot check it against compaction (vault not unlocked)"))
                        return
                    }
                    var snaps = cover
                    if n.kind == .snapshot {
                        guard let included = state.files[key(id, n)]?.included else {
                            report.skipped.append(.init(path: "notes/\(key(id, n))",
                                                        message: "deleted locally; its coverage was never recorded, kept on the server"))
                            return
                        }
                        snaps.append(SnapshotCoverage(name: n, included: included, wall: epoch))
                    }
                    let ok = CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps, retention: 0,
                                                         now: options.now).contains(n)
                    if ok {
                        if !options.dryRun { try client.delete([Vault.notesName, id, n.filename]) }
                        report.deleted.append(.init(side: "remote", path: "notes/\(key(id, n))"))
                        R.remove(n)
                    } else if try download(id, n, entry: entries[n]) {
                        L.insert(n)
                    }
                }
            }
        }

        // Blob deletions are judged against the revisions both sides hold now.
        try syncBlobDeletions(id, &blobs, remoteRevisions: R)
        // A partial copy's note that now holds what the server listed is complete (format.md §1.2).
        settlePartialNote(id, remote: remoteListed, remoteBlobs: blobs.remoteListed ? Set(blobs.remote.keys)
                            : (remoteAtt == nil ? [] : nil))

        guard !options.dryRun else { return }
        // Remember what both sides now share; drop what neither has.
        let shared = L.intersection(R)
        var coverage: [RevisionName: Included] = [:]
        if needsCoverage(id, shared) {
            for r in loaded?.revisions ?? [] {
                if case .snapshot(let inc, _) = r.body { coverage[r.name] = inc }
            }
        }
        for n in shared {
            let k = key(id, n)
            state.files[k] = SyncState.FileRecord(included: coverage[n] ?? state.files[k]?.included)
        }
        for n in S where !L.contains(n) && !R.contains(n) { state.files[key(id, n)] = nil }
    }

    /// The note as `vault` reads it, nil when the vault is not unlocked or
    /// the note cannot be listed.
    func loadForSync(_ id: String) -> LoadedNote? {
        guard let vault, let uuid = UUID(uuidString: id) else { return nil }
        notesRead += 1
        return try? vault.loadNote(uuid)
    }

    /// Whether recording what both sides share needs the note read: a shared
    /// snapshot whose coverage is not recorded yet. A recorded one keeps its
    /// record (snapshots are write-once, so reading it again gives the same
    /// value), and only a file named as a snapshot holds one (a revision
    /// whose content names another kind does not read).
    func needsCoverage(_ id: String, _ shared: Set<RevisionName>) -> Bool {
        shared.contains { $0.kind == .snapshot && state.files[key(id, $0)]?.included == nil }
    }

    /// Rewrites the server's `sempere-index.json` (kept only where one
    /// exists; `sempere vault index` creates it) to list what the server
    /// holds now, so a viewer reading the share as static files is never
    /// silently stale. Unchanged contents are not rewritten.
    ///
    /// When the root listing shows the file with the strong ETag this device
    /// recorded for it and the new contents hash to what it held then,
    /// nothing is fetched or written. Otherwise it is fetched and compared.
    private func refreshRemoteWebIndex(remote: RemoteEntry?) throws {
        let data = try encodedWebIndex()
        let hash = FileDigest.sha256(data)
        if let record = state.webIndex, let etag = remote?.etag, Self.isStrong(etag), etag == record.etag,
           record.hash == hash, remote?.size.map({ $0 == data.count }) ?? true {
            return
        }
        let current = try? client.get([WebIndex.fileName], maxBytes: WebIndex.maxBytes).data
        if current == data {
            state.webIndex = remote?.etag.flatMap { Self.isStrong($0) ? .init(hash: hash, etag: $0) : nil }
            return
        }
        state.webIndex = nil
        guard try client.put([WebIndex.fileName], data, condition: .unconditional) else { return }
        report.uploaded.append(WebIndex.fileName)
        // The ETag of what was just written (a PUT need not return one); the next run compares it.
        if let etag = (try? client.stat([WebIndex.fileName]))??.etag, Self.isStrong(etag) {
            state.webIndex = .init(hash: hash, etag: etag)
        }
    }

    /// An ETag that changes whenever the bytes do (RFC 9110 §8.8.1); a weak
    /// one (`W/"…"`) need not.
    static func isStrong(_ etag: String) -> Bool { !etag.hasPrefix("W/") && !etag.isEmpty }

    /// `WebIndex.encode(remoteRevisions)`, encoded once per run: the web
    /// index and the published summaries both use it after the notes loop.
    func encodedWebIndex() throws -> Data {
        if let encodedIndex { return encodedIndex }
        let data = try WebIndex.encode(remoteRevisions)
        encodedIndex = data
        return data
    }

    /// Uploads a revision (`If-None-Match: *`). Safe on the pool's threads
    /// (`preuploadNewFiles`): what it shares with the run is under `mutex`.
    func upload(_ id: String, _ n: RevisionName) throws {
        defer { updateProgress { $0.uploaded = report.uploaded.count } }
        let path = "notes/\(key(id, n))"
        guard !options.dryRun else { locked { report.uploaded.append(path) }; return }
        let data = try BoundedRead.contents(of: root.appendingPathComponent("notes/\(id)/\(n.filename)"),
                                            maxBytes: options.maxFileBytes)
        try ensureCollection([Vault.notesName, id])
        // A 412 means the server already has it: write-once, so it is the same file.
        try client.put([Vault.notesName, id, n.filename], data, condition: .create)
        locked { report.uploaded.append(path) }
    }

    /// Downloads a revision, checks it (format.md §9.1) and places it.
    /// Returns false when it was not placed: it appeared locally in the
    /// meantime, or it failed a check and was quarantined (reported in
    /// `quarantined`), or an earlier run quarantined it (in `skipped`).
    func download(_ id: String, _ n: RevisionName, entry: RemoteEntry?) throws -> Bool {
        try requireLocalWrite("download notes/\(key(id, n))")
        let path = "notes/\(key(id, n))"
        let size = entry?.size
        if let size, size > options.maxFileBytes { throw WebDAVError.responseTooLarge(path: path, limit: options.maxFileBytes) }
        if skipQuarantined(key(id, n), path: path, entry: entry) { return false }
        let reserved = try locked { try budget.willDownload(size) }
        guard !options.dryRun else {
            locked { budget.release(reserved); report.downloaded.append(path) }
            return true
        }
        let data: Data
        do {
            data = try client.get([Vault.notesName, id, n.filename], maxBytes: options.maxFileBytes).data
        } catch {
            locked { budget.release(reserved) }
            throw error
        }
        try locked { try budget.downloaded(data.count, reserved: reserved) }
        credit(key(id, n), data.count)
        return try placeRevision(id, n, entry: entry, data: data)
    }

    /// Checks a downloaded revision (format.md §9.1) and places it; as `download`.
    func placeRevision(_ id: String, _ n: RevisionName, entry: RemoteEntry?, data: Data) throws -> Bool {
        let path = "notes/\(key(id, n))"
        guard data.count <= options.maxFileBytes else {
            throw WebDAVError.responseTooLarge(path: path, limit: options.maxFileBytes)
        }
        var problem: String?
        if !data.starts(with: Self.ageMagic) {
            problem = "not an age file"
        } else if let checker = checker(), let uuid = UUID(uuidString: id) {
            do { try checker.checkIncomingRevision(data, noteId: uuid, name: n) } catch {
                problem = "\(error)"
            }
        }
        if let problem {
            quarantine(key(id, n), path: path, entry: entry, reason: problem, data: data)
            return false
        }
        locked { state.quarantined?[key(id, n)] = nil }
        let url = root.appendingPathComponent("notes/\(id)/\(n.filename)")
        if try !LocalFS.write(data, to: url, replacing: false) { return false }
        locked { report.downloaded.append(path) }
        return true
    }

    /// Makes sure a collection exists (MKCOL). A note folder or `att/` whose
    /// parent the `notes/` listing did not show is made after its parent;
    /// otherwise a 409 makes the parents first. Safe on the pool's threads:
    /// one MKCOL per collection at a time, the others wait for its outcome.
    func ensureCollection(_ path: [String]) throws {
        collections.lock()
        while makingCollections.contains(path) { collections.wait() }
        if madeCollections.contains(path) { collections.unlock(); return }
        makingCollections.insert(path)
        // The listing showed `notes/`, so a parent it did not show is missing: make it first.
        let parentFirst = path.count >= 3 && madeCollections.contains([Vault.notesName])
            && !madeCollections.contains(Array(path.dropLast()))
        collections.unlock()
        var made = false
        defer {
            collections.lock()
            makingCollections.remove(path)
            if made { madeCollections.insert(path) }
            collections.broadcast()
            collections.unlock()
        }
        if parentFirst { try ensureCollection(Array(path.dropLast())) }
        switch try client.mkcol(path) {
        case .created, .exists: break
        case .missingParent:
            guard !path.isEmpty else {
                try client.createBase()
                break
            }
            try ensureCollection(Array(path.dropLast()))
            _ = try client.mkcol(path)
        }
        made = true
    }
}

/// One sync at a time per state file in this process. Two runs on one state
/// would merge each other's in-flight transfers (`SyncState.Transfers`), so
/// the second would delete the first's temporary upload as a leftover, and
/// whichever ended last would overwrite the other's state (the app's push
/// still running when "Download Again" or a reopen starts another).
final class SyncRunLock: @unchecked Sendable {
    static let shared = SyncRunLock()
    private let condition = NSCondition()
    private var held = Set<String>()

    /// Runs `body` once no other holder has `stateURL`, holding it meanwhile.
    func withLock<T>(_ stateURL: URL, _ body: () throws -> T) rethrows -> T {
        let key = stateURL.standardizedFileURL.resolvingSymlinksInPath().path
        condition.lock()
        while held.contains(key) { condition.wait() }
        held.insert(key)
        condition.unlock()
        defer {
            condition.lock()
            held.remove(key)
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}
