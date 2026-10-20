import Foundation
import Sempere

// MARK: - Key changes in a sync run (docs/design/device-first-sync.md §5.2, §6)
//
// With `SyncOptions.keyring` a run:
// - stores this device's secret in its keyring before it takes a `vault.json`
//   with another secret (R1), and an accepted journal's outgoing secret;
// - never uploads a rewrap journal this device refuses (F2);
// - every key change takes effect at once (decided 2026-10-20): a received
//   revision tagged under an older secret (a late file, F9) is set aside under
//   `late/` in the quarantine, never made current here and never deleted
//   (Adopt or Export); a late blob is taken in only when a revision held here
//   references its content (blobs are inert and content-addressed);
// - records the names that carry this device's id but came from elsewhere
//   (`SecretKeyring.receivedOwnNames`): "own" is decided from that provenance,
//   never from a name, which a removed device can forge;
// - a late file set aside here is resolved once its current copy arrives
//   with the same body (its writer caught up, R3): the kept copy then goes;
// - a device that finds a `vault.json` without any of its keys records that it
//   was removed and stops syncing the vault (no transfer, ever).
// With `SyncOptions.rewrapReplace` too (P4 turns it on; off by default):
// - this device's late local files are rewrapped from the keyring (R3);
// - while both sides hold the same list (rule 1), every file both hold is
//   compared, and a copy is replaced by the other side's only when both
//   verify, their bodies are equal and exactly one is current (rules 2 to 4;
//   both current: the smaller SHA-256 wins), so devices and bridges converge.

/// Stops a run at once: this device was removed from the vault (`noteRemoved`).
struct RemovedFromVault: Error {}

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
    case quarantine(String)
}

/// The same for a blob (taken in under its current name).
enum LateBlobVerdict {
    case notLate
    /// An older name of a blob this device holds under its current name (a rename's leftover): not placed.
    case leftover
    /// A revision held here references its content: taken in under its current name.
    case accept(secretId: String)
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
                let r = try v.rewrapLateFiles(ownDevices: options.ownDevices,
                                              receivedOwn: locked({ kc.ring?.receivedOwnNames }) ?? [])
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
        resolveHeldLateFiles()
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
                  let (previous, _) = vault.acceptedJournal(data, manifest: manifest), let previous else { return }
            let ring = try store.update(vaultId: vault.vaultId) { $0.noteReplaced(previous, now: options.now) }
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

    /// Revisions under a keyring secret held here that are not this device's (R3 skipped them; "own" by
    /// provenance): received before this device learned of the change (a removed device's write to a
    /// target the change had not reached, review finding 2), or another device's file whose current copy
    /// has not arrived yet. When the target holds the current copy, that copy is taken; otherwise the file
    /// is moved to the late-file quarantine (kept, never deleted; resolved when its current copy arrives,
    /// else Adopt or Export), never made current here. Removed only once the keep succeeded (round 2).
    func setAsideLateFiles(_ paths: [String], vault v: Vault) {
        // Only while both sides hold the same list: the target's copy is then judged under this list.
        guard !options.dryRun, kc.listAgreed else { return }
        for p in paths {
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count == 2, let n = RevisionName(parts[1]), let note = UUID(uuidString: parts[0]) else { continue }
            let url = root.appendingPathComponent(Vault.notesName).appendingPathComponent(p)
            guard let data = try? BoundedRead.contents(of: url, maxBytes: options.maxFileBytes),
                  v.lateSecret(ofRevision: data, note: note, name: n) != nil else { continue }
            // The target holds the current copy (its writer or the change's maker rewrapped it), with the
            // same body: take that one.
            if let remote = try? transport.read([Vault.notesName, parts[0], n.filename], maxBytes: options.maxFileBytes).data,
               case .current(let rb) = v.classifyRevision(remote, note: note, name: n),
               v.classifyRevision(data, note: note, name: n).body == rb {
                if (try? options.beforeLocalReplace?("notes/\(p)")) != nil, (try? LocalFS.write(remote, to: url, replacing: true)) != nil {
                    keyChangeActivity { $0.replaced.append(.init(side: "local", path: "notes/\(p)")) }
                }
                continue
            }
            let path = "notes/\(p)"
            let kept = quarantineLate(key(parts[0], n), path: path, entry: nil,
                                      reason: "another device's file under a replaced secret; set aside, never made "
                                          + "current here (resolved when its current copy arrives; else adopt or export it)",
                                      data: data)
            guard kept else {
                notSettled(path, "not set aside: the quarantine could not keep it; left in place, unreadable here")
                continue
            }
            try? LocalFS.remove(url)
            let dir = url.deletingLastPathComponent()
            if (try? LocalFS.entries(dir))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
        }
    }

    // MARK: Late files (F9, F17 to F19)

    /// The verdict on a received revision tagged under an older secret: never taken in (every key change
    /// is immediate); its writer catches up and sends a current copy, which resolves it.
    func lateRevision(_ data: Data, note: UUID, name: RevisionName) -> LateVerdict {
        guard options.keyring != nil, let v = keyChangeVault(),
              v.lateSecret(ofRevision: data, note: note, name: name) != nil else { return .notLate }
        return .quarantine(Self.lateReason)
    }

    /// The verdict on a received blob named under an older secret.
    func lateBlob(at file: URL, note: String, name: String) -> LateBlobVerdict {
        guard options.keyring != nil, let v = keyChangeVault(),
              case .stale(let body, let s?) = v.classifyBlob(at: file, fileName: name) else { return .notLate }
        if let current = v.currentBlobName(at: file, fileName: name),
           FileManager.default.fileExists(atPath: attURL(note).appendingPathComponent(current).path) {
            return .leftover
        }
        // Taken in when a revision this device holds (placed, so accepted here) references its content: a
        // blob is inert and content-addressed, and without it that revision's attachment would be missing
        // (review round 2, property seed 88).
        if let id = UUID(uuidString: note),
           (try? v.blobInventory(note: id))?.referencedHashes.contains(String(decoding: body, as: UTF8.self)) == true {
            return .accept(secretId: SecretKeyring.id(of: s))
        }
        return .quarantine(Self.lateReason)
    }

    static let lateReason = "a late file: tagged under a secret a key change replaced (every key change takes effect "
        + "at once); kept as a late file, never deleted: resolved when its current copy arrives, else adopt or export it"

    /// Quarantines a late file under `late/` in the quarantine folder.
    @discardableResult
    func quarantineLate(_ key: String, path: String, entry: RemoteEntry?, reason: String, data: Data? = nil,
                        file: URL? = nil) -> Bool {
        let kept = quarantine(key, path: LateFiles.folder + "/" + path, entry: entry, reason: reason, data: data, file: file)
        keyChangeActivity { $0.lateQuarantined.append(.init(path: path, message: reason)) }
        return kept
    }

    /// A revision placed here as current: a copy of it this device set aside as late (its writer caught up
    /// and sent this one) is resolved when its body is the same; otherwise it stays, reported.
    func resolveLate(_ id: String, _ n: RevisionName, placed: Data) {
        guard options.keyring != nil, let q = Optional(quarantineRoot), let v = keyChangeVault(),
              let uuid = UUID(uuidString: id), let body = v.classifyRevision(placed, note: uuid, name: n).body else { return }
        let dir = q.appendingPathComponent(LateFiles.folder).appendingPathComponent(Vault.notesName).appendingPathComponent(id)
        guard let names = try? LocalFS.entries(dir) else { return }
        for f in names where f == n.filename || f.hasPrefix(n.filename + ".copy-") {
            let url = dir.appendingPathComponent(f)
            guard let kept = try? BoundedRead.contents(of: url, maxBytes: options.maxFileBytes) else { continue }
            if v.classifyRevision(kept, note: uuid, name: n).body == body {
                try? FileManager.default.removeItem(at: url)
                keyChangeActivity { $0.lateResolved.append("notes/\(id)/\(n.filename)") }
            } else {
                keyChangeActivity { $0.unsettled.append(.init(path: "notes/\(id)/\(n.filename)",
                    message: "a copy set aside as late holds another body under this name: kept (two installs with one device id?)")) }
            }
        }
        if (try? LocalFS.entries(dir))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
    }

    /// The target's `vault.json` lists none of this device's keys: it was removed. Recorded in the keyring
    /// (it never syncs this vault again: `run` stops before any transfer from then on), with the files it
    /// wrote that this target never recorded (its unsynced changes, offered for export); the run stops
    /// here. The removal cannot be verified (the new secret is not given to a removed key): a target
    /// that fakes it only stops this device's sync, which keeps its copy readable.
    func noteRemoved() throws {
        report.removedFromVault = true
        guard let vault, !options.dryRun else { throw RemovedFromVault() }
        var unsynced = Set<String>()
        let store = options.keyring
        let ring = (try? store?.load(vaultId: vault.vaultId)) ?? nil
        let notes = root.appendingPathComponent(Vault.notesName)
        for id in (try? LocalFS.entries(notes)) ?? [] where UUID(uuidString: id) != nil {
            for f in (try? LocalFS.entries(notes.appendingPathComponent(id))) ?? [] {
                guard let n = RevisionName(f), n.filename == f, options.ownDevices.contains(n.device),
                      !(ring?.receivedAsOwn("\(id)/\(f)") ?? false), state.files[key(id, n)] == nil else { continue }
                unsynced.insert("notes/\(id)/\(f)")
            }
            for b in localBlobNames(id) ?? [] where state.files[blobKey(id, b)] == nil {
                unsynced.insert(blobPath(id, b))
            }
        }
        let found = unsynced
        _ = try? store?.update(vaultId: vault.vaultId) {
            if $0.removed == nil { $0.removed = options.now }
            $0.unsynced = ($0.unsynced ?? []).union(found)
        }
        state.removed = state.removed ?? options.now
        state.unsynced = Array(Set(state.unsynced ?? []).union(found)).sorted()
        report.unsynced = state.unsynced ?? []
        try? state.save(stateURL)
        throw RemovedFromVault()
    }

    /// Copies `paths` (a removed device's unsynced files, `SyncReport.unsynced`) and `vault.json` from the vault
    /// folder `vault` into `out`, as a vault folder of their own: what the device wrote that no target holds,
    /// readable with its key (format.md §4, "Recover one note with nothing but age"), for the user to keep or to
    /// bring into the vault from a listed device (`sempere import`). Never over an existing file. Returns the
    /// paths written.
    public static func exportUnsynced(vault: URL, paths: [String], to out: URL) throws -> [String] {
        let fm = FileManager.default
        var written: [String] = []
        for rel in [Vault.manifestName] + paths.sorted() {
            let parts = rel.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.hasPrefix(".") }),
                  rel == Vault.manifestName || parts.first == Vault.notesName else { continue }
            let from = vault.appendingPathComponent(rel), to = out.appendingPathComponent(rel)
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
            written.append(rel)
        }
        return written
    }

    /// Every late copy kept in this target's quarantine whose current copy the vault now holds (it may have
    /// come through another target) with the same body: resolved (`resolveLate`). Once per run.
    func resolveHeldLateFiles() {
        guard options.keyring != nil, !options.dryRun else { return }
        let notes = quarantineRoot.appendingPathComponent(LateFiles.folder).appendingPathComponent(Vault.notesName)
        for id in (try? LocalFS.entries(notes)) ?? [] where UUID(uuidString: id) != nil {
            // A late blob whose content this device now holds under its current name: resolved.
            let lateAtt = notes.appendingPathComponent(id).appendingPathComponent(Vault.attachmentsName)
            for f in (try? LocalFS.entries(lateAtt)) ?? [] {
                let url = lateAtt.appendingPathComponent(f)
                guard let v = keyChangeVault(), let current = v.currentBlobName(at: url, fileName: f.components(separatedBy: ".copy-")[0]),
                      FileManager.default.fileExists(atPath: attURL(id).appendingPathComponent(current).path) else { continue }
                try? FileManager.default.removeItem(at: url)
                keyChangeActivity { $0.lateResolved.append(blobPath(id, f)) }
            }
            if (try? LocalFS.entries(lateAtt))?.isEmpty == true { try? FileManager.default.removeItem(at: lateAtt) }
            let names = (try? LocalFS.entries(notes.appendingPathComponent(id))) ?? []
            for f in Set(names.map { $0.components(separatedBy: ".copy-")[0] }) {
                guard let n = RevisionName(f), n.filename == f,
                      let held = try? BoundedRead.contents(of: root.appendingPathComponent("\(Vault.notesName)/\(id)/\(f)"),
                                                           maxBytes: options.maxFileBytes),
                      let v = keyChangeVault(), case .current = v.classifyRevision(held, note: UUID(uuidString: id)!, name: n)
                else { continue }
                resolveLate(id, n, placed: held)
            }
        }
    }

    /// A revision that carries this device's id arrived from elsewhere: recorded, so it never counts as this
    /// device's own (R3, rewrap-replace of a missed rotation's copy). Reported: another install with this
    /// device id (a restored backup), or a forgery.
    func noteReceivedOwn(_ id: String, _ n: RevisionName) {
        guard options.ownDevices.contains(n.device), let store = options.keyring, let vault, !options.dryRun else { return }
        let path = "\(id)/\(n.filename)"
        if let ring = try? store.update(vaultId: vault.vaultId, { $0.noteReceivedOwn(path) }) { locked { kc.ring = ring } }
        keyChangeActivity { $0.receivedOwn.append("notes/" + path) }
    }

    /// A late blob, taken in under its current name; its old name stays a
    /// shared record, so the leftover is collected like any old name.
    func takeLateBlob(at part: URL, note id: String, name: String, path: String, secretId: String) throws {
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
        keyChangeActivity { $0.lateAccepted.append(.init(path: path, secretId: secretId)) }
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
                                 ownAfterMissedRotation: options.ownDevices.contains(n.device) && missedRotation(v)
                                     && !(locked({ kc.ring?.receivedAsOwn(key(id, n)) }) ?? false)
                                     && v.unverifiedBody(remote, note: uuid, name: n) == l.body,
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
                let keptRemote = quarantine(key, path: path, entry: entry, reason: "rewrap-replace: the server's copy \(why)",
                                            data: remoteData)
                // This device's own revision (by provenance), current here, after it missed a rotation (the
                // user confirmed its list), whose server copy holds the same body under a secret it never held:
                // its own write rewrapped by another device in between. The current copy takes its place, only
                // once the server's copy is kept. Never otherwise: a copy under an unknown secret may be a newer
                // one whose vault.json has not arrived yet (F6); another body under its name (two installs with
                // one device id) is never replaced (review round 2).
                if ownAfterMissedRotation, local.isCurrent, keptRemote {
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
