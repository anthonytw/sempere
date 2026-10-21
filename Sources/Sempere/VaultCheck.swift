import Crypto
import Foundation

// Checking `vault.json` against what this device verified (docs/design/key-hierarchy.md §4.3; format.md
// §15.3, §15.10), for single-epoch vaults (KH2). The checks that need no chain are
// `EpochManifest.check`'s; this file adds the root, the trust record, and the record itself.

extension Vault {
    /// Classifies `manifest` for a device holding `key` (from its own wrap).
    ///
    /// - The root must be the one epoch 1's key gives (this device holds `K_1`), the trust record's, and
    ///   `root` when given.
    /// - With a trust record: the same epoch and `epochId` as the pinned one, every check of
    ///   `EpochManifest.check` against the list it verified, no entry it verified gone or changed but
    ///   for its name, and markers at least those it verified.
    /// - Without one: the checks against epoch 1's first list. A device with a trust store that has no
    ///   record and was given no root cannot confirm the vault (`rootUnconfirmed`): it reads, and writes
    ///   once the join's reply code (or the kit's root) confirmed it.
    static func listStatus(_ manifest: EpochManifest, key: VaultEpochKey, trust: (any EpochTrustStore)?,
                           root expected: Data?) -> ListStatus {
        guard manifest.epoch == 1 else {
            return .refused(ListProblem(.otherEpoch, "epoch \(manifest.epoch): this version reads vaults of one epoch only"))
        }
        guard let derived = try? VaultRoot.fingerprint(vaultId: manifest.vaultId, epochOne: key), derived == manifest.root else {
            return .refused(ListProblem(.rootMismatch, "root is not the one epoch 1's key gives"))
        }
        if let expected, expected != manifest.root {
            return .refused(ListProblem(.rootMismatch, "root is not the one given (the kit's, or the reply code's)"))
        }
        let record: EpochTrustRecord?
        do { record = try trust?.record(for: manifest.vaultId) } catch {
            return .refused(ListProblem(.recordUnreadable, "this device's trust record cannot be read: \(error)"))
        }
        var verified: Set<Data>
        if let record {
            guard record.root == manifest.root else {
                return .refused(ListProblem(.rootMismatch, "root is not the one this device pinned"))
            }
            guard record.pinned?.epochId == manifest.epochId else {
                return .refused(ListProblem(.otherEpoch, "another epoch than the one this device pinned"))
            }
            // The pinned epoch's home and first list come from the record, never from the file (design
            // §4.3): within one epoch only home's additions and renames change the list. With them fixed,
            // `epochSig` and every `addSig` verify under the home this device verified.
            guard record.home == manifest.home else {
                return .refused(ListProblem(.entriesChanged, "the home device is not the one this device verified: "
                    + "only a handoff (a new epoch) changes it"))
            }
            guard let pinned = record.pinned, Set(pinned.list) == Set(manifest.firstList) else {
                return .refused(ListProblem(.entriesChanged, "the epoch's first list is not the one this device verified"))
            }
            verified = Set(record.list.map(\.fingerprint))
        } else {
            verified = Set(manifest.firstList)
        }
        let admitted: [EpochKeyEntry]
        do { admitted = try manifest.check(key: key, verifiedList: verified) } catch let e as EpochManifest.ProblemError {
            return .refused(problem(e.problem))
        } catch {
            return .refused(ListProblem(.listTag, "\(error)"))
        }
        verified.formUnion(admitted.map(\.fingerprint))
        guard let record else {
            if trust != nil, expected == nil {
                return .refused(ListProblem(.rootUnconfirmed, "this device has not confirmed the vault: type the "
                    + "home device's reply words (sempere device confirm), or give the kit's root"))
            }
            return .verified(.firstUse)
        }
        // Under one epoch the list only grows (design §5.1): an entry this device verified is still
        // there, with the same key and signing keys (its name may change).
        let now = Dictionary(manifest.keys.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        var renamed = false
        for entry in record.list {
            guard let current = now[entry.fingerprint] else {
                return .refused(ListProblem(.entriesChanged, "\(entry.role) \(ListProblem.abbreviate(entry.key)) "
                    + "is gone under the same epoch: a removal always starts a new epoch"))
            }
            if current.name != entry.name { renamed = true }
        }
        guard record.markers.isCovered(by: manifest) else {
            return .refused(ListProblem(.markersRolledBack, "format or features are older than this device verified"))
        }
        if !admitted.isEmpty { return .verified(.added) }
        return .verified(renamed ? .renamed : .unchanged)
    }

    static func problem(_ p: EpochManifest.Problem) -> ListProblem {
        switch p {
        case .wrap: return ListProblem(.listTag, "this device's wrap is not of this epoch")
        case .listTag: return ListProblem(.listTag, "listTag does not verify: an entry was changed without the key")
        case .markersTag: return ListProblem(.markersTag, "markersTag does not verify: format or features changed")
        case .authorSig: return ListProblem(.authorSig, "authorSig is not the home device's")
        case .epochSig: return ListProblem(.epochSig, "epochSig does not verify under the epoch's author")
        case .introducesDevice: return ListProblem(.introducesDevice, "the epoch's first list introduces a device")
        case .addSig(let key):
            return ListProblem(.addSig, "\(ListProblem.abbreviate(key)) was not approved by the home device")
        }
    }

    /// Saves this device's trust record for the current (verified) list (format.md §15.10). Writers
    /// keep one, so a record that cannot be saved is an error, tried again by the next write.
    func rememberList() throws {
        guard let trustStore, let secret else { return }
        guard case .verified = listStatus else { return }
        var record = try EpochTrustRecord(
            vaultId: vaultId, root: manifest.root,
            chain: [try .init(epoch: manifest.epoch, key: secret, parent: manifest.parent,
                              list: manifest.firstList.sorted { $0.lexicographicallyPrecedes($1) })],
            list: manifest.keys.map { EpochTrustRecord.Entry(role: $0.role.rawValue, key: $0.key, sign: $0.sign, name: $0.name) },
            markers: VaultMarkers(manifest), home: manifest.home)
        if let memo = trustMemo.last, memo.vaultId == vaultId { record.markers = record.markers.merged(with: memo.markers) }
        guard trustMemo.last != record else { return }
        if let stored = try trustStore.record(for: vaultId) { record.markers = record.markers.merged(with: stored.markers) }
        try trustStore.save(record)
        trustMemo.last = record
    }

    /// Confirms this device's join (design §6.2 step 4): `words` are the reply home showed. They must be
    /// the six words of `JoinCodes.reply` over this device's commitment, the root and epoch of the
    /// `vault.json` at hand: a vault storage built around this device's (public) key has another root.
    /// Then the vault is checked against that root and the trust record saved.
    ///
    /// - Throws: `locked`, `recoveryKeyReadOnly`, `replyMismatch`, `untrustedList` for a list that
    ///   still does not check.
    public mutating func confirmJoin(words: [String]) throws {
        guard let secret else { throw VaultError.locked }
        guard let entry = deviceEntry, let claim = entry.claim else { throw VaultError.recoveryKeyReadOnly }
        let commitment = JoinRequest.commitment(vaultId: vaultId, key: claim.key, sign: claim.sign, kind: claim.kind)
        let reply = JoinCodes.reply(vaultId: vaultId, commitment: commitment, root: manifest.root, frontier: manifest.epochId)
        guard JoinCodes.matches(words, reply) else { throw VaultError.replyMismatch }
        listStatus = Self.listStatus(manifest, key: secret, trust: trustStore, root: manifest.root)
        try requireTrustedList()
        try rememberList()
    }

    /// `data` parsed, when it is a later version of this vault's `vault.json` by its home (design §5.1,
    /// one writer): the same vault, root, epoch and `epochId`, every check passes against the list this
    /// value holds, and that list's entries are all still there. Nil otherwise (also when locked): two
    /// versions whose lists do not contain each other are never merged.
    public func laterVersion(_ data: Data) -> EpochManifest? {
        guard let m = try? Self.readManifest(data), isLaterVersion(m, of: manifest) else { return nil }
        return m
    }

    /// True when `newer` is a later version than `older` of one epoch of this vault, by its home: the same
    /// vault, root, epoch and `epochId`, `newer` passes every check against `older`'s list (which it
    /// holds entirely) under this vault's key, its markers are at least `older`'s, and it adds a device or
    /// renames one. False when locked.
    public func isLaterVersion(_ newer: EpochManifest, of older: EpochManifest) -> Bool {
        guard let secret, newer.vaultId == older.vaultId, newer.vaultId == vaultId, newer.root == older.root,
              newer.epoch == older.epoch, newer.epochId == older.epochId, newer.epochId == secret.epochId,
              Self.readOnlyReasons(newer).isEmpty else { return false }
        // The epoch's head is fixed (design §4.3, §5.1): the same home, first list, parent, reason, author and
        // signature. Only the home of `older` may add devices or rename them in a later version.
        guard newer.home == older.home, Set(newer.firstList) == Set(older.firstList), newer.parent == older.parent,
              newer.epochReason == older.epochReason, newer.epochAuthor == older.epochAuthor,
              newer.epochSig == older.epochSig, newer.recoverySig == older.recoverySig,
              newer.homeEntry?.fingerprint == older.homeEntry?.fingerprint else { return false }
        let base = Set(older.keys.map(\.fingerprint))
        guard base.isSubset(of: Set(newer.keys.map(\.fingerprint))), (try? newer.check(key: secret, verifiedList: base)) != nil,
              VaultMarkers(older).isCovered(by: newer) else { return false }
        // Only the list may grow and names change; nothing else of the epoch moves.
        let names = Dictionary(newer.keys.map { ($0.fingerprint, $0.name) }, uniquingKeysWith: { a, _ in a })
        return newer.keys.count > older.keys.count || older.keys.contains { names[$0.fingerprint] != $0.name }
    }

    /// Whether a `vault.json` received from elsewhere (a sync server, a provider's other version) may
    /// replace the local one (design §4.3, §5.1): nil when it may, else why not.
    ///
    /// It may when it is the local one (or differs only in the unauthenticated `label`), or, with the
    /// vault unlocked, a later version of it by home (`isLaterVersion`). Without the key nothing else can
    /// be checked, and it waits; an older version, another epoch, or one whose list does not hold the
    /// local one is never taken (no merge).
    ///
    /// - Parameters:
    ///   - data: the incoming bytes.
    ///   - local: the local `vault.json` bytes; nil on a first pull (accepted).
    ///   - vault: the local vault, opened with identities if possible.
    public static func incomingManifestProblem(_ data: Data, local: Data?, vault: Vault?) -> String? {
        let incoming: EpochManifest
        do { incoming = try readManifest(data) } catch { return "the incoming vault.json does not parse: \(error)" }
        guard let local else { return nil }
        guard let mine = try? readManifest(local) else { return nil }   // a damaged local copy: take the remote one
        guard incoming.vaultId == mine.vaultId else { return "the incoming vault.json belongs to another vault" }
        if EpochManifest.sameExceptLabel(data, local) { return nil }
        guard incoming.root == mine.root else { return "the incoming vault.json has another root: not this vault" }
        guard incoming.epoch == mine.epoch, incoming.epochId == mine.epochId else {
            return "the incoming vault.json is of another epoch (epoch \(incoming.epoch)); this version reads vaults of "
                + "one epoch only"
        }
        guard let vault, vault.canRead, vault.vaultId == mine.vaultId else {
            return "the incoming vault.json changes the device list; unlock (--identity) so it can be checked (design §4.3)"
        }
        if vault.isLaterVersion(incoming, of: mine) { return nil }
        if vault.isLaterVersion(mine, of: incoming) {
            return "the incoming vault.json is an older version of the local one (fewer devices or older names)"
        }
        return "the incoming vault.json is not a later version of the local one by the home device (design §5.1): "
            + "both are kept, nothing is merged"
    }

    /// The six words this device expects as home's reply, for tests and scripted joins (the CLI never
    /// shows them: the point is that the user types the ones home shows).
    func expectedReplyWords() -> [String]? {
        guard let entry = deviceEntry, let claim = entry.claim else { return nil }
        let commitment = JoinRequest.commitment(vaultId: vaultId, key: claim.key, sign: claim.sign, kind: claim.kind)
        return JoinCodes.words(JoinCodes.reply(vaultId: vaultId, commitment: commitment, root: manifest.root,
                                               frontier: manifest.epochId))
    }
}

extension EpochTrustRecord.Entry {
    /// The entry's fingerprint (format.md §15.4).
    var fingerprint: Data {
        let p = sign?.p256Hex ?? "", m = sign?.mldsa65Hex ?? ""
        return role == EpochKeyEntry.Role.device.rawValue ? KeyFingerprint.device(key: key, signP256: p, signMLDSA65: m)
            : KeyFingerprint.recovery(key: key, signP256: p, signMLDSA65: m)
    }
}
