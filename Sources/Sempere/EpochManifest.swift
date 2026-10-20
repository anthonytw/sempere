import Age
import Crypto
import Foundation

// `vault.json` of the key hierarchy (docs/design/key-hierarchy.md §3, §4.1,
// §4.3; format.md §15.3): the model, a strict reader of untrusted bytes, and
// the checks that need no chain: the reader's own wrap, `listTag`,
// `authorSig` and `epochSig` by the home device (a takeover's `recoverySig` by the
// recovery key), every new entry's `addSig` by home, and the markers.
// KH2 replaces format.md §2's `VaultManifest` with it; nothing reads it yet.

/// One entry of `keys` (design §3).
public struct EpochKeyEntry: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case device, recovery }

    public var role: Role
    public var key: String
    /// Devices only.
    public var id: String?
    public var sign: DeviceSigningPublicKeys?
    public var kind: String?
    public var added: String
    public var addedEpoch: Int?
    public var addedBy: String?
    public var addSig: AuthorSignature?
    public var name: String
    public var wrap: String

    public init(role: Role, key: String, id: String? = nil, sign: DeviceSigningPublicKeys? = nil, kind: String? = nil,
                added: String, addedEpoch: Int? = nil, addedBy: String? = nil, addSig: AuthorSignature? = nil,
                name: String, wrap: String) {
        self.role = role; self.key = key; self.id = id; self.sign = sign; self.kind = kind; self.added = added
        self.addedEpoch = addedEpoch; self.addedBy = addedBy; self.addSig = addSig; self.name = name; self.wrap = wrap
    }

    /// The fingerprint (design §3): a device's, or the recovery key's, binding its signing keys (the
    /// recovery key's derived from it, design §5.6).
    public var fingerprint: Data {
        let p = sign?.p256Hex ?? "", m = sign?.mldsa65Hex ?? ""
        return role == .device ? KeyFingerprint.device(key: key, signP256: p, signMLDSA65: m)
            : KeyFingerprint.recovery(key: key, signP256: p, signMLDSA65: m)
    }

    /// The fields `addSig` covers; nil for the recovery entry or a device entry missing one.
    public var claim: EntryClaim? {
        guard role == .device, let sign, let kind, let addedEpoch, let addedBy else { return nil }
        return EntryClaim(key: key, sign: sign, kind: kind, added: added, addedEpoch: addedEpoch, addedBy: addedBy)
    }

    /// As `listMessage` covers it: absent values empty, numbers decimal.
    package var listEntry: EpochListEntry {
        EpochListEntry(role: role.rawValue, key: key, id: id ?? "", signP256: sign?.p256Hex ?? "",
                       signMLDSA65: sign?.mldsa65Hex ?? "", kind: kind ?? "", added: added,
                       addedEpoch: addedEpoch.map(String.init) ?? "", addedBy: addedBy ?? "",
                       addSigP256: addSig?.p256Hex ?? "", addSigMLDSA65: addSig?.mldsa65Hex ?? "", name: name, wrap: wrap)
    }
}

/// `vault.json` under the key hierarchy (design §3).
public struct EpochManifest: Hashable, Sendable {
    /// The largest `vault.json` read (format.md §9 style; about 15 KB per device).
    public static let maxBytes = 16 << 20

    public var format: String
    public var vaultId: UUID
    public var created: String
    public var root: Data
    public var epoch: Int
    public var epochId: Data
    public var parent: Data?
    public var epochRecord: String
    public var epochRecordHash: Data
    public var keys: [EpochKeyEntry]
    public var listTag: String
    public var epochLink: EpochLink?
    public var epochAuthor: String
    public var epochSig: AuthorSignature
    public var markersTag: String
    public var author: String
    public var authorSig: AuthorSignature
    public var features: [String]
    public var label: String?
    public var reencryptPending: String?
    /// The parent list as the epoch author saw it (sorted fingerprints; empty at epoch 1), signed in
    /// `epochSig` (review H2: so `epochSig` verifies from `vault.json` alone).
    public var parentList: [Data]
    /// The epoch's `reason` (signed in `epochSig`).
    public var epochReason: String
    /// The home device after this epoch (signed in `epochSig`, design §5.6).
    public var home: Data
    /// A takeover's signature by the recovery key (the recovery entry's `sign`) over the `epochSig`
    /// message; nil otherwise.
    public var recoverySig: AuthorSignature?

    /// `listMessage` (design §4).
    public var listMessage: Data {
        EpochListTag.message(vaultId: vaultId, root: Hex.encode(root), epoch: epoch, epochId: Hex.encode(epochId),
                             epochRecordHash: Hex.encode(epochRecordHash), entries: keys.map(\.listEntry))
    }

    /// The message `authorSig` signs.
    public var manifestMessage: Data {
        AuthorMessage.manifest(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId, epochRecordHash: epochRecordHash,
                               listMessage: listMessage, format: format, features: features)
    }

    /// The listed device entries whose id is `id`.
    public func devices(withId id: String) -> [EpochKeyEntry] {
        keys.filter { $0.role == .device && $0.id == id }
    }

    /// Reads untrusted bytes: bounded, the structure of design §3 (exactly one recovery entry, every
    /// key post-quantum, each device's `id` the prefix of its fingerprint, the record name matching
    /// the epoch and id). Signatures and tags are checked by `check`.
    public static func parse(_ data: Data) throws -> EpochManifest {
        guard data.count <= maxBytes else { throw EpochFileError.tooLarge }
        let m: EpochManifest
        do { m = try JSONDecoder().decode(EpochManifest.self, from: data) } catch let e as EpochFileError { throw e } catch {
            throw EpochFileError.malformed("\(error)")
        }
        guard m.epoch >= 1, (m.epoch == 1) == (m.parent == nil), (m.epoch == 1) == (m.epochLink == nil) else {
            throw EpochFileError.malformed("epoch, parent and epochLink disagree")
        }
        guard m.epochRecord == "epochs/" + EpochRecord.fileName(epoch: m.epoch, epochId: m.epochId) else {
            throw EpochFileError.malformed("epochRecord is not this epoch's record")
        }
        guard m.keys.filter({ $0.role == .recovery }).count == 1 else { throw EpochFileError.malformed("not one recovery entry") }
        guard m.keys.contains(where: { $0.role == .device }) else { throw EpochFileError.malformed("no device entry") }
        guard let reason = EpochReason(rawValue: m.epochReason), (m.epoch == 1) == (reason == .create),
              m.recoverySig != nil || reason != .takeover, m.recoverySig == nil || reason == .takeover || reason.mayAddRecovery,
              (m.epoch == 1) == m.parentList.isEmpty else {
            throw EpochFileError.malformed("epochReason, recoverySig or parentList")
        }
        let homeId = String(Hex.encode(m.home).prefix(8))
        guard m.keys.contains(where: { $0.role == .device && $0.fingerprint == m.home }),
              m.epochAuthor == homeId || reason == .handoff, m.author == homeId || m.author == m.epochAuthor else {
            throw EpochFileError.malformed("home is not a listed device, or not the author")
        }
        var seen: Set<String> = []
        for k in m.keys {
            guard k.key.hasPrefix("age1pq1"), seen.insert(k.key).inserted else {
                throw EpochFileError.malformed("a key that is not post-quantum, or listed twice")
            }
            if k.role == .device {
                guard k.claim != nil, k.addSig != nil, k.id == String(Hex.encode(k.fingerprint).prefix(8)) else {
                    throw EpochFileError.malformed("device entry \(k.id ?? "?")")
                }
            } else {
                guard k.sign != nil, k.id == nil, k.kind == nil, k.addedEpoch == nil, k.addedBy == nil, k.addSig == nil else {
                    throw EpochFileError.malformed("recovery entry without its signing keys, or with device fields")
                }
            }
        }
        return m
    }

    /// Why a `vault.json` is tampered (design §4.3); nil when every check passes.
    public enum Problem: Hashable, Sendable {
        /// The reader's own wrap does not open to a key of this epoch (wrong `epochId`, or tampered).
        case wrap
        case listTag
        case markersTag
        /// `authorSig` does not verify under the home device (design §5.6: only home writes the list).
        case authorSig
        /// `epochSig` does not verify under `epochAuthor` over this file's first list and `parentList`
        /// (review H2), or its author is not the parent's home (a takeover: not the new home), or a
        /// takeover's `recoverySig` does not verify under the parent's recovery key.
        case epochSig
        /// The first list is not within `parentList` plus at most the new recovery key of a recovery
        /// replacement or re-encryption, or the new home of a takeover.
        case introducesDevice
        /// An entry outside the verified list is not an addition of this epoch approved by home (review
        /// H1, design §5.6).
        case addSig(key: String)
    }

    /// The recovery entry's fingerprint.
    public var recoveryFingerprint: Data? { keys.first { $0.role == .recovery }?.fingerprint }

    /// The epoch's first list, from this file alone (review H2): the recovery entry, every device
    /// entry added in an earlier epoch, and the home (at epoch 1 the creating device; after a takeover
    /// possibly a device the takeover introduced).
    public var firstList: [Data] {
        keys.filter { k in
            k.role == .recovery || (k.addedEpoch ?? 0) < epoch || k.fingerprint == home
        }.map(\.fingerprint)
    }

    /// The message `epochSig` (and a takeover's `recoverySig`) signs, rebuilt from this file (review H2).
    public var epochMessage: Data? {
        guard let recovery = recoveryFingerprint else { return nil }
        return AuthorMessage.epoch(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId, parent: parent,
                                   reason: epochReason, recovery: recovery, home: home, list: firstList,
                                   parentList: parentList)
    }

    /// The parent epoch as the device verified it (design §4.3): from its pinned epoch (a direct child
    /// whose record has not arrived) or from the record's verified chain.
    public struct VerifiedParent: Hashable, Sendable {
        /// The parent's list (first list plus admitted additions).
        public var list: Set<Data>
        /// The parent's home.
        public var home: Data
        /// The parent's recovery fingerprint.
        public var recovery: Data
        /// The union of the lists of the parent's ancestry, the parent's included (a takeover may list
        /// devices from it).
        public var ancestry: Set<Data>
        /// The parent's recovery signing keys, when known: a kit replacement's optional `recoverySig` by
        /// the old kit is then checked here (otherwise by the chain).
        public var recoverySign: DeviceSigningPublicKeys?

        public init(list: Set<Data>, home: Data, recovery: Data, ancestry: Set<Data>? = nil,
                    recoverySign: DeviceSigningPublicKeys? = nil) {
            self.list = list; self.home = home; self.recovery = recovery; self.ancestry = ancestry ?? list
            self.recoverySign = recoverySign
        }
    }

    /// The checks of design §4.3 that need no chain, for a reader holding `K_e` (from its own wrap):
    /// the key is this epoch's; `listTag` and `markersTag` verify; `epochSig` verifies over the first
    /// list and `parentList` by the parent's home (epoch 1: by its own home; a takeover: by the new home,
    /// and `recoverySig` by the recovery key `TakeoverRule` names), and the first list introduces no
    /// device; every entry is in `verifiedList` or is an addition of this epoch approved by home;
    /// `authorSig` verifies under home (design §5.6: only home writes the list).
    ///
    /// - Parameters:
    ///   - verifiedList: the epoch's list as the device verified it: the first list from the chain (or,
    ///     for a direct child of the pinned epoch, this file's first list once `epochSig` verified and
    ///     the parent list is the pinned one) plus the additions it already admitted.
    ///   - parent: the parent epoch as the device verified it. **Required above epoch 1** (round 7, M3):
    ///     the file's own `home` and `parentList` never stand in for the parent's home or recovery key.
    /// - Returns: the entries admitted now, in admission order (each approved by home).
    public func check(key: VaultEpochKey, verifiedList: Set<Data>, parent: VerifiedParent? = nil) throws -> [EpochKeyEntry] {
        guard key.epochId == epochId else { throw ProblemError(problem: .wrap) }
        guard EpochListTag.verify(listTag, key: key, vaultId: vaultId, root: Hex.encode(root), epoch: epoch,
                                  epochId: Hex.encode(epochId), epochRecordHash: Hex.encode(epochRecordHash),
                                  entries: keys.map(\.listEntry)) else { throw ProblemError(problem: .listTag) }
        let markers = Self.markersMessage(vaultId: vaultId, format: format, features: features)
        guard let given = Hex.decode(markersTag), let markers,
              RecipientsAuth.constantTimeEqual(given, Data(HMAC<SHA256>.authenticationCode(
                  for: markers, using: SymmetricKey(data: key.markersKey)))) else {
            throw ProblemError(problem: .markersTag)
        }
        guard epoch == 1 || parent != nil else { throw ProblemError(problem: .epochSig) }
        let reason = EpochReason(rawValue: epochReason)
        let first = Set(firstList)
        let parentKnown = Set(parentList).intersection(parent?.list ?? [])
        let homeEntry = keys.first { $0.role == .device && $0.fingerprint == home }
        // epochSig (H2, design §5.6): epoch 1 and a takeover by the home itself; any other epoch by the
        // parent's home as the device verified it.
        let signer: EpochKeyEntry?
        if epoch == 1 || reason == .takeover {
            signer = homeEntry.flatMap { $0.id == epochAuthor ? $0 : nil }
        } else {
            signer = devices(withId: epochAuthor).first { e in
                e.fingerprint == parent?.home && parentKnown.contains(e.fingerprint)
                    && (reason == .handoff ? e.fingerprint != home : e.fingerprint == home)
            }
        }
        guard let epochMessage, let signer, let signerKeys = signer.sign,
              epoch > 1 || verifiedList.contains(signer.fingerprint),
              epochSig.verifies(epochMessage, keys: signerKeys) else { throw ProblemError(problem: .epochSig) }
        let recoveryEntry = keys.first { $0.role == .recovery }
        if reason == .takeover {
            // A direct child of the pinned epoch: the parent is the frontier, so the rule names its key.
            guard let recoverySig, let rk = recoveryEntry?.sign, let rf = recoveryFingerprint, let parent,
                  rf == TakeoverRule.recoveryKey(parentRecovery: parent.recovery),
                  recoverySig.verifies(epochMessage, keys: rk) else { throw ProblemError(problem: .epochSig) }
        } else if let recoverySig, let old = parent?.recoverySign {
            guard recoverySig.verifies(epochMessage, keys: old) else { throw ProblemError(problem: .epochSig) }
        }
        if epoch > 1 {
            let new = first.subtracting(parentKnown)
            let allowed: Set<Data>
            switch reason {
            case .some(.takeover):
                // The new home, and devices of the takeover's ancestry the user re-admitted (round 7, M2).
                guard TakeoverRule.listAllowed(first.subtracting([recoveryFingerprint].compactMap { $0 }), home: home,
                                               ancestorLists: parent?.ancestry ?? []) else {
                    throw ProblemError(problem: .introducesDevice)
                }
                allowed = new
            case .some(let r) where r.mayAddRecovery: allowed = Set([recoveryFingerprint].compactMap { $0 })
            default: allowed = []
            }
            guard new.isSubset(of: allowed) else { throw ProblemError(problem: .introducesDevice) }
        }
        // Additions (H1, design §5.6): every entry outside the verified list must be an addition of this
        // epoch approved by home.
        guard let homeEntry, let homeKeys = homeEntry.sign else { throw ProblemError(problem: .authorSig) }
        // A takeover's new home, when the takeover introduces it (a kit join), is approved by the recovery
        // key: `addedBy: "recovery"`, `addSig` by the recovery signing keys.
        if reason == .takeover, homeEntry.addedEpoch == epoch {
            guard let claim = homeEntry.claim, claim.addedBy == EntryClaim.recovery, let sig = homeEntry.addSig,
                  let rk = recoveryEntry?.sign, sig.verifies(AuthorMessage.entry(vaultId: vaultId, claim), keys: rk) else {
                throw ProblemError(problem: .addSig(key: homeEntry.key))
            }
        }
        var result: [EpochKeyEntry] = []
        var admitted = verifiedList
        let pending = keys.filter { $0.role == .device && !verifiedList.contains($0.fingerprint) }
        guard pending.count <= EpochChain.maxAdditions else { throw ProblemError(problem: .addSig(key: pending[0].key)) }
        for k in pending {
            guard let claim = k.claim, claim.addedEpoch == epoch, let sig = k.addSig, k.fingerprint != home,
                  claim.addedBy == homeEntry.id, sig.verifies(AuthorMessage.entry(vaultId: vaultId, claim), keys: homeKeys) else {
                throw ProblemError(problem: .addSig(key: k.key))
            }
            admitted.insert(k.fingerprint); result.append(k)
        }
        // authorSig: by home, or by the epoch's author (the old home writing its handoff).
        let writer = author == homeEntry.id ? homeEntry : (author == signer.id ? signer : nil)
        guard admitted.contains(home), let writer, let writerKeys = writer.sign,
              authorSig.verifies(manifestMessage, keys: writerKeys) else {
            throw ProblemError(problem: .authorSig)
        }
        _ = homeKeys
        return result
    }

    /// The thrown form of `Problem`.
    public struct ProblemError: Error, Hashable, Sendable { public var problem: Problem }

    /// format.md §2.1's markers message (unchanged), nil when a marker holds a NUL.
    static func markersMessage(vaultId: UUID, format: String, features: [String]) -> Data? {
        RecipientsAuth.markersMessage(vaultId: vaultId, format: format, features: features)
    }

    /// `markersTag` under `key` (format.md §2.1 "Version markers", keyed by `markersKey` of `K_e`).
    public static func markersTag(key: VaultEpochKey, vaultId: UUID, format: String, features: [String]) -> String? {
        markersMessage(vaultId: vaultId, format: format, features: features).map {
            Hex.encode(Data(HMAC<SHA256>.authenticationCode(for: $0, using: SymmetricKey(data: key.markersKey))))
        }
    }
}

extension EpochKeyEntry: Codable {
    enum CodingKeys: String, CodingKey { case role, key, id, sign, kind, added, addedEpoch, addedBy, addSig, name, wrap }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let role = Role(rawValue: try c.decode(String.self, forKey: .role)) else { throw EpochFileError.malformed("role") }
        self.role = role
        key = try c.decode(String.self, forKey: .key)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        sign = try c.decodeIfPresent(DeviceSigningPublicKeys.self, forKey: .sign)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        added = try c.decode(String.self, forKey: .added)
        addedEpoch = try c.decodeIfPresent(Int.self, forKey: .addedEpoch)
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy)
        addSig = try c.decodeIfPresent(AuthorSignature.self, forKey: .addSig)
        name = try c.decode(String.self, forKey: .name)
        wrap = try c.decode(String.self, forKey: .wrap)
        guard wrap.utf8.count <= EpochKeyWrap.maxWrapBytes else { throw EpochFileError.tooLarge }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(key, forKey: .key)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(sign, forKey: .sign)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(added, forKey: .added)
        try c.encodeIfPresent(addedEpoch, forKey: .addedEpoch)
        try c.encodeIfPresent(addedBy, forKey: .addedBy)
        try c.encodeIfPresent(addSig, forKey: .addSig)
        try c.encode(name, forKey: .name)
        try c.encode(wrap, forKey: .wrap)
    }
}

extension EpochManifest: Codable {
    enum CodingKeys: String, CodingKey {
        case format, vaultId, created, root, epoch, epochId, parent, epochRecord, epochRecordHash, keys, listTag, epochLink
        case epochAuthor, epochSig, markersTag, author, authorSig, features, label, reencryptPending
        case parentList, epochReason, home, recoverySig
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        created = try c.decode(String.self, forKey: .created)
        root = try ChainEntry.hex32(c, .root)
        epoch = try c.decode(Int.self, forKey: .epoch)
        epochId = try ChainEntry.hex32(c, .epochId)
        parent = try c.contains(.parent) ? ChainEntry.hex32(c, .parent) : nil
        epochRecord = try c.decode(String.self, forKey: .epochRecord)
        epochRecordHash = try ChainEntry.hex32(c, .epochRecordHash)
        keys = try c.decode([EpochKeyEntry].self, forKey: .keys)
        guard keys.count <= EpochChain.maxListSize else { throw EpochFileError.tooLarge }
        listTag = try c.decode(String.self, forKey: .listTag)
        if c.contains(.epochLink) {
            let link = try c.decode(SecretLink.self, forKey: .epochLink)
            guard case .signed = link else { throw EpochFileError.malformed("epochLink") }
            epochLink = link
        } else {
            epochLink = nil
        }
        epochAuthor = try c.decode(String.self, forKey: .epochAuthor)
        epochSig = try c.decode(AuthorSignature.self, forKey: .epochSig)
        markersTag = try c.decode(String.self, forKey: .markersTag)
        author = try c.decode(String.self, forKey: .author)
        authorSig = try c.decode(AuthorSignature.self, forKey: .authorSig)
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        label = try c.decodeIfPresent(String.self, forKey: .label)
        reencryptPending = try c.decodeIfPresent(String.self, forKey: .reencryptPending)
        parentList = try c.contains(.parentList) ? ChainEntry.fingerprints(c, .parentList) : []
        epochReason = try c.decode(String.self, forKey: .epochReason)
        home = try ChainEntry.hex32(c, .home)
        recoverySig = try c.decodeIfPresent(AuthorSignature.self, forKey: .recoverySig)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(created, forKey: .created)
        try c.encode(Hex.encode(root), forKey: .root)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(Hex.encode(epochId), forKey: .epochId)
        if let parent { try c.encode(Hex.encode(parent), forKey: .parent) }
        try c.encode(epochRecord, forKey: .epochRecord)
        try c.encode(Hex.encode(epochRecordHash), forKey: .epochRecordHash)
        try c.encode(keys, forKey: .keys)
        try c.encode(listTag, forKey: .listTag)
        if let epochLink { try c.encode(epochLink, forKey: .epochLink) }
        try c.encode(epochAuthor, forKey: .epochAuthor)
        try c.encode(epochSig, forKey: .epochSig)
        try c.encode(markersTag, forKey: .markersTag)
        try c.encode(author, forKey: .author)
        try c.encode(authorSig, forKey: .authorSig)
        if !features.isEmpty { try c.encode(features, forKey: .features) }
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(reencryptPending, forKey: .reencryptPending)
        if !parentList.isEmpty { try c.encode(parentList.map { Hex.encode($0) }.sorted(), forKey: .parentList) }
        try c.encode(epochReason, forKey: .epochReason)
        try c.encode(Hex.encode(home), forKey: .home)
        try c.encodeIfPresent(recoverySig, forKey: .recoverySig)
    }
}
