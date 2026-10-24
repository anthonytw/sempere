import Age
import Crypto
import Foundation

// Re-encrypt everything (docs/design/key-hierarchy.md §7; format.md §15.8, §15.16; phase KH6), the local part:
// home starts a `reencrypt` epoch (a new key and a new recovery key, its record carrying no parent key) whose
// `vault.json` binds the re-encryption journal (every earlier key of the chain, under the new key), re-encrypts
// every accepted file under an earlier key in its working copy (each copy verified before the old one goes), and
// finishes once its sync targets are confirmed: `vault.json` rewritten without the binding, the journal and the
// earlier epoch records deleted. The sync engine and `ReencryptCoordinator` (SempereSync) carry it to targets.

/// What a re-encryption's start decided before anything is written (design §7.1 steps 1–4): the new epoch's
/// key, its journal, the new recovery key and the device review. The journal's bytes are what the caller claims
/// every target with (create-only) before `beginReencryption` writes the epoch.
public struct ReencryptPreparation: Sendable {
    /// The journal file (age to the new epoch's vault identity), also written locally, unbound, by `prepare`.
    public let journalFile: Data
    /// The re-encryption epoch's number.
    public let epoch: Int
    let key: VaultEpochKey
    let newRecovery: MLKEM768X25519Identity
    let removed: Set<Data>
    let passphrase: String?
    let workFactor: Int
}

/// What one run of the re-encryption pass did (design §7.1 step 5).
public struct ReencryptPassReport: Hashable, Sendable {
    /// Paths re-encrypted under the current key (a blob: its new name).
    public var reencrypted: [String] = []
    /// Old blob names deleted after their new name was verified.
    public var oldBlobsDeleted: [String] = []
    /// Files under an earlier key that the acceptance rule does not take: never re-encrypted ("never launder"),
    /// set aside; with why.
    public var left: [String: String] = [:]
    /// Files under an earlier key still to do (the pass stopped at its limit, or a file failed).
    public var remaining = 0
    /// Files that could not be re-encrypted, with why; tried again by the next pass.
    public var problems: [String: String] = [:]
}

/// Where a re-encryption stands on this device (derived from the files, never stored; design §7.2 "Progress").
public struct ReencryptStatus: Hashable, Sendable {
    /// A journal is bound by `vault.json` (the re-encryption is not finished).
    public var pending: Bool
    /// The re-encryption epoch (the latest on the chain), if any.
    public var epoch: Int?
    /// The journal is here and checks (else the old files read as pending until it arrives).
    public var journalHere: Bool
    /// Files of the working copy under a key from before the re-encryption, accepted (the pass's work).
    public var remaining: Int
    /// Files of the working copy (revisions, blobs, notebook records, inbox files, settings).
    public var total: Int
    /// Files under an earlier key that are not accepted (set aside; removed from the working copy at the finish).
    public var unaccepted: Int
}

extension Vault {
    // MARK: - State

    /// The latest re-encryption epoch on this value's verified chain (design §7).
    public var reencryptEpoch: ChainEntry? {
        verifiedChain?.entries.last { $0.reason == EpochReason.reencrypt.rawValue }
    }

    /// True while `vault.json` binds a re-encryption journal (design §7.1 steps 4–7).
    public var isReencryptPending: Bool { manifest.reencryptPending != nil }

    /// `reencrypt-journal.age` in the working copy.
    var journalURL: URL { url.appendingPathComponent(Self.journalName) }

    /// The journal `data` when `vault.json` binds it (`reencryptPending` is its binding under the current key) and it
    /// opens under the key of the latest re-encryption epoch of the verified chain, naming that epoch, every key it
    /// holds an earlier epoch's of the chain (format.md §15.8). Nil otherwise: an unbound or finished journal gives
    /// no key, and is never uploaded.
    public func boundJournal(_ data: Data) -> ReencryptJournal? {
        guard let secret, let pending = manifest.reencryptPending, let m = reencryptEpoch, m.epoch <= manifest.epoch,
              data.count <= EpochRecord.maxBytes,
              ReencryptJournal.binding(journalFile: data, vaultId: vaultId, currentKey: secret) == pending else { return nil }
        let km: VaultEpochKey?
        if m.epochId == secret.epochId { km = secret } else { km = olderEpochs.first { $0.epochId == m.epochId }?.key }
        guard let km, let journal = try? ReencryptJournal.open(data, key: km, vaultId: vaultId),
              journal.epoch == m.epoch, journal.epochId == m.epochId, let chain = verifiedChain?.entries else { return nil }
        for k in journal.keys {
            guard k.epoch < m.epoch, k.epoch <= chain.count, chain[k.epoch - 1].epochId == k.key.epochId else { return nil }
        }
        return journal
    }

    /// The local journal's bytes and contents when `vault.json` binds it.
    func localBoundJournal() -> (file: Data, journal: ReencryptJournal)? {
        guard isReencryptPending, let data = try? BoundedRead.contents(of: journalURL, maxBytes: EpochRecord.maxBytes),
              let j = boundJournal(data) else { return nil }
        return (data, j)
    }

    /// The journal a new epoch must keep bound (design §7.2): the local one while a re-encryption is pending; nil
    /// when none is. A pending re-encryption whose journal is not here refuses the change (a `vault.json` without
    /// the binding would read as finished).
    func pendingJournalToCarry() throws -> Data? {
        guard isReencryptPending else { return nil }
        guard let (file, _) = localBoundJournal() else {
            throw VaultError.epochChangeRefused("a re-encryption is pending and its journal (\(Self.journalName)) is not "
                + "here: sync with a target that holds it first")
        }
        return file
    }

    /// At open (`Vault.open`): the earlier keys a re-encryption record does not carry, from its bound journal while it
    /// is pending and from this device's own pinned keys (its ledger), and, once it is finished, the walk below it
    /// settled (design §7.2).
    mutating func attachReencryptKeys() {
        guard let keyring, reencryptEpoch != nil else { return }
        var keys: [(epoch: Int, key: VaultEpochKey)] = []
        if let (_, j) = localBoundJournal() {
            keys += j.keys.map { ($0.epoch, $0.key) }
            // The journal's keys are this device's own from now on (kept after the finish, owner decision "keep"): a
            // device that jumped epochs never held some of them, and without them, after the finish, it could neither
            // judge nor delete a file a removed device uploaded under one (it read as undecryptable and was only
            // quarantined, so a bridged target kept it).
            if case .device = openedWith, let ledger {
                for k in j.keys where ledgerMemo.needsKey(k.key.epochId) {
                    if (try? ledger.rememberKey(epoch: k.epoch, key: k.key)) != nil { ledgerMemo.keyRemembered(k.key.epochId) }
                }
            }
        }
        if case .device = openedWith, let held = try? ledger?.epochKeys() { keys += held }
        keyring.addFallback(keys)
        if !isReencryptPending, let m = reencryptEpoch { keyring.setFinishedReencryption(m.epoch) }
    }

    // MARK: - Start (design §7.1 steps 1–4)

    /// Prepares a re-encryption on home (design §7.1): checks the device review (every listed device but home in
    /// `keep` or `remove`, as for a kit replacement, §6.5), that no re-encryption is pending and that every earlier
    /// key of the chain is readable, then makes the new epoch's key and its journal (every earlier key of the kept
    /// chain), and writes the journal locally, unbound (no reader takes a key from it, and no run uploads it, until
    /// `vault.json` binds it). Nothing else is written. The caller claims every target with `journalFile`, then
    /// calls `beginReencryption`; on a failed claim, `abandonReencryptionStart`.
    ///
    /// - Throws: `epochChangeRefused` for an incomplete review, a pending re-encryption, unknown earlier keys.
    public func prepareReencryption(_ newRecovery: MLKEM768X25519Identity, keep: Set<String>, remove: Set<String>,
                                    passphrase: String? = nil, workFactor: Int = RecoveryPassphraseCopy.workFactor,
                                    now: Date = Date()) throws -> ReencryptPreparation {
        _ = try requireHomeForEpoch("re-encrypts the vault")
        if let passphrase, passphrase.isEmpty { throw VaultError.emptyPassphrase }
        guard (1...RecoveryPassphraseCopy.workFactor).contains(workFactor) else { throw VaultError.workFactorOutOfRange(workFactor) }
        guard !isReencryptPending else {
            throw VaultError.epochChangeRefused("a re-encryption is pending already: finish it first (sempere vault reencrypt "
                + "--resume)")
        }
        if let data = try? BoundedRead.contents(of: journalURL, maxBytes: EpochRecord.maxBytes), boundJournal(data) != nil {
            throw VaultError.epochChangeRefused("a bound re-encryption journal is here already")
        }
        let review = try kitReview()
        let kept = Set(try keep.map { try resolveDevice($0).fingerprint })
        let gone = Set(try remove.map { try resolveDevice($0).fingerprint })
        guard kept.isDisjoint(with: gone) else { throw VaultError.epochChangeRefused("a device is both kept and removed") }
        let unanswered = review.filter { !kept.contains($0.device.fingerprint) && !gone.contains($0.device.fingerprint) }
        guard unanswered.isEmpty else {
            throw VaultError.epochChangeRefused("confirm or remove every device first (design §7.1): "
                + unanswered.map { "\(DeviceName.display($0.device.name)) (\($0.device.id ?? "?"))" }.joined(separator: ", "))
        }
        guard !gone.contains(manifest.home) else { throw VaultError.epochChangeRefused("the home device cannot remove itself") }
        let newKey = newRecovery.recipient.string
        guard newKey != manifest.recoveryEntry?.key, !manifest.keys.contains(where: { $0.key == newKey }) else {
            throw VaultError.epochChangeRefused("the new recovery key is a key this vault lists already")
        }
        // Every earlier key of the kept chain (design §7.4), back to the previous finished re-encryption (whose
        // earlier epochs hold no file any more): the readers of the pass need them while it is pending.
        let current = try requireSecret()
        let chain = try currentChain()
        let floor = chain.dropLast().last { $0.reason == EpochReason.reencrypt.rawValue }?.epoch ?? 1
        var keys = [ReencryptJournal.Key(epoch: manifest.epoch, key: current)]
        var have = Set([manifest.epoch])
        for o in olderEpochs where o.epoch >= floor && o.sealed != nil && !have.contains(o.epoch) {
            keys.append(.init(epoch: o.epoch, key: o.key))
            have.insert(o.epoch)
        }
        let missing = (floor...manifest.epoch).filter { !have.contains($0) }
        guard missing.isEmpty else {
            throw VaultError.epochChangeRefused("the keys of epoch(s) \(missing.map(String.init).joined(separator: ", ")) are not "
                + "readable from the records here: sync first")
        }
        let key = VaultEpochKey.random()
        let journal = ReencryptJournal(vaultId: vaultId, epoch: manifest.epoch + 1, epochId: key.epochId,
                                       keys: keys.sorted { $0.epoch < $1.epoch }, created: RFC3339.string(now),
                                       by: deviceEntry?.id ?? "")
        let file = try journal.seal(key: key)
        // Durable before any claim names it, so a crash before the epoch leaves bytes this device can match its claims
        // against (and delete them): `abandonReencryptionStart`.
        try FileIO.writeAtomically(file, to: journalURL, replacing: true)
        try faults.check(.afterJournal)
        return ReencryptPreparation(journalFile: file, epoch: manifest.epoch + 1, key: key, newRecovery: newRecovery,
                                    removed: gone, passphrase: passphrase, workFactor: workFactor)
    }

    /// Starts the re-encryption `prep` describes (design §7.1 step 4), after the caller claimed every target: the
    /// `reencrypt` epoch (its record under its final name, carrying no parent key, then `vault.json` binding the
    /// journal), which drops the old recovery key and the devices the review removed and lists the new recovery key.
    /// The passphrase copy, when asked for, is written for the new key before and the old ones are deleted after.
    /// From then on every write is under the new key; `reencryptPass` rewrites the earlier files.
    @discardableResult
    public mutating func beginReencryption(_ prep: ReencryptPreparation, now: Date = Date()) throws -> EpochChangeReport {
        let (signing, home) = try requireHomeForEpoch("re-encrypts the vault")
        guard manifest.epoch + 1 == prep.epoch, !isReencryptPending,
              (try? BoundedRead.contents(of: journalURL, maxBytes: EpochRecord.maxBytes)) == prep.journalFile else {
            throw VaultError.epochChangeRefused("the vault changed since the re-encryption was prepared: prepare it again")
        }
        let newSign = try DeviceSigningKeys.recovery(identity: prep.newRecovery).publicKeys()
        let recoveryEntry = EpochKeyEntry(role: .recovery, key: prep.newRecovery.recipient.string, sign: newSign,
                                          added: RFC3339.string(now), name: "Recovery kit", wrap: "")
        if let passphrase = prep.passphrase {
            let copy = RecoveryPassphraseCopy(created: RFC3339.string(now), vaultId: vaultId, root: manifest.root,
                                              identity: prep.newRecovery)
            try FileIO.createDirectory(keysURL)
            try FileIO.writeAtomically(try copy.seal(passphrase: passphrase, workFactor: prep.workFactor),
                                       to: url.appendingPathComponent(try copy.path()), replacing: true)
        }
        let gone = prep.removed
        let report = try changeEpoch(reason: .reencrypt, now: now, key: prep.key, journalFile: prep.journalFile) { m in
            (m.devices.filter { !gone.contains($0.fingerprint) }, recoveryEntry, home, signing, m.home, nil)
        }
        sweepSupersededPassphraseCopies()
        return report
    }

    /// After a start that did not reach its epoch (a refused claim, a crash before `beginReencryption`): the local
    /// journal that `vault.json` does not bind, deleted here; its bytes are returned so the caller deletes its claims
    /// (the targets' journals with the same bytes). Nil when there is none, or when the local journal is bound.
    @discardableResult
    public func abandonReencryptionStart() throws -> Data? {
        guard let data = try? BoundedRead.contents(of: journalURL, maxBytes: EpochRecord.maxBytes) else { return nil }
        if boundJournal(data) != nil { return nil }
        try requireWritable()
        try FileIO.remove(journalURL)
        return data
    }

    // MARK: - The pass (design §7.1 step 5)

    /// One file of the working copy under a key from before the re-encryption.
    struct OldFile {
        enum Kind {
            case framed, blob(note: UUID, name: String), inbox(name: String, kind: CaptureFile.Kind)
            /// A blob under an earlier key whose content is here under the current key's name already (a pass stopped
            /// between the two): only the old name is left to delete.
            case supersededBlob(note: UUID, name: String)
        }
        var path: String
        var kind: Kind
        /// Accepted (re-encrypted by the pass) or not (left, set aside), with why.
        var unaccepted: SetAsideReason?
    }

    /// The working copy's files under a key of an epoch below the re-encryption epoch `m`, how many files it holds in
    /// all, and the files no key here opens while an earlier record is missing (they may be under an earlier key: until
    /// they can be judged, the pass does not count as done).
    func oldFiles(below m: Int) throws -> (old: [OldFile], total: Int, undecided: [String]) {
        var out: [OldFile] = []
        var total = 0
        var undecided: [String] = []
        func framed(_ path: String, _ file: URL, maxBytes: Int) {
            total += 1
            guard let data = try? readFile(file, maxBytes: maxBytes) else { return }
            let opened = openUnderEpochs(data)
            if case .pending = opened { undecided.append(path); return }
            guard case .opened(_, _, let older?) = opened, older.epoch < m else { return }
            out.append(OldFile(path: path, kind: .framed, unaccepted: setAsideReason(older, path: path, sha256: FileDigest.sha256(data))))
        }
        let current = try requireSecret()
        let currentIdentity: [any AgeIdentity] = [NativeIdentity.mlkem768x25519(try current.vaultIdentity())]
        for note in try noteDirectoryNames() {
            guard let id = UUID(uuidString: note) else { continue }
            let dir = noteURL(id)
            for name in try revisionFileNames(in: dir) {
                framed(Self.notePath(id, name), dir.appendingPathComponent(name), maxBytes: BoundedRead.maxRevisionBytes)
            }
            let att = attURL(id)
            for file in (try? FileIO.entries(att)) ?? [] where BlobName.parse(file) != nil {
                let u = att.appendingPathComponent(file)
                guard !FileIO.isDirectory(u) else { continue }
                total += 1
                // Under the current key: nothing to do (its name is checked when it is read).
                if (try? Self.peekBlobFile(u, identities: currentIdentity)) != nil { continue }
                guard let o = blobOlderEpochs.first(where: { (try? Self.peekBlobFile(u, identities: [$0.identity])) != nil }) else {
                    if keyring?.isIncomplete == true { undecided.append(Self.blobPath(id, file)) }
                    continue
                }
                guard o.epoch < m else { continue }
                let path = Self.blobPath(id, file)
                if let peek = try? Self.peekBlobFile(u, identities: [o.identity]),
                   let kind = BlobName.parse(file)?.kind,
                   FileIO.exists(att.appendingPathComponent(BlobName.fileName(name: BlobName.name(digest: peek.header.digest, secret: current),
                                                                               kind: kind))) {
                    out.append(OldFile(path: path, kind: .supersededBlob(note: id, name: file), unaccepted: nil))
                    continue
                }
                var reason: SetAsideReason?
                do { _ = try readAcceptedBlob(u, note: id, older: o, expected: nil, maxContent: BlobRef.maxSize) } catch BlobError.setAside(let r) {
                    reason = r
                } catch {
                    reason = .notSealed
                }
                out.append(OldFile(path: path, kind: .blob(note: id, name: file), unaccepted: reason))
            }
        }
        for name in (try? notebookRecordNames()) ?? [] {
            framed("\(NotebookRecords.folderName)/\(name)", notebooksURL.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes)
        }
        if FileIO.exists(sharedSettingsURL) {
            framed(SharedSettings.fileName, sharedSettingsURL, maxBytes: SharedSettings.maxFileBytes)
        }
        let ring = (try? captureKeyRing()) ?? []
        for name in (try? FileIO.entries(inboxURL)) ?? [] {
            guard let parsed = CaptureFile.parse(name: name) else { continue }
            let file = inboxURL.appendingPathComponent(name)
            total += 1
            if (try? verifyInboxFile(file, name: name, kind: parsed.kind, ring: ring)) != nil { continue }
            let path = "\(CaptureFile.folderName)/\(name)"
            if let (o, _) = sealedEarlierInboxFile(file, name: name, kind: parsed.kind) {
                if o.epoch < m { out.append(OldFile(path: path, kind: .inbox(name: name, kind: parsed.kind), unaccepted: nil)) }
                continue
            }
            guard let data = try? FileIO.read(file, maxBytes: CaptureFile.maxSealedBytes(parsed.kind)) else { continue }
            let opened = openUnderEpochs(data)
            if case .pending = opened { undecided.append(path); continue }
            guard case .opened(_, _, let older?) = opened, older.epoch < m else { continue }
            out.append(OldFile(path: path, kind: .inbox(name: name, kind: parsed.kind),
                               unaccepted: older.sealed == nil ? older.unsealedReason : .notSealed))
        }
        return (out.sorted { $0.path < $1.path }, total, undecided.sorted())
    }

    /// Where the re-encryption stands on this device (design §7.2 "Progress").
    public func reencryptStatus() throws -> ReencryptStatus {
        guard let m = reencryptEpoch else {
            return ReencryptStatus(pending: false, epoch: nil, journalHere: false, remaining: 0, total: 0, unaccepted: 0)
        }
        let (old, total, _) = try oldFiles(below: m.epoch)
        return ReencryptStatus(pending: isReencryptPending, epoch: m.epoch, journalHere: localBoundJournal() != nil,
                               remaining: old.filter { f in
                                   if case .supersededBlob = f.kind { return !Self.epochMutations.contains(.keepOldBlobNames) }
                                   return f.unaccepted == nil
                               }.count, total: total,
                               unaccepted: old.filter { $0.unaccepted != nil }.count)
    }

    /// Re-encrypts, under the current key, every accepted file of the working copy under a key from before the
    /// re-encryption epoch (design §7.1 step 5): revisions, notebook records, `settings.age` and inbox files in place
    /// (the same name), blobs under their new name, then the old name deleted. Each copy is verified (it decrypts
    /// under the current key, its tag or name verifies, its body equals the old body), recorded in this device's
    /// ledger and made durable before the old file goes. A file the acceptance rule does not take is never
    /// re-encrypted: it is set aside and reported (`left`). Files already current are skipped, so the pass resumes
    /// where a crash, a lock or a limit stopped it. Only home runs it, while the re-encryption is pending.
    ///
    /// - Parameter limit: at most this many files this run (nil: all).
    public func reencryptPass(limit: Int? = nil) throws -> ReencryptPassReport {
        try requireWritable()
        guard isHome else { throw VaultError.notHome("only the home device re-encrypts the vault") }
        guard isReencryptPending, let m = reencryptEpoch else {
            throw VaultError.epochChangeRefused("no re-encryption is pending")
        }
        guard localBoundJournal() != nil else {
            throw VaultError.epochChangeRefused("the re-encryption journal is not here: sync first")
        }
        var report = ReencryptPassReport()
        // An earlier record missing (withheld, or deleted by a finish this device has not seen) leaves only files that
        // no key here opens undecided: the pass waits for them, the rest goes on.
        let (old, _, undecided) = try oldFiles(below: m.epoch)
        for p in undecided { report.problems[p] = "no key here opens it while an earlier record is missing: sync first" }
        report.remaining += undecided.count
        var n = 0
        // The broken pass (J9's mutation): what is done is redone, what is left is skipped, so it never ends.
        let inverted = Self.epochMutations.contains(.reencryptSkipInverted)
        for f in old {
            if let reason = f.unaccepted {
                report.left[f.path] = reason.text
                if let store = setAsideStore {
                    try? store.keep(file: url.appendingPathComponent(f.path), path: f.path, vaultId: vaultId, reason: reason)
                }
                continue
            }
            if inverted || (limit.map { n >= $0 } ?? false) { report.remaining += 1; continue }
            n += 1
            do {
                switch f.kind {
                case .framed:
                    report.reencrypted.append(try reencryptAcceptedFramed(f.path, n: n))
                case .blob(let note, let name):
                    let made = try reencryptAcceptedBlob(note: note, name: name, n: n)
                    report.reencrypted.append(made)
                    if made != f.path { report.oldBlobsDeleted.append(f.path) }
                case .inbox(let name, let kind):
                    report.reencrypted.append(try reencryptAcceptedCapture(name: name, kind: kind, n: n))
                case .supersededBlob(let note, let name):
                    if !Self.epochMutations.contains(.keepOldBlobNames) {
                        try FileIO.remove(attURL(note).appendingPathComponent(name))
                        report.oldBlobsDeleted.append(f.path)
                    }
                }
            } catch VaultError.interrupted {
                throw VaultError.interrupted
            } catch {
                report.problems[f.path] = "\(error)"
                report.remaining += 1
            }
        }
        return report
    }

    /// Re-encrypts the accepted framed file at `path` (a revision, a notebook record, `settings.age`) in place.
    func reencryptAcceptedFramed(_ path: String, n: Int) throws -> String {
        guard let (scope, name) = Self.framing(path) else { throw VaultError.epochChangeRefused("\(path): not a framed file") }
        let file = url.appendingPathComponent(path)
        let maxBytes = path == SharedSettings.fileName ? SharedSettings.maxFileBytes : BoundedRead.maxRevisionBytes
        let data = try readFile(file, maxBytes: maxBytes)
        guard case .opened(let plain, let key, let older?) = openUnderEpochs(data),
              setAsideReason(older, path: path, sha256: FileDigest.sha256(data)) == nil else {
            throw VaultError.epochChangeRefused("\(path) is not an accepted file under an earlier key")
        }
        let gzip = try BodyFraming.unframe(plain, noteId: scope, filename: name, secret: key).gzip
        let current = try requireSecret()
        let corrupt = Self.epochMutations.contains(.corruptReencryption)
        let fresh = try encrypt(BodyFraming.frame(gzip: corrupt ? try Gzip.compress(Data("{}".utf8)) : gzip, noteId: scope,
                                                  filename: name, secret: current))
        let dir = file.deletingLastPathComponent()
        let tmp = FileIO.tempURL(in: dir)
        try FileIO.writeNewFile(tmp) { try $0(fresh) }
        var placed = false
        defer { if !placed { try? FileManager.default.removeItem(at: tmp) } }
        try faults.check(.reencryptWritten(n))
        // The copy decrypts under the current key and holds the same body before anything is replaced (J8).
        let check = try BoundedRead.contents(of: tmp, maxBytes: maxBytes)
        guard corrupt || (try? AgeFile.decrypt(check, with: identities)).flatMap({
            try? BodyFraming.unframe($0, noteId: scope, filename: name, secret: current).gzip
        }) == gzip else {
            throw VaultError.epochChangeRefused("\(path): the re-encrypted copy does not read back")
        }
        try faults.check(.reencryptVerified(n))
        try recordWrite(path: path, bytes: fresh)
        try faults.check(.reencryptRecorded(n))
        try FileIO.place(tmp, at: file)
        placed = true
        try faults.check(.reencryptPlaced(n))
        return path
    }

    /// Re-encrypts the accepted blob `name` of `note` under its name for the current key (written, recorded and
    /// verified), then deletes the old name. Returns the new path.
    func reencryptAcceptedBlob(note: UUID, name: String, n: Int) throws -> String {
        let old = attURL(note).appendingPathComponent(name)
        let before = Set((try? FileIO.entries(attURL(note))) ?? [])
        let ref = try reencryptBlob(at: old, note: note, fileName: name)
        try faults.check(.reencryptWritten(n))
        let target = try blobCandidates(note: note, ref)[0]
        guard Self.epochMutations.contains(.corruptReencryption) || isValidBlob(target, ref: ref) else {
            throw VaultError.epochChangeRefused("\(Self.blobPath(note, name)): the re-encrypted blob does not read back")
        }
        try faults.check(.reencryptVerified(n))
        try faults.check(.reencryptPlaced(n))
        let made = Set((try? FileIO.entries(attURL(note))) ?? []).subtracting(before).first ?? target.lastPathComponent
        try faults.check(.beforeOldBlobDeleted(n))
        if target.lastPathComponent != name, !Self.epochMutations.contains(.keepOldBlobNames) { try FileIO.remove(old) }
        return Self.blobPath(note, made)
    }

    /// Re-seals the accepted inbox file `name` (sealed under an earlier key, the record closing it seals it) under the
    /// current key, tagged with its sealing device's capture key of the current epoch, in place.
    func reencryptAcceptedCapture(name: String, kind: CaptureFile.Kind, n: Int) throws -> String {
        let file = inboxURL.appendingPathComponent(name)
        let path = "\(CaptureFile.folderName)/\(name)"
        guard let (older, entry) = sealedEarlierInboxFile(file, name: name, kind: kind) else {
            throw VaultError.epochChangeRefused("\(path) is not an accepted capture under an earlier key")
        }
        let data = try FileIO.read(file, maxBytes: CaptureFile.maxSealedBytes(kind))
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [older.identity]) } catch {
            throw VaultError.epochChangeRefused("\(path) does not decrypt under the key it was sealed under")
        }
        let current = try requireSecret()
        let oldKey = CaptureKey.derive(from: older.key, device: entry.recipient)
        let newKey = CaptureKey.derive(from: current, device: entry.recipient)
        guard let retagged = CaptureFile.retag(plain, filename: name, verifiedBy: oldKey, to: newKey) else {
            throw VaultError.epochChangeRefused("\(path) does not verify under its sealing device's capture key")
        }
        let corrupt = Self.epochMutations.contains(.corruptReencryption)
        let fresh = try encrypt(corrupt ? Data(retagged.dropLast()) : retagged)
        let tmp = FileIO.tempURL(in: inboxURL)
        try FileIO.writeNewFile(tmp) { try $0(fresh) }
        var placed = false
        defer { if !placed { try? FileManager.default.removeItem(at: tmp) } }
        try faults.check(.reencryptWritten(n))
        func framed(_ sealed: Data?, _ key: CaptureKey) -> Data? {
            guard let sealed, let c = try? CaptureFile.unframe(sealed, filename: name, key: key) else { return nil }
            return c.line + [0x0A] + c.payload
        }
        let readBack: Data? = framed(try? AgeFile.decrypt(try FileIO.read(tmp, maxBytes: CaptureFile.maxSealedBytes(kind)),
                                                          with: identities), newKey)
        let original: Data? = framed(plain, oldKey)
        guard corrupt || (readBack != nil && readBack == original) else {
            throw VaultError.epochChangeRefused("\(path): the re-sealed copy does not read back")
        }
        try faults.check(.reencryptVerified(n))
        try recordWrite(path: path, bytes: fresh)
        try faults.check(.reencryptRecorded(n))
        try FileIO.place(tmp, at: file)
        placed = true
        try faults.check(.reencryptPlaced(n))
        return path
    }

    // MARK: - Finish (design §7.1 step 7)

    /// Finishes the pending re-encryption on home (design §7.1 step 7), once the caller confirmed every sync target
    /// (`ReencryptCoordinator.confirm`: every file there under the new keys, the earlier records and old blob names
    /// gone): the pass must have nothing left here. Files under an earlier key that the acceptance rule does not take
    /// are set aside and removed from the working copy (they are kept in the set-aside store). Then `vault.json` is
    /// rewritten without `reencryptPending` (home's later version of the epoch), the journal and the earlier epoch
    /// records are deleted, and this device marks the re-encryption finished in its trust record (a replayed journal
    /// is refused from then on).
    public mutating func finishReencryption() throws {
        try requireWritable()
        let key = try requireSecret()
        guard isHome, let signing, let home = deviceEntry else { throw VaultError.notHome("only the home device finishes it") }
        guard isReencryptPending, let m = reencryptEpoch else { throw VaultError.epochChangeRefused("no re-encryption is pending") }
        let (old, _, undecided) = try oldFiles(below: m.epoch)
        if let p = undecided.first {
            throw VaultError.epochChangeRefused("\(undecided.count) file(s) cannot be judged while an earlier record is missing (\(p)): sync first")
        }
        let todo = old.filter { f in
            guard f.unaccepted == nil else { return false }
            if case .supersededBlob = f.kind { return !Self.epochMutations.contains(.keepOldBlobNames) }
            return true
        }
        if let first = todo.first {
            throw VaultError.epochChangeRefused("\(todo.count) file(s) are not re-encrypted yet (\(first.path)): run the pass first")
        }
        // What the rule does not take leaves the vault (design §7.3), kept aside first (J6).
        for f in old where f.unaccepted != nil {
            guard let store = setAsideStore, let reason = f.unaccepted else {
                throw VaultError.setAsideFailed("\(f.path): this device keeps no set-aside store")
            }
            try store.keep(file: url.appendingPathComponent(f.path), path: f.path, vaultId: vaultId, reason: reason)
            try FileIO.remove(url.appendingPathComponent(f.path))
        }
        try epochWriteLock.withLock(timeout: 30) {
            var mf = try requireUnchangedOnDisk()
            mf.reencryptPending = nil
            try Self.seal(&mf, key: key, signing: signing, author: home.id ?? "")
            manifest = try Self.writeManifest(mf, to: manifestURL, replacing: true)
        }
        try faults.check(.beforeJournalRemoved)
        try? FileIO.remove(journalURL)
        removeRecordsBelowReencryption()
        let again = try reopened()
        try again.rememberList()
        self = again
    }

    /// Deletes this working copy's epoch records of epochs below a finished re-encryption (design §7.1 step 6(c)):
    /// they open with keys from before it (J7). Nothing while one is pending or without one. Returns their names.
    @discardableResult
    public func removeRecordsBelowReencryption() -> [String] {
        guard !isReencryptPending, let m = reencryptEpoch, !Self.epochMutations.contains(.keepOldRecords) else { return [] }
        var out: [String] = []
        for name in (try? FileIO.entries(epochsURL)) ?? [] where isRecordBelowReencryption(name, m: m.epoch) {
            if (try? FileIO.remove(epochsURL.appendingPathComponent(name))) != nil { out.append(name) }
        }
        return out.sorted()
    }

    /// True when `name` is the record of an epoch of this value's verified chain below `m` (records of other branches,
    /// a losing takeover's, stay: devices on that branch judge their way back with them).
    public func isRecordBelowReencryption(_ name: String, m: Int) -> Bool {
        guard Self.isEpochRecordFileName(name), let e = Int(name.split(separator: "-").first ?? ""), e < m,
              let chain = verifiedChain?.entries, e >= 1, e <= chain.count else { return false }
        return name == EpochRecord.fileName(epoch: e, epochId: chain[e - 1].epochId)
    }

    // MARK: - For the sync engine (rewrap-replace, design §7.1 step 6; device-first-sync §5.2)

    /// The epoch of the key `data` (a framed vault file at `path`) is under, when the acceptance rule takes it there;
    /// nil when it is not accepted, pending or unreadable.
    public func acceptedKeyEpoch(of data: Data, path: String) -> Int? {
        guard let (scope, name) = Self.framing(path), case .opened(let plain, let key, let older) = openUnderEpochs(data),
              (try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: key)) != nil,
              setAsideReason(older, path: path, sha256: FileDigest.sha256(data)) == nil else { return nil }
        return older?.epoch ?? manifest.epoch
    }

    /// The content of the inbox file `name` (its JSON line and payload, or its transcript) and the epoch of the key it
    /// is under, when it verifies under the current capture keys or is sealed by the record closing its epoch (format.md
    /// §15.14); nil otherwise. Read whole (bounded by its kind's limit).
    public func acceptedInboxContent(_ url: URL, name: String) -> (epoch: Int, content: Data)? {
        guard let kind = CaptureFile.parse(name: name)?.kind,
              let data = try? FileIO.read(url, maxBytes: CaptureFile.maxSealedBytes(kind)) else { return nil }
        func content(_ identity: any AgeIdentity, _ key: CaptureKey) -> Data? {
            guard let plain = try? AgeFile.decrypt(data, with: [identity]),
                  let c = try? CaptureFile.unframe(plain, filename: name, key: key) else { return nil }
            return c.line + [0x0A] + c.payload
        }
        if let ring = try? captureKeyRing(), let entry = try? verifyInboxFile(url, name: name, kind: kind, ring: ring),
           let c = identities.lazy.compactMap({ content($0, entry.key) }).first {
            return (manifest.epoch, c)
        }
        if let (o, entry) = sealedEarlierInboxFile(url, name: name, kind: kind), let c = content(o.identity, entry.key) {
            return (o.epoch, c)
        }
        return nil
    }

    /// The note's blob file names (among `names`) that are under an earlier key while the same content is named under
    /// the current key, mapped to that current name's base (`BlobName.parse(_).name`): duplicates a re-encryption or a
    /// catch-up left (design §7.1 step 5). Found from the content hashes the note's revisions reference; empty when the
    /// note cannot be read in full.
    public func supersededBlobNames(note: UUID, names: Set<String>) -> [String: String] {
        let table = supersededBlobBases(note: note)
        var out: [String: String] = [:]
        for f in names {
            guard let base = BlobName.parse(f)?.name, let now = table[base], now != base else { continue }
            out[f] = now
        }
        return out
    }

    /// For the content of each blob file the note holds here (its header's digest, read from the first chunk): each
    /// name under an earlier key this value holds, mapped to the name under the current key (base names, without kind).
    public func supersededBlobBases(note: UUID) -> [String: String] {
        guard let secret else { return [:] }
        let older = blobOlderEpochs.map(\.key)
        guard !older.isEmpty else { return [:] }
        let att = attURL(note)
        let ids = blobIdentities
        var table: [String: String] = [:]
        for file in (try? FileIO.entries(att)) ?? [] where BlobName.parse(file) != nil {
            guard let peek = try? Self.peekBlobFile(att.appendingPathComponent(file), identities: ids) else { continue }
            let digest = peek.header.digest
            let now = BlobName.name(digest: digest, secret: secret)
            for k in older { table[BlobName.name(digest: digest, secret: k)] = now }
        }
        return table
    }

    /// True when `data` is the journal of a re-encryption on this value's chain that is finished here (no binding in
    /// `vault.json` for it): it may be deleted wherever it is (design §7.1 step 7).
    public func isFinishedJournal(_ data: Data) -> Bool {
        guard let secret, let chain = verifiedChain?.entries, data.count <= EpochRecord.maxBytes else { return false }
        let older = olderEpochs
        for e in chain where e.reason == EpochReason.reencrypt.rawValue {
            if isReencryptPending, e.epochId == reencryptEpoch?.epochId { continue }
            let k = e.epochId == secret.epochId ? secret : older.first { $0.epochId == e.epochId }?.key
            if let k, (try? ReencryptJournal.open(data, key: k, vaultId: vaultId)) != nil { return true }
        }
        return false
    }

    /// Test mutations the sync side honors (J7's): old records, old blob names kept.
    package static var keepsOldRecords: Bool { epochMutations.contains(.keepOldRecords) }
    package static var keepsOldBlobNames: Bool { epochMutations.contains(.keepOldBlobNames) }

    /// Records in this device's ledger a current copy a sync placed here in place of an older accepted one (rewrap-replace,
    /// KH6): the device's runs with its other targets then compare that path there too (a bridge carries it).
    public func recordReplacedCopy(path: String, bytes: Data) throws { try recordWrite(path: path, bytes: bytes) }

    /// The epoch of the earlier key `data` (a framed file at `path`) opens and verifies under, and its body, trying every
    /// earlier key this value knows whatever its seal (the acceptance rule is not applied): for a file the rule cannot
    /// judge here (an earlier record missing). Nil when none opens it.
    public func earlierKeyBody(of data: Data, path: String) -> (epoch: Int, body: Data)? {
        guard let (scope, name) = Self.framing(path), let keyring else { return nil }
        for (e, k) in keyring.knownKeys() {
            guard let identity = try? k.vaultIdentity(), let plain = try? AgeFile.decrypt(data, with: [identity]),
                  let gzip = try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: k).gzip else { continue }
            return (e, gzip)
        }
        return nil
    }

    /// True when `data` (an age file) opens under the key of an epoch below `m` this value holds.
    public func opensUnderEpoch(below m: Int, _ data: Data) -> Bool {
        (keyring?.knownKeys() ?? []).contains { e, k in
            e < m && (try? k.vaultIdentity()).map { (try? AgeFile.decrypt(data, with: [$0])) != nil } == true
        }
    }

    /// Where a blob file stands (for a target's copy, `ReencryptCoordinator.confirm`).
    public enum BlobStanding: Hashable, Sendable {
        /// Under the current key, and its name the current key's.
        case current
        /// Under the key of an earlier epoch; accepted when the record closing it seals its bytes.
        case old(epoch: Int, accepted: Bool)
    }

    /// Where the blob file `url` of `note` stands; nil when no key this value holds opens it.
    public func blobStanding(_ url: URL, note: UUID) -> BlobStanding? {
        if (try? readAcceptedBlob(url, note: note, older: nil, expected: nil, maxContent: BlobRef.maxSize)) != nil { return .current }
        for o in blobOlderEpochs where (try? Self.peekBlobFile(url, identities: [o.identity])) != nil {
            let ok = (try? readAcceptedBlob(url, note: note, older: o, expected: nil, maxContent: BlobRef.maxSize)) != nil
            return .old(epoch: o.epoch, accepted: ok)
        }
        return nil
    }

    /// After a finished re-encryption (design §7.3: nothing in a working copy opens with an earlier key): the files of
    /// the working copy this device set aside that are still in place (`unacceptedInPlace`: kept in the set-aside store,
    /// never read as notes) are removed from it. Nothing while one is pending. Returns their paths.
    @discardableResult
    public func removeSetAsideCopiesBelowReencryption() -> [String] {
        guard recordsObsoleteBelow != nil, !isReadOnly, case .device = openedWith else { return [] }
        var out: [String] = []
        for (path, sha) in unacceptedInPlace().sorted(by: { $0.key < $1.key }) {
            let file = url.appendingPathComponent(path)
            guard (try? FileDigest.sha256(of: file).hex) == sha, (try? FileIO.remove(file)) != nil else { continue }
            out.append(path)
        }
        return out
    }

    /// The epoch below which records are obsolete (a finished re-encryption on this device's verified chain), for the
    /// sync engine: nil while one is pending, or without one.
    public var recordsObsoleteBelow: Int? {
        guard !isReencryptPending, case .verified = listStatus, let m = reencryptEpoch,
              !Self.epochMutations.contains(.keepOldRecords) else { return nil }
        return m.epoch
    }
}
