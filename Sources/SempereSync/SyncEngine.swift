import Age
import Foundation
import Sempere

/// Knobs for one sync run.
public struct SyncOptions: Sendable {
    /// Plan only: no request that changes the server, no local write.
    public var dryRun = false
    /// This device's id (format.md §5): its own `summaries/<device>.sealed`
    /// (§12.5) is only ever uploaded, never taken from the remote. Nil: every
    /// per-device file is treated as another device's.
    public var deviceID: DeviceID?
    /// The vault's write lock on this device (`VaultFileLock`, docs/design/device-first-sync.md §4): held
    /// while the run judges and replaces the local mutable files (`vault.json`, `settings.age`), so a writer
    /// of them in the same process (the app's settings) or another (the CLI) never interleaves with the read,
    /// merge and write. Never held across a request ("lock scope": the server's copies are read before it is taken
    /// and the uploads it decides are made after it is released (`MutableLockScope.swift`). Nil: no lock.
    public var localWriteLock: VaultFileLock?
    /// How long a run waits for `localWriteLock` before it leaves the mutable files to the next run.
    public var localWriteLockTimeout: TimeInterval = 30
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
    public var maxBlobBytes = SyncOptions.defaultMaxBlobBytes

    /// One-way mirror (`sempere sync webdav --push-only`): upload what the
    /// server lacks, replace its `vault.json` / `rewrap-journal.json` with the
    /// local copy and propagate compaction and GC deletions to it, but never
    /// download, never write or delete anything in the local vault. See
    /// `SyncEngine` and docs/io.md.
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
    /// Create the server's `sempere-summaries.sealed` (format.md §12) when it has none, and keep it current,
    /// without the web index: what a device joining the vault lists its notes from before they arrive
    /// (`AppModel+Join`). The app sets it on unlocked two-way runs of a complete copy.
    public var publishSummaries = false
    /// Never write anything to the remote (`PullOnlyRemote`): the run only downloads. A locked vault's
    /// staging run (`LockedStaging`, review of #77, S1).
    public var pullOnly = false
    /// Record this device's `synced` time in its own `summaries/<device>.sealed` at the end of a complete
    /// two-way run (key-hierarchy design §5.5: the removal sheet's stale-sync warning), at most once per
    /// `SyncEngine.syncedInterval`. The CLI's sync commands and the app set it.
    public var recordSynced = false
    /// This device's trust store, for a run without the vault's key (upload-only, or a locked vault): it honors the
    /// device's sightings by epoch number alone (key-hierarchy design §4.3 J5b; review of #86, S3). A run with the
    /// key uses the vault's own.
    public var epochTrust: (any EpochTrustStore)?
    /// Where notes are summarized for that file through the summary cache
    /// (format.md §10); nil reads every changed note.
    public var summaryCacheDirectory: URL?

    /// Blob downloads are made of pieces of this size (`Range` requests on
    /// WebDAV), so memory stays bounded by one of them however fast the server is.
    public var blobSegmentBytes = SyncOptions.defaultSegmentBytes

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
    /// Called as the run moves on (`SyncProgress`): from the run's
    /// threads, one call at a time, so it must return quickly.
    public var progress: (@Sendable (SyncProgress) -> Void)?
    /// Asked before each listing, note and download, and between the
    /// segments of a blob download: true stops the run as a run bound does
    /// (`SyncError.cancelled` in `errors` and `stoppedEarly`). What was
    /// done is kept, a blob cut short continues on the next run.
    public var isCancelled: (@Sendable () -> Bool)?

    /// Files a provider lists but has not downloaded yet (`Arrivals.swift`):
    /// the longest one run waits, in all, for the ones it asked for to arrive.
    /// What has not arrived by then is left for a later run (`SyncReport.arriving`).
    public var arrivalWait: TimeInterval = 10
    /// A folder listed before its files (`Arrivals.swift`) counts as arriving
    /// (nothing in it is judged) for this long after this device first found
    /// it so; then its listing is taken as it is (iCloud's `cloudUnlistedTimeout`).
    public var unlistedTimeout: TimeInterval = 120
    /// A file still not downloaded this long after this device first asked for
    /// it is reported in `errors` (still never deleted or uploaded over).
    public var arrivalStall: TimeInterval = 15 * 60

    /// A partial pull instead of a sync (format.md §1.2, docs/io.md "Partial
    /// copies"): `.metadata` makes or continues a partial copy, `.fetch`
    /// fetches what one lacks. Nil: an ordinary run.
    public var partial: PartialRun?

    /// The largest blob file a reader opens (`BoundedRead.maxBlobFileBytes`,
    /// 1 GiB + 64 MiB).
    public static let defaultMaxBlobBytes = BoundedRead.maxBlobFileBytes

    /// The default piece of a blob download (2 MiB): measured over WebDAV to
    /// keep memory flat for the largest blobs (`WebDAVClient.defaultSegmentBytes` says why).
    public static let defaultSegmentBytes = 2 << 20

    public init(dryRun: Bool = false, deviceLabel: String = "device", now: Date = Date(), maxFileBytes: Int = 256 << 20,
                maxBlobBytes: Int = SyncOptions.defaultMaxBlobBytes,
                blobSegmentBytes: Int = SyncOptions.defaultSegmentBytes) {
        self.dryRun = dryRun; self.deviceLabel = deviceLabel; self.now = now; self.maxFileBytes = maxFileBytes
        self.maxBlobBytes = maxBlobBytes; self.blobSegmentBytes = blobSegmentBytes
    }
}

/// Mirrors a vault directory to a remote and back (docs/io.md, "WebDAV
/// sync", "Sync engine and transports"). The remote only stores files and is
/// reached through a `SyncRemote` (a WebDAV collection: `WebDAVSyncRemote`);
/// "the server" below is that remote.
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
public final class SyncEngine {
    static let ageMagic = Data("age-encryption.org/v1\n".utf8)
    /// The bound of a mutable file read with no bound of its own (16 MiB, the WebDAV client's listing bound).
    static let maxMutableReadBytes = 16 << 20

    let root: URL
    /// The vault the run checks against: the caller's, or (when the caller's no longer matches the
    /// `vault.json` on disk, a key change another run took) the same vault opened again (`runLocked`).
    var vault: Vault?
    /// The run's remote: `interrupt` set to the run's bound and cancellation (`runLocked`).
    private(set) var transport: any SyncRemote
    let stateURL: URL
    let options: SyncOptions
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
    /// `state.thinned` by note as the note loop started (as `recordedFiles`).
    var thinnedFiles: [String: [String]] = [:]
    /// How many notes this run read through `vault` (decrypted every
    /// revision of) to judge deletions or record snapshot coverage.
    var notesRead = 0
    /// Strong ETags of the note folders in this run's `notes/` listing.
    var noteETags: [String: String] = [:]
    /// Whether this run lists only the notes whose folder ETag changed
    /// (`SyncOptions.skipUnchangedNotes`); decided once `notes/` is listed.
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
    /// The server's mutable files read before the write lock was taken, consumed by the judging under it (lock scope).
    var mutablePrefetch: [String: (data: Data, etag: String?)] = [:]
    /// What the server held of each mutable file when this round read it (hash of the bytes, version token): the
    /// base an upload without a precondition of its own is made against (`push`).
    var mutableSeen: [String: (hash: String, etag: String?)] = [:]
    /// Under the write lock: uploads are recorded here instead of made, and made once it is released (lock scope).
    var deferringUploads = false
    var deferredUploads: [DeferredUpload] = []
    /// The server's current `vault.json`, read before the write lock for settling its conflict versions.
    var conflictCurrent: Data?
    /// The epoch of a home-signed child of this device's epoch that the server's `vault.json` names (per-device
    /// summaries, `DeviceSummariesSync.swift`): read at most once per run, when first needed.
    var remoteChildEpoch: Int??
    /// Push-only on a partial copy: server files kept because the copy has
    /// not fetched them yet (format.md §1.2).
    var pendingKept = 0
    /// Files and folders a provider has not downloaded yet (`Arrivals.swift`). Under `mutex`.
    var arrivals = ArrivalTracker()
    /// Device changes (KH4, `EpochSync.swift`): why this run uploads nothing new and syncs only `epochs/` and
    /// `vault.json` (a later epoch this device cannot verify yet, J5b; or it is unlisted, design §5.5).
    var epochHold: String? {
        didSet {
            // Every upload path goes through `holdGate` (`HoldGate.swift`).
            if epochHold == nil || Self.epochMutations.contains(.uploadWhileWaiting) && epochStatus.unlisted == nil
                || Self.epochMutations.contains(.syncSettingsWhileHeld) {
                holdGate.mode = .open
            } else {
                holdGate.mode = epochStatus.unlisted != nil ? .nothing : .epochsOnly
            }
        }
    }
    /// What a held run may still write (`HoldGate.swift`).
    let holdGate = HoldGate()
    /// `heldKeys`, once per vault value (reset when the run reopens it).
    var cachedHeldKeys: String?
    /// Revisions this run wrote over on the target (their version tag is new and unknown until listed again).
    var remoteRewritten: Set<String> = []
    /// The epoch id of the `vault.json` the target holds, as this run last knew it (read, or uploaded): only a run
    /// whose own list stands on the target replaces files there (review of #86, S1).
    var targetEpochId: Data?
    /// Records the target's `epochs/` holds that this device does not (could not take): a copy no key here opens
    /// is then not taken for one under a dropped key (S2).
    var targetHasUnknownRecords = false
    /// Detached sightings this target showed when last looked at (M3), until its `vault.json` is read.
    var detachedPending: [Data: (why: String, seen: Date)] = [:]
    /// True once this run took a later epoch's `vault.json`: the vault is reopened, pinned and caught up.
    var epochTaken = false
    /// What the run met about device changes (`SyncReport.epoch`).
    var epochStatus = SyncReport.EpochStatus()
    /// The remote `vault.json` as this run read it (for the `keys/` deletion rule).
    var remoteManifestData: Data?
    /// A digest of the local `epochs/` names after the epoch step: a file that waited for a record is fetched
    /// again only when it changes (`SyncState.pendingEpoch`).
    var epochsDigest = ""
    /// The epoch records the target holds after the epoch step (nil: not known): a `vault.json` is never
    /// uploaded to a target that lacks its record (design §5.2: record first, then `vault.json`).
    var remoteEpochRecords: Set<String>?
    /// Working-copy files this device set aside that are still in place (path → SHA-256): an accepted copy on
    /// the remote replaces them (design §5.4 step 4).
    var unacceptedHere: [String: String] = [:]
    /// The latest bytes (SHA-256) this device's write ledger holds per path: a shared file whose bytes changed
    /// here since both sides last matched (a catch-up's re-encryption) is compared with the remote's.
    var ledgerShas: [String: String] = [:]
    /// Paths this device holds set-aside copies of: when the local bytes differ from what a target was last
    /// known to hold (the accepted copy replaced them here, from another target), the target's is compared, so
    /// a device that bridges two targets carries the replacement across.
    var asidePaths: Set<String> = []
    /// Per note: blob base names under an earlier key mapped to the current key's (KH6, `supersededTable`).
    var supersededTables: [String: [String: String]] = [:]
    /// The target holds the journal the local `vault.json` binds (`pushReencryptJournal`): only then does a
    /// `vault.json` with `reencryptPending` go there.
    var remoteJournalHere = false
    var remoteJournalETag: String?
    var remoteJournalPresent = false
    /// The journal went up this run (ahead of its `vault.json`).
    var journalUploaded = false
    /// A target's `settings.age` from before a finished re-encryption, kept aside here, to delete after the write lock
    /// (its version tag; empty: none strong).
    var obsoleteSettingsETag: String?

    /// Guards what concurrent listings and downloads share (`TransferPool`):
    /// `state`, `report`, `budget`, `progress`, the checker cache and the
    /// prefetch records. Recursive, so a locked helper may call another.
    let mutex = NSRecursiveLock()
    /// What `options.progress` was last given.
    var progress = SyncProgress()
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
    /// Notes whose revisions this run holds back (format.md §8.1.4 step 4): one of their blobs failed to
    /// upload, or the server's `att/` listing failed while the note has blobs here. A revision then never
    /// reaches the server without an attachment it may reference; the next run sends both.
    var blobsHeldBack = Set<String>()
    /// The keys it uploaded, per note: the note loop counts them as its own uploads.
    var preuploaded: [String: Set<String>] = [:]
    /// SHA-256 of the revisions this run uploaded or placed, by key: recorded with them (`FileRecord.sha256`).
    var placedShas: [String: String] = [:]

    /// - Parameters:
    ///   - directory: the local vault; it may be missing or empty for a first pull.
    ///   - vault: the vault opened with identities, so deletions can be checked
    ///     against the compaction rules; nil or locked means no deletion is propagated.
    ///   - stateURL: the sync-state file (outside `notes/`); see `defaultStateURL`.
    public init(directory: URL, vault: Vault?, remote: any SyncRemote, stateURL: URL,
                options: SyncOptions = SyncOptions()) {
        self.root = directory
        self.vault = (vault?.canRead == true) ? vault : nil
        self.transport = HoldGatedRemote(base: options.pullOnly ? PullOnlyRemote(base: remote) : remote, gate: holdGate)
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
    /// - Throws: `SyncError.vaultMismatch` before touching anything when the
    ///   two sides are different vaults; the transport's error (`WebDAVError.http`,
    ///   `.transport`, …) when the remote's root cannot be listed. Anything per file lands in the report.
    public func run() throws -> SyncReport {
        var report = try SyncRunLock.shared.withLock(stateURL) { try runLocked() }
        // What it wrote in the vault folder, for the app's arrivals (`LocalChanges`) and `--json`.
        report.changed = LocalChanges(report: report)
        return report
    }

    private func runLocked() throws -> SyncReport {
        // A request in flight stops at the run's time bound or a cancellation, not only between requests.
        let limits = options.limits, cancelled = options.isCancelled
        let deadline = Date().addingTimeInterval(limits.maxDuration)
        transport.interrupt = {
            if cancelled?() == true { return SyncError.cancelled }
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
            throw SyncError.io("push-only sync needs a local vault (no \(Vault.manifestName) in \(root.path))")
        }
        if let partial = options.partial {
            guard !options.pushOnly else { throw SyncError.io("a partial pull (--metadata-only, --fetch) cannot be push-only") }
            return try runPartial(partial)
        }
        if options.pushOnly, options.deleteExtraneous, PartialCopy.isPartial(root) {
            // What the copy has not fetched yet looks extraneous to a mirror (format.md §1.2).
            throw SyncError.io("--delete-extraneous refused: \(root.path) is a partial copy; fetch the rest first (--fetch)")
        }
        // A caller may hold a `Vault` opened before an earlier run took another device's key change (the
        // app reopens its own a moment later): checked under it, the new secret's files would be refused and
        // quarantined. The run uses the vault as `vault.json` on disk says it is now.
        if let v = vault, !v.keysMatchManifestOnDisk() {
            if let fresh = try? v.reopened(), fresh.canRead {
                vault = fresh
            } else {
                vault = nil
                report.skipped.append(.init(path: Vault.manifestName, message: "the vault's keys changed and this device's "
                    + "key does not open it: files are checked for their structure only, nothing is deleted"))
            }
        }
        checkerBaseManifest = manifestHash()
        budget = RunBudget(options.limits)
        // A device this device's sightings say is unlisted uploads nothing (design §5.5).
        if let notice = vault?.unlistedNotice { holdForEpoch(unlisted: notice) }
        // A run that cannot judge (upload-only, or without the key) honors the sightings by epoch number (S3).
        if options.pushOnly || epochJudge == nil, !options.dryRun, let local = try? localMutable(Vault.manifestName),
           let hold = Vault.sightingHoldByNumber(local, store: vault?.publicTrustStore ?? options.epochTrust,
                                                 location: transport.location) {
            holdForEpoch(waiting: hold.why)
            epochStatus.heldSince = hold.seen
        }
        let rootEntries = try transport.list([]) ?? []
        try budget.list(rootEntries.count)
        let remoteRoot = Dictionary(rootEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // A provider's evicted root files are asked for at once; vault.json is waited for (`Arrivals.swift`).
        try awaitRootFiles(remoteRoot)
        try checkSameVault(remoteRoot)
        removeLeftoverRemoteTemps()
        // Epoch records first, both ways (design §5.2: every device that holds one pushes it to every target),
        // so a later epoch's vault.json finds its record here (KH4, `EpochSync.swift`). A run bound reached here
        // stops the run as one reached in the notes does (reported, never thrown).
        var stoppedBefore: SyncError?
        do { try syncEpochRecords(remoteRoot: remoteRoot) } catch {
            if let e = error as? SyncError, e.isRunLimit { stoppedBefore = e } else {
                report.errors.append(.init(path: Vault.epochsName, message: Self.describe(error)))
            }
        }
        // The record of a vault.json taken before it arrived is here now: pinned and caught up below.
        if let v = vault, v.isRecordPending, FileManager.default.fileExists(atPath: root.appendingPathComponent(v.manifest.epochRecord).path) {
            epochTaken = true
        }
        // The local mutable files are judged and replaced under the vault's write lock (`localWriteLock`), which
        // is never held across a request (lock scope): the server's copies are read first, the uploads made after.
        // A pending re-encryption's journal goes before the vault.json that binds it (KH6, `push`).
        readReencryptJournal(remoteRoot)
        syncMutableFiles(remoteRoot)

        // A later epoch taken: the vault reopened under it, pinned, and this device's own files caught up
        // (design §5.4), before anything else is judged or uploaded.
        afterEpochTaken()
        // A catch-up an earlier run or write could not finish is tried again before anything is judged (design §5.4):
        // until it runs, this device's unaccepted copies are not set aside, so nothing would replace them.
        if !epochTaken, epochHold == nil, !options.dryRun, !options.pushOnly, let v = epochJudge, v.ledger != nil,
           v.listStatus.allowsWriting, !v.isReadOnly {
            try? v.requireWritable()
        }
        // Once per epoch: the working copy's files the acceptance rule no longer takes are set aside (a change this
        // device made itself, or a takeover's chain, can leave some in place), so accepted copies replace them.
        if epochHold == nil, !options.dryRun, !options.pushOnly, let v = epochJudge, v.setAsideStore != nil,
           v.manifest.epoch > 1, !v.isRecordPending, state.scannedEpoch != Hex.encode(v.manifest.epochId) + ":" + epochsDigest {
            do {
                try v.setAsideScan()
                // After a finished re-encryption the set-aside copies leave the working copy (KH6, J7).
                for p in v.removeSetAsideCopiesBelowReencryption() { report.deleted.append(.init(side: "local", path: p)) }
                // Keyed on the local records too: a record that arrives later turns pending files into set-aside ones.
                state.scannedEpoch = Hex.encode(v.manifest.epochId) + ":" + epochsDigest
            } catch {
                report.skipped.append(.init(path: Vault.notesName, message: "not scanned for files from before a device "
                    + "change: \(SyncReport.printable(Self.describe(error)))"))
            }
        }
        // What keys the notes are judged with (a file that waited for one is fetched again once this moves).
        cachedHeldKeys = epochJudge.map { v in
            let pinned = ((try? v.publicTrustStore?.record(for: v.vaultId)) ?? nil)?.pinned?.epochId
            return "\(v.heldKeysDigest)|\(pinned.map { Hex.encode($0).prefix(16) } ?? "")|\(v.isRecordPending)"
        }
        if let hold = epochHold, !Self.epochMutations.contains(.uploadWhileWaiting) {
            // Unverified-pending or unlisted (design §4.3, §5.5): nothing new is uploaded (J5b), nothing else
            // is synced until the change is verified (or a takeover lists this device again).
            report.skipped.append(.init(path: Vault.notesName, message: SyncReport.printable(hold)))
            if epochStatus.unlisted != nil { epochStatus.unsyncedChanges = unsyncedChangeCount() }
            return finishRun()
        }
        // The re-encryption journal (KH6): taken when bound, replaced, or deleted once finished.
        settleReencryptJournal(remoteRoot)
        if cachedHeldKeys == nil {
            cachedHeldKeys = epochJudge.map { v in
                let pinned = ((try? v.publicTrustStore?.record(for: v.vaultId)) ?? nil)?.pinned?.epochId
                return "\(v.heldKeysDigest)|\(pinned.map { Hex.encode($0).prefix(16) } ?? "")|\(v.isRecordPending)"
            }
        }
        // Join requests and passphrase copies (format.md §15.11, §15.12; KH4).
        if stoppedBefore == nil {
            do { try syncJoinRequests(remoteRoot: remoteRoot) } catch {
                if let e = error as? SyncError, e.isRunLimit { stoppedBefore = e } else {
                    report.errors.append(.init(path: Vault.joinsName, message: Self.describe(error)))
                }
            }
        }
        if stoppedBefore == nil {
            do { try syncPassphraseCopies(remoteRoot: remoteRoot) } catch {
                if let e = error as? SyncError, e.isRunLimit { stoppedBefore = e } else {
                    report.errors.append(.init(path: Vault.keysName, message: Self.describe(error)))
                }
            }
        }
        prepareReplacements()

        // Notebook records (format.md §14): write-once, so the union of both sides.
        // A run bound reached here stops the run like one reached in the notes below: reported (`stoppedEarly`),
        // never thrown, so what the run already replaced (vault.json, settings) still reaches the caller.
        if stoppedBefore == nil {
        do { try syncNotebookRecords(remoteRoot: remoteRoot) } catch {
            if let e = error as? SyncError, e.isRunLimit { stoppedBefore = e } else {
                report.errors.append(.init(path: NotebookRecords.folderName, message: Self.describe(error)))
            }
        }
        }

        do {
            if let stoppedBefore { throw stoppedBefore }
            recordedFiles = state.fileNamesByNote()
            thinnedFiles = SyncState.namesByNote(state.thinned?.keys.map { $0 } ?? [])
            // Note folders a provider listed before their `att/` are left out until they arrive (`Arrivals.swift`).
            let remoteNotes = try setAsideArrivingAttachments(try listRemoteNotes(rootEntries))
            let localNotes = try localNoteIDs()
            for (id, entries) in remoteNotes {
                remoteRevisions[id] = entries.compactMap { e in
                    RevisionName(e.name).flatMap { !e.isCollection && $0.filename == e.name ? e.name : nil }
                }
            }
            let all = Set(remoteNotes.keys).union(localNotes).subtracting(notesNotReadable)
            notesListed = notesNotReadable.isEmpty
            try listAttachments(remoteNotes)
            requestArrivals(remoteNotes)
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
        } catch let e as SyncError where e.isRunLimit {
            // Stop here: what was done is recorded below, the next run continues.
            report.stoppedEarly = Self.describe(e)
            report.errors.append(.init(path: Vault.notesName, message: Self.describe(e)))
        }
        if report.stoppedEarly == nil {
            // After the notes: an adopted note reaches each side before its inbox files go (`InboxSync.swift`).
            do { try syncInbox(remoteRoot: remoteRoot) } catch {
                if let e = error as? SyncError, e.isRunLimit {
                    report.stoppedEarly = Self.describe(e)
                }
                report.errors.append(.init(path: CaptureFile.folderName, message: Self.describe(error)))
            }
        }
        // A complete two-way run: this device's `synced` time in its own summaries file (design §5.5).
        if report.stoppedEarly == nil, notesListed { recordOwnSynced() }
        if report.stoppedEarly == nil {
            do { try syncDeviceSummaries(remoteRoot: remoteRoot) } catch {
                if let e = error as? SyncError, e.isRunLimit { report.stoppedEarly = Self.describe(e) }
                report.errors.append(.init(path: PublishedSummaries.deviceFolderName, message: Self.describe(error)))
            }
        }
        if options.pushOnly { deleteRemoteJunk() }
        let hasIndex = remoteRoot[WebIndex.fileName].map { !$0.isCollection } ?? false
        let hasSummaries = remoteRoot[PublishedSummaries.fileName].map { !$0.isCollection } ?? false
        if !options.dryRun, !notesListed {
            // Published from a partial listing, they would leave notes out.
            for (name, kept) in [(WebIndex.fileName, hasIndex), (PublishedSummaries.fileName, hasSummaries)]
            where kept || options.publishForWebViewer || (name == PublishedSummaries.fileName && options.publishSummaries) {
                report.skipped.append(.init(path: name, message: "the notes on the server were not all listed; not updated"))
            }
        }
        if !options.dryRun, notesListed, options.publishForWebViewer || hasIndex {
            do { try refreshRemoteWebIndex(remote: remoteRoot[WebIndex.fileName].flatMap { $0.isCollection ? nil : $0 }) } catch {
                report.errors.append(.init(path: WebIndex.fileName, message: Self.describe(error)))
            }
        }
        let incompleteNotes = PartialCopyState.incompleteNotes(root)
        if !options.dryRun, notesListed, !incompleteNotes.isEmpty, hasSummaries || options.publishForWebViewer || options.publishSummaries {
            // Entries come from the local notes: the ones not fetched yet would be dropped (format.md §1.2).
            report.skipped.append(.init(path: PublishedSummaries.fileName,
                                        message: "\(incompleteNotes.count) notes are not downloaded yet (partial copy); not updated"))
        } else if !options.dryRun, notesListed {
            refreshRemoteSummaries(exists: hasSummaries)
        }
        if PartialCopy.isPartial(root) || pendingKept > 0 {
            if !options.dryRun, !options.pushOnly, notesListed, report.stoppedEarly == nil {
                PartialCopyState.finishIfComplete(root)
            }
            var status = PartialCopyState.status(root) ?? .init(completed: true)
            status.keptOnServer = pendingKept
            report.partial = status
        }
        return finishRun()
    }

    /// The end of every run: arrivals settled, the state saved, the report finished.
    func finishRun() -> SyncReport {
        finishArrivals()
        if !options.dryRun {
            do {
                try state.save(stateURL)
                // Only now: until the state holds them, the transfers file is what remembers them.
                SyncState.removeTransfers(stateURL)
            } catch {
                report.errors.append(.init(path: stateURL.path, message: "cannot save sync state: \(Self.describe(error))"))
            }
        }
        if epochStatus != SyncReport.EpochStatus() { report.epoch = epochStatus }
        report.progress = locked { var p = progress; p.stage = .done; return p }
        return report
    }

    /// Runs `body` holding `options.localWriteLock` (none: just runs it).
    func withLocalWriteLock(_ body: () throws -> Void) throws {
        guard let lock = options.localWriteLock, !options.dryRun else { return try body() }
        try lock.withLock(timeout: options.localWriteLockTimeout, body)
    }

    /// Every local write goes through this first: a push-only run never makes one.
    func requireLocalWrite(_ what: String) throws {
        if options.pushOnly { throw SyncError.io("push-only run refused to \(what) locally") }
    }

    /// One line for a failure, as a report shows it (control characters escaped).
    public static func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return SyncReport.printable(text.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    // MARK: - Same vault?

    /// `vaultId` (a UUID, lowercased) and `format` of a manifest; nil if it is not one.
    public static func manifestFields(_ data: Data) -> (vaultId: String, format: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["vaultId"] as? String, let uuid = UUID(uuidString: id) else { return nil }
        let format = (obj["format"] as? String).map { SyncReport.printable(String($0.prefix(64))) }
        return (uuid.uuidString.lowercased(), format)
    }

    func checkSameVault(_ remoteRoot: [String: RemoteEntry]) throws {
        guard remoteRoot[Vault.manifestName] != nil,
              let local = try? localMutable(Vault.manifestName),
              let localId = Self.manifestFields(local)?.vaultId else { return }
        let fetched = try transport.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes)
        fetchedManifest = fetched
        let remote = fetched.data
        guard let remoteId = Self.manifestFields(remote)?.vaultId else {
            // A mirror is repaired from the local manifest; a two-way sync has nothing to compare.
            if options.pushOnly { return }
            throw SyncError.malformedResponse("remote vault.json is not a vault manifest")
        }
        if localId != remoteId { throw SyncError.vaultMismatch(local: localId, remote: remoteId) }
    }

    // MARK: - Mutable files

    /// The local file `name` under the vault root, nil when absent. Present
    /// but unreadable or oversized is an error, not "absent".
    /// True when this device's trust store keeps no record of the vault `local` names: a join not confirmed yet.
    func joinUnconfirmed(_ local: Data) -> Bool {
        guard let store = options.epochTrust, let m = try? EpochManifest.parse(local) else { return false }
        return ((try? store.record(for: m.vaultId)) ?? nil) == nil
    }

    func localMutable(_ name: String) throws -> Data? {
        let url = root.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path)
            ? try BoundedRead.contents(of: url, maxBytes: BoundedRead.maxManifestBytes) : nil
    }

    func syncMutable(_ name: String, remote: RemoteEntry?) throws {
        // A later epoch seen on another target whose record has arrived since is taken first (KH4).
        if name == Vault.manifestName { try takeSettledSightings() }
        defer { if name == Vault.manifestName { applyDetachedHolds() } }
        let local = try localMutable(name)
        let record = state.mutable[name]

        guard let local else {
            guard let remote else { return }
            try pullMutable(name, remote: remote)
            return
        }
        let localHash = FileDigest.sha256(local)

        guard let remote else {
            if name == Vault.manifestName { refreshDetachedSightings(nil); applyDetachedHolds() }
            // Never on the server, or wiped there: (re)create it, never overwriting.
            try push(name, local, condition: .create)
            try recordMutable(name, hash: localHash)
            return
        }

        let (remoteData, getETag) = try fetchMutable(name)
        try budget.downloaded(remoteData.count)
        let remoteHash = FileDigest.sha256(remoteData)
        let stamp = remote.etag ?? getETag ?? remote.lastModified
        if name == Vault.manifestName {
            remoteManifestData = remoteData
            targetEpochId = Self.epochOf(remoteData)?.epochId
            refreshDetachedSightings(remoteData)
            applyDetachedHolds()
        }
        if remoteHash == localHash {
            state.mutable[name] = .init(hash: localHash, stamp: stamp)
            return
        }
        // A joining device's approval (design §6.2 step 3): taken, whatever moved since the last run.
        if name == Vault.manifestName, vault == nil,
           Vault.isJoinApproval(remoteData, local: local, identities: options.firstPullIdentities, unconfirmed: joinUnconfirmed(local)) {
            return try accept(name, remoteData, stamp: stamp)
        }
        // Another epoch on the remote (KH4): judged by the device-change rules, never by which side moved.
        if name == Vault.manifestName, Self.otherEpochs(local, remoteData) {
            return try syncManifestAcrossEpochs(local: local, remoteData: remoteData, stamp: stamp,
                                                etag: remote.etag ?? getETag)
        }
        let localChanged = record.map { $0.hash != localHash } ?? true
        let remoteChanged = record.map { $0.hash != remoteHash } ?? true
        switch (localChanged, remoteChanged) {
        case (false, _):
            // Only the server moved on: take it (an atomic replace, the one in-place write sync makes).
            try accept(name, remoteData, stamp: stamp)
        case (true, false):
            try replaceUnchanged(name, local: local, localHash: localHash, etag: remote.etag ?? getETag)
        case (true, true):
            try bothChanged(name, local: local, remoteData: remoteData, stamp: stamp, record: record)
        }
    }

    /// Both sides changed a mutable file since the last sync (or there is no record).
    private func bothChanged(_ name: String, local: Data, remoteData: Data, stamp: String?,
                             record: SyncState.MutableRecord?) throws {
        if name == Vault.manifestName && EpochManifest.sameExceptLabel(local, remoteData) {
            // Only the display label differs: the same vault (format.md §1.3). The server's copy is
            // the one every device shares, so it stays, as iCloud Drive's current version does.
            return try accept(name, remoteData, stamp: stamp)
        }
        if name == Vault.manifestName, let vault {
            // One writer (design §5.1): two versions of one epoch are home's, one after the other, and the
            // newer one's list holds the older one's. The newer stays, on both sides; anything else is a
            // conflict, never merged.
            if vault.laterVersion(remoteData) != nil { return try accept(name, remoteData, stamp: stamp) }
            if let remote = try? EpochManifest.parse(remoteData), vault.isLaterVersion(vault.manifest, of: remote) {
                // Over the copy read this round (`push` makes it conditional on that copy).
                try push(name, local, condition: .unconditional)
                return try recordMutable(name, hash: FileDigest.sha256(local))
            }
        }
        try conflict(name, remote: remoteData,
                     detail: record == nil ? "both sides differ and there is no common ancestor" : "changed on both sides since the last sync")
    }

    /// How many rounds `syncMutableFiles` makes over a mutable file whose upload the server refused because its
    /// copy moved on since it was read (`MutableLockScope.swift`).
    static let stampRetries = 3

    /// Uploads a mutable file this side changed over a server copy that did not change since the last sync,
    /// made once the write lock is released and only if the server still holds that copy (`If-Match`; a server
    /// with no strong token has it read again and compared first, see `flushDeferredUploads`). A copy that
    /// moved on is refused there and judged again in the next round, by its bytes: only different bytes are a
    /// change on the server (then both sides changed: `bothChanged`).
    private func replaceUnchanged(_ name: String, local: Data, localHash: String, etag: String?) throws {
        try push(name, local, condition: Self.replaceCondition(etag: etag))
        try recordMutable(name, hash: localHash)
    }

    /// GETs a mutable file, or takes the copy `checkSameVault` fetched
    /// moments ago in this run (once).
    func fetchMutable(_ name: String) throws -> (data: Data, etag: String?) {
        if name == Vault.manifestName, let fetched = fetchedManifest {
            fetchedManifest = nil
            return fetched
        }
        if let fetched = mutablePrefetch.removeValue(forKey: name) { return fetched }
        guard !deferringUploads else { throw SyncError.io("internal: \(name) was not read before the write lock") }
        return try transport.read([name], maxBytes: Self.maxMutableReadBytes)
    }

    private func pullMutable(_ name: String, remote: RemoteEntry) throws {
        let (data, etag) = try fetchMutable(name)
        try budget.downloaded(data.count)
        try accept(name, data, stamp: remote.etag ?? etag ?? remote.lastModified)
    }

    func accept(_ name: String, _ data: Data, stamp: String?, judged: Bool = false) throws {
        try requireLocalWrite("write \(name)")
        if name == Vault.manifestName, !judged {
            // Never let a list nobody with the key wrote replace ours (design §4.3, §5.1). A joining device takes the
            // approval that lists it (design §6.2 step 3; it confirms it with the reply words before any write).
            let local = try localMutable(name)
            let joining = vault == nil && local.map {
                Vault.isJoinApproval(data, local: $0, identities: options.firstPullIdentities, unconfirmed: joinUnconfirmed($0))
            } == true
            if !joining, let why = Vault.incomingManifestProblem(data, local: local, vault: vault) {
                report.rejected.append(.init(path: name, message: SyncReport.printable(why)))
                return
            }
        }
        report.downloaded.append(name)
        guard !options.dryRun else { return }
        try LocalFS.write(data, to: root.appendingPathComponent(name), replacing: true)
        state.mutable[name] = .init(hash: FileDigest.sha256(data), stamp: stamp)
    }

    /// The precondition for replacing a server copy that was just fetched
    /// and compared with the record: `If-Match` with its strong ETag, or
    /// none. A weak ETag never matches `If-Match` (RFC 9110 §13.1.1), so
    /// sending one would fail every time.
    static func replaceCondition(etag: String?) -> PutCondition {
        guard let etag, isStrong(etag) else { return .unconditional }
        return .replace(etag: etag)
    }

    /// Uploads a mutable file, in the rounds of `syncMutableFiles`: under the write lock it is recorded
    /// (`deferredUploads`) and made once the lock is released. An upload without a precondition of its own
    /// (a weak or missing token) is made against the copy this round read: `If-Match` on that copy's strong
    /// token, or, with none, after reading the server's file again and finding the same bytes.
    func push(_ name: String, _ data: Data, condition: PutCondition) throws {
        if name == Vault.manifestName, let records = remoteEpochRecords, let m = try? EpochManifest.parse(data),
           !records.contains(String(m.epochRecord.dropFirst(Vault.epochsName.count + 1))) {
            // Its record did not reach the target (the epoch step reported why): vault.json waits for it.
            report.skipped.append(.init(path: name, message: "not uploaded: its device-change record \(m.epochRecord) is not "
                + "on the target yet"))
            return
        }
        if name == Vault.manifestName, epochHold != nil {
            // Waiting for a device change, or unlisted (design §4.3, §5.5): this device's vault.json is not spread.
            report.skipped.append(.init(path: name, message: "not uploaded while a device change is not verified here"))
            return
        }
        if options.dryRun { report.uploaded.append(name); return }
        if name == Vault.manifestName, (try? EpochManifest.parse(data))?.reencryptPending != nil, !queueJournal(for: data) {
            // Its re-encryption journal is not on the target and cannot be put there (design §7.1 step 6(a)): it waits.
            report.skipped.append(.init(path: name, message: "not uploaded: the re-encryption journal it binds is not on the "
                + "target yet"))
            return
        }
        guard deferringUploads else { throw SyncError.io("internal: \(name) uploaded outside the write-lock rounds") }
        var condition = condition
        var verifyHash: String?
        if condition == .unconditional, let seen = mutableSeen[name] {
            if let etag = seen.etag, Self.isStrong(etag) { condition = .replace(etag: etag) } else { verifyHash = seen.hash }
        }
        deferredUploads.append(DeferredUpload(name: name, data: data, condition: condition, verifyHash: verifyHash))
    }

    /// Runs `apply` (a report entry for a file the run replaced) once the file's deferred upload has succeeded;
    /// at once when none is pending for it.
    func afterUpload(_ name: String, _ apply: @escaping () -> Void) {
        guard let i = deferredUploads.lastIndex(where: { $0.name == name }) else { return apply() }
        let before = deferredUploads[i].afterUpload
        deferredUploads[i].afterUpload = { before?(); apply() }
    }

    func recordMutable(_ name: String, hash: String) throws {
        guard !options.dryRun else { return }
        if deferringUploads {
            // Recorded when the upload is made (its stamp is the server's after it).
            if let i = deferredUploads.lastIndex(where: { $0.name == name }) { deferredUploads[i].recordHash = hash }
            return
        }
        let entry = try transport.stat([name])
        state.mutable[name] = .init(hash: hash, stamp: entry?.stamp)
    }

    func conflict(_ name: String, remote: Data, detail: String) throws {
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
        if let notes = rootEntries.first(where: { $0.name == Vault.notesName && $0.isCollection }),
           folderArriving([Vault.notesName], entry: notes) {
            // Listed before its folders (`Arrivals.swift`): no note is judged this run.
            notesNotReadable.formUnion(try localNoteIDs())
            return [:]
        }
        guard rootEntries.contains(where: { $0.name == Vault.notesName && $0.isCollection }),
              let dirs = try transport.list([Vault.notesName]) else { return [:] }
        try budget.list(dirs.count)
        madeCollections.formUnion([[], [Vault.notesName]])
        let noteDirs = dirs.filter { $0.isCollection && Vault.isNoteDirectoryName($0.name) }.count
        if noteDirs > options.limits.maxNotes {
            throw SyncError.limitExceeded("the server lists \(noteDirs) notes, more than \(options.limits.maxNotes) (--max-notes)")
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
            if folderArriving([Vault.notesName, d.name], entry: d) {
                // Listed before its files: nothing is judged for it until they arrive (`Arrivals.swift`).
                notesNotReadable.insert(d.name)
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
        // A check of a big vault compares a sample with the tree, and takes the rest from it when they agree.
        var sampled: [String: Result<[RemoteEntry]?, Error>] = [:]
        if mode == .verify, let tree = notesTree, toList.count > Self.verifySample {
            let sample = sampleForCheck(toList, tree: tree)
            let check = try checkSample(sample.sorted(), tree: tree)
            sampled = check.results
            if check.agreed, notesNotReadable.isEmpty {
                if !options.dryRun { state.treeListing = .init(supported: true, verifiedAt: options.now) }
                treeMode = .use
                skipsUnchangedNotes = false
            }
        }
        let fromTree = treeMode == .use
        var rest = toList
        for (name, result) in sampled.sorted(by: { $0.key < $1.key }) {
            rest.removeAll { $0 == name }
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
        if fromTree, let tree = notesTree {
            for name in rest {
                let entries = tree[[name]] ?? []
                out[name] = entries
                exists(name, entries)
                if entries.contains(where: { $0.name == Vault.attachmentsName && $0.isCollection }) {
                    attListings[name] = .success(tree[[name, Vault.attachmentsName]] ?? [])
                }
            }
            updateProgress { $0.notesListed += rest.count }
            return out
        }
        // One PROPFIND per folder, `concurrency` at a time.
        let listed = try listConcurrently(rest.map { [Vault.notesName, $0] }, notes: true)
        for (name, result) in zip(rest, listed) {
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

    /// The revisions of a note whose deletion this device settled with the
    /// remote as thinning before (`SyncState.thinned`), as the run started.
    func thinnedRevisions(_ id: String) -> Set<RevisionName> {
        options.pushOnly ? [] : Set((thinnedFiles[id] ?? []).compactMap(RevisionName.init))
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
        // Settled here as thinning before, and back on one side only: judged below, never copied first.
        let thinned = thinnedRevisions(id)

        let newLocal = L.subtracting(R).subtracting(S)
        let newRemote = R.subtracting(L).subtracting(S)
        let backLocal = newLocal.intersection(thinned)
        let backRemote = newRemote.intersection(thinned)
        let remoteDeleted = L.subtracting(R).intersection(S)
        let localDeleted = R.subtracting(L).intersection(S)

        func attempt(_ n: RevisionName, _ body: () throws -> Void) throws {
            do { try body() } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "notes/\(key(id, n))", message: Self.describe(error)))
            }
        }

        // The prefetch made these already (`prefetchDownloads`); one it placed is in L by now.
        for n in newRemote.subtracting(backRemote).sorted() where !prefetched.contains(key(id, n)) {
            try attempt(n) { if try download(id, n, entry: entries[n]) { L.insert(n) } }
        }
        for n in newLocal.subtracting(backLocal).sorted() {
            // Set aside here (design §5.8): never uploaded, so it is placed nowhere else.
            if heldAside("notes/\(key(id, n))") { continue }
            // The pre-upload pass may have made it already (`preuploadNewFiles`), or tried and reported it.
            switch preuploadOutcome(id, key(id, n)) {
            case .uploaded: R.insert(n)
            case .failed: break
            case .notTried: try attempt(n) { try upload(id, n); R.insert(n) }
            }
        }
        // Thinned here before and back on the server: fetched to be judged with its content (below).
        var fetchedBack = Set<RevisionName>()
        if vault != nil {
            for n in backRemote.sorted() {
                try attempt(n) { if try download(id, n, entry: entries[n]) { L.insert(n); fetchedBack.insert(n) } }
            }
        }

        // Read (decrypted, decoded) only when a deletion is judged or a shared
        // snapshot's coverage is not recorded yet; once, after the transfers
        // above, as before. An unchanged note is never read.
        lazy var loaded: LoadedNote? = loadForSync(id)
        let epoch = Date(timeIntervalSince1970: 0)
        /// Remembers a deletion settled as thinning (`SyncState.thinned`).
        func settleThinned(_ n: RevisionName, included: Included?) {
            guard !options.dryRun else { return }
            state.thinned = state.thinned ?? [:]
            state.thinned?[key(id, n)] = SyncState.FileRecord(included: n.kind == .snapshot ? included : nil)
        }

        // The other side deleted these: delete here only if compaction allows it, else put them back.
        // A compaction there kept its covering snapshot there, so only snapshots the server
        // listed count as cover; an emptied or recreated remote folder deletes nothing here.
        if !remoteDeleted.isEmpty {
            let explained = loaded.map { explainedDeletions(remoteDeleted, of: $0, coverOn: remoteListed) } ?? []
            let readable = Set(loaded?.revisions.map(\.name) ?? [])
            for n in remoteDeleted.sorted() {
                try attempt(n) {
                    let allowed = explained.contains(n)
                    if allowed {
                        report.deleted.append(.init(side: "local", path: "notes/\(key(id, n))"))
                        try requireLocalWrite("delete notes/\(key(id, n))")
                        if !options.dryRun { try LocalFS.remove(dir.appendingPathComponent(n.filename)) }
                        L.remove(n)
                        settleThinned(n, included: loaded?.revisions.first { $0.name == n }.flatMap(SnapshotCoverage.init)?.included)
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
                        if !options.dryRun { try transport.delete([Vault.notesName, id, n.filename]) }
                        report.deleted.append(.init(side: "remote", path: "notes/\(key(id, n))"))
                        R.remove(n)
                        settleThinned(n, included: state.files[key(id, n)]?.included)
                    } else if try download(id, n, entry: entries[n]) {
                        L.insert(n)
                    }
                }
            }
        }

        // Thinned before and back on one side only: another device, or another remote through a
        // device that bridges both, brought it back (design §5.4). Copying it would undo a deletion
        // this pair already settled, and with two bridges on the same two remotes the deletion and
        // the copy chase each other for ever. So it is judged again, with its content, over every
        // revision both sides hold (one back on the server is fetched first), under the same rules
        // as any deletion judged here: a snapshot both sides hold covers it, it is never a
        // checkpoint or the created anchor, every complete checkpoint stays complete, and nothing
        // is judged in a note with an unreadable revision. Explained: deleted wherever it is.
        // Otherwise it is an ordinary file again, copied to the side that lacks it.
        if !backLocal.isEmpty || !backRemote.isEmpty {
            var back = backLocal.union(fetchedBack)
            if vault == nil {
                for n in backLocal.union(backRemote).sorted() {
                    report.skipped.append(.init(path: "notes/\(key(id, n))", message: "thinned before and back on "
                        + (L.contains(n) ? "this side" : "the server") + "; cannot check it against compaction (vault not unlocked)"))
                }
                back = []
            }
            let held = Set(loaded?.revisions.map(\.name) ?? [])
            let explained = loaded.map { explainedDeletions(back, of: $0, coverOn: R.subtracting(back)) } ?? []
            for n in back.sorted() {
                try attempt(n) {
                    if explained.contains(n) {
                        report.deleted.append(.init(side: "local", path: "notes/\(key(id, n))"))
                        try requireLocalWrite("delete notes/\(key(id, n))")
                        if !options.dryRun { try LocalFS.remove(dir.appendingPathComponent(n.filename)) }
                        L.remove(n)
                        if R.contains(n) {
                            if !options.dryRun { try transport.delete([Vault.notesName, id, n.filename]) }
                            report.deleted.append(.init(side: "remote", path: "notes/\(key(id, n))"))
                            R.remove(n)
                        }
                    } else if !held.contains(n) {
                        report.skipped.append(.init(path: "notes/\(key(id, n))", message: "thinned before and back; unreadable here, kept"))
                    } else {
                        if !options.dryRun { state.thinned?[key(id, n)] = nil }
                        if !R.contains(n) { try upload(id, n); R.insert(n) }
                    }
                }
            }
        }

        // Both sides hold the path, with other bytes (design §5.4 step 4): the accepted copy replaces an
        // unaccepted one, after it is set aside (KH4, `EpochSync.swift`).
        for n in L.intersection(R).sorted() {
            try attempt(n) { try replaceUnacceptedRevision(id, n, entry: entries[n], recordedShared: S.contains(n)) }
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
            // The target's version tag when both sides were last known equal: moved on only when this run
            // established that (a comparison or a replacement); a first sighting takes the listing's.
            let (rewritten, placed) = locked { (remoteRewritten.contains(k), placedShas[k]) }
            let old = state.files[k]
            let stamp = rewritten ? nil : (placed != nil ? entries[n]?.stamp : (old?.stamp ?? entries[n]?.stamp))
            state.files[k] = SyncState.FileRecord(included: coverage[n] ?? old?.included, sha256: placed ?? old?.sha256,
                                                  stamp: stamp)
            // In step on both sides again: no longer a settled deletion.
            state.thinned?[k] = nil
        }
        for n in S where !L.contains(n) && !R.contains(n) { state.files[key(id, n)] = nil }
        if L.isEmpty && R.isEmpty { for n in thinned { state.thinned?[key(id, n)] = nil } }
        if state.thinned?.isEmpty == true { state.thinned = nil }
    }

    /// Which of `names` (revisions of the note that `loaded` holds) a compactor
    /// or thinner of this format could have deleted, given the snapshots among
    /// `loaded`'s revisions that the other side holds (`coverOn`): format.md
    /// §5.3, §5.8.4; security review 2026-10, stage 4, S2. Never a checkpoint
    /// or the created anchor, every complete checkpoint still complete
    /// afterwards (its positioned snapshots and witnesses kept), and nothing
    /// judged from a note with an unreadable revision. Their age is not judged:
    /// thinning everything except checkpoints is a legitimate action.
    func explainedDeletions(_ names: Set<RevisionName>, of loaded: LoadedNote,
                            coverOn other: Set<RevisionName>) -> Set<RevisionName> {
        guard loaded.failures.isEmpty, !names.isEmpty else { return [] }
        let epoch = Date(timeIntervalSince1970: 0)
        let onOther = loaded.revisions.filter { other.contains($0.name) }.compactMap(SnapshotCoverage.init)
        var coverage: [RevisionName: SnapshotCoverage] = [:]
        for r in loaded.revisions { if let c = SnapshotCoverage(r) { coverage[c.name] = c } }
        let readable = Set(loaded.revisions.map(\.name))
        let protected = CompactionPlanner.neverDeleted(loaded.revisions)
        var explained = Set<RevisionName>()
        for n in names where readable.contains(n) && !protected.contains(n) {
            var snaps = onOther
            if var own = coverage[n] { own.wall = epoch; snaps.append(own) }
            if CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps,
                                           retention: 0, now: options.now).contains(n) {
                explained.insert(n)
            }
        }
        return CompactionPlanner.deletionKeepsCheckpoints(explained, from: loaded.revisions, now: options.now) ? explained : []
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
        let current = try? transport.read([WebIndex.fileName], maxBytes: WebIndex.maxBytes).data
        if current == data {
            state.webIndex = remote?.etag.flatMap { Self.isStrong($0) ? .init(hash: hash, etag: $0) : nil }
            return
        }
        state.webIndex = nil
        guard try transport.write([WebIndex.fileName], .data(data), condition: .unconditional) else { return }
        report.uploaded.append(WebIndex.fileName)
        // The ETag of what was just written (a PUT need not return one); the next run compares it.
        if let etag = (try? transport.stat([WebIndex.fileName]))??.etag, Self.isStrong(etag) {
            state.webIndex = .init(hash: hash, etag: etag)
        }
    }

    /// An ETag that changes whenever the bytes do (RFC 9110 §8.8.1); a weak
    /// one (`W/"…"`) need not. The same rule for every remote's version
    /// tokens (`SyncRemote.swift`).
    public static func isStrong(_ etag: String) -> Bool { !etag.hasPrefix("W/") && !etag.isEmpty }

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
        if revisionsHeldBack(id) {
            throw SyncError.io("\(path) not uploaded in this run: an attachment of its note did not upload "
                + "(format.md §8.1.4 step 4); the next run sends both")
        }
        guard !options.dryRun else { locked { report.uploaded.append(path) }; return }
        let data = try BoundedRead.contents(of: root.appendingPathComponent("notes/\(id)/\(n.filename)"),
                                            maxBytes: options.maxFileBytes)
        try ensureCollection([Vault.notesName, id])
        // A 412 means the server already has it: write-once, so it is the same file.
        try transport.write([Vault.notesName, id, n.filename], .data(data), condition: .create)
        locked { report.uploaded.append(path); placedShas[key(id, n)] = FileDigest.sha256(data) }
        if Self.epochMutations.contains(.pruneLedgerOnUpload), let ledger = vault?.ledger, let entries = try? ledger.entries() {
            try? ledger.remove(entries.filter { $0.path == path })
        }
    }

    /// True when this run must not upload `id`'s revisions (`blobsHeldBack`).
    func revisionsHeldBack(_ id: String) -> Bool {
        if locked({ blobsHeldBack.contains(id) }) { return true }
        // The server's `att/` listing failed: no blob of this note is sent in this run.
        if case .failure? = locked({ attListings[id] }), !(localBlobNames(id) ?? []).isEmpty { return true }
        return false
    }

    /// Downloads a revision, checks it (format.md §9.1) and places it.
    /// Returns false when it was not placed: it appeared locally in the
    /// meantime, or it failed a check and was quarantined (reported in
    /// `quarantined`), or an earlier run quarantined it (in `skipped`).
    func download(_ id: String, _ n: RevisionName, entry: RemoteEntry?) throws -> Bool {
        try requireLocalWrite("download notes/\(key(id, n))")
        let path = "notes/\(key(id, n))"
        let size = entry?.size
        if let size, size > options.maxFileBytes { throw SyncError.responseTooLarge(path: path, limit: options.maxFileBytes) }
        if skipQuarantined(key(id, n), path: path, entry: entry) || skipPendingEpoch(key(id, n), path: path, entry: entry) {
            return false
        }
        // Listed but not downloaded by its provider yet: asked for, waited for a while, else left for later.
        let remotePath = [Vault.notesName, id, n.filename]
        if try !available(remotePath, entry: entry) { return false }
        let reserved = try locked { try budget.willDownload(size) }
        guard !options.dryRun else {
            locked { budget.release(reserved); report.downloaded.append(path) }
            return true
        }
        let data: Data
        do {
            data = try transport.read(remotePath, maxBytes: options.maxFileBytes).data
        } catch {
            locked { budget.release(reserved) }
            if Self.isUnavailable(error) {
                noteArriving(remotePath)
                return false
            }
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
            throw SyncError.responseTooLarge(path: path, limit: options.maxFileBytes)
        }
        var problem: IncomingFileProblem?
        if !data.starts(with: Self.ageMagic) {
            problem = IncomingFileProblem("not an age file")
        } else if let checker = checker(), let uuid = UUID(uuidString: id) {
            do { try checker.checkIncomingRevision(data, noteId: uuid, name: n) } catch let e as IncomingFileProblem {
                problem = e
            } catch {
                problem = IncomingFileProblem("\(error)")
            }
        }
        if let problem {
            // Set aside (an old key the acceptance rule does not take), pending (its record has not arrived),
            // or quarantined (format.md §9.1; key-hierarchy design §5.3).
            refuseIncoming(key(id, n), path: path, entry: entry, problem: problem, data: data)
            return false
        }
        locked { state.quarantined?[key(id, n)] = nil; state.pendingEpoch?[key(id, n)] = nil }
        let url = root.appendingPathComponent("notes/\(id)/\(n.filename)")
        if try !LocalFS.write(data, to: url, replacing: false) { return false }
        locked { report.downloaded.append(path); placedShas[key(id, n)] = FileDigest.sha256(data) }
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
        switch try transport.makeCollection(path) {
        case .created, .exists: break
        case .missingParent:
            guard !path.isEmpty else {
                try transport.createBase()
                break
            }
            try ensureCollection(Array(path.dropLast()))
            _ = try transport.makeCollection(path)
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
