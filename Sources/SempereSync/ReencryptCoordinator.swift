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
        public init(name: String, remote: any SyncRemote) { self.name = name; self.remote = remote }
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

    /// Unbound journals first seen on targets, by target name and SHA-256 (hex) of the bytes, kept by the caller
    /// between attempts (the CLI: next to the store's sync states).
    public typealias ClaimSightings = [String: [String: Date]]

    /// Claims every target for `journal` (design §7.1 step 3). `vault` judges what a target holds (finished journals
    /// are replaced); `seen` remembers unbound ones, which are replaced once older than `claimLifetime`.
    public static func claim(_ journal: Data, vault: Vault, on targets: [Target], seen: inout ClaimSightings,
                             now: Date = Date()) -> [String: ClaimOutcome] {
        var out: [String: ClaimOutcome] = [:]
        for t in targets {
            do {
                try t.remote.createBase()
                if try t.remote.write([Vault.journalName], .data(journal), condition: .create) {
                    out[t.name] = .claimed
                    continue
                }
                let got = try t.remote.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
                if got.data == journal { out[t.name] = .claimed; continue }
                let hash = FileDigest.sha256(got.data)
                let first = seen[t.name]?[hash] ?? now
                seen[t.name, default: [:]][hash] = first
                let stale = vault.isFinishedJournal(got.data) || now.timeIntervalSince(first) > claimLifetime
                guard stale, let etag = got.etag, SyncEngine.isStrong(etag) else {
                    out[t.name] = .refused("\(t.name) holds another re-encryption journal (another re-encryption in flight, or a "
                        + "start that stopped; first seen \(RFC3339.string(first)); it is replaced a day after)")
                    continue
                }
                out[t.name] = try t.remote.write([Vault.journalName], .data(journal), condition: .replace(etag: etag))
                    ? .claimed : .refused("\(t.name)'s journal changed meanwhile")
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

    /// Confirms one target (design §7.1 step 6(c)); see the top of this file. `memo` (path → version tag of a copy
    /// found current) spares reading files again; the caller keeps it per target.
    public static func confirm(vault v: Vault, target t: Target, memo: inout [String: String], scratch: URL) -> Confirmation {
        var c = Confirmation(target: t.name)
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
            do {
                let got = try r.read(path, maxBytes: BoundedRead.maxRevisionBytes)
                let isInbox = path.first == CaptureFile.folderName
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
                if epoch == nil, unaccepted == nil, !isInbox { return }   // pending or unreadable: no earlier key opens it here
                if epoch == nil, isInbox, !opensUnderOldKey(v, got.data, below: m) { return }
                guard let etag = got.etag ?? entry.etag, SyncEngine.isStrong(etag) else {
                    c.waiting[p] = "under an earlier key, and the target gives no strong version tag to replace it under"
                    return
                }
                let localURL = v.url.appendingPathComponent(p)
                if epoch != nil, let local = try? BoundedRead.contents(of: localURL, maxBytes: BoundedRead.maxRevisionBytes),
                   isInbox ? sameInbox(v, local, got.data, name: path[1], scratch: scratch)
                           : (v.acceptedKeyEpoch(of: local, path: p).map { $0 >= m } ?? false)
                             && v.plainBody(of: local, path: p) == v.plainBody(of: got.data, path: p) {
                    if try r.write(path, .data(local), condition: .replace(etag: etag)) { c.replaced.append(p) } else {
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
                confirmBlobs(v, r, note: noteId, below: m, into: &c, scratch: scratch)
            }
            for e in try r.list([NotebookRecords.folderName]) ?? [] where !e.isCollection && NotebookRecords.id(ofFileName: e.name) != nil {
                settle([NotebookRecords.folderName, e.name], entry: e)
            }
            for e in try r.list([CaptureFile.folderName]) ?? [] where !e.isCollection && CaptureFile.parse(name: e.name) != nil {
                settle([CaptureFile.folderName, e.name], entry: e)
            }
            if let e = try r.stat([SharedSettings.fileName]), !e.isCollection { settle([SharedSettings.fileName], entry: e) }
        } catch {
            fail(Vault.notesName, error)
        }
        // The earlier records go last, once nothing else needs them.
        guard c.waiting.isEmpty else { return c }
        do {
            for e in try r.list([Vault.epochsName]) ?? [] where !e.isCollection && Vault.isEpochRecordFileName(e.name) {
                guard let n = Int(e.name.split(separator: "-").first ?? ""), n < m else { continue }
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
    }

    /// One step of a pending re-encryption on home (design §7.1 steps 5–7): the pass, a run with every target (`sync`),
    /// each target confirmed, and, when every one is, the finish and a run with every target again. A crash, a lock
    /// or an unreachable target leaves it for the next call (`sempere vault reencrypt --resume`).
    public static func advance(_ vault: inout Vault, targets: [Target], sync: (Target) throws -> Void,
                               memo: inout [String: [String: String]], scratch: URL) throws -> Progress {
        var p = Progress()
        guard vault.isReencryptPending else { return p }
        let pass = try vault.reencryptPass()
        p.pass = pass
        for t in targets { try? sync(t) }
        vault = try vault.reopened()
        guard pass.remaining == 0, pass.problems.isEmpty, vault.isReencryptPending else { return p }
        for t in targets {
            var m = memo[t.name] ?? [:]
            p.targets.append(confirm(vault: vault, target: t, memo: &m, scratch: scratch))
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
    static func confirmBlobs(_ v: Vault, _ r: any SyncRemote, note: UUID, below m: Int, into c: inout Confirmation, scratch: URL) {
        let id = note.uuidString.lowercased()
        let folder = [Vault.notesName, id, Vault.attachmentsName]
        guard let entries = try? r.list(folder) ?? [] else { return }
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
            case .old(let epoch, accepted: true)? where epoch < m:
                c.waiting[p] = "an accepted blob under an earlier key whose current name is not on the target yet: sync first"
            case .old(let epoch, accepted: false)? where epoch < m:
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
