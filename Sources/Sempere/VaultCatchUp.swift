import Age
import Crypto
import Foundation

// Catch-up (docs/design/key-hierarchy.md §5.4; format.md §15.14; phase KH3): when a device first verifies
// a `vault.json` of an epoch above the one it wrote under, it re-encrypts under the current key exactly the
// files of its own write ledger that the change did not seal, and prunes the entries whose seal is final.
// Every other file under an earlier key that the acceptance rule does not take is copied into the
// set-aside store (the original stays where it is, never placed in a note).

/// What `Vault.catchUp` did.
public struct CatchUpReport: Hashable, Sendable {
    /// The paths re-encrypted under the current key (a blob under its new name).
    public var reencrypted: [String] = []
    /// Ledger entries pruned: sealed by a record whose seal is final (`LedgerRule.sealIsFinal`).
    public var pruned = 0
    /// Ledger entries kept: sealed, but a takeover could still drop the record that sealed them.
    public var sealedKept = 0
    /// Ledger entries dropped because their file is gone or holds other bytes (a later write of the path).
    public var dropped: [String] = []
    /// Unaccepted files copied into the set-aside store.
    public var setAside: [String] = []
    /// Files that could not be caught up, with why; catch-up is tried again by the next writer.
    public var problems: [String: String] = [:]

    /// True when nothing happened.
    public var isEmpty: Bool {
        reencrypted.isEmpty && pruned == 0 && dropped.isEmpty && setAside.isEmpty && problems.isEmpty
    }
}

/// Whether a vault value (and its copies) caught up already, or is catching up now.
final class CatchUpMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var done: Data?

    private var backOff: (epochId: Data, until: Date)?

    /// True when no catch-up is running, and none of `epochId` left problems within the back-off (the ledger's
    /// own mark says whether one is needed: review M3).
    func shouldRun(_ epochId: Data, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let b = backOff, b.epochId == epochId, now < b.until { return false }
        return !running
    }

    /// An automatic catch-up of `epochId` left problems: the next writes do not scan the vault again for a while
    /// (review nit: a persistent problem made every autosave rescan). `vault catch-up` still runs at once.
    func backOff(_ epochId: Data, for interval: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        backOff = (epochId, now.addingTimeInterval(interval))
    }

    /// Marks a catch-up running; false when one already is (a nested call).
    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    /// Ends the running catch-up; `epochId` when it finished that epoch.
    func end(_ epochId: Data?) {
        lock.lock(); defer { lock.unlock() }
        running = false
        if let epochId { done = epochId }
    }

    func markDone(_ epochId: Data) { lock.lock(); done = epochId; lock.unlock() }
}

extension Vault {
    /// Runs `catchUp` once per epoch for a writer with a ledger (`requireWritable` calls it): the first write
    /// after this device verified a new epoch catches up its own files first (design §5.4 steps 1–2).
    func catchUpIfNeeded() throws {
        guard ledger != nil, case .device = openedWith, case .verified = listStatus, let secret,
              catchUpMemo.shouldRun(secret.epochId) else { return }
        // The ledger's own mark decides, read at every write (an append of another epoch's entry clears it).
        if try ledger?.caughtUp() == secret.epochId { return }
        if !(try catchUp()).problems.isEmpty { catchUpMemo.backOff(secret.epochId, for: Self.catchUpBackOff) }
    }

    /// How long writes skip an automatic catch-up of an epoch after one left problems.
    static let catchUpBackOff: TimeInterval = 300

    /// Catches this device up to the current epoch (design §5.4): for every entry of its write ledger under
    /// an earlier epoch,
    ///
    /// - sealed with its digest by the record that closed that epoch (on the chain): kept, or pruned once
    ///   the seal is final (`LedgerRule.sealIsFinal`);
    /// - otherwise (written after the change, or under an epoch a takeover dropped): the file is
    ///   re-encrypted under the current key (the same body, a new file key and tag; a blob under its new
    ///   name, its old name kept), the copy verified, the old bytes set aside, then put in place, and the
    ///   ledger updated;
    /// - an entry whose file is gone or holds other bytes is dropped.
    ///
    /// Then every other unaccepted file of the working copy is copied into the set-aside store. An
    /// unreadable ledger fails closed (`VaultError.ledgerUnreadable`): nothing is re-encrypted or set aside.
    @discardableResult
    public func catchUp(now: Date = Date()) throws -> CatchUpReport {
        var report = CatchUpReport()
        guard let ledger, case .device = openedWith, let secret else { return report }
        let owner = catchUpMemo.enter()
        var finished = false
        defer { if owner { catchUpMemo.end(finished ? secret.epochId : nil) } }
        try requireWritable()
        let entries = try ledger.entries()
        let current = secret.epochId
        let chain = verifiedChain?.entries ?? []
        let chainIds = chain.isEmpty ? [current] : chain.map(\.epochId)
        let pinned = chain.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) }
        let older = olderEpochs
        var keys: [Data: VaultEpochKey] = [:]
        for o in older { keys[o.epochId] = o.key }
        for (_, k) in try ledger.epochKeys() where keys[k.epochId] == nil { keys[k.epochId] = k }
        let (liveEntries, stale) = ledgerLiveness(entries, now: now)
        var gone = stale
        report.dropped = stale.map(\.path)
        var n = 0
        for e in liveEntries {
            guard let ref = e.fileRef else { gone.append(e); continue }
            if ref.epochId == current { continue }
            if let i = chainIds.firstIndex(of: ref.epochId), i + 1 < chainIds.count,
               older.first(where: { $0.epochId == ref.epochId })?.sealed?[e.path] == e.sha256 {
                if LedgerRule.sealIsFinal(sealer: chainIds[i + 1], pinned: pinned) {
                    gone.append(e); report.pruned += 1
                } else {
                    report.sealedKept += 1
                }
                continue
            }
            guard let key = keys[ref.epochId] else {
                report.problems[e.path] = "the key of the epoch it was written under is not known"
                continue
            }
            if Self.epochMutations.contains(.skipCatchUp) { continue }
            n += 1
            do {
                report.reencrypted.append(try reencryptOwn(e, key: key, n: n))
                gone.append(e)
            } catch VaultError.interrupted {
                throw VaultError.interrupted
            } catch {
                report.problems[e.path] = "\(error)"
            }
        }
        if Self.epochMutations.contains(.catchUpByDeviceId), let me = writerDevice {
            // The broken rule: files named with this device's id count as its own, whoever wrote them.
            for note in (try? noteDirectoryNames()) ?? [] {
                guard let id = UUID(uuidString: note) else { continue }
                for name in (try? revisionFileNames(in: noteURL(id))) ?? [] where RevisionName(name)?.device == me {
                    let path = Self.notePath(id, name)
                    guard let data = try? readFile(noteURL(id).appendingPathComponent(name), maxBytes: BoundedRead.maxRevisionBytes),
                          case .opened(_, let k, let o?) = openUnderEpochs(data), setAsideReason(o, path: path,
                                                                                          sha256: FileDigest.sha256(data)) != nil
                    else { continue }
                    n += 1
                    let e = LedgerEntry(path: path, sha256: FileDigest.sha256(data), epoch: o.epoch, epochId: o.epochId)
                    if (try? reencryptOwn(e, key: k, n: n)) != nil { report.reencrypted.append(path) }
                }
            }
        }
        try ledger.remove(gone)
        sweepSupersededPassphraseCopies()
        report.setAside = try setAsideScan(skipping: Set(report.problems.keys))
        // The mark only when nothing of an older epoch was recorded meanwhile (review R1); else the next write
        // catches that up too.
        if report.problems.isEmpty, try ledger.setCaughtUp(current, unlessAppendedBeyond: Set(entries)) {
            finished = true
        }
        return report
    }

    /// How long an entry whose bytes are not (or no longer) at its path is kept: it may be the intent of a write
    /// still in flight in another process (design §5.4, intent first). After that it is a crash's leftover, or
    /// its file was deleted (compaction, thinning, adoption), and it goes.
    static let ledgerIntentGrace: TimeInterval = 3600

    /// Splits the ledger into the entries that matter and those to drop (review M2, S5). Per path, the live
    /// entry is the NEWEST one whose digest is the file's bytes now: entries before it are superseded (dropped);
    /// entries after it are intents not placed (a crash between the entry and the file, or a write in flight),
    /// kept for `ledgerIntentGrace`, then dropped. A path whose file holds none of its digests (or is gone) keeps
    /// its entries for the grace period too. So a crash after a catch-up's new entry and before its file is
    /// placed drops the new entry, never the old one that still names the file.
    ///
    /// - Parameter hashSingles: false for the routine prune (`pruneLedger`): a path with one entry and a file is
    ///   kept without hashing it; catch-up hashes every file it may re-encrypt.
    func ledgerLiveness(_ entries: [LedgerEntry], now: Date, hashSingles: Bool = true) -> (live: [LedgerEntry], drop: [LedgerEntry]) {
        var byPath: [String: [LedgerEntry]] = [:]
        var order: [String] = []
        for e in entries {
            if byPath[e.path] == nil { order.append(e.path) }
            byPath[e.path, default: []].append(e)
        }
        var live: [LedgerEntry] = [], drop: [LedgerEntry] = []
        func expired(_ e: LedgerEntry) -> Bool {
            guard let t = RFC3339.parse(e.time) else { return true }
            return now.timeIntervalSince(t) > Self.ledgerIntentGrace
        }
        for path in order {
            let list = byPath[path] ?? []
            let file = url.appendingPathComponent(path)
            if !hashSingles, list.count == 1, let e = list.first, FileIO.exists(file) { live.append(e); continue }
            let sha = FileIO.exists(file) ? (try? FileDigest.sha256(of: file).hex) : nil
            let liveIndex = sha.flatMap { s in list.lastIndex { $0.sha256 == s } }
            for (i, e) in list.enumerated() {
                if let liveIndex {
                    if i == liveIndex { live.append(e) } else if i < liveIndex || expired(e) { drop.append(e) }
                } else if expired(e) {
                    drop.append(e)
                }
            }
        }
        return (live, drop)
    }

    /// Drops the ledger entries whose files are gone or superseded (review S5): the ledger then grows with the
    /// vault's live files, not with every write. Run every `ledgerPruneEvery` appends by `recordWrite`, and by
    /// `vault catch-up`. Returns how many went.
    @discardableResult
    public func pruneLedger(now: Date = Date()) throws -> Int {
        guard let ledger else { return 0 }
        let drop = ledgerLiveness(try ledger.entries(), now: now, hashSingles: false).drop
        try ledger.remove(drop)
        return drop.count
    }

    /// How many appends between two routine prunes.
    static let ledgerPruneEvery = 512

    /// Re-encrypts this device's own file of `entry` (under `key`) under the current key; returns its path.
    func reencryptOwn(_ entry: LedgerEntry, key: VaultEpochKey, n: Int) throws -> String {
        let file = url.appendingPathComponent(entry.path)
        let parts = entry.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == Self.notesName, parts[2] == Self.attachmentsName, let note = UUID(uuidString: parts[1]) {
            // A blob goes to its new name (the old one stays until collection): written and placed as one
            // atomic step that records its own ledger entry first, then read back, then the old entry goes.
            let before = Set((try? FileIO.entries(attURL(note))) ?? [])
            let ref = try reencryptBlob(at: file, note: note, fileName: parts[3], extraKeys: [key])
            try faults.check(.catchUpWritten(n))
            let made = Set((try? FileIO.entries(attURL(note))) ?? []).subtracting(before)
            let target = try blobCandidates(note: note, ref)[0]
            guard Self.epochMutations.contains(.corruptReencryption) || isValidBlob(target, ref: ref) else {
                throw VaultError.epochChangeRefused("\(entry.path): the re-encrypted blob does not read back")
            }
            try faults.check(.catchUpVerified(n))
            try faults.check(.catchUpPlaced(n))
            return made.first.map { Self.blobPath(note, $0) } ?? Self.blobPath(note, target.lastPathComponent)
        }
        if parts.count == 2, parts[0] == CaptureFile.folderName, let parsed = CaptureFile.parse(name: parts[1]) {
            return try reencryptOwnCapture(entry, file: file, name: parts[1], kind: parsed.kind, key: key, n: n)
        }
        guard let (scope, name) = Self.framing(entry.path) else {
            throw VaultError.epochChangeRefused("\(entry.path): this version catches up revisions, blobs, notebook records, "
                + "inbox files and settings.age")
        }
        let data = try readFile(file, maxBytes: BoundedRead.maxRevisionBytes)
        let identity = NativeIdentity.mlkem768x25519(try key.vaultIdentity())
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [identity]) } catch {
            throw VaultError.epochChangeRefused("\(entry.path) does not decrypt under the key it was written under")
        }
        let gzip = try BodyFraming.unframe(plain, noteId: scope, filename: name, secret: key).gzip
        let current = try requireSecret()
        let corrupt = Self.epochMutations.contains(.corruptReencryption)
        let body = corrupt ? try Gzip.compress(Data("{}".utf8)) : gzip
        let fresh = try encrypt(BodyFraming.frame(gzip: body, noteId: scope, filename: name, secret: current))
        let dir = file.deletingLastPathComponent()
        let tmp = FileIO.tempURL(in: dir)
        try FileIO.writeNewFile(tmp) { try $0(fresh) }
        var placed = false
        defer { if !placed { try? FileManager.default.removeItem(at: tmp) } }
        try faults.check(.catchUpWritten(n))
        // The copy decrypts under the current key and holds the same body before anything is replaced.
        let check = try BoundedRead.contents(of: tmp, maxBytes: BoundedRead.maxRevisionBytes)
        guard corrupt || (try? AgeFile.decrypt(check, with: identities)).flatMap({
            try? BodyFraming.unframe($0, noteId: scope, filename: name, secret: current).gzip
        }) == gzip else {
            throw VaultError.epochChangeRefused("\(entry.path): the re-encrypted copy does not read back")
        }
        try faults.check(.catchUpVerified(n))
        // The old bytes are set aside first (J6), then the ledger knows the new ones, then they are in place.
        guard let setAsideStore else { throw VaultError.setAsideFailed("\(entry.path): this device keeps no set-aside store") }
        if !Self.epochMutations.contains(.replaceWithoutSettingAside) {
            try setAsideStore.keep(data, path: entry.path, vaultId: vaultId, reason: .notSealed, epochId: key.epochId)
        }
        try recordWrite(path: entry.path, bytes: fresh)
        try faults.check(.catchUpRecorded(n))
        try FileIO.place(tmp, at: file)
        placed = true
        try faults.check(.catchUpPlaced(n))
        return entry.path
    }

    /// Re-seals this device's own inbox file (a quick capture sealed with a profile of the epoch of `key`,
    /// design §5.7) under the current key: the same JSON line and payload, tagged with this device's capture
    /// key of the current epoch and encrypted to the current vault identity, verified before anything is
    /// replaced, the old bytes set aside first.
    func reencryptOwnCapture(_ entry: LedgerEntry, file: URL, name: String, kind: CaptureFile.Kind, key: VaultEpochKey,
                             n: Int) throws -> String {
        guard let me = deviceEntry else { throw VaultError.removedFromVault("this device is not on the list") }
        let fingerprint = CaptureKey.fingerprint(of: me.key)
        let data = try FileIO.read(file, maxBytes: CaptureFile.maxSealedBytes(kind))
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [NativeIdentity.mlkem768x25519(try key.vaultIdentity())]) } catch {
            throw VaultError.epochChangeRefused("\(entry.path) does not decrypt under the key it was written under")
        }
        let current = try requireSecret()
        let newKey = CaptureKey.derive(from: current, device: fingerprint)
        guard let retagged = CaptureFile.retag(plain, filename: name, verifiedBy: CaptureKey.derive(from: key, device: fingerprint),
                                               to: newKey) else {
            throw VaultError.epochChangeRefused("\(entry.path) is not this device's capture under the key it was written under")
        }
        let corrupt = Self.epochMutations.contains(.corruptReencryption)
        let fresh = try encrypt(corrupt ? Data(retagged.dropLast()) : retagged)
        let dir = file.deletingLastPathComponent()
        let tmp = FileIO.tempURL(in: dir)
        try FileIO.writeNewFile(tmp) { try $0(fresh) }
        var placed = false
        defer { if !placed { try? FileManager.default.removeItem(at: tmp) } }
        try faults.check(.catchUpWritten(n))
        let check = try FileIO.read(tmp, maxBytes: CaptureFile.maxSealedBytes(kind))
        guard corrupt || (try? AgeFile.decrypt(check, with: identities)).flatMap({
            try? CaptureFile.unframe($0, filename: name, key: newKey)
        }).map({ $0.line + [0x0A] + $0.payload }) == (try? CaptureFile.unframe(plain, filename: name,
                                                                               key: CaptureKey.derive(from: key, device: fingerprint)))
            .map({ $0.line + [0x0A] + $0.payload }) else {
            throw VaultError.epochChangeRefused("\(entry.path): the re-sealed copy does not read back")
        }
        try faults.check(.catchUpVerified(n))
        guard let setAsideStore else { throw VaultError.setAsideFailed("\(entry.path): this device keeps no set-aside store") }
        if !Self.epochMutations.contains(.replaceWithoutSettingAside) {
            try setAsideStore.keep(data, path: entry.path, vaultId: vaultId, reason: .notSealed, epochId: key.epochId)
        }
        try recordWrite(path: entry.path, bytes: fresh)
        try faults.check(.catchUpRecorded(n))
        try FileIO.place(tmp, at: file)
        placed = true
        try faults.check(.catchUpPlaced(n))
        return entry.path
    }

    /// Copies every file of the working copy that the acceptance rule sets aside into the set-aside store
    /// (design §5.8); the originals stay, never placed. Returns their paths. Nothing to do at epoch 1 with no
    /// keys off the chain.
    @discardableResult
    public func setAsideScan(skipping: Set<String> = []) throws -> [String] {
        guard let setAsideStore, keyring != nil, canRead else { return [] }
        var out: [String] = []
        func keep(_ path: String, _ file: URL, _ reason: SetAsideReason) throws {
            guard !skipping.contains(path) else { return }
            try setAsideStore.keep(file: file, path: path, vaultId: vaultId, reason: reason)
            out.append(path)
        }
        let secret = try requireSecret()
        for note in try noteDirectoryNames() {
            guard let id = UUID(uuidString: note) else { continue }
            let dir = noteURL(id)
            for name in try revisionFileNames(in: dir) {
                guard let n = RevisionName(name), let data = try? readFile(dir.appendingPathComponent(name),
                                                                         maxBytes: BoundedRead.maxRevisionBytes) else { continue }
                do { _ = try revisionJSON(data, note: note, name: n, secret: secret) } catch RevisionReadError.setAside(let r) {
                    try keep(Self.notePath(id, name), dir.appendingPathComponent(name), r)
                } catch {}
            }
            let att = attURL(id)
            for file in (try? FileIO.entries(att)) ?? [] where BlobName.parse(file) != nil {
                let url = att.appendingPathComponent(file)
                do { _ = try readAnyAcceptedBlob(url, note: id, maxContent: BlobRef.maxSize) } catch BlobError.setAside(let r) {
                    try keep(Self.blobPath(id, file), url, r)
                } catch {}
            }
        }
        for name in (try? notebookRecordNames()) ?? [] {
            let url = notebooksURL.appendingPathComponent(name)
            guard let data = try? readFile(url, maxBytes: NotebookRecords.maxFileBytes) else { continue }
            do { _ = try openNotebookRecord(data, fileName: name) } catch NotebookRecordError.setAside(let r) {
                try keep("\(NotebookRecords.folderName)/\(name)", url, r)
            } catch {}
        }
        if let data = try? readFile(sharedSettingsURL, maxBytes: SharedSettings.maxFileBytes) {
            do { _ = try openSharedSettings(data, allowNewerReader: true) } catch SharedSettingsError.setAside(let r) {
                try keep(SharedSettings.fileName, sharedSettingsURL, r)
            } catch {}
        }
        // Inbox files under an earlier key that no record seals (design §5.3 rule 4): never adopted, kept aside.
        if let ring = try? captureKeyRing() {
            for name in (try? FileIO.entries(inboxURL)) ?? [] {
                guard let parsed = CaptureFile.parse(name: name) else { continue }
                let file = inboxURL.appendingPathComponent(name)
                if (try? verifyInboxFile(file, name: name, kind: parsed.kind, ring: ring)) != nil { continue }
                if sealedEarlierInboxFile(file, name: name, kind: parsed.kind) != nil { continue }
                guard let data = try? FileIO.read(file, maxBytes: CaptureFile.maxSealedBytes(parsed.kind)),
                      case .opened(_, _, let older?) = openUnderEpochs(data) else { continue }
                try keep("\(CaptureFile.folderName)/\(name)", file, older.sealed == nil ? .dropped
                         : older.sealed?["\(CaptureFile.folderName)/\(name)"] == nil ? .notSealed : .bytesDiffer)
            }
        }
        return out
    }
}
