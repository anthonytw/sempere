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
//   §8.1.6 rules 1–3 hold for its note there; otherwise it is copied back.
//   A blob the server dropped is deleted here only once this device has
//   found it collectable for `blobRetention` (rule 4 as this device sees it:
//   the server cannot prove the collector waited); until then it is kept.

extension SyncEngine {
    /// Prefix of an interrupted download's partial file in `att/`. Starts
    /// with the vault's temporary-file prefix, so every listing ignores it,
    /// and is never a vault writer's own temporary name (those continue
    /// with a UUID).
    static let partialPrefix = FileIO.tempPrefix + "part-"

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
    static func priority(_ name: String) -> Int {
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
        set.recorded = recordedBlobs(id)

        if remoteAtt != nil {
            do {
                let listed: [RemoteEntry]?
                if let made = attListings.removeValue(forKey: id) {
                    listed = try made.get()   // listed ahead (`listAttachments`), and counted then
                } else {
                    listed = try transport.list([Vault.notesName, id, Vault.attachmentsName])
                    if let listed { try budget.list(listed.count) }
                }
                if let entries = listed {
                    set.remoteListed = true
                    for e in entries {
                        if e.name.hasPrefix(FileIO.tempPrefix) { continue }   // another device's upload in flight
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
                // Unknown remote state: transfer nothing, delete nothing; and no revision of this note goes
                // up without the blobs it may reference.
                if !(localBlobNames(id) ?? []).isEmpty { locked { _ = blobsHeldBack.insert(id) } }
                set.recorded = []
                set.local = [:]
                return set
            }
        }

        let att = attURL(id)
        set.localListed = FileIO.isDirectory(att)
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
                state.partials[blobKey(id, String(p.dropFirst(Self.partialPrefix.count)))] = nil
            }
        }

        func ordered(_ names: Set<String>, _ size: (String) -> Int) -> [String] {
            names.sorted { (Self.priority($0), size($0), $0) < (Self.priority($1), size($1), $1) }
        }
        // The prefetch made some already (`prefetchDownloads`); one it placed is in `set.local` by now.
        for name in ordered(newRemote, { set.remote[$0]?.size ?? Int.max }) where !prefetched.contains(blobKey(id, name)) {
            try blobAttempt(id, name) {
                if let size = try downloadBlob(id, name, entry: set.remote[name]) { set.local[name] = size }
            }
        }
        for name in ordered(newLocal, { set.local[$0] ?? 0 }) {
            // The pre-upload pass may have made it already (`preuploadNewFiles`), or tried and reported it.
            switch preuploadOutcome(id, blobKey(id, name)) {
            case .uploaded: set.remote[name] = RemoteEntry(name: name, isCollection: false)
            case .failed: break
            case .notTried:
                try blobAttempt(id, name) {
                    try uploadBlob(id, name)
                    set.remote[name] = RemoteEntry(name: name, isCollection: false)
                }
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
        // A partial copy: blobs it has not fetched (stand-ins), and every blob of a note
        // not fetched in full, are pending: never extraneous, never deleted (format.md §1.2).
        let incomplete = PartialCopy.isIncomplete(noteFolder: attURL(id).deletingLastPathComponent())
        let standIns = Set(PartialCopyState.pendingBlobs(root, id))
        let localDeleted = incomplete ? [] : remote.intersection(set.recorded).subtracting(local)
        if options.pushOnly {
            // Never synced and not local: not ours, unless the copy has not fetched it yet.
            for name in remote.subtracting(local).subtracting(set.recorded).sorted() {
                if incomplete || standIns.contains(name) {
                    pendingKept += 1
                    continue
                }
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
                        // Rule 4 as this device sees it (security review 2026-10, S2 for blobs): a
                        // collector waited `blobRetention` after finding the blob collectable, so
                        // a server deletion is followed only once this device has found it so for
                        // as long. Until then it stays here, not uploaded again: nothing references it.
                        let key = blobKey(id, name)
                        let since = state.files[key]?.unreferencedSince ?? options.now
                        if !options.dryRun { state.files[key, default: .init()].unreferencedSince = since }
                        let due = since.addingTimeInterval(options.blobRetention)
                        guard options.now >= due else {
                            report.skipped.append(.init(path: blobPath(id, name), message: "deleted on the server; unreferenced "
                                + "here since \(Self.compactUTC(since)), kept until \(Self.compactUTC(due)) (format.md §8.1.6 rule 4)"))
                            return
                        }
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
                        if !options.dryRun { try transport.delete([Vault.notesName, id, Vault.attachmentsName, name]) }
                        report.deleted.append(.init(side: "remote", path: blobPath(id, name)))
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
    /// 2. no re-encryption is unfinished (format.md §8.1.6 rule 2; re-encryption comes with KH6);
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

    /// Saves the transfers in flight mid-run (`SyncState.Transfers`, a file
    /// next to the state), so the next run knows about a partial download or
    /// a temporary upload even if this one is killed. A killed run's other
    /// progress is not saved: the next run finds it on both sides. Best
    /// effort.
    private func checkpoint() {
        guard !options.dryRun else { return }
        locked { _ = try? state.saveTransfers(stateURL) }
    }

    /// Uploads one blob: streamed to a temporary name, then `MOVE`d to its
    /// own name without overwriting. A blob the server already has under
    /// that name is the same content (the name is keyed by its hash), so
    /// losing that race is success. Safe on the pool's threads
    /// (`preuploadNewFiles`): what it shares with the run is under `mutex`.
    func uploadBlob(_ id: String, _ name: String) throws {
        do { try uploadBlobOnce(id, name) } catch {
            // Its note's revisions wait for the next run (`blobsHeldBack`).
            locked { _ = blobsHeldBack.insert(id) }
            throw error
        }
    }

    private func uploadBlobOnce(_ id: String, _ name: String) throws {
        let path = blobPath(id, name)
        let file = attURL(id).appendingPathComponent(name)
        guard let size = LocalFS.regularFileSize(file) else { throw SyncError.io("\(path) is not a regular file") }
        if size > options.maxBlobBytes { throw SyncError.io("\(path) is \(size) bytes, over the blob limit; not uploaded") }
        guard !options.dryRun else { locked { report.uploaded.append(path) }; return }
        try ensureCollection([Vault.notesName, id, Vault.attachmentsName])
        let tempName = FileIO.tempPrefix + UUID().uuidString.lowercased()
        let temp = [Vault.notesName, id, Vault.attachmentsName, tempName]
        let tempRel = temp.joined(separator: "/")
        locked { state.remoteTemps.append(tempRel) }
        checkpoint()
        var moved = false
        defer {
            // Gone after a MOVE; otherwise removed now, or by the next run if that fails.
            if moved || (try? transport.delete(temp)) != nil { locked { state.remoteTemps.removeAll { $0 == tempRel } } }
        }
        guard try transport.write(temp, .file(file), condition: .create) else {
            throw SyncError.io("\(path): the temporary upload name already exists on the server")
        }
        moved = try transport.moveNoOverwrite(temp, to: [Vault.notesName, id, Vault.attachmentsName, name])
        locked { report.uploaded.append(path) }
        updateProgress { $0.uploaded = report.uploaded.count }
    }

    /// Downloads one blob into place (never over an existing file); returns
    /// its size, or nil when the file appeared locally meanwhile. Continues
    /// an earlier partial download of the same remote version.
    func downloadBlob(_ id: String, _ name: String, entry: RemoteEntry?) throws -> Int? {
        try requireLocalWrite("download \(blobPath(id, name))")
        let path = blobPath(id, name)
        let limit = options.maxBlobBytes
        if let size = entry?.size, size > limit { throw SyncError.responseTooLarge(path: path, limit: limit) }
        if skipQuarantined(blobKey(id, name), path: path, entry: entry) { return nil }
        let remote = [Vault.notesName, id, Vault.attachmentsName, name]
        // Listed but not downloaded by its provider yet: asked for, waited for a while, else left for later.
        if try !available(remote, entry: entry) { return nil }
        let reserved = try locked { try budget.willDownload(entry?.size) }
        var settled = false
        defer { if !settled { locked { budget.release(reserved) } } }
        guard !options.dryRun else { locked { report.downloaded.append(path) }; return entry?.size ?? 0 }
        let att = attURL(id)
        do { try FileManager.default.createDirectory(at: att, withIntermediateDirectories: true) } catch {
            // Another download of the same note may have created it meanwhile.
            guard FileIO.isDirectory(att) else { throw SyncError.io("create \(att.path): \(error.localizedDescription)") }
        }
        let key = blobKey(id, name)
        let part = att.appendingPathComponent(Self.partialPrefix + name)
        // Only a strong ETag can back `If-Range` (RFC 9110 §13.1.5): with a weak or
        // missing one a cut download is not resumed, it starts over.
        let etag = entry?.etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }
        var offset = 0
        var fetched = 0
        if let etag, locked({ state.partials[key]?.etag == etag }), let have = LocalFS.regularFileSize(part) {
            offset = have
        } else {
            try? FileManager.default.removeItem(at: part)
        }
        if let etag {
            locked { state.partials[key] = .init(etag: etag) }
            checkpoint()
        }
        credit(key, offset)
        func discard() {
            try? FileManager.default.removeItem(at: part)
            locked { state.partials[key] = nil }
        }
        // Each segment counts towards the progress; a cancellation stops between two.
        let segmentDone: (Int) throws -> Void = { [self] bytes in
            credit(key, bytes)
            try checkCancelled()
        }
        // A partial file as long as the listing says was complete when the
        // last run stopped: only the checks below remain.
        if offset == 0 || entry?.size != offset {
            defer {
                // What this run fetched counts against its budget (checked below).
                fetched = max((LocalFS.regularFileSize(part) ?? offset) - offset, 0)
            }
            do {
                // A partial file that does not fit the remote one starts over (`SyncRemote.download`).
                try transport.download(remote, to: part, resumeFrom: offset, ifETag: etag, maxBytes: limit,
                                       segmentBytes: options.blobSegmentBytes, progress: segmentDone)
            } catch where Self.isUnavailable(error) {
                // Evicted between the listing and the read: arriving, not failed.
                discard()
                noteArriving(remote)
                return nil
            } catch {
                // A dropped connection or a timeout (a `TransientRemoteError`, e.g. WebDAV's
                // `.offline`), a cancellation or the run's time bound keeps the partial file
                // for the next run.
                if (error as? SyncError)?.isRunLimit == true || (error as? any TransientRemoteError)?.isTransient == true {
                    if etag == nil || LocalFS.regularFileSize(part) == nil { discard() }
                } else {
                    discard()
                }
                throw error
            }
        }
        settled = true
        do { try locked { try budget.downloaded(fetched, reserved: reserved) } } catch { discard(); throw error }
        guard let size = LocalFS.regularFileSize(part) else { discard(); throw SyncError.io("\(path): nothing was downloaded") }
        guard size <= limit else { discard(); throw SyncError.responseTooLarge(path: path, limit: limit) }
        if let listed = entry?.size, listed != size {
            discard()
            throw SyncError.malformedResponse("\(path) is \(size) bytes, the listing said \(listed); not written")
        }
        // Checked before it is placed (format.md §9.1): a failure is
        // quarantined, never placed and never silently dropped.
        var problem: String?
        if try LocalFS.prefix(of: part, count: Self.ageMagic.count) != Self.ageMagic {
            problem = "not an age file"
        } else if let checker = checker() {
            do { try checker.checkIncomingBlob(at: part, fileName: name) } catch { problem = "\(error)" }
        }
        defer { locked { state.partials[key] = nil } }
        if let problem {
            quarantine(key, path: path, entry: entry, reason: problem, file: part)
            return nil
        }
        locked { state.quarantined?[key] = nil }
        guard try LocalFS.placeNew(part, at: att.appendingPathComponent(name)) else { return nil }
        locked { report.downloaded.append(path) }
        return size
    }

    /// Deletes the temporary upload names an interrupted earlier run left on
    /// the server (only this device's own, recorded in the state).
    func removeLeftoverRemoteTemps() {
        guard !options.dryRun, !state.remoteTemps.isEmpty else { return }
        state.remoteTemps = state.remoteTemps.filter { rel in
            let comps = rel.split(separator: "/").map(String.init)
            guard comps.last?.hasPrefix(FileIO.tempPrefix) == true else { return false }
            return (try? transport.delete(comps)) == nil
        }
    }
}
