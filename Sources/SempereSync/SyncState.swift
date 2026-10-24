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
    /// Remote files and folders a provider listed but had not downloaded,
    /// keyed by their path (`notes/<id>/<name>`; a folder's ends with `/`), with
    /// when this device first found them so (`Arrivals.swift`): the bound on
    /// how long they count as arriving.
    var arriving: [String: Date]?

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
    /// The epoch (id, hex) and local `epochs/` names (a digest) whose working copy this device last scanned for
    /// files the acceptance rule no longer takes (`Vault.setAsideScan`): once per epoch and record set, whoever made
    /// the change (KH4).
    var scannedEpoch: String?
    /// Set when this device's `vault.json` replaced the target's of another epoch (a branch its chain beats, or a
    /// refused one): until a complete run over every note, each revision both sides hold is read and compared, as
    /// the losing branch's devices may have replaced accepted copies there (design §5.4 step 4; KH4).
    var compareShared: Bool?
    /// Epoch records on the target whose bytes this device checked against the hash a `vault.json` or a record
    /// above names, with the version tag they had then: read again only when it moves (review of #86, M1).
    var verifiedRecords: [String: String]?
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
        try LocalFS.write(try enc.encode(self), to: url, replacing: true)
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
