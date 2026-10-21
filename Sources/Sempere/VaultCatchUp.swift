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

    /// True when a catch-up for `epochId` is neither running nor done.
    func shouldRun(_ epochId: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !running && done != epochId
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
        if try ledger?.caughtUp() == secret.epochId {
            catchUpMemo.markDone(secret.epochId)
            return
        }
        try catchUp()
    }

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
    public func catchUp() throws -> CatchUpReport {
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
        var latest: [String: LedgerEntry] = [:]
        for e in entries { latest[e.path] = e }
        var gone: [LedgerEntry] = []
        var n = 0
        for e in entries {
            guard let ref = e.fileRef else { gone.append(e); continue }
            if ref.epochId == current { continue }
            guard latest[e.path] == e else { gone.append(e); continue }   // a later write of the same path
            if let i = chainIds.firstIndex(of: ref.epochId), i + 1 < chainIds.count,
               older.first(where: { $0.epochId == ref.epochId })?.sealed?[e.path] == e.sha256 {
                if LedgerRule.sealIsFinal(sealer: chainIds[i + 1], pinned: pinned) {
                    gone.append(e); report.pruned += 1
                } else {
                    report.sealedKept += 1
                }
                continue
            }
            let file = url.appendingPathComponent(e.path)
            guard FileIO.exists(file), (try? FileDigest.sha256(of: file).hex) == e.sha256 else {
                gone.append(e); report.dropped.append(e.path)
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
        try ledger.remove(gone)
        report.setAside = try setAsideScan(skipping: Set(report.problems.keys))
        if report.problems.isEmpty {
            try ledger.setCaughtUp(current)
            finished = true
        }
        return report
    }

    /// Re-encrypts this device's own file of `entry` (under `key`) under the current key; returns its path.
    func reencryptOwn(_ entry: LedgerEntry, key: VaultEpochKey, n: Int) throws -> String {
        let file = url.appendingPathComponent(entry.path)
        let parts = entry.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == Self.notesName, parts[2] == Self.attachmentsName, let note = UUID(uuidString: parts[1]) {
            try faults.check(.catchUpWritten(n))
            try faults.check(.catchUpVerified(n))
            let before = Set((try? FileIO.entries(attURL(note))) ?? [])
            try reencryptBlob(at: file, note: note, fileName: parts[3])
            try faults.check(.catchUpPlaced(n))
            let made = Set((try? FileIO.entries(attURL(note))) ?? []).subtracting(before)
            return made.first.map { Self.blobPath(note, $0) } ?? entry.path
        }
        guard let (scope, name) = Self.framing(entry.path) else {
            throw VaultError.epochChangeRefused("\(entry.path): this version catches up revisions, blobs, notebook records "
                + "and settings.age")
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
        return out
    }
}
