import Foundation
import Sempere

// MARK: - Key changes in a sync run (docs/design/device-first-sync.md §5.2, §6)
//
// With `SyncOptions.keyring` a run:
// - stores this device's secret in its keyring before it takes a `vault.json`
//   with another secret (R1), and an accepted journal's policy (mode, late-file
//   window) when it first takes the journal (§6.5);
// - never uploads a rewrap journal this device refuses (F2);
// - treats a received revision or blob tagged under an older secret (one this
//   device held, or an accepted journal's outgoing one) as a late file (F9):
//   rewrapped and placed while the window of every change since that secret
//   is open (counted from when this device first saw each), quarantined as a
//   late file after it, never deleted (F9, F17 to F19, I6).
// With `SyncOptions.rewrapReplace` too (P4 turns it on; off by default):
// - this device's late local files are rewrapped from the keyring (R3);
// - while both sides hold the same list (rule 1), every file both hold is
//   compared, and a copy is replaced by the other side's only when both
//   verify, their bodies are equal and exactly one is current (rules 2 to 4;
//   both current: the smaller SHA-256 wins), so devices and bridges converge.

/// What a run keeps for its key-change work.
struct KeyChangeRunState {
    /// This device's keyring for the vault, as loaded at the start and updated since.
    var ring: SecretKeyring?
    /// `vault.json` was the same list on both sides when the run started, and stayed so.
    var listAgreed = false
    /// The local `vault.json` when the run started.
    var startManifest: Data?
    /// Both sides' `vault.json` were there and held different lists when the run started: blob names
    /// keyed under one side's secret say nothing about the other's, so no blob is collected this run.
    var listsDiffer = false
    /// This run compares the copies both sides hold (rewrap-replace).
    var sweeping = false
    /// Nothing the sweep found stays unsettled.
    var sweepClean = true
    /// The checking vault with the keyring's secrets, keyed by the manifest it was opened from.
    var vault: (manifest: String?, vault: Vault?)?
    /// Old blob names of each note's local blobs (`isRewrapLeftover`).
    var oldNames: [String: Set<String>] = [:]
}

/// What to do with a received file under an older secret.
enum LateVerdict {
    case notLate
    case accept(rewrapped: Data, deadline: Date, secretId: String)
    case quarantine(String)
}

/// The same for a blob (taken in under its current name).
enum LateBlobVerdict {
    case notLate
    /// An older name of a blob this device holds under its current name (a rename's leftover): not placed.
    case leftover
    case accept(deadline: Date, secretId: String)
    case quarantine(String)
}

extension SyncEngine {
    /// Adds to the run's key-change report.
    func keyChangeActivity(_ body: (inout SyncReport.KeyChangeActivity) -> Void) {
        locked {
            var a = report.keyChange ?? SyncReport.KeyChangeActivity()
            body(&a)
            report.keyChange = a
        }
    }

    /// The vault received files are judged with, holding the keyring's older secrets.
    func keyChangeVault() -> Vault? {
        locked {
            let hash = manifestHash()
            if let cached = kc.vault, cached.manifest == hash { return cached.vault }
            let v = checker().flatMap { $0.canRead ? $0.withOlderSecrets(from: kc.ring) : nil }
            kc.vault = (hash, v)
            return v
        }
    }

    // MARK: Run phases

    /// Before the mutable files: the keyring, and whether both sides hold the same list.
    func beginKeyChangeRun() {
        kc.startManifest = try? localMutable(Vault.manifestName)
        if let remote = fetchedManifest?.data, let local = kc.startManifest {
            kc.listAgreed = Vault.sameList(local, remote)
        }
        // Fail closed: a remote vault.json not listed or not read counts as another list (review 10).
        kc.listsDiffer = !kc.listAgreed
        guard let store = options.keyring, let vault, let secret = vault.currentSecret else { return }
        do {
            // The keyring always holds the current secret (design §6.1 C0).
            kc.ring = options.dryRun ? try store.load(vaultId: vault.vaultId)
                : try store.update(vaultId: vault.vaultId) { $0.remember(secret, now: options.now) }
        } catch {
            // Reported, not an error of every run: sync goes on without the keyring (late files are then
            // never taken in, only quarantined) until it is repaired (`SealedFileKeyringStore.setAside`).
            let why = Self.describe(error)
            keyChangeActivity { $0.keyringProblem = why }
        }
    }

    /// After the mutable files: R3, and whether this run compares copies.
    func afterMutableFiles() {
        if (try? localMutable(Vault.manifestName)) != kc.startManifest { kc.listAgreed = false }
        guard options.rewrapReplace, !options.pushOnly, !options.dryRun, let store = options.keyring,
              vault != nil, let local = try? localMutable(Vault.manifestName),
              let fingerprint = Vault.listFingerprint(local) else { return }
        // R3: this device's late files (and stale copies) rewrapped from its keyring.
        if options.lateRewrap, state.lateRewrapFor != fingerprint, let v = keyChangeVault() {
            do {
                let r = try v.rewrapLateFiles(ownDevices: options.ownDevices)
                if !r.rewrapped.isEmpty {
                    keyChangeActivity { $0.rewrapped += r.rewrapped.count }
                    bumpGeneration(store)
                }
                setAsideLateFiles(r.lateSkipped, vault: v)
                if r.isComplete, r.lateSkipped.isEmpty || kc.listAgreed { state.lateRewrapFor = fingerprint }
            } catch {
                report.skipped.append(.init(path: Vault.notesName, message: "late files not rewrapped: \(Self.describe(error))"))
            }
        }
        let journals = remoteJournal || FileManager.default.fileExists(atPath: root.appendingPathComponent(Vault.journalName).path)
        kc.sweeping = kc.listAgreed && keyChangeVault() != nil && (state.rewrapSettled != settledMarker(fingerprint) || journals)
    }

    /// After the notes: records a settled pair.
    func finishKeyChangeRun() {
        guard options.rewrapReplace, options.keyring != nil, !options.dryRun, !options.pushOnly,
              let local = try? localMutable(Vault.manifestName), let fingerprint = Vault.listFingerprint(local) else { return }
        let marker = settledMarker(fingerprint)
        let clean = notesListed && report.errors.isEmpty && report.stoppedEarly == nil
        if kc.sweeping, kc.sweepClean, clean {
            state.rewrapSettled = marker
            keyChangeActivity { $0.settled = true }
        } else if !kc.sweeping, kc.listAgreed, clean, state.rewrapSettled == marker {
            keyChangeActivity { $0.settled = true }
        }
    }

    func settledMarker(_ fingerprint: String) -> String {
        let generation = (try? options.keyring?.load(vaultId: vault?.vaultId ?? UUID()))??.generation ?? 0
        return "\(fingerprint)#\(generation)"
    }

    /// A local file changed by a rewrap: every other target's pair compares its copies again.
    func bumpGeneration(_ store: any SecretKeyringStore) {
        guard let id = vault?.vaultId else { return }
        if let ring = try? store.update(vaultId: id, { $0.generation = ($0.generation ?? 0) + 1 }) { locked { kc.ring = ring } }
    }

    // MARK: Mutable files (R1, the journal's policy, F2)

    /// Before `vault.json` or the journal is replaced locally.
    func willTakeMutable(_ name: String, _ data: Data) throws {
        guard let store = options.keyring, let vault, let old = vault.currentSecret else { return }
        if name == Vault.manifestName {
            guard let new = vault.secret(ofManifest: data), new != old else { return }
            // R1: the outgoing secret is kept before vault.json stops naming it.
            let ring = try store.update(vaultId: vault.vaultId) {
                $0.remember(old, now: options.now)
                $0.noteReplaced(old, now: options.now)
                $0.remember(new, now: options.now)
            }
            locked { kc.ring = ring; kc.vault = nil }
        } else if name == Vault.journalName {
            guard let manifest = try? localMutable(Vault.manifestName),
                  let (policy, previous, changedAt) = vault.acceptedJournalPolicy(data, manifest: manifest), let previous else { return }
            // The change's policy, copied when first seen (design §6.5).
            let ring = try store.update(vaultId: vault.vaultId) {
                $0.noteReplaced(previous, now: options.now)
                $0.notePolicy(policy, outgoing: previous, changedAt: changedAt)
            }
            locked { kc.ring = ring; kc.vault = nil }
        }
    }

    /// Why the local journal must not be uploaded (F2): this device does not
    /// accept it now, or cannot judge it (locked). Nil: it may be.
    func journalNotUploadable(_ local: Data) -> String? {
        guard let vault else {
            return "the rewrap journal is uploaded only by a run that can judge it (unlock: --identity)"
        }
        return vault.acceptsJournal(local) ? nil
            : "this device refuses the local rewrap journal (vault.json does not bind it): never uploaded (design §6.2 F2)"
    }

    /// Another device's revisions under a keyring secret held here (R3 skipped them) whose names say they
    /// were written after the change away from that secret (or all of them when this device never saw the
    /// change's time): received here before this device learned of the change (a removed device's write to a target the change had not reached, review finding 2).
    /// They are moved to the late-file quarantine (kept, never deleted; Adopt or Export), never made
    /// current here. One whose name claims an earlier time stays as it is, under its old wrap, unreadable
    /// until its writer or a current copy from a target replaces it.
    func setAsideLateFiles(_ paths: [String], vault v: Vault) {
        // Only while both sides hold the same list: the target's copy is then judged under this list.
        guard !options.dryRun, kc.listAgreed, let ring = locked({ kc.ring }) else { return }
        for p in paths {
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count == 2, let n = RevisionName(parts[1]), let note = UUID(uuidString: parts[0]) else { continue }
            let url = root.appendingPathComponent(Vault.notesName).appendingPathComponent(p)
            guard let data = try? BoundedRead.contents(of: url, maxBytes: options.maxFileBytes),
                  let s = v.lateSecret(ofRevision: data, note: note, name: n) else { continue }
            // The target holds the current copy (the change's maker rewrapped it): take that one.
            if let remote = try? transport.read([Vault.notesName, parts[0], n.filename], maxBytes: options.maxFileBytes).data,
               v.classifyRevision(remote, note: note, name: n).isCurrent {
                if (try? options.beforeLocalReplace?("notes/\(p)")) != nil, (try? LocalFS.write(remote, to: url, replacing: true)) != nil {
                    keyChangeActivity { $0.replaced.append(.init(side: "local", path: "notes/\(p)")) }
                }
                continue
            }
            // With the change's time known, only what was written after it; unknown (the journal never seen
            // here), every such file: fail closed.
            if let changedAt = ring.entry(for: s)?.changedAt,
               Double(n.hlc.millis) / 1000 <= changedAt.timeIntervalSince1970 { continue }
            let path = "notes/\(p)"
            quarantineLate(key(parts[0], n), path: path, entry: nil,
                           reason: "another device's file under a replaced secret, written after the change; set aside, "
                               + "never made current here (adopt or export it)", data: data)
            try? LocalFS.remove(url)
            let dir = url.deletingLastPathComponent()
            if (try? LocalFS.entries(dir))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
        }
    }

    // MARK: Late files (F9, F17 to F19)

    /// The verdict on a received revision tagged under an older secret.
    func lateRevision(_ data: Data, note: UUID, name: RevisionName) -> LateVerdict {
        guard options.keyring != nil, let v = keyChangeVault(), let s = v.lateSecret(ofRevision: data, note: note, name: name),
              let deadline = locked({ kc.ring?.lateFileDeadline(for: s) }) else { return .notLate }
        guard options.now < deadline else { return .quarantine(lateReason(deadline)) }
        do {
            return .accept(rewrapped: try v.rewrappedRevision(data, note: note, name: name), deadline: deadline,
                           secretId: SecretKeyring.id(of: s))
        } catch {
            return .notLate
        }
    }

    /// The verdict on a received blob named under an older secret.
    func lateBlob(at file: URL, note: String, name: String) -> LateBlobVerdict {
        guard options.keyring != nil, let v = keyChangeVault(),
              case .stale(_, let s?) = v.classifyBlob(at: file, fileName: name) else { return .notLate }
        if let current = v.currentBlobName(at: file, fileName: name),
           FileManager.default.fileExists(atPath: attURL(note).appendingPathComponent(current).path) {
            return .leftover
        }
        guard let deadline = locked({ kc.ring?.lateFileDeadline(for: s) }) else { return .notLate }
        return options.now < deadline ? .accept(deadline: deadline, secretId: SecretKeyring.id(of: s)) : .quarantine(lateReason(deadline))
    }

    func lateReason(_ deadline: Date) -> String {
        "a late file: tagged under a secret a key change replaced, after its late-file window (ended "
            + "\(Self.compactUTC(deadline))); kept as a late file, never deleted: adopt or export it (design §6.2 F9)"
    }

    /// Quarantines a late file under `late/` in the quarantine folder.
    func quarantineLate(_ key: String, path: String, entry: RemoteEntry?, reason: String, data: Data? = nil, file: URL? = nil) {
        quarantine(key, path: LateFiles.folder + "/" + path, entry: entry, reason: reason, data: data, file: file)
        keyChangeActivity { $0.lateQuarantined.append(.init(path: path, message: reason)) }
    }

    /// A late revision was placed, rewrapped: the remote copy is replaced
    /// by it too while both sides hold the same list (rewrap-replace).
    func tookLateRevision(_ id: String, _ n: RevisionName, path: String, placed: Data, entry: RemoteEntry?, deadline: Date,
                          secretId: String) {
        keyChangeActivity { $0.lateAccepted.append(.init(path: path, deadline: deadline, secretId: secretId)) }
        guard options.rewrapReplace, kc.listAgreed, let etag = entry?.etag, Self.isStrong(etag) else { return }
        if (try? transport.write([Vault.notesName, id, n.filename], .data(placed), condition: .replace(etag: etag))) == true {
            keyChangeActivity { $0.replaced.append(.init(side: "remote", path: path)) }
        }
    }

    /// A late blob, taken in under its current name; its old name stays a
    /// shared record, so the leftover is collected like any old name.
    func takeLateBlob(at part: URL, note id: String, name: String, path: String, deadline: Date, secretId: String) throws {
        defer { try? FileManager.default.removeItem(at: part) }
        guard let v = keyChangeVault(), let current = v.currentBlobName(at: part, fileName: name) else { return }
        let target = attURL(id).appendingPathComponent(current)
        if !FileManager.default.fileExists(atPath: target.path) {
            let tmp = FileIO.tempURL(in: attURL(id))
            do { try v.rewrapBlobCopy(at: part, to: tmp) } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
            try options.beforeLocalReplace?(blobPath(id, current))
            if try !LocalFS.placeNew(tmp, at: target) { try? FileManager.default.removeItem(at: tmp) }
            locked { report.downloaded.append(blobPath(id, current)) }
        }
        locked { state.files[blobKey(id, name)] = SyncState.FileRecord() }
        keyChangeActivity { $0.lateAccepted.append(.init(path: path, deadline: deadline, secretId: secretId)) }
    }

    /// True when `name` (on the server, gone here) is an older name of a blob this device holds.
    func isRewrapLeftover(_ id: String, _ name: String, local: [String]) -> Bool {
        guard options.keyring != nil, let uuid = UUID(uuidString: id), let v = keyChangeVault() else { return false }
        if let known = locked({ kc.oldNames[id] }) { return known.contains(name) }
        let names = v.olderBlobNames(note: uuid, fileNames: local)
        locked { kc.oldNames[id] = names }
        return names.contains(name)
    }

    /// After a received copy was placed (rewrap-replace on): its version is recorded when both sides
    /// now hold the same current bytes; a copy that is not current (written under the list before an
    /// addition) makes the next run rewrap this device's local files again (R3).
    func placedCopy(_ k: String, entry: RemoteEntry?, sameAsRemote: Bool, isCurrent: (Vault) -> Bool) {
        guard options.rewrapReplace, options.keyring != nil, let v = keyChangeVault() else { return }
        if isCurrent(v) {
            if sameAsRemote, let stamp = entry?.stamp { locked { state.files[k, default: .init()].stamp = stamp } }
        } else {
            locked { state.lateRewrapFor = nil }
        }
    }

    // MARK: Rewrap-replace (design §5.2)

    /// Compares every copy both sides hold of one note while the run sweeps.
    func rewrapReplaceNote(_ id: String, revisions: Set<RevisionName>, entries: [RevisionName: RemoteEntry],
                           blobs: BlobSet) throws {
        guard options.rewrapReplace, kc.listAgreed, !options.dryRun, let v = keyChangeVault(),
              let uuid = UUID(uuidString: id) else { return }
        /// Compared when the run sweeps, or when the server's copy changed since both were found current.
        func due(_ k: String, _ entry: RemoteEntry?) -> Bool {
            if kc.sweeping { return true }
            // Never compared by this pair: once, after this device saw any key change.
            guard let recorded = state.files[k]?.stamp else { return true }
            return entry?.stamp != recorded
        }
        /// Records the server's version once both copies are the same.
        func settled(_ k: String, _ remote: [String], _ etag: String?) {
            let stamp = etag ?? ((try? transport.stat(remote)) ?? nil)?.stamp
            locked { state.files[k, default: .init()].stamp = stamp }
        }
        let dir = root.appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        for n in revisions.sorted() where due(key(id, n), entries[n]) {
            let path = "notes/\(key(id, n))"
            let remotePath = [Vault.notesName, id, n.filename]
            do {
                let local = try BoundedRead.contents(of: dir.appendingPathComponent(n.filename), maxBytes: options.maxFileBytes)
                let (remote, etag) = try transport.read(remotePath, maxBytes: options.maxFileBytes)
                try budget.downloaded(remote.count)
                if local == remote {
                    if case .current = v.classifyRevision(local, note: uuid, name: n) {
                        settled(key(id, n), remotePath, etag)
                    } else if options.ownDevices.contains(n.device) {
                        notSettled(path, "neither copy is current yet")   // this device's own: R3 rewraps it
                    } else {
                        // Another device's, under an older wrap on both sides: only its writer (or a current
                        // copy from elsewhere) makes it current; it does not hold this pair back.
                        staleKept(path)
                        settled(key(id, n), remotePath, etag)
                    }
                    continue
                }
                let l = v.classifyRevision(local, note: uuid, name: n), r = v.classifyRevision(remote, note: uuid, name: n)
                try settleCopies(path: path, key: key(id, n), local: l, remote: r,
                                 ownAfterMissedRotation: options.ownDevices.contains(n.device) && missedRotation(v),
                                 localHash: FileDigest.sha256(local), remoteHash: FileDigest.sha256(remote),
                                 entry: entries[n], etag: etag, remoteData: remote,
                                 replaceRemote: { cond in
                                     try self.transport.write([Vault.notesName, id, n.filename], .data(local), condition: cond)
                                 },
                                 replaceLocal: { try LocalFS.write(remote, to: dir.appendingPathComponent(n.filename), replacing: true) },
                                 settled: { settled(self.key(id, n), remotePath, $0) })
            } catch {
                try rethrowRunLimit(error)
                kc.sweepClean = false
                report.errors.append(.init(path: path, message: Self.describe(error)))
            }
        }
        let att = attURL(id)
        for name in Set(blobs.local.keys).intersection(blobs.remote.keys).sorted() where due(blobKey(id, name), blobs.remote[name]) {
            let path = blobPath(id, name)
            let remotePath = [Vault.notesName, id, Vault.attachmentsName, name]
            let tmp = FileIO.tempURL(in: att)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let localURL = att.appendingPathComponent(name)
                let result = try transport.download(remotePath, to: tmp, resumeFrom: 0,
                                                    ifETag: nil, maxBytes: options.maxBlobBytes,
                                                    segmentBytes: options.blobSegmentBytes, progress: nil)
                let lh = try FileDigest.sha256(of: localURL).hex, rh = try FileDigest.sha256(of: tmp).hex
                if lh == rh {
                    if case .current = v.classifyBlob(at: localURL, fileName: name) {
                    } else {
                        staleKept(path)   // R3 rewraps it here when a readable revision of this device's references it
                    }
                    settled(blobKey(id, name), remotePath, result.etag ?? blobs.remote[name]?.etag)
                    continue
                }
                let l = v.classifyBlob(at: localURL, fileName: name), r = v.classifyBlob(at: tmp, fileName: name)
                let remoteData = (try? Data(contentsOf: tmp)) ?? Data()
                try settleCopies(path: path, key: blobKey(id, name), local: l, remote: r, localHash: lh, remoteHash: rh,
                                 entry: blobs.remote[name], etag: result.etag, remoteData: remoteData,
                                 replaceRemote: { cond in
                                     try self.transport.write([Vault.notesName, id, Vault.attachmentsName, name], .file(localURL),
                                                              condition: cond)
                                 },
                                 replaceLocal: { try FileIO.place(tmp, at: localURL) },
                                 settled: { settled(self.blobKey(id, name), remotePath, $0) })
            } catch {
                try rethrowRunLimit(error)
                kc.sweepClean = false
                report.errors.append(.init(path: path, message: Self.describe(error)))
            }
        }
    }

    /// A file left under an older wrap on both sides, which this pair cannot make current.
    func staleKept(_ path: String) {
        keyChangeActivity { $0.staleKept.append(path) }
    }

    /// A shared file whose copies are not settled: the pair is not settled either.
    func notSettled(_ path: String, _ why: String) {
        locked {
            kc.sweepClean = false
            state.rewrapSettled = nil
        }
        keyChangeActivity { $0.unsettled.append(.init(path: path, message: why)) }
    }

    /// Rules 2 to 4 of design §5.2 for two differing copies of one path.
    /// True when this device took its current list on the user's confirmation without a link: it missed a
    /// rotation, so secrets other devices hold are unknown to it (`SecretKeyring.Entry.confirmedUnlinked`).
    func missedRotation(_ v: Vault) -> Bool {
        guard let current = v.currentSecret, let ring = locked({ kc.ring }) else { return false }
        return ring.entry(for: current)?.confirmedUnlinked == true
    }

    private func settleCopies(path: String, key: String, local: Vault.CopyStatus, remote: Vault.CopyStatus,
                              ownAfterMissedRotation: Bool = false,
                              localHash: String, remoteHash: String, entry: RemoteEntry?, etag: String?, remoteData: Data,
                              replaceRemote: (PutCondition) throws -> Bool, replaceLocal: () throws -> Void,
                              settled: (String?) -> Void) throws {
        func unsettled(_ why: String) { notSettled(path, why) }
        // Rule 2: both verify. A remote copy that does not is quarantined (never placed, never deleted).
        guard let rb = remote.body else {
            if case .invalid(let why) = remote {
                quarantine(key, path: path, entry: entry, reason: "rewrap-replace: the server's copy \(why)", data: remoteData)
                // This device's own revision, current here, after it missed a rotation (the user confirmed its
                // list): the server's copy under a secret it never held is its own write rewrapped by another
                // device in between (or a forgery). It is kept above; the current copy takes its place. Never
                // otherwise: a copy under an unknown secret may be a newer one whose vault.json has not
                // arrived yet (F6).
                if ownAfterMissedRotation, local.isCurrent {
                    return try replaceRemoteCopy(path: path, entry: entry, etag: etag, replaceRemote: replaceRemote,
                                                 settled: settled)
                }
            }
            return unsettled("the server's copy does not verify here")
        }
        guard let lb = local.body else { return unsettled("the local copy does not verify here; left as it is") }
        // Rule 3: the same body. Otherwise one name holds two contents (I3): never placed.
        guard lb == rb else {
            quarantine(key, path: path, entry: entry, reason: "rewrap-replace: another body under the same name", data: remoteData)
            return unsettled("the two copies hold different contents")
        }
        // Rule 4: exactly one current wins; both current, the smaller SHA-256.
        let localWins: Bool
        switch (local.isCurrent, remote.isCurrent) {
        case (true, false): localWins = true
        case (false, true): localWins = false
        case (true, true): localWins = localHash < remoteHash
        case (false, false): return unsettled("neither copy is current yet")
        }
        if localWins {
            try replaceRemoteCopy(path: path, entry: entry, etag: etag, replaceRemote: replaceRemote, settled: settled)
        } else {
            try options.beforeLocalReplace?(path)
            try replaceLocal()
            keyChangeActivity { $0.replaced.append(.init(side: "local", path: path)) }
            if let store = options.keyring { bumpGeneration(store) }
            // A revision now current here may reference blobs R3 left under an older name: look again.
            locked { state.lateRewrapFor = nil }
            settled(etag ?? entry?.etag)
        }
    }
}

extension SyncEngine {
    /// Replaces the server's copy by this device's, only under its strong version token.
    func replaceRemoteCopy(path: String, entry: RemoteEntry?, etag: String?,
                           replaceRemote: (PutCondition) throws -> Bool, settled: (String?) -> Void) throws {
        guard let etag = (etag ?? entry?.etag), Self.isStrong(etag) else {
            // No unconditional replace: another device's replace could be lost under it (review finding 7).
            keyChangeActivity { $0.weakStamps = true }
            return notSettled(path, "the server gives no strong version token to replace its copy under")
        }
        if try replaceRemote(.replace(etag: etag)) {
            keyChangeActivity { $0.replaced.append(.init(side: "remote", path: path)) }
            settled(nil)
        } else {
            notSettled(path, "the server's copy changed while it was replaced")
        }
    }
}

/// Late files a sync quarantined (design §6.2 F9, §8.4 "review late files"):
/// listed, adopted into the vault (rewrapped from the keyring, the user's
/// explicit choice, whatever the window) or exported. Nothing else removes them.
public enum LateFiles {
    /// The folder under a quarantine root that holds late files, by vault path.
    public static let folder = "late"

    /// One quarantined late file.
    public struct Item: Hashable, Sendable {
        /// Its vault path (`notes/<id>/<name>` or `notes/<id>/att/<name>`).
        public var path: String
        /// Where the quarantine keeps it.
        public var file: URL
    }

    /// Every late file under `quarantine` (a sync's `quarantineDirectory`).
    public static func list(quarantine: URL) -> [Item] {
        let base = quarantine.appendingPathComponent(folder)
        guard let e = FileManager.default.enumerator(atPath: base.path) else { return [] }
        return e.compactMap { $0 as? String }.sorted().compactMap { rel in
            let url = base.appendingPathComponent(rel)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { return nil }
            // A further copy of one path is kept as `<name>.copy-<hash>`; its vault path is the name's.
            let path = rel.range(of: ".copy-").map { String(rel[..<$0.lowerBound]) } ?? rel
            return Item(path: path, file: url)
        }
    }

    /// Adopts a late file: rewrapped to the current list from `vault`'s
    /// older secrets (`withOlderSecrets`) and placed in the vault, never over
    /// an existing file. Then removed from the quarantine.
    ///
    /// - Throws: `IncomingFileProblem` when it does not verify under any
    ///   secret the vault holds; `VaultError` from the writes.
    public static func adopt(_ item: Item, into vault: Vault) throws {
        try vault.requireWritable()
        let parts = item.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == Vault.notesName, let note = UUID(uuidString: parts[1]) else {
            throw IncomingFileProblem("not a note file: \(item.path)")
        }
        if parts.count == 3, let name = RevisionName(parts[2]) {
            let data = try BoundedRead.contents(of: item.file, maxBytes: BoundedRead.maxRevisionBytes)
            let current = try vault.rewrappedRevision(data, note: note, name: name)
            try vault.checkIncomingRevision(current, noteId: note, name: name)
            let target = vault.url.appendingPathComponent(item.path)
            if try !LocalFS.write(current, to: target, replacing: false) {
                throw VaultError.alreadyExists(target.path)
            }
        } else if parts.count == 4, parts[2] == Vault.attachmentsName {
            guard let current = vault.currentBlobName(at: item.file, fileName: parts[3]) else {
                throw IncomingFileProblem("the blob does not verify under any secret this device holds")
            }
            let dir = vault.url.appendingPathComponent(Vault.notesName).appendingPathComponent(parts[1])
                .appendingPathComponent(Vault.attachmentsName)
            try FileIO.createDirectory(dir)
            let target = dir.appendingPathComponent(current)
            if !FileManager.default.fileExists(atPath: target.path) {
                let tmp = FileIO.tempURL(in: dir)
                try vault.rewrapBlobCopy(at: item.file, to: tmp)
                if try !LocalFS.placeNew(tmp, at: target) { try? FileManager.default.removeItem(at: tmp) }
            }
        } else {
            throw IncomingFileProblem("not a note file: \(item.path)")
        }
        try FileManager.default.removeItem(at: item.file)
    }

    /// Exports a late file as it is (an age file its old recipients open
    /// with stock `age`) to `directory`, under its vault path, never over an
    /// existing file; then removes it from the quarantine.
    @discardableResult
    public static func export(_ item: Item, to directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(item.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: item.file, to: target)
        try FileManager.default.removeItem(at: item.file)
        return target
    }
}
