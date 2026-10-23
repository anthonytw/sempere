import Age
import Crypto
import Foundation

// New epochs (docs/design/key-hierarchy.md §5.2, §5.6, §6.3, §6.5; format.md §15.14; phase KH3): removing
// devices, handing the home role over, a takeover with the recovery key, and replacing the recovery kit.
// Each is the same sequence: the parent epoch's sealed set, a fresh `K_{e+1}`, the epoch record written
// under its final name first, then `vault.json` in one atomic write, under the vault's write lock. Only
// the home device signs the first three kinds (a removal, a handoff, a kit replacement); a takeover is
// signed by the recovery key and its new home.

/// Test seam: where an epoch change or a catch-up stops, as a crash there would (design §11.1
/// `EpochFaults`). Never set outside tests.
struct EpochFaults: Hashable, Sendable {
    enum Point: Hashable, Sendable {
        /// The new epoch's record is at its final name; `vault.json` is not written yet (an orphan record).
        case afterRecord
        /// `vault.json` is written; the trust record and the passphrase copies are not updated yet.
        case afterManifest
        /// A ledger entry is durable; its file is not placed yet.
        case afterLedgerIntent
        /// Catch-up of file n (1-based): the re-encrypted copy is written, not verified.
        case catchUpWritten(Int)
        /// Catch-up of file n: the copy verified, not put in place.
        case catchUpVerified(Int)
        /// Catch-up of file n: its new ledger entry is durable, the copy not put in place (review M2).
        case catchUpRecorded(Int)
        /// Catch-up of file n: in place; the ledger not updated.
        case catchUpPlaced(Int)
    }
    var stop: Point?

    func check(_ p: Point) throws {
        if stop == p { throw VaultError.interrupted }
    }
}

/// What an epoch change did.
public struct EpochChangeReport: Hashable, Sendable {
    public var epoch: Int
    public var epochId: Data
    public var reason: EpochReason
    /// The devices the new epoch no longer lists (computed: the parent list minus the first list).
    public var removed: [Data]
    /// The new home's fingerprint.
    public var home: Data
    /// How many files the record sealed.
    public var sealed: Int
}

extension Vault {
    /// The write lock every writer of this vault's `vault.json` takes (design §5.2): the store's, when the
    /// vault is a store vault (`VaultStore.writeLock(for:)`), else a hidden lock file in the vault folder.
    ///
    /// It excludes the other writers of `vault.json` and `settings.age` (approvals, renames, a sync run's
    /// placing), not every note write: a revision another process writes under the old key after the seal
    /// is not sealed, and its writer re-encrypts it from its ledger (design §5.2 step 2, §5.4; J1).
    var epochWriteLock: VaultFileLock {
        let idFolder = url.deletingLastPathComponent()
        let root = idFolder.deletingLastPathComponent()
        if idFolder.lastPathComponent == vaultId.uuidString.lowercased(),
           FileIO.isDirectory(root.appendingPathComponent(VaultStore.locksName, isDirectory: true)) {
            return VaultStore(root: root).writeLock(for: vaultId)
        }
        return VaultFileLock.at(url.appendingPathComponent(".sempere-write.lock"))
    }

    // MARK: - Sealing (design §5.2 step 3)

    /// One epoch's key as a sealing walk sees it: the epoch whose files are sealed (`sealed` nil) and the
    /// earlier ones with their sealed sets.
    struct SealView {
        var current: (epochId: Data, key: VaultEpochKey, identity: NativeIdentity)
        var older: [OlderEpoch]

        /// Decrypts and verifies `data` (a framed file: `scope`, `name`) under the view's keys; true when the
        /// acceptance rule takes it.
        func accepts(framed data: Data, scope: String, name: String, path: String) -> Bool {
            if let plain = try? AgeFile.decrypt(data, with: [current.identity]) {
                return (try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: current.key)) != nil
            }
            for o in older {
                guard let plain = try? AgeFile.decrypt(data, with: [o.identity]) else { continue }
                guard (try? BodyFraming.unframe(plain, noteId: scope, filename: name, secret: o.key)) != nil,
                      let sealed = o.sealed else { return false }
                return sealed[path] == FileDigest.sha256(data)
            }
            return false
        }
    }

    /// The sealed set of the epoch `view.current` (design §5.2 step 3): the path and SHA-256 of every file in
    /// the working copy that the acceptance rule takes under it or an earlier key of `view`: revisions,
    /// blobs, notebook records, `settings.age`, and inbox files of that epoch (format.md §15.14). Files set
    /// aside or pending are not included.
    func sealedSet(_ view: SealView) throws -> [String: String] {
        var out: [String: String] = [:]
        let secrets = [view.current.key] + view.older.map(\.key)
        let idents: [NativeIdentity] = [view.current.identity] + view.older.map(\.identity)
        for note in try noteDirectoryNames() {
            guard let id = UUID(uuidString: note) else { continue }
            let dir = noteURL(id)
            for name in try revisionFileNames(in: dir) {
                let path = Self.notePath(id, name)
                guard let data = try? readFile(dir.appendingPathComponent(name), maxBytes: BoundedRead.maxRevisionBytes),
                      view.accepts(framed: data, scope: note, name: name, path: path) else { continue }
                out[path] = FileDigest.sha256(data)
            }
            let att = attURL(id)
            for file in (try? FileIO.entries(att)) ?? [] where BlobName.parse(file) != nil {
                let url = att.appendingPathComponent(file)
                guard !FileIO.isDirectory(url), let parsed = BlobName.parse(file) else { continue }
                // Its name says which key it is under; it is taken when it decrypts there and, under an earlier
                // key, is sealed with these bytes.
                for (i, k) in secrets.enumerated() {
                    guard let peek = try? Self.peekBlobFile(url, identities: [idents[i]]),
                          BlobName.verify(parsed.name, digest: peek.header.digest, secrets: [k]) != nil else { continue }
                    guard let sha = try? FileDigest.sha256(of: url).hex else { break }
                    let path = Self.blobPath(id, file)
                    if i == 0 || view.older[i - 1].sealed?[path] == sha { out[path] = sha }
                    break
                }
            }
        }
        for name in (try? notebookRecordNames()) ?? [] {
            let path = "\(NotebookRecords.folderName)/\(name)"
            guard let data = try? readFile(notebooksURL.appendingPathComponent(name), maxBytes: NotebookRecords.maxFileBytes),
                  view.accepts(framed: data, scope: NotebookRecords.tagScope, name: name, path: path) else { continue }
            out[path] = FileDigest.sha256(data)
        }
        if let data = try? readFile(sharedSettingsURL, maxBytes: SharedSettings.maxFileBytes),
           view.accepts(framed: data, scope: SharedSettings.tagScope, name: SharedSettings.fileName, path: SharedSettings.fileName) {
            out[SharedSettings.fileName] = FileDigest.sha256(data)
        }
        // Inbox files of the sealed epoch whose tag verifies under a listed device's capture key.
        if view.current.key == secret, let ring = try? captureKeyRing() {
            for name in (try? FileIO.entries(inboxURL)) ?? [] {
                guard let parsed = CaptureFile.parse(name: name) else { continue }
                let url = inboxURL.appendingPathComponent(name)
                guard (try? verifyInboxFile(url, name: name, kind: parsed.kind, ring: ring)) != nil,
                      let sha = try? FileDigest.sha256(of: url).hex else { continue }
                out["\(CaptureFile.folderName)/\(name)"] = sha
            }
        }
        return out
    }

    // MARK: - Writing an epoch

    /// Everything an epoch change decides; `writeEpoch` makes the files.
    struct EpochPlan {
        var reason: EpochReason
        /// The parent epoch: its key, its verified chain (epoch 1 … parent) and its list as the author saw it.
        var parentKey: VaultEpochKey
        var parentChain: [ChainEntry]
        var parentList: [Data]
        /// The same-epoch additions of the parent epoch the author saw (carried in its chain entry).
        var parentAdditions: [ChainAddition]
        /// The new epoch's device entries (their wraps are made here), in list order.
        var devices: [EpochKeyEntry]
        /// The recovery entry (wrap made here).
        var recovery: EpochKeyEntry
        var home: Data
        /// The author: its device entry (key and signing keys) and signing keys.
        var author: EpochKeyEntry
        var signing: DeviceSigningKeys
        /// A takeover's recovery key (its signing pair and public keys), or the old kit's optional
        /// signature on a kit replacement.
        var recoverySigner: (keys: DeviceSigningKeys, author: ChainAuthor)?
        /// The sealed set of the parent epoch.
        var sealed: [String: String]
        /// SHA-256 of the parent epoch's record file (format.md §15.6): the hash link down the chain.
        var parentRecordHash: Data
        var created: Date
        var label: String?
        var features: [String]
    }

    /// Writes the new epoch of `plan` (design §5.2 steps 4–5): the record under its final name, then
    /// `vault.json`. Returns the new manifest and key.
    func writeEpoch(_ plan: EpochPlan) throws -> (manifest: EpochManifest, key: VaultEpochKey) {
        guard let parentEntry = plan.parentChain.last, let authorKey = plan.author.sign, let authorId = plan.author.id else {
            throw VaultError.epochChangeRefused("the parent epoch's chain is not known")
        }
        let key = VaultEpochKey.random()
        let epoch = parentEntry.epoch + 1
        var chain = plan.parentChain
        chain[chain.count - 1].additions = plan.parentAdditions
        let recoveryFP = plan.recovery.fingerprint
        let firstList = (plan.devices.filter { ($0.addedEpoch ?? 0) < epoch || $0.fingerprint == plan.home }.map(\.fingerprint)
            + [recoveryFP]).sorted { $0.lexicographicallyPrecedes($1) }
        var entry = ChainEntry(
            epoch: epoch, epochId: key.epochId, parent: parentEntry.epochId, linkPublicKeys: try LinkPublicKeys(epochKey: key),
            link: try EpochLinks.link(from: plan.parentKey, to: key, epoch: epoch, vaultId: vaultId),
            reason: plan.reason.rawValue, list: firstList, parentList: plan.parentList.sorted { $0.lexicographicallyPrecedes($1) },
            author: ChainAuthor(key: plan.author.key, sign: authorKey), epochSig: Self.placeholderSignature,
            recovery: recoveryFP, home: plan.home, recoveryAuthor: plan.recoverySigner?.author)
        let message = entry.epochMessage(vaultId: vaultId, root: manifest.root)
        entry.epochSig = try plan.signing.sign(message)
        entry.recoverySig = try plan.recoverySigner.map { try $0.keys.sign(message) }
        chain.append(entry)
        let stamp = RFC3339.string(plan.created)
        let removed = Set(plan.parentList).subtracting(firstList)
        let record = EpochRecord(vaultId: vaultId, root: manifest.root, epoch: epoch, epochId: key.epochId,
                                 parent: EpochRecordParent(epoch: parentEntry.epoch, epochId: parentEntry.epochId,
                                                           key: plan.parentKey, sealed: plan.sealed,
                                                           recordHash: plan.parentRecordHash),
                                 chain: chain, created: stamp, by: authorId, reason: plan.reason.rawValue,
                                 removed: removed.sorted { $0.lexicographicallyPrecedes($1) })
        let recordFile = try record.seal(key: key)
        var keys: [EpochKeyEntry] = []
        for d in plan.devices {
            var e = d
            guard let r = try? NativeRecipient(string: d.key) else { throw VaultError.invalidRecipient(d.key) }
            e.wrap = try EpochKeyWrap.seal(key, vaultId: vaultId, epoch: epoch, to: r)
            keys.append(e)
        }
        var rec = plan.recovery
        guard let rr = try? NativeRecipient(string: rec.key) else { throw VaultError.invalidRecipient(rec.key) }
        rec.wrap = try EpochKeyWrap.seal(key, vaultId: vaultId, epoch: epoch, to: rr)
        keys.append(rec)
        var m = EpochManifest(
            format: manifest.format, vaultId: vaultId, created: manifest.created, root: manifest.root, epoch: epoch,
            epochId: key.epochId, parent: parentEntry.epochId, epochRecord: Self.epochsName + "/" + record.fileName,
            epochRecordHash: Data(SHA256.hash(data: recordFile)), keys: keys, listTag: "", epochLink: entry.link,
            epochAuthor: authorId, epochSig: entry.epochSig, markersTag: "", author: authorId,
            authorSig: Self.placeholderSignature, features: plan.features, label: plan.label, reencryptPending: nil,
            parentList: entry.parentList, epochReason: plan.reason.rawValue, home: plan.home, recoverySig: entry.recoverySig)
        try Self.seal(&m, key: key, signing: plan.signing, author: authorId)
        // The record is durable under its final name before vault.json names it (design §5.2 step 4): a crash
        // here leaves an orphan, which nothing reads.
        try FileIO.createDirectory(epochsURL)
        try FileIO.writeAtomically(recordFile, to: url.appendingPathComponent(m.epochRecord), replacing: false)
        try FileIO.syncDirectory(epochsURL)
        try faults.check(.afterRecord)
        let written = try Self.writeManifest(m, to: manifestURL, replacing: true)
        try faults.check(.afterManifest)
        return (written, key)
    }

    /// The current epoch's verified chain (epoch 1's record read when needed) and its record's parent.
    func currentChain() throws -> [ChainEntry] {
        if let verifiedChain { return verifiedChain.entries }
        guard manifest.epoch == 1, let key = secret else {
            throw VaultError.untrustedList(listStatus.problem ?? ListProblem(.otherEpoch, "the chain did not verify"))
        }
        let data = try readFile(url.appendingPathComponent(manifest.epochRecord), maxBytes: EpochRecord.maxBytes)
        guard Data(SHA256.hash(data: data)) == manifest.epochRecordHash else {
            throw VaultError.manifestCorrupt("\(manifest.epochRecord) is not the record vault.json names")
        }
        let record = try EpochRecord.open(data, key: key, vaultId: vaultId, epoch: 1)
        _ = try EpochChain.verify(record.chain, vaultId: vaultId, root: manifest.root)
        return record.chain
    }

    /// The same-epoch additions of the current epoch (approved by its home), for its chain entry.
    func currentAdditions() -> [ChainAddition] {
        let homeId = String(Hex.encode(manifest.home).prefix(8))
        return manifest.devices.compactMap { d in
            guard let claim = d.claim, claim.addedEpoch == manifest.epoch, claim.addedBy == homeId, d.fingerprint != manifest.home,
                  let sig = d.addSig else { return nil }
            return ChainAddition(claim: claim, addSig: sig)
        }
    }

    /// The view that seals the current epoch: its key, then every earlier one of the chain.
    func currentSealView() throws -> SealView {
        let key = try requireSecret()
        return SealView(current: (key.epochId, key, .mlkem768x25519(try key.vaultIdentity())), older: olderEpochs)
    }

    /// Re-opens this vault after an epoch it wrote, as `identity` (the new epoch's device), and pins it.
    mutating func adopt(after written: EpochManifest, identity: NativeIdentity, signing: DeviceSigningKeys) throws {
        var again = try Vault.open(at: url, identities: [identity], signing: signing, trust: trustStore, root: givenRoot ?? written.root,
                                   ledger: ledger, setAside: setAsideStore)
        again.faults = faults
        guard case .verified = again.listStatus else {
            throw VaultError.untrustedList(again.listStatus.problem ?? ListProblem(.otherEpoch, "the new epoch does not check"))
        }
        try again.rememberList()
        try? again.ledger?.setCaughtUp(written.epochId)
        self = again
    }

    /// The common preconditions of an epoch change by home (design §5.2 step 1, §5.6).
    func requireHomeForEpoch(_ what: String) throws -> (signing: DeviceSigningKeys, home: EpochKeyEntry) {
        try requireWritable()
        try requireCompleteCopy()
        guard isHome, let signing, let home = deviceEntry else {
            let who = manifest.homeEntry.map { "\(DeviceName.display($0.name)) (\($0.id ?? "?"))" } ?? "another device"
            throw VaultError.notHome("only the home device \(what): \(who) manages this vault's devices")
        }
        return (signing, home)
    }

    // MARK: - Removal (design §5.2)

    /// Removes the listed devices `ids` (design §5.2): after this device catches up its own ledger, under
    /// the vault's write lock, a new epoch whose record seals every accepted file and whose `vault.json`
    /// wraps a new key to every remaining key. Only home removes, and never itself (hand off first).
    /// From the moment it returns, every write of this device is under the new key.
    ///
    /// - Parameter ids: device ids (or unique prefixes of 4+ hex digits).
    @discardableResult
    public mutating func removeDevices(_ ids: [String], now: Date = Date()) throws -> EpochChangeReport {
        let (signing, home) = try requireHomeForEpoch("removes devices")
        let targets = try ids.map { try resolveDevice($0) }
        guard !targets.isEmpty else { throw VaultError.epochChangeRefused("name at least one device to remove") }
        guard !targets.contains(where: { $0.fingerprint == manifest.home }) else {
            throw VaultError.epochChangeRefused("the home device cannot remove itself: hand the home role to another "
                + "device first (sempere devices handoff)")
        }
        let gone = Set(targets.map(\.fingerprint))
        return try changeEpoch(reason: .remove, now: now) { m in
            (m.devices.filter { !gone.contains($0.fingerprint) }, m.recoveryEntry, home, signing, m.home, nil)
        }
    }

    /// Hands the home role to the listed device `id` (design §5.6 rule 2): a new epoch with the same list,
    /// signed by this (the old) home. From then on only the new home changes the list.
    @discardableResult
    public mutating func handOff(to id: String, now: Date = Date()) throws -> EpochChangeReport {
        let (signing, home) = try requireHomeForEpoch("hands the home role over")
        let target = try resolveDevice(id)
        guard target.fingerprint != manifest.home else {
            throw VaultError.epochChangeRefused("this device is home already")
        }
        return try changeEpoch(reason: .handoff, now: now) { m in
            (m.devices, m.recoveryEntry, home, signing, target.fingerprint, nil)
        }
    }

    /// The steps every home epoch change shares (design §5.2): this device's catch-up, then under the
    /// write lock the sealed set, the record and `vault.json`, then the pin.
    mutating func changeEpoch(reason: EpochReason, now: Date,
                              _ decide: (EpochManifest) throws -> (devices: [EpochKeyEntry], recovery: EpochKeyEntry?,
                                                                     author: EpochKeyEntry, signing: DeviceSigningKeys,
                                                                     home: Data, recoverySigner: (DeviceSigningKeys, ChainAuthor)?))
        throws -> EpochChangeReport {
        // This device's own files of earlier epochs first (design §5.2 step 2), so it seals them too.
        _ = try catchUp()
        let held = unlockIdentities.first { Self.recipientString(of: $0) == deviceEntry?.key }
        let identity = (held as? NativeIdentity) ?? (held as? MLKEM768X25519Identity).map { NativeIdentity.mlkem768x25519($0) }
        guard let identity, let mySigning = signing else { throw VaultError.locked }
        var result: (EpochManifest, VaultEpochKey, Int)?
        try epochWriteLock.withLock(timeout: 30) {
            let m = try requireUnchangedOnDisk()
            let d = try decide(m)
            guard let recovery = d.recovery else { throw VaultError.manifestCorrupt("no recovery entry") }
            let sealed = try sealedSet(try currentSealView())
            let plan = EpochPlan(reason: reason, parentKey: try requireSecret(), parentChain: try currentChain(),
                                 parentList: m.keys.map(\.fingerprint), parentAdditions: currentAdditions(),
                                 devices: d.devices, recovery: recovery, home: d.home, author: d.author, signing: d.signing,
                                 recoverySigner: d.recoverySigner.map { (keys: $0.0, author: $0.1) }, sealed: sealed,
                                 parentRecordHash: m.epochRecordHash, created: now, label: m.label, features: m.features)
            let (written, key) = try writeEpoch(plan)
            result = (written, key, sealed.count)
        }
        guard let (written, _, sealedCount) = result else { throw VaultError.interrupted }
        let removed = Set(manifest.keys.map(\.fingerprint)).subtracting(written.firstList)
        try adopt(after: written, identity: identity, signing: mySigning)
        return EpochChangeReport(epoch: written.epoch, epochId: written.epochId, reason: reason,
                                 removed: removed.sorted { $0.lexicographicallyPrecedes($1) }, home: written.home, sealed: sealedCount)
    }

    // MARK: - Replacing the recovery kit (design §6.5)

    /// One device of the review before a kit replacement (design §6.5 step 1).
    public struct KitReviewItem: Hashable, Sendable {
        public var device: EpochKeyEntry
        /// True when a takeover since the current kit was created introduced or re-admitted it, or made it home.
        public var takeoverSinceKit: Bool
    }

    /// The device review of a kit replacement: every listed device but home, each marked when a takeover
    /// since the current kit was created touched it (design §6.5 step 1).
    public func kitReview() throws -> [KitReviewItem] {
        let chain = try currentChain()
        let kitStart = chain.lastIndex { $0.recovery != chain.last?.recovery }.map { $0 + 1 } ?? 0
        var touched = Set<Data>()
        for e in chain[kitStart...] where e.reason == EpochReason.takeover.rawValue {
            touched.insert(e.home)
            touched.formUnion(e.list)
        }
        return manifest.devices.filter { $0.fingerprint != manifest.home }.map {
            KitReviewItem(device: $0, takeoverSinceKit: touched.contains($0.fingerprint))
        }
    }

    /// Replaces the recovery kit (design §6.5): on home, after the device review (every listed device but
    /// home is in `keep` or `remove`), a `recovery` epoch that drops the current recovery key and the devices
    /// in `remove`, and adds `newRecovery`. When the user still holds the old kit (`oldRecovery`) the epoch
    /// also carries its signature (evidence only). With `passphrase`, the passphrase copy is written for the
    /// new key and the old copies are deleted. The caller has asked for device-owner authentication (the app:
    /// Face ID or the passcode; the CLI: `--yes` after showing the review).
    ///
    /// - Throws: `epochChangeRefused` for an incomplete review or an old kit that is not the current one.
    @discardableResult
    public mutating func replaceRecoveryKit(_ newRecovery: MLKEM768X25519Identity, keep: Set<String>, remove: Set<String>,
                                            oldRecovery: MLKEM768X25519Identity? = nil, passphrase: String? = nil,
                                            workFactor: Int = RecoveryPassphraseCopy.workFactor,
                                            now: Date = Date()) throws -> EpochChangeReport {
        let (signing, home) = try requireHomeForEpoch("replaces the recovery kit")
        if let passphrase, passphrase.isEmpty { throw VaultError.emptyPassphrase }
        guard (1...RecoveryPassphraseCopy.workFactor).contains(workFactor) else { throw VaultError.workFactorOutOfRange(workFactor) }
        let review = try kitReview()
        let kept = Set(try keep.map { try resolveDevice($0).fingerprint })
        let gone = Set(try remove.map { try resolveDevice($0).fingerprint })
        guard kept.isDisjoint(with: gone) else { throw VaultError.epochChangeRefused("a device is both kept and removed") }
        let unanswered = review.filter { !kept.contains($0.device.fingerprint) && !gone.contains($0.device.fingerprint) }
        guard unanswered.isEmpty else {
            throw VaultError.epochChangeRefused("confirm or remove every device first (design §6.5): "
                + unanswered.map { "\(DeviceName.display($0.device.name)) (\($0.device.id ?? "?"))" }.joined(separator: ", "))
        }
        guard !gone.contains(manifest.home) else { throw VaultError.epochChangeRefused("the home device cannot remove itself") }
        let newSigning = try DeviceSigningKeys.recovery(identity: newRecovery)
        let newSign = try newSigning.publicKeys()
        let newKey = newRecovery.recipient.string
        guard newKey != manifest.recoveryEntry?.key, !manifest.keys.contains(where: { $0.key == newKey }) else {
            throw VaultError.epochChangeRefused("the new recovery key is a key this vault lists already")
        }
        var oldSigner: (DeviceSigningKeys, ChainAuthor)?
        if let oldRecovery {
            let oldSigning = try DeviceSigningKeys.recovery(identity: oldRecovery)
            let author = ChainAuthor(key: oldRecovery.recipient.string, sign: try oldSigning.publicKeys())
            guard author.recoveryFingerprint == manifest.recoveryFingerprint else {
                throw VaultError.epochChangeRefused("the old recovery key given is not this vault's current kit")
            }
            oldSigner = (oldSigning, author)
        }
        let recoveryEntry = EpochKeyEntry(role: .recovery, key: newKey, sign: newSign, added: RFC3339.string(now),
                                          name: "Recovery kit", wrap: "")
        // The new passphrase copy is in place before vault.json names the key; the old ones go after.
        if let passphrase {
            let copy = RecoveryPassphraseCopy(created: RFC3339.string(now), vaultId: vaultId, root: manifest.root, identity: newRecovery)
            let path = try copy.path()
            try FileIO.createDirectory(keysURL)
            try FileIO.writeAtomically(try copy.seal(passphrase: passphrase, workFactor: workFactor),
                                       to: url.appendingPathComponent(path), replacing: true)
        }
        let report = try changeEpoch(reason: .recovery, now: now) { m in
            (m.devices.filter { !gone.contains($0.fingerprint) }, recoveryEntry, home, signing, m.home, oldSigner)
        }
        sweepSupersededPassphraseCopies()
        return report
    }

    /// Deletes passphrase copies of a recovery key the current `vault.json` no longer lists (design §8.2):
    /// on home, at a verified epoch, so also after a kit replacement that crashed between its `vault.json` and
    /// this step (review S6). A leaked superseded copy would still open every earlier epoch.
    func sweepSupersededPassphraseCopies() {
        guard isHome, case .verified = listStatus, let current = manifest.recoveryFingerprint,
              let chain = verifiedChain?.entries else { return }
        // Only kits the chain retired: a copy written for a kit not adopted yet (a replacement in progress) stays.
        let retired = Set(chain.map(\.recovery)).subtracting([current])
        for name in passphraseCopyNames() {
            let hex = name.dropFirst("recovery-".count).dropLast(".key.age".count)
            if let fp = Hex.decode(String(hex)), retired.contains(fp) { try? FileIO.remove(keysURL.appendingPathComponent(name)) }
        }
    }

    // MARK: - Takeover (design §5.6 rule 3, §6.3)

    /// A device of a takeover's list: the devices of the parent's list (checked by default) and of earlier
    /// lists of its ancestry that a later epoch removed (unchecked by default, design §6.3).
    public struct TakeoverCandidate: Hashable, Sendable {
        public var fingerprint: Data
        public var id: String
        /// Its name as this device's trust record knows it when it does (`nameTrusted`), else as the current
        /// `vault.json` says it, which a stolen home may have renamed (review S3).
        public var name: String
        public var nameTrusted: Bool
        /// On the parent epoch's list.
        public var listed: Bool
        /// Removed by an epoch the takeover drops (`TakeoverPlan.dropped`): not checked by default, since
        /// the home of that epoch may have removed it for a reason (review S3).
        public var removedByDroppedEpoch: Bool
        /// Checked by default on the takeover screen (design §6.3): on the parent's list and not removed by a
        /// dropped epoch.
        public var checkedByDefault: Bool { listed && !removedByDroppedEpoch }
    }

    /// An epoch above the takeover's parent that the takeover drops (design §5.6 rule 4), as the screen shows it.
    public struct DroppedEpoch: Hashable, Sendable {
        public var epoch: Int
        public var reason: String
        /// The id of the device that signed it.
        public var author: String
        /// The devices it removed (fingerprints): computed from its signed parent and first lists.
        public var removed: [Data]
    }

    /// What a takeover starts from: the epoch it is made under and the devices the user may pick.
    public struct TakeoverPlan: Sendable {
        /// The parent epoch (this device's pinned frontier; for a joiner, the vault's current epoch).
        public var parentEpoch: Int
        public var parentId: Data
        public var candidates: [TakeoverCandidate]
        /// The epochs above the parent that the vault holds and the takeover drops, oldest first.
        public var dropped: [DroppedEpoch]
    }

    /// Opens the vault at `url` with the recovery key `recovery` for a takeover by `device` (design §6.3):
    /// rooted at `root` (the kit's, the passphrase copy's) or at this device's trust record, and returns the
    /// plan: the parent epoch (this device's pinned frontier when it has one on the vault's chain) and the
    /// devices the user picks from.
    ///
    /// - Throws: `epochChangeRefused` when the recovery key is not the parent's kit, or the pinned
    ///   frontier is not on the vault's chain; `untrustedList` when the vault does not check.
    public static func takeoverPlan(at url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity,
                                    trust: (any EpochTrustStore)?, root: Data?) throws -> TakeoverPlan {
        let ctx = try TakeoverContext(url: url, device: device, recovery: recovery, trust: trust, root: root)
        return ctx.plan
    }

    /// Takes over the vault at `url` (design §5.6 rule 3, §6.3): `device` becomes home, under a `takeover`
    /// epoch whose parent is its pinned frontier (a joiner's: the vault's current epoch), whose list is the
    /// devices in `keep` plus `device` itself and the recovery key, signed by `device` and by `recovery`'s
    /// signing pair. When `device` is on no list of the parent's ancestry it joins as the new home
    /// (`addedBy: "recovery"`, a kit join). Returns the vault opened as `device`.
    ///
    /// - Parameters:
    ///   - keep: fingerprints of the devices to keep (from `takeoverPlan`'s candidates).
    ///   - name, kind: the new home's name and kind when it joins.
    public static func takeover(at url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity, keep: Set<Data>,
                                name: String = "sempere CLI", kind: String = "cli", trust: (any EpochTrustStore)?, root: Data?,
                                ledger: (any WriteLedgerStore)? = nil, setAside: SetAsideStore? = nil,
                                now: Date = Date()) throws -> (vault: Vault, report: EpochChangeReport) {
        try takeover(at: url, device: device, recovery: recovery, keep: keep, name: name, kind: kind, trust: trust, root: root,
                     ledger: ledger, setAside: setAside, now: now, faults: EpochFaults())
    }

    static func takeover(at url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity, keep: Set<Data>,
                         name: String, kind: String, trust: (any EpochTrustStore)?, root: Data?,
                         ledger: (any WriteLedgerStore)?, setAside: SetAsideStore?, now: Date,
                         faults: EpochFaults) throws -> (vault: Vault, report: EpochChangeReport) {
        guard JoinRequest.isValidKind(kind) else { throw VaultError.joinRequestRefused("kind \(kind)") }
        let ctx = try TakeoverContext(url: url, device: device, recovery: recovery, trust: trust, root: root)
        var vault = ctx.vault
        vault.ledger = ledger
        vault.setAsideStore = setAside
        vault.faults = faults
        let allowed = Set(ctx.plan.candidates.map(\.fingerprint))
        guard keep.isSubset(of: allowed) else {
            throw VaultError.epochChangeRefused("a takeover lists only devices of its ancestry's lists (design §5.6)")
        }
        let recoverySigning = try DeviceSigningKeys.recovery(identity: recovery)
        let recoveryAuthor = ChainAuthor(key: recovery.recipient.string, sign: try recoverySigning.publicKeys())
        let stamp = RFC3339.string(now)
        let epoch = ctx.parentEpoch + 1
        let homeId = device.id
        // Each kept device: its entry as the vault lists it when that is from the parent's ancestry; else, for a
        // device a later epoch removed, its entry rebuilt from the approval the chain carries (its original
        // `addSig`, so it is in the first list); else (an epoch's author, whose approval the chain does not
        // carry) a fresh approval by the new home.
        var devices: [EpochKeyEntry] = []
        for fp in keep where fp != device.fingerprint {
            let name = ctx.entries[fp]?.name ?? "Device \(Hex.encode(fp).prefix(8))"
            if let e = ctx.entries[fp], (e.addedEpoch ?? Int.max) <= ctx.parentEpoch {
                devices.append(e)
            } else if let a = ctx.approvals[fp], a.claim.addedEpoch <= ctx.parentEpoch {
                devices.append(EpochKeyEntry(role: .device, key: a.claim.key, id: String(Hex.encode(fp).prefix(8)),
                                             sign: a.claim.sign, kind: a.claim.kind, added: a.claim.added,
                                             addedEpoch: a.claim.addedEpoch, addedBy: a.claim.addedBy, addSig: a.addSig,
                                             name: name, wrap: ""))
            } else if let k = ctx.keysByFingerprint[fp] {
                let claim = EntryClaim(key: k.key, sign: k.sign, kind: k.kind, added: stamp, addedEpoch: epoch, addedBy: homeId)
                devices.append(EpochKeyEntry(role: .device, key: k.key, id: String(Hex.encode(fp).prefix(8)), sign: k.sign,
                                             kind: k.kind, added: stamp, addedEpoch: epoch, addedBy: homeId,
                                             addSig: try device.signing.sign(AuthorMessage.entry(vaultId: vault.vaultId, claim)),
                                             name: name, wrap: ""))
            }
        }
        // The new home: its own entry when the parent's ancestry lists it with one, else a kit join.
        let homeEntry: EpochKeyEntry
        if let e = ctx.entries[device.fingerprint], (e.addedEpoch ?? Int.max) <= ctx.parentEpoch {
            homeEntry = e
        } else {
            let claim = EntryClaim(key: device.key, sign: device.sign, kind: kind, added: stamp, addedEpoch: epoch,
                                   addedBy: EntryClaim.recovery)
            homeEntry = EpochKeyEntry(role: .device, key: device.key, id: homeId, sign: device.sign, kind: kind, added: stamp,
                                      addedEpoch: epoch, addedBy: EntryClaim.recovery,
                                      addSig: try recoverySigning.sign(AuthorMessage.entry(vaultId: vault.vaultId, claim)),
                                      name: DeviceName.clean(name), wrap: "")
        }
        guard !devices.contains(where: { $0.id == homeId }) else {
            throw VaultError.joinRequestRefused("this device's id \(homeId) is a listed device's: generate another key")
        }
        devices.insert(homeEntry, at: 0)
        var result: (EpochManifest, Int)?
        try vault.epochWriteLock.withLock(timeout: 30) {
            _ = try vault.requireUnchangedOnDisk()
            let sealed = try vault.sealedSet(ctx.view)
            let plan = EpochPlan(reason: .takeover, parentKey: ctx.parentKey, parentChain: ctx.parentChain,
                                 parentList: ctx.parentList, parentAdditions: ctx.parentAdditions, devices: devices,
                                 recovery: ctx.recoveryEntry, home: device.fingerprint, author: homeEntry, signing: device.signing,
                                 recoverySigner: (keys: recoverySigning, author: recoveryAuthor), sealed: sealed,
                                 parentRecordHash: ctx.parentRecordHash, created: now,
                                 label: vault.manifest.label, features: vault.manifest.features)
            let (written, _) = try vault.writeEpoch(plan)
            result = (written, sealed.count)
        }
        guard let (written, sealedCount) = result else { throw VaultError.interrupted }
        try vault.adopt(after: written, identity: device.nativeIdentity, signing: device.signing)
        let removed = Set(ctx.parentList).subtracting(written.firstList)
        return (vault, EpochChangeReport(epoch: written.epoch, epochId: written.epochId, reason: .takeover,
                                         removed: removed.sorted { $0.lexicographicallyPrecedes($1) },
                                         home: written.home, sealed: sealedCount))
    }

    // MARK: - Removed devices (design §5.5)

    /// Why this device (one of `held` keys) is not on the newest list, when it can tell (design §4.3 step 2,
    /// §5.5): its trust record pins the vault, the `vault.json` at hand is a verified next epoch after the
    /// pinned one (`EpochFrontier.verifiedChild`), and its first list omits this device. Nil otherwise (a key
    /// never listed, an epoch it cannot verify).
    static func removalNotice(_ m: EpochManifest, held: Set<String>, signing: DeviceSigningKeys?,
                              trust: (any EpochTrustStore)?) -> String? {
        guard let trust, let record = try? trust.record(for: m.vaultId), let pinned = record.pinned,
              let frontier = EpochFrontier(record: record), let child = frontier.verifiedChild(m),
              let mine = record.list.first(where: { $0.role == EpochKeyEntry.Role.device.rawValue && held.contains($0.key) }),
              pinned.list.contains(mine.fingerprint) || record.list.contains(mine),
              !m.firstList.contains(mine.fingerprint)
        else { return nil }
        let signer = child.signer
        let who = DeviceName.display(signer.name)
        let what = child.reason == .takeover ? "took over with the recovery kit" : "removed this device"
        return "this device is not on the newest device list of the vault: \(who) (\(signer.id ?? "?")) \(what) "
            + "(epoch \(m.epoch)). It writes nothing to the vault. If that is a mistake (a lost device that was "
            + "managing devices), a takeover with the recovery kit undoes it, and this device rejoins when the vault shows it."
    }

    /// The epoch this device has verified, to check a claim of the next one against (`EpochFrontier`): its
    /// trust record's pinned epoch when it keeps one for this vault, else this value's own epoch when it is
    /// unlocked and its `vault.json` checked (a reader without a record). Nil otherwise.
    public var epochFrontier: EpochFrontier? {
        if let trustStore, let record = try? trustStore.record(for: vaultId) { return EpochFrontier(record: record) }
        guard case .verified = listStatus, let secret, let links = try? LinkPublicKeys(epochKey: secret),
              let recovery = manifest.recoveryEntry?.fingerprint else { return nil }
        return EpochFrontier(vaultId: vaultId, root: manifest.root, epoch: manifest.epoch, epochId: manifest.epochId,
                             linkPublicKeys: links, recovery: recovery, home: manifest.home)
    }
}

/// An epoch a device has verified (its trust record's pinned epoch, design §4): what a `vault.json` that
/// claims to be the next epoch is checked against, by both the removal notice (design §5.5) and the
/// per-device summaries sync (format.md §12.5), so the two can never disagree about which next epoch to
/// believe.
public struct EpochFrontier: Hashable, Sendable {
    public var vaultId: UUID
    public var root: Data
    public var epoch: Int
    public var epochId: Data
    /// The epoch's link public keys: what the child's `epochLink` must verify under.
    public var linkPublicKeys: LinkPublicKeys
    /// The epoch's recovery fingerprint: the only kit a takeover child may be signed by.
    public var recovery: Data
    /// The home device after the epoch: the only device a removal, handoff or kit-replacement child may be
    /// signed by.
    public var home: Data

    public init(vaultId: UUID, root: Data, epoch: Int, epochId: Data, linkPublicKeys: LinkPublicKeys, recovery: Data,
                home: Data) {
        self.vaultId = vaultId; self.root = root; self.epoch = epoch; self.epochId = epochId
        self.linkPublicKeys = linkPublicKeys; self.recovery = recovery; self.home = home
    }

    /// The pinned epoch of `record` with the record's root and home; nil without one.
    public init?(record: EpochTrustRecord) {
        guard let pinned = record.pinned else { return nil }
        self.init(vaultId: record.vaultId, root: record.root, epoch: pinned.epoch, epochId: pinned.epochId,
                  linkPublicKeys: pinned.linkPublicKeys, recovery: pinned.recovery, home: record.home)
    }

    /// A next epoch that verifies from this frontier alone.
    public struct Child: Sendable {
        public var epoch: Int
        public var reason: EpochReason?
        /// The child's author: the frontier's home, or for a takeover the new home.
        public var signer: EpochKeyEntry
    }

    /// `m` when it is the direct child of this epoch (design §4.3 step 2, §5.5, §5.6): the same vault and
    /// root, epoch + 1, `parent` this `epochId`, its `epochLink` verifies under this epoch's link keys, and
    /// its `epochSig` verifies under the frontier's home (a listed entry whose fingerprint is `home`, which
    /// binds its signing keys), or, for a takeover, its `recoverySig` under the recovery entry whose
    /// fingerprint is this epoch's kit and its `epochSig` under its new home. Nil otherwise: nothing from
    /// `m` is believed.
    public func verifiedChild(_ m: EpochManifest) -> Child? {
        guard m.vaultId == vaultId, m.root == root, m.epoch == epoch + 1, m.parent == epochId,
              EpochLinks.verify(m.epochLink, keys: linkPublicKeys, epoch: m.epoch, childEpochId: m.epochId,
                                vaultId: m.vaultId),
              let message = m.epochMessage
        else { return nil }
        let reason = EpochReason(rawValue: m.epochReason)
        let signer: EpochKeyEntry?
        if reason == .takeover {
            guard let rs = m.recoverySig, let recoveryEntry = m.recoveryEntry, let rk = recoveryEntry.sign,
                  recoveryEntry.fingerprint == recovery, rs.verifies(message, keys: rk) else { return nil }
            signer = m.homeEntry
        } else {
            signer = m.keys.first { $0.role == .device && $0.fingerprint == home }
        }
        guard let signer, let keys = signer.sign, m.epochSig.verifies(message, keys: keys) else { return nil }
        return Child(epoch: m.epoch, reason: reason, signer: signer)
    }
}

/// What a takeover needs, read once (design §6.3).
struct TakeoverContext {
    var vault: Vault
    var plan: Vault.TakeoverPlan
    var parentEpoch: Int
    var parentKey: VaultEpochKey
    var parentChain: [ChainEntry]
    var parentList: [Data]
    var parentAdditions: [ChainAddition]
    /// SHA-256 of the parent epoch's record (the current one's from vault.json; an earlier one's as the hash
    /// links down the chain bound it).
    var parentRecordHash: Data
    var recoveryEntry: EpochKeyEntry
    var view: Vault.SealView
    /// Entries of the current `vault.json`, by fingerprint.
    var entries: [Data: EpochKeyEntry]
    /// Keys of devices the chain knows (authors and additions), by fingerprint.
    var keysByFingerprint: [Data: (key: String, sign: DeviceSigningPublicKeys, kind: String)]
    /// The approvals the chain carries up to the parent (each addition's claim and `addSig`), by fingerprint.
    var approvals: [Data: ChainAddition]

    init(url: URL, device: DeviceKeys, recovery: MLKEM768X25519Identity, trust: (any EpochTrustStore)?, root: Data?) throws {
        let record = try trust?.record(for: Vault.open(at: url).vaultId)
        guard root != nil || record != nil else {
            throw VaultError.untrustedList(ListProblem(.rootUnconfirmed, "a takeover needs the vault's root: the kit's "
                + "(--root), or the passphrase copy's"))
        }
        // The recovery key opens the current epoch; the vault is checked against the root and the trust record.
        let v = try Vault.open(at: url, identities: [NativeIdentity.mlkem768x25519(recovery)], trust: trust, root: root ?? record?.root)
        guard v.openedWith == .recovery else {
            throw VaultError.epochChangeRefused("the key given is not this vault's recovery key")
        }
        // The vault checks: rooted, and (with a trust record) on a chain this device follows.
        if let problem = v.listStatus.problem { throw VaultError.untrustedList(problem) }
        let chain = try v.currentChain()
        // The parent: this device's pinned frontier when the chain holds it, else (a joiner) the current epoch.
        let parentIndex: Int
        if let pinned = record?.pinned {
            guard let i = chain.firstIndex(where: { $0.epochId == pinned.epochId }) else {
                throw VaultError.epochChangeRefused("the vault's chain does not hold the epoch this device pinned: open the "
                    + "vault once with this device's key (or take over from a device that follows this chain)")
            }
            parentIndex = i
        } else {
            parentIndex = chain.count - 1
        }
        let parent = chain[parentIndex]
        // Valid only under the pinned frontier's own kit (design §5.6 rule 3, `TakeoverRule.recoveryKey`).
        let pinnedEpochs = record?.chain.map { TakeoverRule.PinnedEpoch(epochId: $0.epochId, recovery: $0.recovery) } ?? []
        let path = chain[...parentIndex].map(\.epochId)
        let recoveryFP = try KeyFingerprint.recovery(identity: recovery)
        guard TakeoverRule.recoveryKey(parentRecovery: parent.recovery, parentPath: Array(path), pinned: pinnedEpochs)
                == parent.recovery, parent.recovery == recoveryFP else {
            throw VaultError.epochChangeRefused("this recovery kit is not the kit of the epoch this device takes over from "
                + "(retired, or not pinned yet): only the current kit of the pinned epoch takes over (design §5.6)")
        }
        // The parent's key: the current one, or from the records below it.
        let older = v.olderEpochs
        let parentKey: VaultEpochKey
        let view: Vault.SealView
        if parentIndex == chain.count - 1 {
            parentKey = try v.requireSecret()
            view = try v.currentSealView()
            parentRecordHash = v.manifest.epochRecordHash
        } else {
            guard let k = older.first(where: { $0.epochId == parent.epochId }), let h = k.recordHash else {
                throw VaultError.epochChangeRefused("the key of epoch \(parent.epoch) is not readable from the records")
            }
            parentKey = k.key
            parentRecordHash = h
            view = Vault.SealView(current: (k.epochId, k.key, k.identity), older: older.filter { $0.epoch < parent.epoch })
        }
        // The parent's list includes its same-epoch additions: carried in the next entry for an earlier
        // epoch, and for the current one admitted from vault.json by the check at open.
        var prefix = Array(chain[...parentIndex])
        var directory = DeviceDirectory()
        if parentIndex == chain.count - 1 {
            prefix[parentIndex].additions = v.currentAdditions()
            for d in v.manifest.devices { if let s = d.sign { directory.add(key: d.key, sign: s) } }
        }
        let verified = try EpochChain.verify(prefix, vaultId: v.vaultId, root: v.manifest.root, directory: directory)
        // Devices of the parent's ancestry: the parent's list (checked by default) and earlier ones a later
        // epoch removed (unchecked).
        let parentListSet = verified.lists[parentIndex].list
        let ancestry = verified.lists.reduce(into: Set<Data>()) { $0.formUnion($1.list) }.subtracting(verified.recoveryKeys)
        var keys: [Data: (key: String, sign: DeviceSigningPublicKeys, kind: String)] = [:]
        var approvals: [Data: ChainAddition] = [:]
        for e in chain {
            if let s = e.author.sign { keys[e.author.fingerprint] = (e.author.key, s, "cli") }
            for a in e.additions { keys[a.fingerprint] = (a.claim.key, a.claim.sign, a.claim.kind) }
        }
        for (i, e) in prefix.enumerated() {
            // Only the approvals the chain check admitted (by the home of their epoch).
            let admitted = Set(verified.lists[i].admitted.map(\.fingerprint))
            for a in e.additions where admitted.contains(a.fingerprint) { approvals[a.fingerprint] = a }
        }
        var entries: [Data: EpochKeyEntry] = [:]
        for d in v.manifest.devices {
            entries[d.fingerprint] = d
            if let s = d.sign { keys[d.fingerprint] = (d.key, s, d.kind ?? "cli") }
        }
        // The epochs this takeover drops (above its parent on the vault's chain), and whom they removed.
        let dropped = chain[(parentIndex + 1)...].map { e in
            Vault.DroppedEpoch(epoch: e.epoch, reason: e.reason, author: String(Hex.encode(e.author.fingerprint).prefix(8)),
                               removed: Set(e.parentList).subtracting(e.list).sorted { $0.lexicographicallyPrecedes($1) })
        }
        let removedByDropped = Set(dropped.flatMap(\.removed))
        // Names this device verified itself (its trust record), never the current file's when it has them.
        var trustedNames: [Data: String] = [:]
        for e in record?.list ?? [] { trustedNames[e.fingerprint] = e.name }
        let candidates = ancestry.filter { $0 != device.fingerprint && keys[$0] != nil }.map { fp in
            Vault.TakeoverCandidate(
                fingerprint: fp, id: String(Hex.encode(fp).prefix(8)),
                name: DeviceName.display(trustedNames[fp] ?? entries[fp]?.name ?? "Device \(Hex.encode(fp).prefix(8))"),
                nameTrusted: trustedNames[fp] != nil, listed: parentListSet.contains(fp),
                removedByDroppedEpoch: removedByDropped.contains(fp))
        }.sorted { ($0.checkedByDefault ? 0 : 1, $0.id) < ($1.checkedByDefault ? 0 : 1, $1.id) }
        // The parent's own list as its author saw it, and its additions: from the parent's vault.json when it is
        // the current one, else from the chain (the parent's first list plus the additions the next epoch carried).
        let parentList: [Data]
        let parentAdditions: [ChainAddition]
        if parentIndex == chain.count - 1 {
            parentList = v.manifest.keys.map(\.fingerprint)
            parentAdditions = v.currentAdditions()
        } else {
            parentList = Array(parentListSet)
            parentAdditions = chain[parentIndex].additions
        }
        // The kit's entry as the vault lists it; after a kit replacement above the parent (a thief's), rebuilt
        // from the key itself.
        if let listed = v.manifest.recoveryEntry, listed.fingerprint == recoveryFP {
            recoveryEntry = listed
        } else {
            recoveryEntry = EpochKeyEntry(role: .recovery, key: recovery.recipient.string,
                                          sign: try DeviceSigningKeys.recovery(identity: recovery).publicKeys(),
                                          added: v.manifest.created, name: "Recovery kit", wrap: "")
        }
        vault = v; parentEpoch = parent.epoch; self.parentKey = parentKey; parentChain = Array(chain[...parentIndex])
        self.parentList = parentList; self.parentAdditions = parentAdditions; self.view = view; self.entries = entries
        keysByFingerprint = keys
        self.approvals = approvals
        plan = Vault.TakeoverPlan(parentEpoch: parent.epoch, parentId: parent.epochId, candidates: candidates, dropped: dropped)
    }
}
