import Foundation
import Sempere

// MARK: - Re-encryption over sync (docs/design/key-hierarchy.md §7.1 steps 6–7, §7.2; format.md §15.16; phase KH6)
//
// - `reencrypt-journal.age`: uploaded (create-only) before a `vault.json` that binds it, and a `vault.json` with
//   `reencryptPending` never goes to a target without its journal; taken from a target only when the local
//   `vault.json` binds it; a target's copy of another bound journal is replaced only where this device's list
//   stands; one this device's chain shows finished is deleted (here and where this device's list stands). An
//   unbound journal (a claim in flight, an abandoned start) is never uploaded, taken or deleted by a run.
// - Rewrap-replace (device-first-sync §5.2, rules 1–4): when both sides hold an accepted copy of a path with the
//   same body, the copy under the later epoch's key replaces the other (the smaller SHA-256 between two of one
//   epoch), on either side, only where this device's list stands and under a strong version tag. Revisions,
//   notebook records and inbox files; `settings.age` is merged as a mutable file, blobs change name.
// - Old blob names: a blob under an earlier key whose content the note references under the current key's name too
//   (a re-encryption's, or a catch-up's, duplicate) is never uploaded or downloaded, and is deleted on each side that
//   holds the current name.
// - Epoch records below a finished re-encryption (J7): never pushed or fetched, deleted here and on the target.

extension SyncEngine {
    // MARK: Old blob names

    /// The note's table of superseded blob base names (old → current), from this run's vault; empty without a
    /// re-encryption on its chain.
    func supersededTable(_ id: String) -> [String: String] {
        guard let v = epochJudge, v.reencryptEpoch != nil, let note = UUID(uuidString: id) else { return [:] }
        if let t = locked({ supersededTables[id] }) { return t }
        let t = v.supersededBlobBases(note: note)
        locked { supersededTables[id] = t }
        return t
    }

    /// The names among `names` that are superseded old names whose current name is among `present`.
    func supersededNames(_ id: String, _ names: Set<String>, present: Set<String>) -> [String: String] {
        let table = supersededTable(id)
        guard !table.isEmpty else { return [:] }
        let bases = Set(present.compactMap { BlobName.parse($0)?.name })
        var out: [String: String] = [:]
        for n in names {
            guard let base = BlobName.parse(n)?.name, let now = table[base], now != base, bases.contains(now) else { continue }
            out[n] = now
        }
        return out
    }

    /// Deletes the note's superseded old blob names on each side that holds the current name (here always; on the
    /// target only in a two-way run whose list stands there and that is not held), and forgets them in `set`.
    func dropSupersededBlobs(_ id: String, _ set: inout BlobSet) {
        guard !options.dryRun, let v = epochJudge else { return }
        let all = Set(set.local.keys).union(set.remote.keys)
        let old = supersededNames(id, all, present: all)
        guard !old.isEmpty else { return }
        let localBases = Set(set.local.keys.compactMap { BlobName.parse($0)?.name })
        let remoteBases = Set(set.remote.keys.compactMap { BlobName.parse($0)?.name })
        let mayWriteRemote = !options.pushOnly && epochHold == nil && epochStatus.conflict == nil && listStandsHere(v)
        for (name, now) in old.sorted(by: { $0.key < $1.key }) {
            if set.local[name] != nil, localBases.contains(now), !options.pushOnly {
                do {
                    try requireLocalWrite("delete \(blobPath(id, name))")
                    try LocalFS.remove(attURL(id).appendingPathComponent(name))
                    set.local[name] = nil
                    report.deleted.append(.init(side: "local", path: blobPath(id, name)))
                } catch {
                    report.errors.append(.init(path: blobPath(id, name), message: Self.describe(error)))
                }
            }
            if let e = set.remote[name], remoteBases.contains(now), mayWriteRemote {
                do {
                    let etag = e.etag.flatMap { Self.isStrong($0) ? $0 : nil }
                    if try transport.delete([Vault.notesName, id, Vault.attachmentsName, name], ifETag: etag) {
                        set.remote[name] = nil
                        report.deleted.append(.init(side: "remote", path: blobPath(id, name)))
                    }
                } catch {
                    report.errors.append(.init(path: blobPath(id, name), message: Self.describe(error)))
                }
            }
            // Gone from a side: not a deletion for the collection rules to judge (or copy back).
            if set.local[name] == nil || set.remote[name] == nil { set.recorded.remove(name) }
        }
    }

    // MARK: Rewrap-replace

    /// Which of two accepted copies with the same body wins (device-first-sync §5.2 rule 4): the one under the later
    /// epoch's key, else the smaller SHA-256. Nil when they are not both accepted with one body, or are the same.
    enum RewrapSide { case local, remote }
    func rewrapWinner(_ v: Vault, local: Data, remote: Data, path: String) -> RewrapSide? {
        guard local != remote, let le = v.acceptedKeyEpoch(of: local, path: path),
              let re = v.acceptedKeyEpoch(of: remote, path: path),
              let lb = v.plainBody(of: local, path: path), lb == v.plainBody(of: remote, path: path) else { return nil }
        if le != re { return le > re ? .local : .remote }
        return FileDigest.sha256(local) < FileDigest.sha256(remote) ? .local : .remote
    }

    /// `rewrapWinner` for an inbox file: both copies verify (current capture keys, or sealed under an earlier key) with
    /// the same content; only where this device's list stands and the run is not held.
    func inboxRewrapWinner(local: URL, remote: URL, name: String, localHash: String, remoteHash: String) -> RewrapSide? {
        guard !options.dryRun, epochHold == nil, epochStatus.conflict == nil, let v = epochJudge, listStandsHere(v),
              let l = v.acceptedInboxContent(local, name: name), let r = v.acceptedInboxContent(remote, name: name),
              l.content == r.content else { return nil }
        if l.epoch != r.epoch { return l.epoch > r.epoch ? .local : .remote }
        return localHash < remoteHash ? .local : .remote
    }

    // MARK: The journal

    /// Before the mutable files: whether the target holds the journal the local `vault.json` binds (`remoteJournalHere`),
    /// and the version of the one it holds otherwise. Nothing is written here: `push` queues the journal ahead of a
    /// `vault.json` that binds it (so a held run, which uploads no `vault.json`, uploads no journal either, J5b).
    func readReencryptJournal(_ remoteRoot: [String: RemoteEntry]) {
        remoteJournalHere = false
        remoteJournalETag = nil
        remoteJournalPresent = remoteRoot[Vault.journalName].map { !$0.isCollection } ?? false
        guard !options.dryRun, epochHold == nil, epochStatus.unlisted == nil,
              let manifest = (try? localMutable(Vault.manifestName)).flatMap({ $0 }).flatMap({ try? EpochManifest.parse($0) }),
              manifest.reencryptPending != nil else { return }
        let url = root.appendingPathComponent(Vault.journalName)
        guard let local = try? BoundedRead.contents(of: url, maxBytes: EpochRecord.maxBytes) else { return }
        if let v = epochJudge, v.boundJournal(local) == nil { return }
        guard let e = remoteRoot[Vault.journalName], !e.isCollection else { return }
        do {
            let got = try transport.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
            try budget.downloaded(got.data.count)
            remoteJournalHere = got.data == local
            remoteJournalETag = got.etag ?? e.etag
        } catch {
            report.errors.append(.init(path: Vault.journalName, message: Self.describe(error)))
        }
    }

    /// For a `vault.json` with `reencryptPending` about to be uploaded where the target lacks its journal: the journal
    /// queued ahead of it (created; another one there replaced under its version tag: the list being uploaded wins).
    /// False when it cannot be: the `vault.json` then waits.
    func queueJournal(for manifest: Data) -> Bool {
        if remoteJournalHere { return true }
        let url = root.appendingPathComponent(Vault.journalName)
        guard let local = try? BoundedRead.contents(of: url, maxBytes: EpochRecord.maxBytes) else { return false }
        if let v = epochJudge, (try? EpochManifest.parse(manifest))?.epochId == v.manifest.epochId, v.boundJournal(local) == nil {
            return false
        }
        let condition: PutCondition
        if remoteJournalPresent {
            guard let etag = remoteJournalETag, Self.isStrong(etag) else { return false }
            condition = .replace(etag: etag)
        } else {
            condition = .create
        }
        deferredUploads.append(DeferredUpload(name: Vault.journalName, data: local, condition: condition, verifyHash: nil))
        return true
    }

    /// After the mutable files (and a later epoch taken): a bound journal this copy lacks is taken from the target and
    /// the vault reopened with its keys; a target's other journal is replaced by the bound one where this device's list
    /// stands; a journal of a re-encryption this device's chain shows finished is deleted on both sides.
    func settleReencryptJournal(_ remoteRoot: [String: RemoteEntry]) {
        guard !options.dryRun, epochHold == nil, let v = epochJudge else { return }
        let url = root.appendingPathComponent(Vault.journalName)
        let local = try? BoundedRead.contents(of: url, maxBytes: EpochRecord.maxBytes)
        let entry = remoteRoot[Vault.journalName].flatMap { $0.isCollection ? nil : $0 }
        do {
            if v.isReencryptPending {
                if let local, v.boundJournal(local) != nil {
                    guard !remoteJournalHere, !journalUploaded, listStandsHere(v), epochStatus.conflict == nil else { return }
                    guard let entry else {
                        // The target holds this device's vault.json but not its journal (withheld, lost): put back.
                        if try transport.write([Vault.journalName], .data(local), condition: .create) {
                            report.uploaded.append(Vault.journalName)
                        }
                        return
                    }
                    guard !options.pushOnly else { return }
                    let got = try transport.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
                    try budget.downloaded(got.data.count)
                    guard got.data != local, v.boundJournal(got.data) == nil,
                          let etag = got.etag ?? entry.etag, Self.isStrong(etag) else { return }
                    if try transport.write([Vault.journalName], .data(local), condition: .replace(etag: etag)) {
                        report.uploaded.append(Vault.journalName)
                        report.replaced.append(.init(side: "remote", path: Vault.journalName))
                    }
                } else if let entry, !options.pushOnly {
                    if try !available([Vault.journalName], entry: entry) { return }
                    let got = try transport.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
                    try budget.downloaded(got.data.count)
                    guard v.boundJournal(got.data) != nil else {
                        report.skipped.append(.init(path: Vault.journalName, message: "not the journal vault.json binds; not taken"))
                        return
                    }
                    try requireLocalWrite("write \(Vault.journalName)")
                    try LocalFS.write(got.data, to: url, replacing: true)
                    report.downloaded.append(Vault.journalName)
                    // The earlier keys it holds: files that waited for them are read (and fetched) again.
                    let fresh = try v.reopened()
                    vault = fresh
                    checkerCache = nil
                    state.scannedEpoch = nil
                    cachedHeldKeys = nil
                }
                return
            }
            // No re-encryption pending here: a finished one's journal goes, wherever this device's list stands.
            if let local, v.isFinishedJournal(local), !options.pushOnly {
                try requireLocalWrite("delete \(Vault.journalName)")
                try LocalFS.remove(url)
                report.deleted.append(.init(side: "local", path: Vault.journalName))
            }
            if let entry, listStandsHere(v), epochStatus.conflict == nil, epochStatus.unlisted == nil {
                let got = try transport.read([Vault.journalName], maxBytes: EpochRecord.maxBytes)
                try budget.downloaded(got.data.count)
                guard v.isFinishedJournal(got.data) else { return }
                let etag = (got.etag ?? entry.etag).flatMap { Self.isStrong($0) ? $0 : nil }
                if try transport.delete([Vault.journalName], ifETag: etag) {
                    report.deleted.append(.init(side: "remote", path: Vault.journalName))
                }
            }
        } catch {
            report.errors.append(.init(path: Vault.journalName, message: Self.describe(error)))
        }
    }

    /// A received file set aside here (kept first) that opens under a key from before a finished re-encryption: deleted on
    /// the target where this device's list stands (J7 on a target home does not confirm, a bridge's), never otherwise.
    func deleteObsoleteUnaccepted(_ path: String, entry: RemoteEntry?, data: Data?, file: URL?) {
        guard !options.dryRun, !options.pushOnly, epochHold == nil, epochStatus.conflict == nil, let v = epochJudge,
              let m = v.recordsObsoleteBelow, listStandsHere(v),
              let bytes = data ?? file.flatMap({ try? BoundedRead.contents(of: $0, maxBytes: options.maxFileBytes) }),
              v.opensUnderEpoch(below: m, bytes) else { return }
        let etag = (entry?.etag).flatMap { Self.isStrong($0) ? $0 : nil }
        if (try? transport.delete(path.split(separator: "/").map(String.init), ifETag: etag)) == true {
            locked { report.deleted.append(.init(side: "remote", path: path)) }
        }
    }

    // MARK: Epoch records below a finished re-encryption

    /// The epoch below which records are obsolete for this run (a finished re-encryption on the verified chain).
    var recordsObsoleteBelow: Int? { vault?.recordsObsoleteBelow }

    /// True when `name` is an epoch record below a finished re-encryption.
    func isObsoleteRecord(_ name: String) -> Bool {
        guard let m = recordsObsoleteBelow, let v = vault else { return false }
        return v.isRecordBelowReencryption(name, m: m)
    }
}
