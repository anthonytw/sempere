import Crypto
import Foundation
import Sempere

// MARK: - Device changes over sync (docs/design/key-hierarchy.md §4.3, §5.2–§5.5, §8.2; phase KH4)
//
// - `epochs/`: write-once records, the union of both sides, pushed by every device that holds one to every
//   target it syncs (a withheld record comes back). Synced before `vault.json`, so a later epoch's record is
//   usually here when its `vault.json` is judged. Never deleted. A received record is checked for its shape
//   only: it counts once a `vault.json` names it with its hash.
// - `vault.json` of another epoch: judged by `Vault.judgeIncoming` (the chain, the precedence rule), never by
//   which side changed since the last run. A later epoch this device follows is taken, the vault reopened,
//   pinned and caught up (§5.4); one it cannot verify yet is remembered (a sighting) and the run uploads
//   nothing new (J5b), on every target, until it is verified; one that does not list this device makes it
//   unlisted (§5.5): it uploads nothing and keeps pulling `vault.json` and `epochs/`; when this device's own
//   is the later one, it replaces the target's.
// - Received files under an earlier key that the acceptance rule does not take are set aside, never placed or
//   quarantined; files whose key's record has not arrived are pending (not placed, fetched again once a record
//   or `vault.json` arrives).
// - An accepted copy replaces an unaccepted copy of the same path (§5.4 step 4), on either side, after the
//   unaccepted one is set aside on this device; never an accepted one, and only under a strong version tag.
// - `joins/`: the union, and a request one side deleted since both held it (home approved or expired it) is
//   deleted on the other. Home deletes requests older than 7 days and those of listed keys.
// - `keys/`: the union, except passphrase copies whose fingerprint neither `vault.json` names: deleted on the
//   target by a device whose verified epoch is at least the target's, never brought back (§8.2).

extension SyncEngine {
    /// How long a device's `synced` time (design §5.5) may age before a complete two-way run writes it again:
    /// each write is an upload to every target, so not on every run.
    static let syncedInterval: TimeInterval = 3600
    /// Join requests older than this are deleted by home (design §6.2).
    static let joinRequestLifetime: TimeInterval = 7 * 86_400

    // MARK: Holding back (J5b, unlisted)

    /// This run uploads nothing new: a later epoch this device cannot verify yet (`waiting`), or it is unlisted.
    func holdForEpoch(waiting: String? = nil, unlisted: String? = nil) {
        if let unlisted {
            epochStatus.unlisted = SyncReport.printable(unlisted)
            epochHold = "this device is not on the newest device list (design §5.5): \(unlisted) Nothing is uploaded; "
                + "vault.json and epochs/ are still pulled"
        } else if let waiting {
            epochStatus.waiting = SyncReport.printable(waiting)
            if epochHold == nil {
                epochHold = "waiting for a device change to be verified (design §4.3): \(waiting). Nothing new is uploaded "
                    + "until it is"
            }
        }
    }

    // MARK: epochs/

    func syncEpochRecords(remoteRoot: [String: RemoteEntry]) throws {
        defer { epochsDigest = Self.localEpochsDigest(root) }
        // Until the target's records are known, no vault.json goes there (`push`).
        remoteEpochRecords = []
        let folder = Vault.epochsName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let local = Set(try LocalFS.entries(localDir).filter(Vault.isEpochRecordFileName))
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        // Unchanged on both sides since the last run left them in step: not listed (as unchanged notes).
        let digest = Self.localEpochsDigest(root)
        let folderTag = remoteRoot[folder].flatMap { $0.isCollection ? $0.etag : nil }.flatMap { Self.isStrong($0) ? $0 : nil }
        if options.skipUnchangedNotes, hadState, state.folderETagsChange == true, let folderTag,
           state.epochsStamp == SyncState.EpochsStamp(etag: folderTag, local: digest) {
            remoteEpochRecords = local
            return
        }
        var transferred = false
        defer {
            if !options.dryRun {
                state.epochsStamp = (!transferred && folderTag != nil) ? SyncState.EpochsStamp(etag: folderTag ?? "", local: digest) : nil
            }
        }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if Vault.isEpochRecordFileName(e.name) {
                    listed[e.name] = e
                } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                    remoteJunk.append([folder, e.name])
                }
            }
        }
        // In step only when both sides held the same records before any transfer.
        if local != Set(listed.keys) { transferred = true }
        // Pushed by every device that holds one, unlisted ones excepted (they upload nothing).
        if epochStatus.unlisted == nil {
            for name in local.subtracting(listed.keys).sorted() {
                try checkCancelled()
                let path = "\(folder)/\(name)"
                let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: EpochRecord.maxBytes)
                if options.dryRun { report.uploaded.append(path); continue }
                try ensureCollection([folder])
                // A create-only write that finds the name taken: the record is there already (write-once).
                _ = try transport.write([folder, name], .data(data), condition: .create)
                report.uploaded.append(path)
                listed[name] = listed[name] ?? RemoteEntry(name: name, isCollection: false)
            }
        }
        remoteEpochRecords = Set(listed.keys).union(options.dryRun ? local : [])
        guard !options.pushOnly else { return }
        for name in Set(listed.keys).subtracting(local).sorted() {
            try checkCancelled()
            let path = "\(folder)/\(name)"
            if let size = listed[name]?.size, size > EpochRecord.maxBytes {
                report.skipped.append(.init(path: path, message: "larger than an epoch record may be; not downloaded"))
                continue
            }
            if try !available([folder, name], entry: listed[name]) { continue }
            let got: (data: Data, etag: String?)
            do { got = try transport.read([folder, name], maxBytes: EpochRecord.maxBytes) } catch where Self.isUnavailable(error) {
                noteArriving([folder, name])
                continue
            }
            try budget.downloaded(got.data.count)
            do { try Vault.checkIncomingEpochRecord(got.data, name: name) } catch {
                quarantine(path, path: path, entry: listed[name], reason: Self.describe(error), data: got.data)
                continue
            }
            try requireLocalWrite("write \(path)")
            report.downloaded.append(path)
            guard !options.dryRun else { continue }
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            try LocalFS.write(got.data, to: localDir.appendingPathComponent(name), replacing: false)
        }
    }

    /// A digest of the names in the local `epochs/` (a new record makes pending files worth fetching again).
    static func localEpochsDigest(_ root: URL) -> String {
        let names = ((try? LocalFS.entries(root.appendingPathComponent(Vault.epochsName))) ?? []).filter(Vault.isEpochRecordFileName)
        return String(FileDigest.sha256(Data(names.sorted().joined(separator: "\n").utf8)).prefix(16))
    }

    // MARK: vault.json of another epoch

    /// The epoch and id `data` (a `vault.json`) names; nil when it does not parse.
    static func epochOf(_ data: Data) -> (epoch: Int, epochId: Data)? {
        guard let m = try? EpochManifest.parse(data) else { return nil }
        return (m.epoch, m.epochId)
    }

    /// True when both parse and name different epochs.
    static func otherEpochs(_ a: Data, _ b: Data) -> Bool {
        guard let x = epochOf(a), let y = epochOf(b) else { return false }
        return x.epochId != y.epochId
    }

    /// The vault this run judges epochs with: opened with a device key.
    var epochJudge: Vault? {
        guard let v = vault, v.canRead, v.deviceFingerprint != nil else { return nil }
        return v
    }

    /// Two-way: the remote `vault.json` is of another epoch than the local one (design §4.3, §5.6).
    func syncManifestAcrossEpochs(local: Data, remoteData: Data, stamp: String?, etag: String?) throws {
        let name = Vault.manifestName
        guard let v = epochJudge else {
            // Locked here (or the recovery key): only the numbers can be compared.
            if let r = Self.epochOf(remoteData), let l = Self.epochOf(local), r.epoch >= l.epoch {
                holdForEpoch(waiting: "the target holds vault.json of epoch \(r.epoch) (this copy: epoch \(l.epoch)); open "
                    + "this vault with its device key so the change can be checked")
                report.rejected.append(.init(path: name, message: "of another epoch: unlock (--identity) so it can be checked "
                    + "(design §4.3)"))
            } else {
                try conflict(name, remote: remoteData, detail: "of an earlier epoch; unlock (--identity) so it can be checked")
            }
            return
        }
        let judgment = v.judgeIncoming(remoteData, local: local)
        switch judgment {
        case .same:
            try accept(name, remoteData, stamp: stamp, judged: true)
        case .later, .laterRecordPending:
            try accept(name, remoteData, stamp: stamp, judged: true)
            noteEpochTaken(remoteData, recordPending: judgment == .laterRecordPending)
        case .behind:
            // This device's chain is the later one: its vault.json replaces the target's, under the version read.
            guard let etag, Self.isStrong(etag) || options.dryRun else {
                if try push(name, local, condition: .unconditional) { try recordMutable(name, hash: FileDigest.sha256(local)) }
                return
            }
            if try push(name, local, condition: Self.replaceCondition(etag: etag)) {
                try recordMutable(name, hash: FileDigest.sha256(local))
            }
        case .waiting(let why):
            remember(remoteData, v)
            v.pinDeferredTakeover(remoteData)
            holdForEpoch(waiting: "\(why) (at \(SyncReport.printable(transport.location)))")
        case .unlisted(let notice):
            remember(remoteData, v)
            holdForEpoch(unlisted: notice)
        case .conflict(let why):
            epochStatus.conflict = SyncReport.printable(why)
            try conflict(name, remote: remoteData, detail: why)
        case .refused(let why):
            report.rejected.append(.init(path: name, message: SyncReport.printable(why)))
        }
    }

    /// Push-only: the server's `vault.json` is of another epoch (design §4.3). Returns true when the server's
    /// copy is kept (it is later, or cannot be judged here); false when the local one may replace it.
    func keepServerManifestOfOtherEpoch(local: Data, server: Data) -> Bool {
        remoteManifestData = server
        guard let v = epochJudge else {
            guard let r = Self.epochOf(server), let l = Self.epochOf(local), r.epoch >= l.epoch else { return false }
            holdForEpoch(waiting: "the server holds vault.json of epoch \(r.epoch) (this copy: epoch \(l.epoch)); a run with "
                + "this vault's device key checks it")
            report.conflicts.append(.init(path: Vault.manifestName, remoteCopy: nil, detail: "the server holds another epoch; "
                + "kept on the server"))
            return true
        }
        switch v.judgeIncoming(server, local: local) {
        case .behind, .refused, .same:
            return false
        case .later, .laterRecordPending:
            remember(server, v)
            holdForEpoch(waiting: "the server holds a later device change (epoch \(Self.epochOf(server)?.epoch ?? 0)); a "
                + "two-way run takes it")
        case .waiting(let why):
            remember(server, v)
            v.pinDeferredTakeover(server)
            holdForEpoch(waiting: "\(why) (at \(SyncReport.printable(transport.location)))")
        case .unlisted(let notice):
            remember(server, v)
            holdForEpoch(unlisted: notice)
        case .conflict(let why):
            epochStatus.conflict = SyncReport.printable(why)
            report.conflicts.append(.init(path: Vault.manifestName, remoteCopy: nil, detail: why + "; kept on the server"))
        }
        return true
    }

    /// Remembers a `vault.json` this device did not take (`Vault.rememberSighting`).
    private func remember(_ data: Data, _ v: Vault) {
        guard !options.dryRun else { return }
        do { try v.rememberSighting(data, source: transport.location, now: options.now) } catch {
            report.errors.append(.init(path: Vault.manifestName, message: "cannot remember the later device change: "
                + Self.describe(error)))
        }
    }

    private func noteEpochTaken(_ data: Data, recordPending: Bool) {
        epochTaken = true
        if let e = Self.epochOf(data) {
            epochStatus.taken = e.epoch
            epochStatus.recordPending = recordPending
            if !options.dryRun { epochJudge?.forgetSighting(e.epochId) }
        }
    }

    /// Before the remote's `vault.json` is compared (two-way, under the write lock): a later epoch seen on
    /// another target whose record has arrived since is taken now, and sightings still waiting (or making
    /// this device unlisted) hold this run's uploads back too (J5b on every target).
    func takeSettledSightings() throws {
        guard !options.pushOnly, !options.dryRun, let v = epochJudge else { return }
        let settled = v.settleSightings()
        var holds: [IncomingEpoch] = []
        for (s, judgment) in settled.sorted(by: { $0.sighting.epoch > $1.sighting.epoch }) {
            if judgment.isTaken, !epochTaken {
                try requireLocalWrite("write \(Vault.manifestName)")
                let local = try localMutable(Vault.manifestName)
                // Judged again against what is on disk now (another run may have moved it).
                let now = v.judgeIncoming(s.manifest, local: local)
                guard now.isTaken else { continue }
                try LocalFS.write(s.manifest, to: root.appendingPathComponent(Vault.manifestName), replacing: true)
                report.downloaded.append(Vault.manifestName)
                noteEpochTaken(s.manifest, recordPending: now == .laterRecordPending)
                v.forgetSighting(s.epochId)
                // The rest is judged against the vault as it is now.
                vault = try v.reopened()
                checkerCache = nil
                return try takeSettledSightings()
            }
            holds.append(judgment)
        }
        for j in holds {
            switch j {
            case .unlisted(let n): holdForEpoch(unlisted: n)
            case .waiting(let why): holdForEpoch(waiting: why)
            default: break
            }
        }
    }

    /// After the mutable files: a taken epoch reopens the vault under it, pins it (the trust record) and catches
    /// this device's own files up (design §5.4: re-encrypted under the new key, the rest set aside), outside the
    /// write lock, before the notes are judged or uploaded.
    func afterEpochTaken() {
        guard epochTaken, !options.dryRun, !options.pushOnly, let v = vault else { return }
        do {
            let fresh = try v.reopened()
            vault = fresh.canRead ? fresh : nil
            checkerBaseManifest = manifestHash()
            checkerCache = nil
            // What holds this run back is judged again under the epoch taken (a takeover that lists this device
            // again ends its being unlisted).
            epochHold = nil
            epochStatus.unlisted = nil
            epochStatus.waiting = nil
            if let n = fresh.unlistedNotice { holdForEpoch(unlisted: n) }
            if let w = fresh.waitingNotice { holdForEpoch(waiting: w) }
            guard fresh.canRead, fresh.deviceFingerprint != nil, fresh.listStatus.allowsWriting, fresh.isReadOnly == false else {
                if let p = fresh.listStatus.problem {
                    report.skipped.append(.init(path: Vault.manifestName, message: SyncReport.printable("taken, not pinned: \(p.detail)")))
                }
                return
            }
            if fresh.ledger != nil {
                let caught = try fresh.catchUp()
                epochStatus.caughtUp = caught.reencrypted.count
                for (path, why) in caught.problems.sorted(by: { $0.key < $1.key }) where path != fresh.manifest.epochRecord {
                    report.skipped.append(.init(path: path, message: SyncReport.printable("not caught up: \(why)")))
                }
            } else {
                // Pinned (the trust record), nothing to catch up without a ledger.
                try fresh.requireWritable()
            }
        } catch {
            report.skipped.append(.init(path: Vault.manifestName, message: "the new epoch was taken; "
                + SyncReport.printable(Self.describe(error))))
        }
    }

    // MARK: Received files the acceptance rule does not take

    /// A received file that did not pass its checks: set aside (an earlier key the acceptance rule does not
    /// take), pending (its key's record has not arrived), or quarantined (format.md §9.1).
    func refuseIncoming(_ key: String, path: String, entry: RemoteEntry?, problem: IncomingFileProblem,
                        data: Data? = nil, file: URL? = nil) {
        if problem.pending {
            locked {
                report.pending.append(.init(path: path, message: SyncReport.printable(problem.reason)))
                state.pendingEpoch = state.pendingEpoch ?? [:]
                state.pendingEpoch?[key] = pendingStamp(entry)
            }
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        if let reason = problem.setAside, let checker = checker(), let store = checker.setAsideStore {
            do {
                if let data {
                    try store.keep(data, path: path, vaultId: checker.vaultId, reason: reason)
                } else if let file {
                    try store.keep(file: file, path: path, vaultId: checker.vaultId, reason: reason)
                }
                locked {
                    report.setAside.append(.init(path: path, message: SyncReport.printable(problem.reason)))
                    state.quarantined = state.quarantined ?? [:]
                    state.quarantined?[key] = .init(stamp: Self.quarantineStamp(entry), manifest: manifestHash(),
                                                    unlocked: true, key: Self.checkerKeyID(checker), setAside: true)
                }
                if let file { try? FileManager.default.removeItem(at: file) }
                return
            } catch {
                // Not kept aside (design §5.8): quarantined instead, never placed.
            }
        }
        quarantine(key, path: path, entry: entry, reason: problem.reason, data: data, file: file)
    }

    /// The remote version and the local root a pending file was judged against.
    func pendingStamp(_ entry: RemoteEntry?) -> String {
        "\(Self.quarantineStamp(entry) ?? "")|\(manifestHash() ?? "")|\(epochsDigest)"
    }

    /// True when `key` waited for a record in an earlier run and neither its remote version nor the local
    /// `vault.json` and `epochs/` changed since: not fetched again.
    func skipPendingEpoch(_ key: String, path: String, entry: RemoteEntry?) -> Bool {
        locked {
            guard let recorded = state.pendingEpoch?[key] else { return false }
            guard recorded == pendingStamp(entry) else {
                state.pendingEpoch?[key] = nil
                return false
            }
            report.skipped.append(.init(path: path, message: "waits for a device-change record; fetched again once one arrives"))
            return true
        }
    }

    // MARK: An accepted copy replaces an unaccepted one (design §5.4 step 4)

    /// What this run compares on shared paths: the working copy's set-aside files still in place, and the
    /// latest bytes of this device's own writes at the current epoch (catch-up re-encryptions among them).
    func prepareReplacements() {
        guard let v = epochJudge else { return }
        unacceptedHere = v.unacceptedInPlace()
        guard v.manifest.epoch > 1, let ledger = v.ledger, let entries = try? ledger.entries() else { return }
        let current = Hex.encode(v.manifest.epochId)
        var latest: [String: String] = [:]
        for e in entries where e.epochId == current { latest[e.path] = e.sha256 }
        ledgerShas = latest
    }

    /// Both sides hold revision `n` of note `id`: when this device set its copy aside, or rewrote it since both
    /// sides last matched, the remote's is read; the accepted one replaces an unaccepted one.
    func replaceUnacceptedRevision(_ id: String, _ n: RevisionName, entry: RemoteEntry?) throws {
        let k = key(id, n)
        let path = "\(Vault.notesName)/\(k)"
        try replaceUnaccepted(path, remotePath: [Vault.notesName, id, n.filename], recordKey: k, entry: entry,
                              recorded: state.files[k]?.sha256) { data in
            guard let checker = checker(), let uuid = UUID(uuidString: id) else { return }
            try checker.checkIncomingRevision(data, noteId: uuid, name: n)
        }
    }

    /// The shared path `path` (remote `remotePath`): see `replaceUnacceptedRevision`. `check` must accept the
    /// remote copy before it is placed here.
    func replaceUnaccepted(_ path: String, remotePath: [String], recordKey: String, entry: RemoteEntry?, recorded: String?,
                           check: (Data) throws -> Void) throws {
        guard !options.dryRun, let v = epochJudge, v.setAsideStore != nil else { return }
        let here = unacceptedHere[path]
        let rewritten = ledgerShas[path]
        guard here != nil || (rewritten != nil && rewritten != recorded) else { return }
        let file = root.appendingPathComponent(path)
        let local = try BoundedRead.contents(of: file, maxBytes: options.maxFileBytes)
        let localSha = FileDigest.sha256(local)
        guard localSha == here || localSha == rewritten, localSha != recorded else { return }
        if try !available(remotePath, entry: entry) { return }
        let got = try transport.read(remotePath, maxBytes: options.maxFileBytes)
        try locked { try budget.downloaded(got.data.count) }
        let remoteSha = FileDigest.sha256(got.data)
        if remoteSha == localSha {
            locked { placedShas[recordKey] = localSha }
            return
        }
        let mine = v.acceptance(of: local, path: path), theirs = v.acceptance(of: got.data, path: path)
        guard let store = v.setAsideStore else { return }
        let etag = got.etag ?? entry?.etag
        if mine.isAccepted, case .setAside(let reason) = theirs {
            // The target holds an unaccepted copy: set aside here first (J6), then replaced under its version tag.
            guard let etag, Self.isStrong(etag) else {
                report.skipped.append(.init(path: path, message: "the target's copy is not accepted, and the target gives no "
                    + "strong version tag to replace it under; not replaced"))
                return
            }
            try store.keep(got.data, path: path, vaultId: v.vaultId, reason: reason)
            guard try transport.write(remotePath, .data(local), condition: .replace(etag: etag)) else {
                report.skipped.append(.init(path: path, message: "changed on the target meanwhile; compared again next run"))
                return
            }
            locked {
                report.uploaded.append(path)
                report.replaced.append(.init(side: "remote", path: path))
                placedShas[recordKey] = localSha
            }
        } else if theirs.isAccepted, !mine.isAccepted, mine != .pending {
            // This device's copy is not accepted, the target's is: kept aside first (J6), then replaced here.
            guard !options.pushOnly else { return }
            let reason: SetAsideReason
            if case .setAside(let r) = mine { reason = r } else { reason = .notSealed }
            try store.keep(local, path: path, vaultId: v.vaultId, reason: reason)
            do { try check(got.data) } catch {
                report.skipped.append(.init(path: path, message: SyncReport.printable("the target's copy does not check: \(error)")))
                return
            }
            try requireLocalWrite("replace \(path)")
            try LocalFS.write(got.data, to: file, replacing: true)
            locked {
                report.downloaded.append(path)
                report.replaced.append(.init(side: "local", path: path))
                placedShas[recordKey] = remoteSha
            }
        } else if mine.isAccepted, theirs.isAccepted {
            // Both accepted (a sealed copy and its re-encryption: the same body): neither is replaced.
            locked { placedShas[recordKey] = localSha }
        }
    }

    // MARK: joins/

    func syncJoinRequests(remoteRoot: [String: RemoteEntry]) throws {
        let folder = Vault.joinsName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        func isRequest(_ n: String) -> Bool {
            guard n.hasSuffix(".join.json") else { return false }
            let id = n.dropLast(".join.json".count)
            return id.count == 8 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
        var local = Set(try LocalFS.entries(localDir).filter(isRequest))
        // Home deletes requests older than 7 days and those of keys already listed (design §6.2).
        if let v = epochJudge, v.isHome, !options.dryRun, !options.pushOnly {
            for r in v.joinRequests() where local.contains(r.name) {
                let listed = r.request.map { req in v.manifest.keys.contains { $0.key == req.key } } ?? false
                let created = r.request.flatMap { RFC3339.parse($0.created) }
                let old = created.map { options.now.timeIntervalSince($0) > Self.joinRequestLifetime } ?? false
                if listed || old {
                    try? FileManager.default.removeItem(at: localDir.appendingPathComponent(r.name))
                    local.remove(r.name)
                    report.deleted.append(.init(side: "local", path: "\(folder)/\(r.name)"))
                }
            }
        }
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if isRequest(e.name) { listed[e.name] = e } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                }
            }
        }
        let recorded = Set(state.joins ?? [])
        var both = Set<String>()
        for name in local.union(listed.keys).sorted() {
            try checkCancelled()
            let path = "\(folder)/\(name)"
            switch (local.contains(name), listed[name]) {
            case (true, .some):
                both.insert(name)
            case (true, nil):
                if recorded.contains(name) {
                    // Deleted on the target since (approved or expired by home): deleted here too.
                    guard !options.pushOnly else { continue }
                    try requireLocalWrite("delete \(path)")
                    if !options.dryRun { try LocalFS.remove(localDir.appendingPathComponent(name)) }
                    report.deleted.append(.init(side: "local", path: path))
                } else {
                    let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: JoinRequest.maxBytes)
                    if options.dryRun { report.uploaded.append(path); continue }
                    try ensureCollection([folder])
                    if try transport.write([folder, name], .data(data), condition: .create) {
                        report.uploaded.append(path)
                        both.insert(name)
                    }
                }
            case (false, .some(let e)):
                if recorded.contains(name) {
                    // Deleted here since (home approved it): deleted on the target, in the version listed.
                    if !options.dryRun {
                        let etag = e.etag.flatMap { Self.isStrong($0) ? $0 : nil }
                        guard try transport.delete([folder, name], ifETag: etag) else { continue }
                    }
                    report.deleted.append(.init(side: "remote", path: path))
                } else {
                    guard !options.pushOnly else { continue }
                    if try !available([folder, name], entry: e) { continue }
                    let got: (data: Data, etag: String?)
                    do { got = try transport.read([folder, name], maxBytes: JoinRequest.maxBytes) } catch where Self.isUnavailable(error) {
                        noteArriving([folder, name])
                        continue
                    }
                    try budget.downloaded(got.data.count)
                    // A request is plaintext and untrusted (format.md §15.12): it must parse, name this vault, and
                    // be named after its own key.
                    guard let request = try? JoinRequest.parse(got.data), request.fileName == name,
                          request.vaultId.uuidString.lowercased() == checkerVaultId() ?? request.vaultId.uuidString.lowercased() else {
                        report.skipped.append(.init(path: path, message: "not a join request of this vault; not placed"))
                        continue
                    }
                    try requireLocalWrite("write \(path)")
                    report.downloaded.append(path)
                    guard !options.dryRun else { continue }
                    try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                    if try LocalFS.write(got.data, to: localDir.appendingPathComponent(name), replacing: false) { both.insert(name) }
                }
            case (false, nil):
                break
            }
        }
        if !options.dryRun { state.joins = both.isEmpty ? nil : both.sorted() }
    }

    /// The local vault's id (lowercase), from its `vault.json`.
    private func checkerVaultId() -> String? {
        (try? localMutable(Vault.manifestName)).flatMap { $0.flatMap { Self.manifestFields($0)?.vaultId } }
    }

    // MARK: keys/

    func syncPassphraseCopies(remoteRoot: [String: RemoteEntry]) throws {
        let folder = Vault.keysName
        let localDir = root.appendingPathComponent(folder, isDirectory: true)
        let local = Set(try LocalFS.entries(localDir).filter { Vault.passphraseCopyFingerprint($0) != nil })
        if let dir = remoteRoot[folder], dir.isCollection, folderArriving([folder], entry: dir) { return }
        var listed: [String: RemoteEntry] = [:]
        if remoteRoot[folder]?.isCollection == true, let entries = try transport.list([folder]) {
            try budget.list(entries.count)
            for e in entries where !e.isCollection {
                if Vault.passphraseCopyFingerprint(e.name) != nil { listed[e.name] = e } else if !e.name.hasPrefix(".") {
                    report.ignored.append("\(folder)/\(SyncReport.printable(e.name))")
                }
            }
        }
        // Superseded (design §8.2): the fingerprint matches no key of either vault.json.
        let localManifest = (try? localMutable(Vault.manifestName)).flatMap { $0.flatMap { try? EpochManifest.parse($0) } }
        let remoteManifest = remoteManifestData.flatMap { try? EpochManifest.parse($0) }
        var named = Set<Data>()
        for m in [localManifest, remoteManifest].compactMap({ $0 }) { for k in m.keys { named.insert(k.fingerprint) } }
        func superseded(_ name: String) -> Bool {
            guard localManifest != nil, let fp = Vault.passphraseCopyFingerprint(name) else { return false }
            return !named.contains(fp)
        }
        // Deleting on the target needs this device's own verified epoch at least the target's.
        let mayDelete: Bool = {
            guard let v = epochJudge, case .verified = v.listStatus else { return false }
            return v.manifest.epoch >= (remoteManifest?.epoch ?? 0)
        }()
        for name in local.union(listed.keys).sorted() {
            try checkCancelled()
            let path = "\(folder)/\(name)"
            switch (local.contains(name), listed[name]) {
            case (true, .some):
                if superseded(name), mayDelete, !options.pushOnly {
                    // Kept by nobody: deleted on both sides, never brought back.
                    if !options.dryRun { _ = try transport.delete([folder, name], ifETag: nil) }
                    report.deleted.append(.init(side: "remote", path: path))
                    try requireLocalWrite("delete \(path)")
                    if !options.dryRun { try LocalFS.remove(localDir.appendingPathComponent(name)) }
                    report.deleted.append(.init(side: "local", path: path))
                }
            case (true, nil):
                if superseded(name) {
                    if mayDelete, !options.pushOnly {
                        try requireLocalWrite("delete \(path)")
                        if !options.dryRun { try LocalFS.remove(localDir.appendingPathComponent(name)) }
                        report.deleted.append(.init(side: "local", path: path))
                    }
                    continue
                }
                let data = try BoundedRead.contents(of: localDir.appendingPathComponent(name), maxBytes: RecoveryPassphraseCopy.maxBytes)
                if options.dryRun { report.uploaded.append(path); continue }
                try ensureCollection([folder])
                if try transport.write([folder, name], .data(data), condition: .create) { report.uploaded.append(path) }
            case (false, .some(let e)):
                if superseded(name) {
                    if mayDelete {
                        if !options.dryRun {
                            let etag = e.etag.flatMap { Self.isStrong($0) ? $0 : nil }
                            guard try transport.delete([folder, name], ifETag: etag) else { continue }
                        }
                        report.deleted.append(.init(side: "remote", path: path))
                    }
                    continue
                }
                guard !options.pushOnly else { continue }
                if try !available([folder, name], entry: e) { continue }
                let got: (data: Data, etag: String?)
                do { got = try transport.read([folder, name], maxBytes: RecoveryPassphraseCopy.maxBytes) } catch where Self.isUnavailable(error) {
                    noteArriving([folder, name])
                    continue
                }
                try budget.downloaded(got.data.count)
                do { try Vault.checkIncomingPassphraseCopy(got.data, name: name) } catch {
                    quarantine(path, path: path, entry: e, reason: Self.describe(error), data: got.data)
                    continue
                }
                try requireLocalWrite("write \(path)")
                report.downloaded.append(path)
                guard !options.dryRun else { continue }
                try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                try LocalFS.write(got.data, to: localDir.appendingPathComponent(name), replacing: false)
            case (false, nil):
                break
            }
        }
    }

    // MARK: synced, unsynced changes (design §5.5)

    /// At the end of a complete two-way run: this device's `synced` time in its own summaries file.
    func recordOwnSynced() {
        guard options.recordSynced, !options.dryRun, !options.pushOnly, !options.pullOnly, options.partial == nil,
              report.errors.isEmpty,
              let v = epochJudge, let me = v.writerDevice, options.deviceID == nil || options.deviceID == me else { return }
        do { try v.recordSynced(device: me, now: options.now, granularity: Self.syncedInterval) } catch {
            report.skipped.append(.init(path: PublishedSummaries.deviceFolderName, message: "synced time not recorded: "
                + SyncReport.printable(Self.describe(error))))
        }
    }

    /// While unlisted: this device's own changes that the target does not hold, by its sync state (the files
    /// of its write ledger whose path the last runs did not find on both sides).
    func unsyncedChangeCount() -> Int {
        guard let ledger = vault?.ledger, let entries = try? ledger.entries() else { return 0 }
        var paths = Set(entries.map(\.path))
        paths = paths.filter { p in
            let parts = p.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[0] == Vault.notesName { return state.files[parts.dropFirst().joined(separator: "/")] == nil }
            if parts.count == 2, parts[0] == CaptureFile.folderName { return state.inbox?[parts[1]] == nil }
            if p == SharedSettings.fileName {
                let file = root.appendingPathComponent(p)
                let sha = (try? FileDigest.sha256(of: file).hex)
                return state.mutable[p]?.hash != sha
            }
            return true
        }
        return paths.count
    }
}
