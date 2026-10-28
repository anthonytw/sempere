import Foundation
import Sempere

// MARK: - The re-encryption coordinator (docs/design/key-hierarchy.md §7.1 steps 3, 6(c), 7; P4a's claims; KH6)
//
// What home does on its targets around the local steps of `Vault` (prepare, begin, pass, finish):
//
// - **Claim** (step 3): the journal written create-only (`If-None-Match: *`, or `link(2)` on a folder) to every
//   target before the epoch exists. A target that holds another journal refuses the claim, except one this device
//   shows finished, or an unbound one first seen here more than a day ago (a start that never reached its epoch):
//   those are replaced under their version tag. A refused claim aborts the start; `release` deletes the claims made.
// - **Confirm** (step 6(c)): one pass over a target, after this device's runs propagated its files there: every file
//   under a key from before the re-encryption is replaced by this device's current copy of it (the same body), or,
//   when the acceptance rule does not take it, kept aside here and deleted there; old blob names whose current name
//   is there are deleted; once nothing else is left, the epoch records below the re-encryption are deleted. A target
//   is confirmed when it holds this device's `vault.json` and journal and nothing under an earlier key.
// - **Finish** (step 7) is `Vault.finishReencryption` once every target is confirmed; the next runs carry the
//   `vault.json` without the binding and delete the journal there.

/// Re-encryption steps on sync targets (see above).
public enum ReencryptCoordinator {
    /// One target of the vault.
    public struct Target: Sendable {
        public var name: String
        public var remote: any SyncRemote
        /// This device synced with the target before (`FolderTargetRun.syncedBefore`): its base, if gone, is never made
        /// again by a claim (`SyncRemote.checkAbsentBase`).
        public var syncedBefore: Bool
        public init(name: String, remote: any SyncRemote, syncedBefore: Bool = false) {
            self.name = name; self.remote = remote; self.syncedBefore = syncedBefore
        }
    }

    /// How long an unbound journal on a target counts as a claim in flight (P4a: the in-flight day).
    public static let claimLifetime: TimeInterval = 86_400

    /// What a claim found on one target.
    public enum ClaimOutcome: Hashable, Sendable {
        /// Written (or this journal was there already).
        case claimed
        /// Another journal is there: a re-encryption in flight, or a claim not yet a day old (`since` it was first
        /// seen here).
        case refused(String)
        /// The target could not be reached.
        case unreachable(String)

        public var isClaimed: Bool { self == .claimed }
    }

    /// When another journal was first seen on each target, by target name (one entry, `sightingKey`), kept by the
    /// caller between attempts (the CLI and the app: next to the store's sync states). Keyed by the target, not by the
    /// bytes: storage changing the junk journal's bytes at every attempt must not restart the day (review of #89, S2).
    /// Forgotten once the target holds no other journal.
    public typealias ClaimSightings = [String: [String: Date]]

    /// The one key of a target's sighting.
    static let sightingKey = "journal"

    /// Where a store keeps the claim sightings of a vault (beside its targets' sync states), shared by the CLI and the app.
    public static func claimSightingsURL(store: VaultStore, vaultId: UUID) -> URL {
        store.targets.stateDirectory(UUID(), of: vaultId).deletingLastPathComponent().appendingPathComponent("reencrypt-claims.json")
    }

    /// The claim sightings saved at `url` (none when it is missing or unreadable: the day starts again).
    public static func loadClaimSightings(_ url: URL) -> ClaimSightings {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: 1 << 20) else { return [:] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(ClaimSightings.self, from: data)) ?? [:]
    }

    /// Saves claim sightings at `url` (best effort).
    public static func saveClaimSightings(_ seen: ClaimSightings, to url: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(seen).write(to: url, options: .atomic)
    }

    /// The confirm memo of one re-encryption: target name → path → strong version tag of a copy found current.
    public typealias ConfirmMemo = [String: [String: String]]

    private struct StoredMemo: Codable {
        var epochId: String
        var targets: ConfirmMemo
    }

    /// Where a store keeps a vault's confirm memo (beside the claim sightings), shared by the CLI and the app.
    public static func confirmMemoURL(store: VaultStore, vaultId: UUID) -> URL {
        claimSightingsURL(store: store, vaultId: vaultId).deletingLastPathComponent().appendingPathComponent("reencrypt-confirmed.json")
    }

    /// The memo saved at `url` for the re-encryption `epochId` (empty for another one, or when missing or unreadable).
    public static func loadConfirmMemo(_ url: URL, epochId: Data) -> ConfirmMemo {
        guard let data = try? BoundedRead.contents(of: url, maxBytes: 64 << 20),
              let stored = try? JSONDecoder().decode(StoredMemo.self, from: data), stored.epochId == Hex.encode(epochId) else { return [:] }
        return stored.targets
    }

    /// Saves the memo of the re-encryption `epochId` at `url` (best effort); an empty memo removes the file.
    public static func saveConfirmMemo(_ memo: ConfirmMemo, epochId: Data, to url: URL) {
        guard !memo.values.allSatisfy(\.isEmpty) else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(StoredMemo(epochId: Hex.encode(epochId), targets: memo)).write(to: url, options: .atomic)
    }

    /// Adds to `memo` what a target's sync state (`stateURL`) shows current there: revisions both sides last held with
    /// the bytes of the working copy's file, that file under the current key, under a strong version tag (a run's own
    /// uploads and comparisons). A confirmation then reads only the rest.
    public static func seedConfirmMemo(_ memo: inout [String: String], vault v: Vault, stateURL: URL) {
        guard let m = v.reencryptEpoch?.epoch, let state = try? SyncState.load(stateURL) else { return }
        for (k, record) in state.files {
            guard let sha = record.sha256, let tag = record.stamp, SyncEngine.isStrong(tag) else { continue }
            let p = "\(Vault.notesName)/\(k)"
            guard memo[p] == nil, let data = try? BoundedRead.contents(of: v.url.appendingPathComponent(p), maxBytes: BoundedRead.maxRevisionBytes),
                  FileDigest.sha256(data) == sha, let e = v.acceptedKeyEpoch(of: data, path: p), e >= m else { continue }
            memo[p] = tag
        }
    }

    /// Claims every target for `journal` (design §7.1 step 3). `vault` judges what a target holds (finished journals
    /// are replaced); `seen` remembers unbound ones, which are replaced once older than `claimLifetime`.
    public static func claim(_ journal: Data, vault: Vault, on targets: [Target], seen: inout ClaimSightings,
                             now: Date = Date()) -> [String: ClaimOutcome] {
        var out: [String: ClaimOutcome] = [:]
        for t in targets {
            do {
                // The rule every base creation follows (`FolderRemote.absentBase`): a target synced before that is gone,
                // or only a provider's stand-in, is never made again here (review of #119).
                if try t.remote.list([]) == nil { try t.remote.checkAbsentBase(syncedBefore: t.syncedBefore) }
                try t.remote.createBase()
                if try t.remote.write([Vault.journalName], .data(journal), condition: .create) {
                    out[t.name] = .claimed
                    seen[t.name] = nil
                    continue
                }
                let got = try t.remote.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
                if got.data == journal { out[t.name] = .claimed; seen[t.name] = nil; continue }
                // The earliest sighting of any other journal there, whatever its bytes now.
                let first = seen[t.name]?.values.min() ?? now
                seen[t.name] = [sightingKey: first]
                let stale = vault.isFinishedJournal(got.data) || now.timeIntervalSince(first) > claimLifetime
                guard stale, let etag = got.etag, SyncEngine.isStrong(etag) else {
                    out[t.name] = .refused("\(t.name) holds another re-encryption journal (another re-encryption in flight, or a "
                        + "start that stopped; first seen \(RFC3339.string(first)); it is replaced a day after)")
                    continue
                }
                out[t.name] = try t.remote.write([Vault.journalName], .data(journal), condition: .replace(etag: etag))
                    ? .claimed : .refused("\(t.name)'s journal changed meanwhile")
                if out[t.name] == .claimed { seen[t.name] = nil }
            } catch {
                out[t.name] = .unreachable(SyncEngine.describe(error))
            }
        }
        return out
    }

    /// Deletes the claims for `journal` (a start that stopped, `Vault.abandonReencryptionStart`): each target's
    /// journal with exactly these bytes, under its version tag. Returns the targets it was deleted on.
    @discardableResult
    public static func release(_ journal: Data, on targets: [Target]) -> [String] {
        var out: [String] = []
        for t in targets {
            guard let got = try? t.remote.read([Vault.journalName], maxBytes: EpochRecord.maxBytes), got.data == journal else { continue }
            let etag = got.etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }
            if (try? t.remote.delete([Vault.journalName], ifETag: etag)) == true { out.append(t.name) }
        }
        return out
    }

    /// One target's state after `confirm`.
    public struct Confirmation: Hashable, Sendable {
        public var target: String
        /// Nothing under a key from before the re-encryption is left there.
        public var confirmed: Bool { waiting.isEmpty }
        /// Vault files looked at, and how many are under the new keys.
        public var files = 0
        public var current = 0
        /// Replaced there by this device's current copy.
        public var replaced: [String] = []
        /// Deleted there (unaccepted files, kept aside here first; old blob names; earlier epoch records).
        public var deleted: [String] = []
        /// What still keeps it from being confirmed, by path.
        public var waiting: [String: String] = [:]
        public init(target: String) { self.target = target }
    }

    /// What one confirmation may still read: at most `limit` files, until `isCancelled` says to stop (a short
    /// connection window, the app's Cancel). Once stopped, the target waits; the memo keeps what was found current.
    public struct Budget: @unchecked Sendable {
        public var limit: Int?
        public var isCancelled: @Sendable () -> Bool
        public init(limit: Int? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) {
            self.limit = limit; self.isCancelled = isCancelled
        }
        public static let unlimited = Budget()
    }

    /// What `confirm` puts in `waiting` when its budget ran out.
    public static let stoppedKey = "(stopped)"

    /// Confirms one target (design §7.1 step 6(c)); see the top of this file. `memo` (path → strong version tag of a
    /// copy found current) spares reading files again; the caller keeps it per target, across steps and processes
    /// (`loadConfirmMemo`, `saveConfirmMemo`, `seedConfirmMemo`), so a home with short connection windows still gets
    /// through every file over several runs (offline audit P17; review of #89, S8). `budget` stops it between files.
    public static func confirm(vault v: Vault, target t: Target, memo: inout [String: String], scratch: URL,
                               budget: Budget = .unlimited) -> Confirmation {
        var c = Confirmation(target: t.name)
        var reads = 0
        var stopped = false
        /// One more file may be read (else the target waits for the next confirmation).
        func mayRead() -> Bool {
            if stopped { return false }
            if budget.isCancelled() || budget.limit.map({ reads >= $0 }) == true {
                stopped = true
                c.waiting[stoppedKey] = "stopped before every file was looked at; the next confirmation goes on"
                return false
            }
            reads += 1
            return true
        }
        guard let m = v.reencryptEpoch?.epoch, v.canRead else {
            c.waiting[""] = "no re-encryption on this vault's chain"
            return c
        }
        let r = t.remote
        func fail(_ path: String, _ error: Error) { c.waiting[path] = SyncEngine.describe(error) }
        // The target holds this device's vault.json and, while pending, its journal.
        do {
            let remoteManifest = try r.read([Vault.manifestName], maxBytes: BoundedRead.maxManifestBytes).data
            let local = try BoundedRead.contents(of: v.url.appendingPathComponent(Vault.manifestName), maxBytes: BoundedRead.maxManifestBytes)
            if !EpochManifest.sameExceptLabel(remoteManifest, local) {
                c.waiting[Vault.manifestName] = "the target does not hold this device's vault.json yet: sync it first"
            }
            if v.isReencryptPending {
                let journal = try? r.read([Vault.journalName], maxBytes: EpochRecord.maxBytes).data
                if journal.map({ v.boundJournal($0) == nil }) ?? true {
                    c.waiting[Vault.journalName] = "the target does not hold the re-encryption journal yet: sync it first"
                }
            }
        } catch {
            fail(Vault.manifestName, error)
            return c
        }
        guard c.waiting.isEmpty else { return c }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Framed files and inbox files: replaced by the current local copy, or set aside here and deleted there.
        func settle(_ path: [String], entry: RemoteEntry) {
            let p = path.joined(separator: "/")
            c.files += 1
            if let tag = entry.etag, SyncEngine.isStrong(tag), memo[p] == tag { c.current += 1; return }
            guard mayRead() else { return }
            do {
                let isInbox = path.first == CaptureFile.folderName
                let limit = isInbox ? CaptureFile.maxSealedBytes(CaptureFile.parse(name: path[1])?.kind ?? .capture)
                    : path == [SharedSettings.fileName] ? SharedSettings.maxFileBytes : BoundedRead.maxRevisionBytes
                let got = try r.read(path, maxBytes: limit)
                let epoch: Int?
                var unaccepted: SetAsideReason?
                if isInbox {
                    let staged = scratch.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staged) }
                    try got.data.write(to: staged)
                    epoch = v.acceptedInboxContent(staged, name: path[1])?.epoch
                } else {
                    epoch = v.acceptedKeyEpoch(of: got.data, path: p)
                    if epoch == nil, case .setAside(let reason) = v.acceptance(of: got.data, path: p) { unaccepted = reason }
                }
                if let epoch, epoch >= m {
                    c.current += 1
                    if let tag = got.etag ?? entry.etag, SyncEngine.isStrong(tag) { memo[p] = tag }
                    return
                }
                var sameBodyAsCurrent = false
                if epoch == nil, unaccepted == nil {
                    // Not judged by the acceptance rule here (an earlier record missing: withheld, or deleted by a finish
                    // this device has not seen). Opened with every earlier key it knows: home's working copy holds every
                    // accepted file under the new keys (its pass is done), so a copy with the same body is replaced by it,
                    // and any other is kept aside here and deleted there. One no earlier key opens is left (nothing from
                    // before opens it).
                    guard v.opensUnderEpoch(below: m, got.data) else { return }
                    if !isInbox, let (_, body) = v.earlierKeyBody(of: got.data, path: p),
                       let local = try? BoundedRead.contents(of: v.url.appendingPathComponent(p), maxBytes: limit),
                       (v.acceptedKeyEpoch(of: local, path: p).map { $0 >= m } ?? false), v.plainBody(of: local, path: p) == body {
                        sameBodyAsCurrent = true
                    } else if isInbox, FileManager.default.fileExists(atPath: v.url.appendingPathComponent(p).path) {
                        sameBodyAsCurrent = true   // the same capture, re-sealed here by the pass
                    } else {
                        unaccepted = .notSealed
                    }
                }
                if epoch == nil, isInbox, !opensUnderOldKey(v, got.data, below: m) { return }
                guard let etag = got.etag ?? entry.etag, SyncEngine.isStrong(etag) else {
                    c.waiting[p] = "under an earlier key, and the target gives no strong version tag to replace it under"
                    return
                }
                let localURL = v.url.appendingPathComponent(p)
                if let local = try? BoundedRead.contents(of: localURL, maxBytes: limit), sameBodyAsCurrent || (epoch != nil &&
                   (isInbox ? sameInbox(v, local, got.data, name: path[1], scratch: scratch)
                           : (v.acceptedKeyEpoch(of: local, path: p).map { $0 >= m } ?? false)
                             && v.plainBody(of: local, path: p) == v.plainBody(of: got.data, path: p))) {
                    if try r.write(path, .data(local), condition: .replace(etag: etag)) {
                        // Not memoized: whatever is there next time is read once more (another device may have put a
                        // copy there in between, and a stat would vouch for it unread).
                        c.replaced.append(p)
                    } else {
                        c.waiting[p] = "changed on the target meanwhile"
                    }
                    return
                }
                if epoch != nil {
                    c.waiting[p] = "under an earlier key, and this device holds no current copy of it yet: sync first"
                    return
                }
                guard let store = v.setAsideStore else {
                    c.waiting[p] = "not accepted, and this device keeps no set-aside store to keep it in first"
                    return
                }
                if Vault.keepsUnacceptedOnTargets { c.current += 1; return }   // the mutation (J7)
                try store.keep(got.data, path: p, vaultId: v.vaultId, reason: unaccepted ?? .notSealed)
                if try r.delete(path, ifETag: etag) { c.deleted.append(p) } else { c.waiting[p] = "changed on the target meanwhile" }
            } catch {
                fail(p, error)
            }
        }
        do {
            for note in try r.list([Vault.notesName]) ?? [] where note.isCollection && Vault.isNoteDirectoryName(note.name) {
                let entries = try r.list([Vault.notesName, note.name]) ?? []
                for e in entries where !e.isCollection && RevisionName(e.name)?.filename == e.name {
                    settle([Vault.notesName, note.name, e.name], entry: e)
                }
                guard entries.contains(where: { $0.isCollection && $0.name == Vault.attachmentsName }),
                      let noteId = UUID(uuidString: note.name) else { continue }
                confirmBlobs(v, r, note: noteId, below: m, into: &c, memo: &memo, scratch: scratch, mayRead: mayRead)
            }
            for e in try r.list([NotebookRecords.folderName]) ?? [] where !e.isCollection && NotebookRecords.id(ofFileName: e.name) != nil {
                settle([NotebookRecords.folderName, e.name], entry: e)
            }
            for e in try r.list([CaptureFile.folderName]) ?? [] where !e.isCollection && CaptureFile.parse(name: e.name) != nil {
                settle([CaptureFile.folderName, e.name], entry: e)
            }
            if let e = try r.stat([SharedSettings.fileName]), !e.isCollection { settle([SharedSettings.fileName], entry: e) }
            // Per-device published summaries sealed under a key from before (hints; a device removed in the review or
            // one offline never rewrites its own): deleted under their version tags (review of #89, S1).
            let folder = PublishedSummaries.deviceFolderName
            for e in try r.list([folder]) ?? [] where !e.isCollection && PublishedSummaries.device(ofFileName: e.name) != nil {
                let p = "\(folder)/\(e.name)"
                c.files += 1
                if let tag = e.etag, SyncEngine.isStrong(tag), memo[p] == tag { c.current += 1; continue }
                guard mayRead() else { break }
                let got = try r.read([folder, e.name], maxBytes: PublishedSummaries.maxFileBytes)
                guard v.summariesUnderEpoch(below: m, got.data) else {
                    c.current += 1
                    if let tag = (got.etag ?? e.etag), SyncEngine.isStrong(tag) { memo[p] = tag }
                    continue
                }
                guard let etag = (got.etag ?? e.etag).flatMap({ SyncEngine.isStrong($0) ? $0 : nil }) else {
                    c.waiting[p] = "sealed under an earlier key, and the target gives no strong version tag to delete it under"
                    continue
                }
                if try r.delete([folder, e.name], ifETag: etag) { c.deleted.append(p) } else { c.waiting[p] = "changed on the target meanwhile" }
            }
        } catch {
            fail(Vault.notesName, error)
        }
        // The earlier records go last, once nothing else needs them.
        guard c.waiting.isEmpty else { return c }
        do {
            for e in try r.list([Vault.epochsName]) ?? [] where !e.isCollection && v.isRecordBelowReencryption(e.name, m: m) {
                if Vault.keepsOldRecords {
                    c.waiting["\(Vault.epochsName)/\(e.name)"] = "kept (test mutation)"
                    continue
                }
                if try r.delete([Vault.epochsName, e.name], ifETag: e.etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }) {
                    c.deleted.append("\(Vault.epochsName)/\(e.name)")
                }
            }
        } catch {
            fail(Vault.epochsName, error)
        }
        if Vault.keepsOldRecords { c.waiting = c.waiting.filter { !$0.key.hasPrefix(Vault.epochsName) } }
        return c
    }

    /// Where one `advance` left the re-encryption.
    public struct Progress: Sendable {
        /// The pass on this device.
        public var pass: ReencryptPassReport?
        /// Each target's confirmation (none when the pass has work left).
        public var targets: [Confirmation] = []
        /// True once `vault.json` was rewritten without the binding (and the runs after carried it).
        public var finished = false
        public init() {}
    }

    /// One step of a pending re-encryption on home (design §7.1 steps 5–7): the pass, a run with every target (`sync`),
    /// each target confirmed, and, when every one is, the finish and a run with every target again. A crash, a lock
    /// or an unreachable target leaves it for the next call (`sempere vault reencrypt --resume`).
    public static func advance(_ vault: inout Vault, targets: [Target], sync: (Target) throws -> Void,
                               memo: inout [String: [String: String]], scratch: URL, budget: Budget = .unlimited) throws -> Progress {
        var p = Progress()
        guard vault.isReencryptPending else { return p }
        let pass = try vault.reencryptPass()
        p.pass = pass
        for t in targets { try? sync(t) }
        vault = try vault.reopened()
        guard pass.remaining == 0, pass.problems.isEmpty, vault.isReencryptPending else { return p }
        for t in targets {
            var m = memo[t.name] ?? [:]
            p.targets.append(confirm(vault: vault, target: t, memo: &m, scratch: scratch, budget: budget))
            memo[t.name] = m
        }
        guard p.targets.allSatisfy(\.confirmed) else { return p }
        try vault.finishReencryption()
        p.finished = true
        for t in targets { try? sync(t) }
        vault = try vault.reopened()
        return p
    }

    /// True when `data` (an age file) opens under the key of an epoch below `m` this vault holds.
    static func opensUnderOldKey(_ v: Vault, _ data: Data, below m: Int) -> Bool {
        v.opensUnderEpoch(below: m, data)
    }

    /// The two inbox files hold the same capture content.
    static func sameInbox(_ v: Vault, _ a: Data, _ b: Data, name: String, scratch: URL) -> Bool {
        let x = scratch.appendingPathComponent(UUID().uuidString), y = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: x); try? FileManager.default.removeItem(at: y) }
        guard (try? a.write(to: x)) != nil, (try? b.write(to: y)) != nil,
              let l = v.acceptedInboxContent(x, name: name), let r = v.acceptedInboxContent(y, name: name) else { return false }
        return l.content == r.content
    }

    /// The note's blobs on the target: a name this device holds is current (its own pass made it); another is read
    /// and judged: under the new keys, fine; an old name whose current name is there, deleted; an unaccepted one, kept
    /// aside here and deleted; an accepted old one without its current name there, waiting (the next run uploads it).
    static func confirmBlobs(_ v: Vault, _ r: any SyncRemote, note: UUID, below m: Int, into c: inout Confirmation,
                             memo: inout [String: String], scratch: URL, mayRead: () -> Bool) {
        let id = note.uuidString.lowercased()
        let folder = [Vault.notesName, id, Vault.attachmentsName]
        // A listing that fails decides nothing: the target waits (review of #89, S3).
        let entries: [RemoteEntry]
        do { entries = try r.list(folder) ?? [] } catch {
            c.waiting[folder.joined(separator: "/")] = SyncEngine.describe(error)
            return
        }
        let names = Set(entries.filter { !$0.isCollection && BlobName.parse($0.name) != nil }.map(\.name))
        let local = Set(((try? FileManager.default.contentsOfDirectory(atPath: v.url.appendingPathComponent(folder.joined(separator: "/")).path)) ?? []))
        let superseded = v.supersededBlobNames(note: note, names: names)
        let remoteBases = Set(names.compactMap { BlobName.parse($0)?.name })
        for e in entries where names.contains(e.name) {
            let p = (folder + [e.name]).joined(separator: "/")
            c.files += 1
            if local.contains(e.name), !superseded.keys.contains(e.name) { c.current += 1; continue }
            let etag = e.etag.flatMap { SyncEngine.isStrong($0) ? $0 : nil }
            if let now = superseded[e.name], remoteBases.contains(now) {
                if Vault.keepsOldBlobNames { continue }
                if (try? r.delete(folder + [e.name], ifETag: etag)) == true { c.deleted.append(p) } else { c.waiting[p] = "not deleted" }
                continue
            }
            if let etag, memo[p] == etag { c.current += 1; continue }
            guard mayRead() else { return }
            let staged = scratch.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                _ = try r.download(folder + [e.name], to: staged, resumeFrom: 0, ifETag: nil, maxBytes: Int(BlobRef.maxSize) + (1 << 20),
                                   segmentBytes: 1 << 20, progress: nil)
            } catch {
                c.waiting[p] = SyncEngine.describe(error)
                continue
            }
            switch v.blobStanding(staged, note: note) {
            case .current?:
                c.current += 1
                if let etag { memo[p] = etag }
            case .old(let epoch, accepted: true)? where epoch < m:
                c.waiting[p] = "an accepted blob under an earlier key whose current name is not on the target yet: sync first"
            case .old(let epoch, accepted: false)? where epoch < m:
                if Vault.keepsUnacceptedOnTargets { c.current += 1; continue }   // the mutation (J7)
                guard let store = v.setAsideStore, (try? store.keep(file: staged, path: p, vaultId: v.vaultId, reason: .notSealed)) != nil,
                      (try? r.delete(folder + [e.name], ifETag: etag)) == true else {
                    c.waiting[p] = "not accepted, and not kept aside here or deleted there"
                    continue
                }
                c.deleted.append(p)
            default:
                c.current += 1   // under a later key, or opened by no key here (nothing from before opens it)
            }
        }
    }
}
