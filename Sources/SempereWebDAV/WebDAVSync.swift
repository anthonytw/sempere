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
    /// Where notes are summarised for that file through the summary cache
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
    let client: WebDAVClient
    let stateURL: URL
    let options: WebDAVSyncOptions
    var state = SyncState()
    var report: SyncReport
    private var madeCollections = Set<[String]>()
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

    /// Runs one sync.
    ///
    /// - Throws: `WebDAVError.vaultMismatch` before touching anything when the
    ///   two sides are different vaults; `.http`/`.transport` when the server's
    ///   root cannot be listed. Anything per file lands in the report.
    public func run() throws -> SyncReport {
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
        checkerBaseManifest = manifestHash()
        budget = RunBudget(options.limits)
        let rootEntries = try client.list([]) ?? []
        try budget.list(rootEntries.count)
        let remoteRoot = Dictionary(rootEntries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try checkSameVault(remoteRoot)
        remoteJournal = remoteRoot[Vault.journalName] != nil
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

        do {
            let remoteNotes = try listRemoteNotes(rootEntries)
            let localNotes = try localNoteIDs()
            recordedFiles = state.fileNamesByNote()
            for (id, entries) in remoteNotes {
                remoteRevisions[id] = entries.compactMap { e in
                    RevisionName(e.name).flatMap { !e.isCollection && $0.filename == e.name ? e.name : nil }
                }
            }
            for id in Set(remoteNotes.keys).union(localNotes).sorted() {
                do {
                    try budget.checkTime()
                    try syncNote(id, remoteEntries: remoteNotes[id])
                } catch {
                    try rethrowRunLimit(error)
                    report.errors.append(.init(path: "notes/\(id)", message: Self.describe(error)))
                }
            }
        } catch let e as WebDAVError where e.isRunLimit {
            // Stop here: what was done is recorded below, the next run continues.
            report.stoppedEarly = Self.describe(e)
            report.errors.append(.init(path: Vault.notesName, message: Self.describe(e)))
        }
        if options.pushOnly { deleteRemoteJunk() }
        if !options.dryRun, options.publishForWebViewer || remoteRoot[WebIndex.fileName].map({ !$0.isCollection }) ?? false {
            do { try refreshRemoteWebIndex() } catch {
                report.errors.append(.init(path: WebIndex.fileName, message: Self.describe(error)))
            }
        }
        if !options.dryRun {
            refreshRemoteSummaries(exists: remoteRoot[PublishedSummaries.fileName].map { !$0.isCollection } ?? false)
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

    private func checkSameVault(_ remoteRoot: [String: RemoteEntry]) throws {
        guard remoteRoot[Vault.manifestName] != nil,
              let local = try? localMutable(Vault.manifestName),
              let localId = WebDAVConnection.manifestFields(local)?.vaultId else { return }
        let remote = try client.get([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data
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
                report.skipped.append(.init(path: name, message: "removed locally; left on the server (sync never deletes it)"))
                return
            }
            try pullMutable(name, remote: remote)
            return
        }
        let localHash = FileDigest.sha256(local)

        guard let remote else {
            // Never on the server, or wiped there: (re)create it, never overwriting.
            if try push(name, local, condition: .create) { try recordMutable(name, hash: localHash) }
            return
        }

        let (remoteData, getETag) = try client.get([name])
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
            let condition: PutCondition = (remote.etag ?? getETag).map { .replace(etag: $0) } ?? .unconditional
            if try push(name, local, condition: condition) {
                try recordMutable(name, hash: localHash)
            } else {
                try conflict(name, remote: remoteData, detail: "the server copy changed while uploading")
            }
        case (true, true):
            try conflict(name, remote: remoteData,
                         detail: record == nil ? "both sides differ and there is no common ancestor" : "changed on both sides since the last sync")
        }
    }

    private func pullMutable(_ name: String, remote: RemoteEntry) throws {
        let (data, etag) = try client.get([name])
        try budget.downloaded(data.count)
        try accept(name, data, stamp: remote.etag ?? etag ?? remote.lastModified)
    }

    private func accept(_ name: String, _ data: Data, stamp: String?) throws {
        try requireLocalWrite("write \(name)")
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
        let noteDirs = dirs.filter { $0.isCollection && Vault.isNoteDirectoryName($0.name) }.count
        if noteDirs > options.limits.maxNotes {
            throw WebDAVError.limitExceeded("the server lists \(noteDirs) notes, more than \(options.limits.maxNotes) (--max-notes)")
        }
        var out: [String: [RemoteEntry]] = [:]
        for d in dirs {
            guard d.isCollection, Vault.isNoteDirectoryName(d.name) else {
                report.ignored.append(SyncReport.printable("notes/\(d.name)"))
                remoteJunk.append([Vault.notesName, d.name])
                continue
            }
            try budget.checkTime()
            let entries = try client.list([Vault.notesName, d.name]) ?? []
            try budget.list(entries.count)
            out[d.name] = entries
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

        for n in newRemote.sorted() { try attempt(n) { if try download(id, n, entry: entries[n]) { L.insert(n) } } }
        for n in newLocal.sorted() { try attempt(n) { try upload(id, n); R.insert(n) } }

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
            for n in remoteDeleted.sorted() {
                try attempt(n) {
                    var allowed = false
                    if loaded != nil, readable.contains(n) {
                        var snaps = onServer
                        if var own = coverage[n] { own.wall = epoch; snaps.append(own) }
                        allowed = CompactionPlanner.deletable(names: [n], wall: [n: epoch], snapshots: snaps,
                                                              retention: 0, now: options.now).contains(n)
                    }
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
                        report.deleted.append(.init(side: "remote", path: "notes/\(key(id, n))"))
                        if !options.dryRun { try client.delete([Vault.notesName, id, n.filename]) }
                        R.remove(n)
                    } else if try download(id, n, entry: entries[n]) {
                        L.insert(n)
                    }
                }
            }
        }

        // Blob deletions are judged against the revisions both sides hold now.
        try syncBlobDeletions(id, &blobs, remoteRevisions: R)

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
    private func refreshRemoteWebIndex() throws {
        let data = try WebIndex.encode(remoteRevisions)
        let current = try? client.get([WebIndex.fileName], maxBytes: WebIndex.maxBytes).data
        guard current != data else { return }
        guard try client.put([WebIndex.fileName], data, condition: .unconditional) else { return }
        report.uploaded.append(WebIndex.fileName)
    }

    func upload(_ id: String, _ n: RevisionName) throws {
        let path = "notes/\(key(id, n))"
        report.uploaded.append(path)
        guard !options.dryRun else { return }
        let data = try BoundedRead.contents(of: root.appendingPathComponent("notes/\(id)/\(n.filename)"),
                                            maxBytes: options.maxFileBytes)
        try ensureCollection([Vault.notesName, id])
        // A 412 means the server already has it: write-once, so it is the same file.
        try client.put([Vault.notesName, id, n.filename], data, condition: .create)
    }

    /// Downloads a revision, checks it (format.md §9.1) and places it.
    /// Returns false when it was not placed: it appeared locally in the
    /// meantime, or it failed a check and was quarantined (reported in
    /// `quarantined`), or an earlier run quarantined it (in `skipped`).
    private func download(_ id: String, _ n: RevisionName, entry: RemoteEntry?) throws -> Bool {
        try requireLocalWrite("download notes/\(key(id, n))")
        let path = "notes/\(key(id, n))"
        let size = entry?.size
        if let size, size > options.maxFileBytes { throw WebDAVError.responseTooLarge(path: path, limit: options.maxFileBytes) }
        if skipQuarantined(key(id, n), path: path, entry: entry) { return false }
        try budget.willDownload(size)
        report.downloaded.append(path)
        guard !options.dryRun else { return true }
        let (data, _) = try client.get([Vault.notesName, id, n.filename], maxBytes: options.maxFileBytes)
        try budget.downloaded(data.count)
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
            report.downloaded.removeLast()
            quarantine(key(id, n), path: path, entry: entry, reason: problem, data: data)
            return false
        }
        state.quarantined?[key(id, n)] = nil
        let url = root.appendingPathComponent("notes/\(id)/\(n.filename)")
        if try !LocalFS.write(data, to: url, replacing: false) { report.downloaded.removeLast(); return false }
        return true
    }

    func ensureCollection(_ path: [String]) throws {
        guard !madeCollections.contains(path) else { return }
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
        madeCollections.insert(path)
    }
}
