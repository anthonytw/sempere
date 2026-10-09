import Foundation
import Sempere

// MARK: - Attachment blobs (docs/attachments.md §4 "WebDAV", format.md §8.1)
//
// Each note's `att/` is synced with the same write-once table as its
// revisions, with these differences:
//
// - Blobs are streamed both ways: an upload reads the file from disk, a
//   download writes the body to a partial file, so memory does not grow with
//   the blob. They have their own size limit (`maxBlobBytes`).
// - An upload goes to a temporary name on the server and is renamed into
//   place with `MOVE` and `Overwrite: F`, so no reader ever sees a partial
//   blob under its final name and an existing blob is never replaced.
// - A download goes to `att/.sempere-tmp-part-<name>` and is linked into
//   place; an interrupted one continues with `Range` / `If-Range` from the
//   same ETag on the next run.
// - A blob one side dropped is deleted on the other side only if format.md
//   §8.1.6 rules 1–3 hold for its note there (the side that dropped it
//   applied rule 4); otherwise it is copied back.

extension WebDAVSync {
    /// Prefix of an interrupted download's partial file in `att/`. Starts
    /// with the vault's temporary-file prefix, so every listing ignores it,
    /// and is never a vault writer's own temporary name (those continue
    /// with a UUID).
    static let partialPrefix = LocalFS.tempPrefix + "part-"

    /// One note's blobs on both sides, by file name.
    struct BlobSet {
        /// Local blob files and their sizes.
        var local: [String: Int] = [:]
        /// Remote blob files.
        var remote: [String: RemoteEntry] = [:]
        /// Names both sides had at the end of the last sync.
        var recorded = Set<String>()
        /// False when the server has no `att/` collection for the note (a
        /// wiped or recreated folder: nothing it lacks counts as deleted).
        var remoteListed = false
        /// False when the note has no local `att/` folder.
        var localListed = false
    }

    func blobKey(_ id: String, _ name: String) -> String { "\(id)/\(Vault.attachmentsName)/\(name)" }
    func blobPath(_ id: String, _ name: String) -> String { "notes/\(blobKey(id, name))" }
    func attURL(_ id: String) -> URL {
        root.appendingPathComponent(Vault.notesName).appendingPathComponent(id).appendingPathComponent(Vault.attachmentsName)
    }

    /// A canonical blob file name (`<64 hex>.<kind>.age`, format.md §8.1.2).
    static func isBlobName(_ name: String) -> Bool {
        guard let parsed = BlobName.parse(name) else { return false }
        return BlobName.fileName(name: parsed.name, kind: parsed.kind) == name
    }

    /// Transfer order: small kinds first (docs/attachments.md §4), then by size.
    private static func priority(_ name: String) -> Int {
        switch BlobName.parse(name)?.kind.rawValue {
        case "transcript": return 0
        case "image": return 1
        case "pdf": return 2
        case "bin": return 3
        case "audio": return 4
        default: return 5
        }
    }

    // MARK: Phase 1: transfers

    /// Lists both sides of a note's `att/` and copies new blobs each way.
    /// Listing failures are reported; the note's revisions still sync.
    func syncBlobTransfers(_ id: String, remoteAtt: RemoteEntry?) throws -> BlobSet {
        var set = BlobSet()
        let prefix = "\(id)/\(Vault.attachmentsName)/"
        set.recorded = Set(state.files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })

        if remoteAtt != nil {
            do {
                if let entries = try client.list([Vault.notesName, id, Vault.attachmentsName]) {
                    try budget.list(entries.count)
                    set.remoteListed = true
                    for e in entries {
                        if e.name.hasPrefix(LocalFS.tempPrefix) { continue }   // another device's upload in flight
                        guard !e.isCollection, Self.isBlobName(e.name) else {
                            report.ignored.append(SyncReport.printable("notes/\(id)/\(Vault.attachmentsName)/\(e.name)"))
                            remoteJunk.append([Vault.notesName, id, Vault.attachmentsName, e.name])
                            continue
                        }
                        set.remote[e.name] = e
                    }
                }
            } catch {
                try rethrowRunLimit(error)
                report.errors.append(.init(path: "notes/\(id)/\(Vault.attachmentsName)", message: Self.describe(error)))
                // Unknown remote state: transfer nothing, delete nothing.
                set.recorded = []
                set.local = [:]
                return set
            }
        }

        let att = attURL(id)
        set.localListed = LocalFS.isDirectory(att)
        var partials: [String] = []
        for f in try LocalFS.entries(att) {
            if f.hasPrefix(Self.partialPrefix) { partials.append(f); continue }
            guard Self.isBlobName(f), let size = LocalFS.regularFileSize(att.appendingPathComponent(f)) else { continue }
            set.local[f] = size
        }

        // Push-only: nothing is downloaded, and a blob the server lacks is
        // uploaded whether or not the last sync had it.
        let newRemote = options.pushOnly ? [] : Set(set.remote.keys).subtracting(set.local.keys).subtracting(set.recorded)
        let newLocal = options.pushOnly
            ? Set(set.local.keys).subtracting(set.remote.keys)
            : Set(set.local.keys).subtracting(set.remote.keys).subtracting(set.recorded)

        // A partial file whose blob is not downloaded in this run is stale.
        if !options.dryRun && !options.pushOnly {
            for p in partials where !newRemote.contains(String(p.dropFirst(Self.partialPrefix.count))) {
                try? FileManager.default.removeItem(at: att.appendingPathComponent(p))
                state.partials?[blobKey(id, String(p.dropFirst(Self.partialPrefix.count)))] = nil
            }
        }

        func ordered(_ names: Set<String>, _ size: (String) -> Int) -> [String] {
            names.sorted { (Self.priority($0), size($0), $0) < (Self.priority($1), size($1), $1) }
        }
        for name in ordered(newRemote, { set.remote[$0]?.size ?? Int.max }) {
            try blobAttempt(id, name) {
                if let size = try downloadBlob(id, name, entry: set.remote[name]) { set.local[name] = size }
            }
        }
        for name in ordered(newLocal, { set.local[$0] ?? 0 }) {
            try blobAttempt(id, name) {
                try uploadBlob(id, name)
                set.remote[name] = RemoteEntry(name: name, isCollection: false)
            }
        }
        return set
    }

    private func blobAttempt(_ id: String, _ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch {
            try rethrowRunLimit(error)
            report.errors.append(.init(path: blobPath(id, name), message: Self.describe(error)))
        }
    }

    // MARK: Phase 2: deletions (format.md §8.1.6)

    /// Handles blobs that one side dropped since the last sync, then records
    /// what both sides share. Runs after the note's revisions were synced, so
    /// that the references both sides hold now are the ones checked.
    func syncBlobDeletions(_ id: String, _ set: inout BlobSet, remoteRevisions: Set<RevisionName>) throws {
        let local = Set(set.local.keys), remote = Set(set.remote.keys)
        let remoteDeleted = options.pushOnly ? [] : local.intersection(set.recorded).subtracting(remote)
        let localDeleted = remote.intersection(set.recorded).subtracting(local)
        if options.pushOnly {
            // Never synced and not local: not ours.
            for name in remote.subtracting(local).subtracting(set.recorded).sorted() {
                if reportExtraneous(blobPath(id, name), remove: [Vault.notesName, id, Vault.attachmentsName, name]) { set.remote[name] = nil }
            }
        }

        if !remoteDeleted.isEmpty || !localDeleted.isEmpty {
            let judge = collectable(id, remoteRevisions: remoteRevisions)
            // The server dropped these: delete here only if collection allows it, else upload again.
            for name in remoteDeleted.sorted() {
                try blobAttempt(id, name) {
                    guard case .judged(let allowed) = judge else {
                        if case .unknown(let why) = judge {
                            report.skipped.append(.init(path: blobPath(id, name), message: "deleted on the server; \(why)"))
                        }
                        return
                    }
                    if set.remoteListed && allowed(name) {
                        report.deleted.append(.init(side: "local", path: blobPath(id, name)))
                        try requireLocalWrite("delete \(blobPath(id, name))")
                        if !options.dryRun { try LocalFS.remove(attURL(id).appendingPathComponent(name)) }
                        set.local[name] = nil
                    } else {
                        try uploadBlob(id, name)
                        set.remote[name] = RemoteEntry(name: name, isCollection: false)
                    }
                }
            }
            // We dropped these: delete on the server only if collection allows it there, else download again.
            for name in localDeleted.sorted() {
                try blobAttempt(id, name) {
                    guard case .judged(let allowed) = judge else {
                        if case .unknown(let why) = judge {
                            report.skipped.append(.init(path: blobPath(id, name), message: "deleted locally; \(why)"))
                        }
                        return
                    }
                    if set.localListed && allowed(name) {
                        report.deleted.append(.init(side: "remote", path: blobPath(id, name)))
                        if !options.dryRun { try client.delete([Vault.notesName, id, Vault.attachmentsName, name]) }
                        set.remote[name] = nil
                    } else if options.pushOnly {
                        report.skipped.append(.init(path: blobPath(id, name),
                                                    message: "missing locally and not explained by collection, kept on the server"))
                    } else if let size = try downloadBlob(id, name, entry: set.remote[name]) {
                        set.local[name] = size
                    }
                }
            }
        }

        guard !options.dryRun else { return }
        let shared = Set(set.local.keys).intersection(set.remote.keys)
        for name in shared { state.files[blobKey(id, name)] = SyncState.FileRecord() }
        // A blob one side still has keeps its record (a skipped deletion is decided later).
        for name in set.recorded where set.local[name] == nil && set.remote[name] == nil {
            state.files[blobKey(id, name)] = nil
        }
    }

    /// Whether blobs of a note may be deleted, by name.
    enum BlobJudgement {
        /// Rules 1–3 checked: the predicate says whether a blob file name is collectable.
        case judged((String) -> Bool)
        /// Nothing can be checked (no unlocked vault); nothing is deleted or restored.
        case unknown(String)
    }

    /// format.md §8.1.6 rules 1–3 for one note, for both sides at once:
    ///
    /// 1. every local revision of the note was listed, read and verified, and
    ///    every revision the server holds is one of them (byte-identical,
    ///    since revisions are write-once), so both sides' sets were read;
    /// 2. no `rewrap-journal.json` exists on either side;
    /// 3. no revision read references the blob's content hash: a blob is
    ///    collectable when its name is not the keyed name of any referenced
    ///    hash (in any kind).
    ///
    /// When rule 1 or 2 fails, every blob of the note counts as referenced
    /// (it is copied back, never deleted).
    func collectable(_ id: String, remoteRevisions: Set<RevisionName>) -> BlobJudgement {
        guard let vault, let note = UUID(uuidString: id) else {
            return .unknown("cannot check it against the collection rules (vault not unlocked)")
        }
        guard !vault.pendingRewrap, !remoteJournal else { return .judged { _ in false } }
        let inventory: BlobInventory
        do { inventory = try vault.blobInventory(note: note) } catch { return .judged { _ in false } }
        let readable = Set(inventory.references.keys)
        guard inventory.isComplete, remoteRevisions.isSubset(of: readable) else { return .judged { _ in false } }
        var referenced = Set<String>()
        for hash in inventory.referencedHashes {
            guard let digest = Hex.decode(hash), let name = try? vault.blobName(sha256: digest) else {
                // A malformed hash cannot be mapped to a name: keep everything.
                return .judged { _ in false }
            }
            referenced.insert(name)
        }
        return .judged { file in
            guard let parsed = BlobName.parse(file) else { return false }
            return !referenced.contains(parsed.name)
        }
    }

    // MARK: Transfers

    /// Saves the sync state mid-run, so the next run knows about a partial
    /// download or a temporary upload even if this one is killed. Every
    /// record in it is true at that point (per-note records are written only
    /// once a note is finished). Best effort.
    private func checkpoint() {
        guard !options.dryRun else { return }
        try? state.save(stateURL)
    }

    /// Uploads one blob: streamed to a temporary name, then `MOVE`d to its
    /// own name without overwriting. A blob the server already has under
    /// that name is the same content (the name is keyed by its hash), so
    /// losing that race is success.
    func uploadBlob(_ id: String, _ name: String) throws {
        let path = blobPath(id, name)
        let file = attURL(id).appendingPathComponent(name)
        guard let size = LocalFS.regularFileSize(file) else { throw WebDAVError.io("\(path) is not a regular file") }
        if size > options.maxBlobBytes { throw WebDAVError.io("\(path) is \(size) bytes, over the blob limit; not uploaded") }
        report.uploaded.append(path)
        guard !options.dryRun else { return }
        try ensureCollection([Vault.notesName, id, Vault.attachmentsName])
        let tempName = LocalFS.tempPrefix + UUID().uuidString.lowercased()
        let temp = [Vault.notesName, id, Vault.attachmentsName, tempName]
        let tempRel = temp.joined(separator: "/")
        state.remoteTemps = (state.remoteTemps ?? []) + [tempRel]
        checkpoint()
        var moved = false
        defer {
            // Gone after a MOVE; otherwise removed now, or by the next run if that fails.
            if moved || (try? client.delete(temp)) != nil { state.remoteTemps?.removeAll { $0 == tempRel } }
        }
        guard try client.put(temp, fromFile: file, condition: .create) else {
            throw WebDAVError.io("\(path): the temporary upload name already exists on the server")
        }
        moved = try client.move(temp, to: [Vault.notesName, id, Vault.attachmentsName, name], overwrite: false)
    }

    /// Downloads one blob into place (never over an existing file); returns
    /// its size, or nil when the file appeared locally meanwhile. Continues
    /// an earlier partial download of the same remote version.
    func downloadBlob(_ id: String, _ name: String, entry: RemoteEntry?) throws -> Int? {
        try requireLocalWrite("download \(blobPath(id, name))")
        let path = blobPath(id, name)
        let limit = options.maxBlobBytes
        if let size = entry?.size, size > limit { throw WebDAVError.io("\(path) is \(size) bytes, over the blob limit; skipped") }
        if skipQuarantined(blobKey(id, name), path: path, entry: entry) { return nil }
        try budget.willDownload(entry?.size)
        report.downloaded.append(path)
        guard !options.dryRun else { return entry?.size ?? 0 }
        let att = attURL(id)
        do { try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true) } catch {
            throw WebDAVError.io("create \(att.path): \(error.localizedDescription)")
        }
        let key = blobKey(id, name)
        let part = att.appendingPathComponent(Self.partialPrefix + name)
        let remote = [Vault.notesName, id, Vault.attachmentsName, name]
        let etag = entry?.etag
        var offset = 0
        var fetched = 0
        if let etag, state.partials?[key]?.etag == etag, let have = LocalFS.regularFileSize(part) {
            offset = have
        } else {
            try? FileManager.default.removeItem(at: part)
        }
        if let etag {
            state.partials = state.partials ?? [:]
            state.partials?[key] = .init(etag: etag)
            checkpoint()
        }
        func discard() {
            try? FileManager.default.removeItem(at: part)
            state.partials?[key] = nil
        }
        // A partial file as long as the listing says was complete when the
        // last run stopped: only the checks below remain.
        if offset == 0 || entry?.size != offset {
            defer {
                // What this run fetched counts against its budget (checked below).
                fetched = max((LocalFS.regularFileSize(part) ?? offset) - offset, 0)
            }
            do {
                do {
                    try client.download(remote, to: part, resumeFrom: offset, ifRange: etag, maxBytes: limit,
                                        segmentBytes: options.blobSegmentBytes)
                } catch WebDAVError.http(_, _, 416) where offset > 0 {
                    // The partial file does not fit the remote one: start over.
                    try? FileManager.default.removeItem(at: part)
                    try client.download(remote, to: part, maxBytes: limit, segmentBytes: options.blobSegmentBytes)
                }
            } catch let e as WebDAVError {
                // A dropped connection keeps the partial file for the next run.
                if case .transport = e, etag != nil, LocalFS.regularFileSize(part) != nil {} else { discard() }
                throw e
            } catch {
                discard()
                throw error
            }
        }
        do { try budget.downloaded(fetched) } catch { discard(); throw error }
        guard let size = LocalFS.regularFileSize(part) else { discard(); throw WebDAVError.io("\(path): nothing was downloaded") }
        guard size <= limit else { discard(); throw WebDAVError.io("\(path) is over the blob limit; skipped") }
        if let listed = entry?.size, listed != size {
            discard()
            throw WebDAVError.malformedResponse("\(path) is \(size) bytes, the listing said \(listed); not written")
        }
        // Checked before it is placed (format.md §9.1): a failure is
        // quarantined, never placed and never silently dropped.
        var problem: String?
        if try LocalFS.prefix(of: part, count: Self.ageMagic.count) != Self.ageMagic {
            problem = "not an age file"
        } else if let checker = checker() {
            do { try checker.checkIncomingBlob(at: part, fileName: name) } catch { problem = "\(error)" }
        }
        defer { state.partials?[key] = nil }
        if let problem {
            report.downloaded.removeLast()
            quarantine(key, path: path, entry: entry, reason: problem, file: part)
            return nil
        }
        state.quarantined?[key] = nil
        guard try LocalFS.placeNew(part, at: att.appendingPathComponent(name)) else {
            report.downloaded.removeLast()
            return nil
        }
        return size
    }

    /// Deletes the temporary upload names an interrupted earlier run left on
    /// the server (only this device's own, recorded in the state).
    func removeLeftoverRemoteTemps() {
        guard !options.dryRun, let temps = state.remoteTemps, !temps.isEmpty else { return }
        state.remoteTemps = temps.filter { rel in
            let comps = rel.split(separator: "/").map(String.init)
            guard comps.last?.hasPrefix(LocalFS.tempPrefix) == true else { return false }
            return (try? client.delete(comps)) == nil
        }
    }
}
