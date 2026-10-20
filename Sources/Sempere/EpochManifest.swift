import Age
import Crypto
import Foundation

// `vault.json` of the key hierarchy (docs/design/key-hierarchy.md §3, §4.1,
// §4.3; format.md §15.3): the model, a strict reader of untrusted bytes, and
// the checks that need no chain: the reader's own wrap, `listTag`,
// `authorSig`, every entry's `addSig` (approver or kit join) and the markers.
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

    /// The fingerprint (design §3): a device's binds its signing keys; the recovery key's its key alone.
    public var fingerprint: Data {
        if let sign { return KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex) }
        return KeyFingerprint.recovery(key: key)
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
    /// A `resolve` epoch's rejected author (signed in `epochSig`).
    public var rejected: Data?

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
              m.rejected == nil || reason == .resolve, (m.epoch == 1) == m.parentList.isEmpty else {
            throw EpochFileError.malformed("epochReason, rejected or parentList")
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
                guard k.id == nil, k.sign == nil, k.kind == nil, k.addedEpoch == nil, k.addedBy == nil, k.addSig == nil else {
                    throw EpochFileError.malformed("recovery entry with device fields")
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
        /// `authorSig` does not verify under a device of the verified list (or admitted now) whose id
        /// is `author`.
        case authorSig
        /// `epochSig` does not verify under `epochAuthor`, a device of the signed parent list (epoch 1:
        /// of the first list), over this file's first list and `parentList` (review H2).
        case epochSig
        /// The first list is not within `parentList` plus at most the new recovery key of a recovery
        /// replacement or re-encryption.
        case introducesDevice
        /// An entry outside the verified list is not an addition of this epoch that `addSig` admits
        /// against the verified list (review H1).
        case addSig(key: String)
    }

    /// The recovery entry's fingerprint.
    public var recoveryFingerprint: Data? { keys.first { $0.role == .recovery }?.fingerprint }

    /// The epoch's first list, from this file alone (review H2): the recovery entry and every device
    /// entry added in an earlier epoch; at epoch 1, the recovery entry and the creating device
    /// (`epochAuthor`, added at epoch 1).
    public var firstList: [Data] {
        keys.filter { k in
            k.role == .recovery || (k.addedEpoch ?? 0) < epoch || (epoch == 1 && k.id == epochAuthor && k.addedEpoch == 1)
        }.map(\.fingerprint)
    }

    /// The message `epochSig` signs, rebuilt from this file (review H2).
    public var epochMessage: Data? {
        guard let recovery = recoveryFingerprint else { return nil }
        return AuthorMessage.epoch(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId, parent: parent,
                                   reason: epochReason, recovery: recovery, rejected: rejected, list: firstList,
                                   parentList: parentList)
    }

    /// The checks of design §4.3 that need no chain, for a reader holding `K_e` (from its own wrap):
    /// the key is this epoch's; `listTag` and `markersTag` verify; `epochSig` verifies over the first
    /// list and `parentList`, by a device of the parent list, and the first list introduces no device;
    /// every entry is in `verifiedList` or is an addition of this epoch admitted against it; `authorSig`
    /// verifies under an admitted device.
    ///
    /// - Parameters:
    ///   - verifiedList: the epoch's list as the device verified it: the first list from the chain (or,
    ///     for a direct child of the pinned epoch, this file's first list once `epochSig` verified and
    ///     the parent list is the pinned one) plus the additions it already admitted. Entries outside
    ///     it are admitted only against it, never against each other's say-so in this file.
    ///   - verifiedParentList: the parent epoch's list as the device verified it, when known (a direct
    ///     child of the pinned epoch): the epoch author and the first list must then be within it
    ///     (and the signed `parentList`), except a new recovery key.
    /// - Returns: the entries admitted now, in admission order, with their approver (nil: a kit join).
    public func check(key: VaultEpochKey, verifiedList: Set<Data>, verifiedParentList: Set<Data>? = nil) throws
        -> [(entry: EpochKeyEntry, approver: Data?)] {
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
        // epochSig (H2): by a device of the signed parent list (epoch 1: of the first list).
        let first = Set(firstList)
        // With the parent's list as this device verified it (a direct child of the pinned epoch), the
        // author must be in it; otherwise the signed parentList stands in until the record's chain is
        // checked (design §4.3 step 2).
        let parentKnown = verifiedParentList ?? Set(parentList)
        let signers = epoch == 1 ? first.intersection(verifiedList) : Set(parentList).intersection(parentKnown)
        guard let epochMessage, devices(withId: epochAuthor).contains(where: { e in
            signers.contains(e.fingerprint) && (e.sign.map { epochSig.verifies(epochMessage, keys: $0) } ?? false)
        }) else { throw ProblemError(problem: .epochSig) }
        if epoch > 1 {
            let new = first.subtracting(Set(parentList).intersection(parentKnown))
            let reason = EpochReason(rawValue: epochReason)
            guard new.isEmpty || (reason?.mayAddRecovery == true && new == Set([recoveryFingerprint].compactMap { $0 })) else {
                throw ProblemError(problem: .introducesDevice)
            }
        }
        // Additions (H1): every entry outside the verified list must be an addition of this epoch,
        // approved by a device already admitted (the verified list, then additions admitted before it),
        // or a kit join. Approval chains inside this epoch are followed in any order; each signature
        // is checked once per candidate approver.
        var admitted = verifiedList
        var result: [(entry: EpochKeyEntry, approver: Data?)] = []
        var pending: [EpochKeyEntry] = []
        for k in keys where k.role == .device && !verifiedList.contains(k.fingerprint) {
            guard let claim = k.claim, claim.addedEpoch == epoch, k.addSig != nil else {
                throw ProblemError(problem: .addSig(key: k.key))
            }
            pending.append(k)
        }
        guard pending.count <= EpochChain.maxAdditions else { throw ProblemError(problem: .addSig(key: pending[0].key)) }
        var signing: [Data: DeviceSigningPublicKeys] = [:]
        for k in keys where k.role == .device { if let s = k.sign { signing[k.fingerprint] = s } }
        var tried: Set<[Data]> = []
        var progress = true
        while progress && !pending.isEmpty {
            progress = false
            var i = 0
            while i < pending.count {
                let k = pending[i]
                guard let claim = k.claim, let sig = k.addSig else { i += 1; continue }
                let m = AuthorMessage.entry(vaultId: vaultId, claim)
                var approver: Data??
                if claim.claimsKitJoin {
                    if !tried.contains([k.fingerprint, k.fingerprint]) {
                        tried.insert([k.fingerprint, k.fingerprint])
                        if sig.verifies(m, keys: claim.sign) { approver = .some(nil) }
                    }
                } else {
                    let candidates = admitted.filter {
                        $0 != k.fingerprint && claim.addedBy.utf8.count == 8 && Hex.encode($0).hasPrefix(claim.addedBy)
                    }.sorted { $0.lexicographicallyPrecedes($1) }
                    for c in candidates where !tried.contains([k.fingerprint, c]) {
                        tried.insert([k.fingerprint, c])
                        if let keys = signing[c], sig.verifies(m, keys: keys) { approver = .some(c); break }
                    }
                }
                if let approver {
                    admitted.insert(k.fingerprint); result.append((k, approver)); pending.remove(at: i); progress = true
                } else {
                    i += 1
                }
            }
        }
        if let left = pending.first { throw ProblemError(problem: .addSig(key: left.key)) }
        let message = manifestMessage
        guard devices(withId: author).contains(where: { e in
            admitted.contains(e.fingerprint) && (e.sign.map { authorSig.verifies(message, keys: $0) } ?? false)
        }) else { throw ProblemError(problem: .authorSig) }
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
        case parentList, epochReason, rejected
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
        rejected = try c.contains(.rejected) ? ChainEntry.hex32(c, .rejected) : nil
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
        if let rejected { try c.encode(Hex.encode(rejected), forKey: .rejected) }
    }
}
