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
        /// `authorSig` does not verify under the listed device whose id is `author`.
        case authorSig
        /// An entry's `addSig` fails, or names someone other than its signer, or is self-signed and
        /// does not say `recovery` (design §3, §6.3).
        case addSig(key: String)
    }

    /// The checks of design §4.3 that need no chain, for a reader holding `K_e` (from its own wrap):
    /// the key is this epoch's, `listTag` and `markersTag` verify, `authorSig` verifies under a
    /// listed device, and every device entry's `addSig` verifies under its approver or itself.
    ///
    /// - Parameter approvers: devices that may have approved entries first listed in an earlier
    ///   `vault.json` of `addedEpoch` (the chain's lists and additions); entries of this file count too.
    /// - Parameter founders: epoch 1's first list (the chain's): the creating device signs its own entry
    ///   and names itself in `addedBy` (design §3 says nothing of it; format.md §15.4 decides).
    /// - Returns: the kit joins (entries whose `addSig` is their own), in list order.
    public func check(key: VaultEpochKey, approvers: DeviceDirectory = DeviceDirectory(), founders: Set<Data> = []) throws
        -> [EpochKeyEntry] {
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
        let message = manifestMessage
        guard devices(withId: author).contains(where: { $0.sign.map { authorSig.verifies(message, keys: $0) } ?? false }) else {
            throw ProblemError(problem: .authorSig)
        }
        var directory = approvers
        for k in keys where k.role == .device { if let s = k.sign { directory.add(key: k.key, sign: s) } }
        var kitJoins: [EpochKeyEntry] = []
        for k in keys where k.role == .device {
            guard let claim = k.claim, let sig = k.addSig else { throw ProblemError(problem: .addSig(key: k.key)) }
            let m = AuthorMessage.entry(vaultId: vaultId, claim)
            if sig.verifies(m, keys: claim.sign) {
                // Self-signed: a kit join, which must say so; or the device that created the vault
                // (epoch 1's first list), which has no approver and names itself.
                if claim.claimsKitJoin {
                    kitJoins.append(k)
                } else if founders.contains(k.fingerprint), claim.addedEpoch == 1, claim.addedBy == k.id {
                    continue
                } else {
                    throw ProblemError(problem: .addSig(key: k.key))
                }
                continue
            }
            let approved = !claim.claimsKitJoin && directory.keys.contains { fp, keys in
                Hex.encode(fp).hasPrefix(claim.addedBy) && claim.addedBy.utf8.count == 8 && fp != k.fingerprint
                    && sig.verifies(m, keys: keys)
            }
            guard approved else { throw ProblemError(problem: .addSig(key: k.key)) }
        }
        return kitJoins
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
    }
}
