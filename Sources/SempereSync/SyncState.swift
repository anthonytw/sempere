import Crypto
import Foundation
import Sempere

/// What the last successful sync left behind, so the next one can tell which
/// side changed. It lives outside the vault (default `$XDG_STATE_HOME/sempere/sync/`)
/// and holds no secrets: file names, hashes, ETags and snapshot coverage.
struct SyncState: Codable, Equatable {
    /// Last-synced version of a mutable file.
    struct MutableRecord: Codable, Equatable {
        /// SHA-256 (hex) of the content both sides had.
        var hash: String
        /// The remote ETag (else Last-Modified) at that time.
        var stamp: String?
        /// Compared again from then on even when neither side changed (a device's own summaries file left
        /// behind a later copy: re-sealed once that copy is older than the window, format.md §12.5).
        var recheckAfter: Date? = nil
        /// Published summaries only: when `stamp` was first recorded, and whether it settled (`SyncEngine.settle`);
        /// an unchanged stamp skips the read only then. Nil: not settled.
        var timing: StampTiming? = nil
        var settled: Bool { timing?.settled == true }
    }

    /// A revision or blob file both sides had.
    struct FileRecord: Codable, Equatable {
        /// For a snapshot, what it covered, so a later compaction that removed it can be checked.
        var included: Included?
        /// For a blob the server dropped while this device holds it: when this
        /// device first found it collectable (format.md §8.1.6 rules 1–3), with
        /// every look since agreeing. The deletion is followed here only once
        /// that is `blobRetention` ago (rule 4; `BlobSync.swift`).
        var unreferencedSince: Date?
        /// SHA-256 (hex) of the bytes both sides held when this device last knew them equal (an upload, a
        /// download, a comparison): a local copy with other bytes since (a catch-up's re-encryption) is
        /// compared with the remote's, and the accepted one replaces an unaccepted one (key-hierarchy design
        /// §5.4 step 4). Nil in older state files and for blobs.
        var sha256: String?
        /// The target's version tag (`RemoteEntry.stamp`) of a revision when this device last knew both sides
        /// equal: another one means the target's copy was replaced since, and it is compared (KH4, review of #86).
        var stamp: String?
    }

    /// A blob download that was interrupted: its partial file
    /// (`att/.sempere-tmp-part-<name>`) continues only from the same remote
    /// version.
    struct PartialRecord: Codable, Equatable {
        /// The ETag the download started from (sent as `If-Range`).
        var etag: String
    }

    var version = 1
    var mutable: [String: MutableRecord] = [:]
    /// Keyed `<noteId>/<file name>` for revisions and
    /// `<noteId>/att/<file name>` for blobs.
    var files: [String: FileRecord] = [:]
    /// Revisions whose deletion this device settled with this remote as a
    /// compaction or thinning (explained: docs/io.md "Compaction deletes")
    /// and that neither side has held since, keyed like `files` (a
    /// snapshot's record keeps its coverage). When one comes back on one side
    /// only (another device or remote brought it back), it is deleted again
    /// there if it is still explained, never copied to the other side
    /// (docs/design/device-first-sync.md §5.4). Nil in older state files.
    var thinned: [String: FileRecord]?
    /// Interrupted blob downloads, keyed `<noteId>/att/<file name>`.
    var partials: [String: PartialRecord] = [:]
    /// Temporary upload names (paths below the collection) this device
    /// created on the server and has not removed yet; the next run deletes them.
    var remoteTemps: [String] = []
    /// SHA-256 (hex) of the server listing (`sempere-index.json` bytes, then
    /// 0 and the manifest's sealed vault secret) the server's published
    /// summaries were last written for by this device,
    /// when every note there got an entry (else nil: try again next run).
    var publishedSummaries: String?
    /// Remote files an earlier run downloaded and quarantined (format.md
    /// §9.1), keyed like `files`: not downloaded again while the server's
    /// copy and the local `vault.json` are unchanged.
    var quarantined: [String: QuarantineRecord]?
    /// The server's `sempere-index.json` as this device last wrote or
    /// matched it; nil until it was.
    var webIndex: WebIndexRecord?

    /// Per note folder on the server, the ETag it had when the last run
    /// left the note unchanged and in step on both sides (`NoteStamps.swift`).
    var notes: [String: NoteStamp] = [:]
    /// Note folders this device wrote a revision into, with their ETag from
    /// before: the next run checks the server changed it.
    var stampProbes: [String: String] = [:]
    /// Whether the server was seen to change a note folder's ETag when a
    /// revision was written into it (true), or seen not to (false, for
    /// good); nil until a write was checked.
    var folderETagsChange: Bool?
    /// When a run last listed every note folder.
    var lastFullListing: Date?
    /// Whether the server answers `PROPFIND` `Depth: infinity` on `notes/`
    /// in full (`TreeListing.swift`); nil until a run checked.
    var treeListing: TreeListingRecord?
    /// Where runs that list the note folders in batches got to (`BatchedListing.swift`, offline audit P7): the next one
    /// goes on from there. Nil while the note folders are listed in one go.
    var listingPass: ListingPass?
    /// Large blob uploads a connection window cut short (`LargeUploads.swift`, offline audit P3). Nil: none.
    var largeUploads: LargeUploadRecord?

    /// A sweep over the note folders in batches, across runs (offline audit P7).
    struct ListingPass: Codable, Equatable {
        /// The last note (by id) of the sweep's sorted order that a run synced; nil: the sweep starts at the first.
        var cursor: String?
        /// When the sweep started (`SyncOptions.now` of its first run).
        var started: Date
        /// Every note folder was listed in it, none failed: once it reaches the end, it counts as a full listing
        /// (`lastFullListing`, for `skipUnchangedNotes`).
        var clean: Bool
        /// True when only runs that skipped unchanged folders made it unclean (a run that lists them all then starts
        /// a new sweep); false once a listing failed in it.
        var skipRun: Bool? = nil
    }

    /// What recent runs learned about large uploads (offline audit P3).
    struct LargeUploadRecord: Codable, Equatable {
        /// The smallest blob whose upload a window cut short since a larger one went through: later runs send blobs
        /// this large last, and leave those of 1 MiB or more for a longer run.
        var cutAt: Int?
        /// When (`SyncOptions.now`) the last cut was recorded: one older than a day is forgotten.
        var cutWhen: Date?
        /// Runs in a row that left a large blob for a longer one: at `SyncEngine.largeRetryAfter`, a run tries them anyway.
        var deferredRuns = 0

        init(cutAt: Int? = nil, cutWhen: Date? = nil, deferredRuns: Int = 0) {
            self.cutAt = cutAt; self.cutWhen = cutWhen; self.deferredRuns = deferredRuns
        }

        /// Every field may be missing (a writer that leaves one out reads as its default).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cutAt = try c.decodeIfPresent(Int.self, forKey: .cutAt)
            cutWhen = try c.decodeIfPresent(Date.self, forKey: .cutWhen)
            deferredRuns = try c.decodeIfPresent(Int.self, forKey: .deferredRuns) ?? 0
        }
    }
    /// Remote files and folders a provider listed but had not downloaded,
    /// keyed by their path (`notes/<id>/<name>`; a folder's ends with `/`), with
    /// when this device first found them so (`Arrivals.swift`): the bound on
    /// how long they count as arriving.
    var arriving: [String: Date]?
    /// When the last run of this pair ended (its `SyncOptions.now`): a longer gap before the next one (the device
    /// asleep, offline) is not counted toward an arrival stall (`Arrivals.swift`, offline audit P5).
    var lastRun: Date?
    /// Join requests (`joins/`, format.md §15.12) by file name: how long this device has known each, on its own clock
    /// (offline audit P2). Home deletes a request once that passes 7 days, never by the joiner's `created`. The age
    /// grows by the time between two runs that see it, and never shrinks: a clock that goes back (a device without a
    /// clock of its own that boots into the past) only pauses it (review of #90, N3).
    var joinsSeen: [String: JoinSighting]?

    struct JoinSighting: Codable, Equatable {
        /// Seconds known so far.
        var age: TimeInterval
        /// The clock at the last run that saw it.
        var last: Date
    }

    /// Capture inbox files (format.md §11) both sides held at the end of the
    /// last run, keyed by file name: a file one side lacks since is deleted on
    /// the other only when adoption explains it (`InboxSync.swift`). Nil in
    /// older state files and when there were none.
    var inbox: [String: InboxRecord]?
    /// Per-device published summaries (`summaries/<device>.sealed`, format.md
    /// §12.5) as both sides held them at the end of the last run, keyed by file
    /// name (`DeviceSummariesSync.swift`). Nil in older state files.
    var deviceSummaries: [String: MutableRecord]?
    /// Join requests (`joins/`, format.md §15.12) both sides held at the end of the last run: one a side lacks
    /// since was deleted there (home approved or expired it), and is deleted on the other (KH4).
    var joins: [String]?
    /// Notebook records (`notebooks/<name>`) whose bytes both sides held when this device last knew them
    /// equal, as `FileRecord.sha256` does for revisions (key-hierarchy design §5.4 step 4; KH4).
    var notebookShas: [String: String]?
    /// Notebook records both sides held at the end of the last run (for `UnsyncedChanges`; KH4).
    var notebookNames: [String]?
    /// `epochs/` as the last run left it in step on both sides: the remote folder's strong ETag and a digest of
    /// the local names. With `skipUnchangedNotes` on a server seen to change folder ETags, an unchanged pair is
    /// not listed again (KH4).
    var epochsStamp: EpochsStamp?
    /// Paths this device set aside that are still in place here, with the remote version they were last
    /// compared with: read again only when the remote's changes (design §5.4 step 4; KH4).
    var comparedAside: [String: String]?
    /// When each `comparedAside` entry was first compared under its version, and whether a comparison at least
    /// `SyncEngine.stampSettleInterval` later found it again: only then does an unchanged version skip the read (a tag
    /// made from the modification time in whole seconds does not move for a same-size rewrite within the second,
    /// such as the accepted copy replacing the target's; `QuarantineRecord.settled`).
    var comparedAsideTiming: [String: StampTiming]?
    /// The epoch (id, hex) and local `epochs/` names (a digest) whose working copy this device last scanned for
    /// files the acceptance rule no longer takes (`Vault.setAsideScan`): once per epoch and record set, whoever made
    /// the change (KH4).
    var scannedEpoch: String?
    /// Set when this device's `vault.json` replaced the target's of another epoch (a branch its chain beats, or a
    /// refused one): until a complete run over every note, each revision both sides hold is read and compared, as
    /// the losing branch's devices may have replaced accepted copies there (design §5.4 step 4; KH4).
    var compareShared: Bool?
    /// The shared files that pass (`compareShared`) already read and compared, by record key: a later run, cut short
    /// by a short connection window, goes on from them instead of reading the same first files again. Cleared with
    /// the flag, and when a new pass starts.
    var comparedShared: Set<String>?
    /// Epoch records on the target whose bytes this device checked against the hash a `vault.json` or a record
    /// above names, with the version tag they had then: read again only when it moves (review of #86, M1).
    var verifiedRecords: [String: String]?
    /// When each `verifiedRecords` tag was first verified, and whether it settled (`SyncEngine.settle`): only then does
    /// it skip the check (a removed device, which keeps the storage's credentials, can put junk of the same size under
    /// a record's name within the second its tag was verified here).
    var verifiedRecordsTiming: [String: StampTiming]?
    /// SHA-256 of local epoch records by name, with their size and modification time ("size:mtime|hex"): hashed
    /// again only when those move (re-check N4).
    var recordHashes: [String: String]?

    struct EpochsStamp: Codable, Equatable {
        var etag: String
        var local: String
    }
    /// Remote files that waited for a device-change record (key-hierarchy design §5.3 rule 3), keyed like
    /// `files`: the remote version and the local `epochs/` and `vault.json` they were judged against. Not
    /// downloaded again until one of them changes (KH4).
    var pendingEpoch: [String: String]?
    /// When each `pendingEpoch` entry was first judged under its version, and whether it settled: only a settled one
    /// is skipped (a whole-second version tag hides a same-size rewrite within the second, `comparedAsideTiming`).
    var pendingEpochTiming: [String: StampTiming]?
    /// Files, epoch records and passphrase copies this device deleted on the target as obsolete (below a finished
    /// re-encryption, KH6; a superseded kit's copy), by path: the SHA-256 (hex) of the bytes deleted ("" when the name
    /// fixes them: a record, a passphrase copy). The same thing uploaded again (by a removed device that never learns of
    /// its removal, its list in conflict: design §10's residual) is left, not deleted at every run: deleting it each
    /// time kept two devices changing the target for ever (sync stress seed 17).
    var deletedObsolete: [String: String]?

    /// An inbox file as both sides held it.
    struct InboxRecord: Codable, Equatable {
        /// SHA-256 (hex) of its bytes.
        var hash: String
        /// The remote's version token for it.
        var stamp: String?
        /// The local file's size and modification time then: unchanged, the
        /// local copy is not hashed again (a capture may be 256 MiB).
        var size: Int
        var modified: Double?
        /// When `stamp` was first recorded for this file, and whether a run that read the file at least
        /// `SyncEngine.stampSettleInterval` later still found it (`SyncEngine.settle`): only then does an unchanged
        /// stamp skip the read (a whole-second tag hides a same-size re-seal within the second). Nil: not settled.
        var timing: StampTiming? = nil
        var settled: Bool { timing?.settled == true }
    }

    /// What a run found about `Depth: infinity` listings.
    struct TreeListingRecord: Codable, Equatable {
        /// False once the server refused one (for good, until the state is deleted).
        var supported: Bool
        /// When a run last found the tree equal to the one-by-one listings.
        var verifiedAt: Date?
    }

    /// A note folder's recorded ETag.
    struct NoteStamp: Codable, Equatable {
        /// Its strong ETag in the `notes/` listing.
        var etag: String
        /// Whether it held an `att/` folder (listed every run regardless).
        var att: Bool
    }

    /// What the server's `sempere-index.json` held when this device last
    /// wrote it or found it current.
    struct WebIndexRecord: Codable, Equatable {
        /// SHA-256 (hex) of its bytes.
        var hash: String
        /// Its strong ETag then (a weak or missing one is never recorded).
        var etag: String
    }

    /// When a version tag was first seen standing for the same bytes, and whether it settled (`SyncEngine.settle`).
    struct StampTiming: Codable, Equatable {
        var since: Date
        var settled: Bool
        /// `ProcessInfo.systemUptime` at `since`: within one boot, the time that passed is the uptime's, so a wall
        /// clock stepped forward cannot settle a tag (`SyncEngine.settle`).
        var uptime: TimeInterval? = nil
    }

    /// A quarantined remote file.
    struct QuarantineRecord: Codable, Equatable {
        /// The remote version (ETag, else Last-Modified, else size) that failed.
        var stamp: String?
        /// SHA-256 (hex) of the local `vault.json` it was checked against,
        /// and whether the vault was unlocked: either changing checks it again.
        var manifest: String?
        var unlocked: Bool
        /// Which key checked it (`SyncEngine.checkerKeyID`: derived from the epoch id, revealing
        /// nothing): a run under another key checks it again. Nil in older records, and when locked.
        var key: String?
        /// True when the file was kept in the set-aside store rather than the quarantine (an earlier key the
        /// acceptance rule does not take, key-hierarchy design §5.3 rule 4; KH4). Nil in older records.
        var setAside: Bool?
        /// SHA-256 (hex) of the refused bytes, when (`SyncEngine.stampClock`) they were first refused under this
        /// record's fields, and whether a read at least `SyncEngine.stampSettleInterval` later found the same
        /// bytes under the same stamp. Only a settled record skips the download: a tag made from the modification
        /// time in whole seconds does not move for a same-size rewrite within the second the copy was written
        /// (an accepted copy replacing this one), and after that interval any rewrite falls in a later second.
        /// Nil in older records (read again once).
        var sha256: String? = nil
        var timing: StampTiming? = nil
        var settled: Bool { timing?.settled == true }
    }

    /// The keys of `files` grouped by note: for each note id (the key up to
    /// its first `/`), the rest of each of its keys (`<file name>` for a
    /// revision, `att/<file name>` for a blob). One pass over `files`, so a
    /// run looks a note's records up without scanning every other note's.
    func fileNamesByNote() -> [String: [String]] {
        Self.namesByNote(files.keys)
    }

    /// Keys `<noteId>/<rest>` grouped by note id, as `fileNamesByNote`.
    static func namesByNote<S: Sequence>(_ keys: S) -> [String: [String]] where S.Element == String {
        var out: [String: [String]] = [:]
        for key in keys {
            guard let slash = key.firstIndex(of: "/") else { continue }
            out[String(key[..<slash]), default: []].append(String(key[key.index(after: slash)...]))
        }
        return out
    }

    /// The default state file for one (remote, local vault) pair.
    static func defaultURL(remote: URL, vault: URL,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".local/state", isDirectory: true)
        }
        let key = remote.absoluteString + "\n" + vault.standardizedFileURL.path
        let id = Hex.encode(SHA256.hash(data: Data(key.utf8)).prefix(8))
        return base.appendingPathComponent("sempere/sync/\(id).json")
    }

    /// Nil when there is no state file; throws when it exists but is unreadable.
    static func load(_ url: URL) throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try BoundedRead.contents(of: url, maxBytes: BoundedRead.maxRevisionBytes)
        // The version first: a newer layout is refused as such, whatever its fields.
        let version = try JSONDecoder().decode(Version.self, from: data).version
        guard version == 1 else { throw SyncError.io("sync state \(url.path) has version \(version)") }
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    private struct Version: Decodable {
        var version: Int
    }

    /// Saves the whole state (atomically). Not pretty-printed: it holds a
    /// record per revision and blob of the vault.
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try LocalFS.write(try enc.encode(prunedTimings()), to: url, replacing: true)
    }

    /// The state with each timing map cut down to the entries of the map it times (`comparedAsideTiming`,
    /// `pendingEpochTiming`, `verifiedRecordsTiming`), so neither outlives the other.
    func prunedTimings() -> SyncState {
        var s = self
        func pruned<V>(_ timing: [String: StampTiming]?, by map: [String: V]?) -> [String: StampTiming]? {
            guard let timing else { return nil }
            let kept = timing.filter { map?[$0.key] != nil }
            return kept.isEmpty ? nil : kept
        }
        s.comparedAsideTiming = pruned(comparedAsideTiming, by: comparedAside)
        s.pendingEpochTiming = pruned(pendingEpochTiming, by: pendingEpoch)
        s.verifiedRecordsTiming = pruned(verifiedRecordsTiming, by: verifiedRecords)
        return s
    }

    // MARK: Transfers in flight

    /// What a run must find again if it is killed mid-transfer: the
    /// interrupted downloads and the temporary upload names. A run saves
    /// this, not the whole state, before each blob transfer, so a
    /// checkpoint costs the few entries in flight rather than a record per
    /// revision and blob; the end-of-run save carries them in the state
    /// itself and removes this file.
    struct Transfers: Codable, Equatable {
        var partials: [String: PartialRecord]
        var remoteTemps: [String]
    }

    /// `<state file>.transfers`, next to the state file.
    static func transfersURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".transfers")
    }

    /// The transfers file of `url`; nil when there is none. Throws when it
    /// exists but is unreadable.
    static func loadTransfers(_ url: URL) throws -> Transfers? {
        let t = transfersURL(url)
        guard FileManager.default.fileExists(atPath: t.path) else { return nil }
        let data = try BoundedRead.contents(of: t, maxBytes: BoundedRead.maxManifestBytes)
        return try JSONDecoder().decode(Transfers.self, from: data)
    }

    /// Saves `partials` and `remoteTemps` (atomically) to the transfers file of `url`.
    func saveTransfers(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try LocalFS.write(try enc.encode(Transfers(partials: partials, remoteTemps: remoteTemps)),
                          to: Self.transfersURL(url), replacing: true)
    }

    /// Removes the transfers file of `url`, if any.
    static func removeTransfers(_ url: URL) {
        try? FileManager.default.removeItem(at: transfersURL(url))
    }

    /// Takes in what a killed run saved: its temporary upload names are
    /// added to ours (deleting one that is gone is harmless), its partial
    /// downloads win over ours (they are newer).
    mutating func merge(_ t: Transfers) {
        for x in t.remoteTemps where !remoteTemps.contains(x) { remoteTemps.append(x) }
        partials.merge(t.partials) { _, new in new }
    }
}

extension SyncState {
    /// Whether a run with this state ever synced with the remote: `vault.json`, a file or a note recorded. A state
    /// file alone says nothing (a run that only found the folder on its way, or one that failed early, may leave one).
    var syncedBefore: Bool { mutable[Vault.manifestName] != nil || !files.isEmpty || !notes.isEmpty }

    /// The one test of "synced before" (`SyncEngine`, `FolderTargetRun.syncedBefore`), from a load of the state file:
    /// no file, false; a state, `syncedBefore`; a file that cannot be read (corrupt, over the bound, a newer layout),
    /// true: never take a target this device may have synced for a new one (its folder would be made again).
    static func syncedBefore(_ loaded: Result<SyncState?, any Error>) -> Bool {
        switch loaded {
        case .success(let s): return s?.syncedBefore ?? false
        case .failure: return true
        }
    }
}

