import Crypto
import Foundation

// The public chain of an epoch record and its check (docs/design/key-hierarchy.md
// §4.1, §4.3, §5.2.1; format.md §15.6, §15.7): every epoch since epoch 1, with
// its link keys, its author and `epochSig`, its first list, the parent list
// its author signed, and the same-epoch additions its successor carried.
// Pure functions.

/// Why a chain does not verify (design §4.3). Each names the epoch at fault.
public enum ChainError: Error, Hashable, Sendable {
    /// No entries, or more than `EpochChain.maxEpochs`.
    case empty
    /// Epoch numbers not 1, 2, 3, …, or a `parent` that is not the previous `epochId`.
    case badSequence(epoch: Int)
    /// Epoch 1's link keys do not hash to the trusted root.
    case notRooted
    /// The link into this epoch does not verify under the previous epoch's link keys.
    case brokenLink(epoch: Int)
    /// The author is not in the parent's list (epoch 1: not in its own first list).
    case authorNotListed(epoch: Int)
    /// `epochSig` does not verify under the author's signing keys.
    case badEpochSig(epoch: Int)
    /// The first list holds a device that is not in the parent's list, or more
    /// than one new key, or a new key outside a recovery replacement.
    case introducesDevice(epoch: Int)
    /// More than `EpochChain.maxAdditions` additions.
    case tooManyAdditions(epoch: Int)
    /// The reason is not one of the six.
    case badReason(epoch: Int)
}

/// The author of an epoch, as its chain entry carries it.
public struct ChainAuthor: Hashable, Sendable, Codable {
    public var key: String
    public var p256: String
    public var mldsa65: String

    public init(key: String, sign: DeviceSigningPublicKeys) {
        self.key = key; p256 = sign.p256Hex; mldsa65 = sign.mldsa65Hex
    }

    /// Nil when the hex is malformed.
    public var sign: DeviceSigningPublicKeys? { DeviceSigningPublicKeys(p256Hex: p256, mldsa65Hex: mldsa65) }

    /// The device fingerprint (design §3).
    public var fingerprint: Data { KeyFingerprint.device(key: key, signP256: p256, signMLDSA65: mldsa65) }
}

/// A same-epoch addition carried in a chain entry: the fields `addSig` covers, and `addSig`.
public struct ChainAddition: Hashable, Sendable {
    public var claim: EntryClaim
    public var addSig: AuthorSignature

    public init(claim: EntryClaim, addSig: AuthorSignature) { self.claim = claim; self.addSig = addSig }

    public var fingerprint: Data { claim.fingerprint }
}

extension ChainAddition: Codable {
    enum CodingKeys: String, CodingKey { case key, sign, kind, added, addedEpoch, addedBy, addSig }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = EntryClaim(key: try c.decode(String.self, forKey: .key),
                           sign: try c.decode(DeviceSigningPublicKeys.self, forKey: .sign),
                           kind: try c.decode(String.self, forKey: .kind), added: try c.decode(String.self, forKey: .added),
                           addedEpoch: try c.decode(Int.self, forKey: .addedEpoch),
                           addedBy: try c.decode(String.self, forKey: .addedBy))
        addSig = try c.decode(AuthorSignature.self, forKey: .addSig)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claim.key, forKey: .key)
        try c.encode(claim.sign, forKey: .sign)
        try c.encode(claim.kind, forKey: .kind)
        try c.encode(claim.added, forKey: .added)
        try c.encode(claim.addedEpoch, forKey: .addedEpoch)
        try c.encode(claim.addedBy, forKey: .addedBy)
        try c.encode(addSig, forKey: .addSig)
    }
}

/// The reasons an epoch is made (design §5.2.1).
public enum EpochReason: String, Hashable, Sendable, Codable, CaseIterable {
    case create, remove, recovery, reencrypt, reapply, resolve

    /// May the first list hold one key that is not in the parent list (a new recovery key)?
    var mayAddRecovery: Bool { self == .recovery || self == .reencrypt }
}

/// One epoch of a record's `chain` (design §5.2.1).
public struct ChainEntry: Hashable, Sendable {
    public var epoch: Int
    public var epochId: Data
    /// The parent's `epochId`; nil at epoch 1.
    public var parent: Data?
    public var linkPublicKeys: LinkPublicKeys
    /// The link into this epoch, by the parent's link keys; nil at epoch 1.
    public var link: EpochLink?
    public var reason: String
    /// The first list: fingerprints, as signed (sorted when signed).
    public var list: [Data]
    /// The parent list as the author saw it (empty at epoch 1).
    public var parentList: [Data]
    public var author: ChainAuthor
    public var epochSig: AuthorSignature
    /// The additions made during this epoch that the next epoch's author saw.
    public var additions: [ChainAddition]

    public init(epoch: Int, epochId: Data, parent: Data?, linkPublicKeys: LinkPublicKeys, link: EpochLink?,
                reason: String, list: [Data], parentList: [Data], author: ChainAuthor, epochSig: AuthorSignature,
                additions: [ChainAddition] = []) {
        self.epoch = epoch; self.epochId = epochId; self.parent = parent; self.linkPublicKeys = linkPublicKeys
        self.link = link; self.reason = reason; self.list = list; self.parentList = parentList; self.author = author
        self.epochSig = epochSig; self.additions = additions
    }

    /// The message its `epochSig` signs.
    public func epochMessage(vaultId: UUID, root: Data) -> Data {
        AuthorMessage.epoch(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId, parent: parent,
                            reason: reason, list: list, parentList: parentList)
    }
}

extension ChainEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case epoch, epochId, parent, linkPublicKeys, link, reason, list, parentList, author, epochSig, additions
    }
    enum LinkKeys: String, CodingKey { case ed25519, mldsa65 }

    static func hex32<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Data {
        guard let d = Hex.decode(try c.decode(String.self, forKey: key)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not 64 lowercase hex digits")
        }
        return d
    }

    static func fingerprints<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> [Data] {
        let strings = try c.decode([String].self, forKey: key)
        guard strings.count <= EpochChain.maxListSize else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "too many fingerprints")
        }
        let out = strings.compactMap { Hex.decode($0) }
        guard out.count == strings.count else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not fingerprints")
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try c.decode(Int.self, forKey: .epoch)
        epochId = try Self.hex32(c, .epochId)
        parent = try c.contains(.parent) ? Self.hex32(c, .parent) : nil
        let k = try c.nestedContainer(keyedBy: LinkKeys.self, forKey: .linkPublicKeys)
        guard let ed = Hex.decode(try k.decode(String.self, forKey: .ed25519), count: LinkPublicKeys.ed25519Size),
              let ml = Hex.decode(try k.decode(String.self, forKey: .mldsa65), count: LinkPublicKeys.mldsa65Size),
              let keys = LinkPublicKeys(ed25519: ed, mldsa65: ml) else {
            throw DecodingError.dataCorruptedError(forKey: .linkPublicKeys, in: c,
                                                   debugDescription: "not 32 + 1952 bytes of lowercase hex")
        }
        linkPublicKeys = keys
        link = try c.decodeIfPresent(SecretLink.self, forKey: .link)
        reason = try c.decode(String.self, forKey: .reason)
        list = try Self.fingerprints(c, .list)
        parentList = try Self.fingerprints(c, .parentList)
        author = try c.decode(ChainAuthor.self, forKey: .author)
        epochSig = try c.decode(AuthorSignature.self, forKey: .epochSig)
        additions = try c.decodeIfPresent([ChainAddition].self, forKey: .additions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(Hex.encode(epochId), forKey: .epochId)
        if let parent { try c.encode(Hex.encode(parent), forKey: .parent) }
        var k = c.nestedContainer(keyedBy: LinkKeys.self, forKey: .linkPublicKeys)
        try k.encode(Hex.encode(linkPublicKeys.ed25519), forKey: .ed25519)
        try k.encode(Hex.encode(linkPublicKeys.mldsa65), forKey: .mldsa65)
        if let link { try c.encode(link, forKey: .link) }
        try c.encode(reason, forKey: .reason)
        try c.encode(list.map { Hex.encode($0) }, forKey: .list)
        try c.encode(parentList.map { Hex.encode($0) }, forKey: .parentList)
        try c.encode(author, forKey: .author)
        try c.encode(epochSig, forKey: .epochSig)
        if !additions.isEmpty { try c.encode(additions, forKey: .additions) }
    }
}

/// Signing keys of devices, by fingerprint. Every entry is self-certifying:
/// its fingerprint is computed from its key and signing keys.
public struct DeviceDirectory: Sendable {
    public private(set) var keys: [Data: DeviceSigningPublicKeys] = [:]

    public init() {}

    /// Adds a device; returns its fingerprint.
    @discardableResult
    public mutating func add(key: String, sign: DeviceSigningPublicKeys) -> Data {
        let fp = KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex)
        keys[fp] = sign
        return fp
    }

    /// Every author and addition of `chain`.
    public mutating func add(chain: [ChainEntry]) {
        for e in chain {
            if let s = e.author.sign { add(key: e.author.key, sign: s) }
            for a in e.additions { add(key: a.claim.key, sign: a.claim.sign) }
        }
    }
}

/// The result of admitting one epoch's additions (design §4.1).
public struct AdmittedAdditions: Hashable, Sendable {
    /// The first list plus every admitted addition: the epoch's list as its children see it.
    public var list: Set<Data>
    /// Each admitted addition's fingerprint and its approver (nil for a kit join), in order.
    public var admitted: [(fingerprint: Data, approver: Data?)]
    /// The indices of rejected additions.
    public var rejected: [Int]

    public static func == (a: AdmittedAdditions, b: AdmittedAdditions) -> Bool {
        a.list == b.list && a.rejected == b.rejected && a.admitted.map(\.fingerprint) == b.admitted.map(\.fingerprint)
            && a.admitted.map(\.approver) == b.admitted.map(\.approver)
    }

    public func hash(into h: inout Hasher) { h.combine(list); h.combine(rejected) }
}

/// Chain checks (design §4.1, §4.3).
public enum EpochChain {
    /// At most this many additions per epoch (design §4.1 "bound").
    public static let maxAdditions = 256
    /// At most this many epochs in one chain, and fingerprints in one list (format.md §9 style bounds).
    public static let maxEpochs = 100_000
    public static let maxListSize = 4096

    /// Admits `additions` of epoch `epoch` in one pass, in order (design §4.1): each must name
    /// this epoch, and its `addSig` must verify under its own keys with `addedBy: "recovery"` (a
    /// kit join), or under the keys of an already admitted device whose id is `addedBy` (never its
    /// own keys then). A self-signed entry that names an approver, or one whose approver is not
    /// admitted yet, is rejected.
    ///
    /// - Throws: `ChainError.tooManyAdditions` above the bound.
    public static func admit(_ additions: [ChainAddition], epoch: Int, firstList: [Data], vaultId: UUID,
                             directory: DeviceDirectory) throws -> AdmittedAdditions {
        guard additions.count <= maxAdditions else { throw ChainError.tooManyAdditions(epoch: epoch) }
        var list = Set(firstList)
        var admitted: [(fingerprint: Data, approver: Data?)] = []
        var rejected: [Int] = []
        for (i, a) in additions.enumerated() {
            let fp = a.fingerprint
            let message = AuthorMessage.entry(vaultId: vaultId, a.claim)
            guard a.claim.addedEpoch == epoch else { rejected.append(i); continue }
            if a.addSig.verifies(message, keys: a.claim.sign) {
                // Self-signed: a kit join, whatever the field says; it must say so.
                if a.claim.claimsKitJoin {
                    list.insert(fp); admitted.append((fp, nil))
                } else {
                    rejected.append(i)
                }
                continue
            }
            guard !a.claim.claimsKitJoin else { rejected.append(i); continue }
            let approver = list.sorted { $0.lexicographicallyPrecedes($1) }.first { candidate in
                guard Hex.encode(candidate).hasPrefix(a.claim.addedBy), a.claim.addedBy.utf8.count == 8,
                      let keys = directory.keys[candidate] else { return false }
                return a.addSig.verifies(message, keys: keys)
            }
            if let approver {
                list.insert(fp); admitted.append((fp, approver))
            } else {
                rejected.append(i)
            }
        }
        return AdmittedAdditions(list: list, admitted: admitted, rejected: rejected)
    }

    /// A checked chain.
    public struct Verified: Sendable {
        public var entries: [ChainEntry]
        /// Per entry: its first list plus its admitted additions.
        public var lists: [AdmittedAdditions]
        /// Per entry: the keys it removed (none at epoch 1), computed (design §4.1).
        public var removals: [Set<Data>]
        /// Approver of every admitted addition (nil: a kit join).
        public var approvers: [Data: Data?]
        /// Epoch 1's first list.
        public var founders: Set<Data>

        /// The `addedBy` chain of `fingerprint` (design §4.1): its approver, that approver's, and
        /// so on, until a founder or a kit join. Empty for a founder or a kit join.
        public func approverChain(of fingerprint: Data) -> [Data] {
            var out: [Data] = []
            var cur = fingerprint
            var seen: Set<Data> = [cur]
            while !founders.contains(cur), let next = approvers[cur] ?? nil, !seen.contains(next) {
                out.append(next); seen.insert(next); cur = next
            }
            return out
        }
    }

    /// Checks `chain` from epoch 1 (design §4.3): rooted at `root`, each link under the previous
    /// link keys, each author in its parent's list (first list plus admitted additions) and its
    /// `epochSig` valid, each first list within the parent's list plus at most one new key in a
    /// recovery replacement or re-encryption (never a known device).
    ///
    /// - Parameter directory: devices known from elsewhere (a `vault.json`'s `keys[]`), added to
    ///   the chain's own authors and additions.
    public static func verify(_ chain: [ChainEntry], vaultId: UUID, root: Data,
                              directory extra: DeviceDirectory = DeviceDirectory()) throws -> Verified {
        guard !chain.isEmpty, chain.count <= maxEpochs else { throw ChainError.empty }
        var directory = extra
        directory.add(chain: chain)
        var lists: [AdmittedAdditions] = []
        var removals: [Set<Data>] = []
        var approvers: [Data: Data?] = [:]
        for (i, e) in chain.enumerated() {
            guard e.epoch == i + 1 else { throw ChainError.badSequence(epoch: e.epoch) }
            guard let reason = EpochReason(rawValue: e.reason) else { throw ChainError.badReason(epoch: e.epoch) }
            guard let authorKeys = e.author.sign else { throw ChainError.badEpochSig(epoch: e.epoch) }
            let authorFP = e.author.fingerprint
            let first = Set(e.list)
            if i == 0 {
                guard e.parent == nil, e.link == nil, e.parentList.isEmpty, reason == .create else {
                    throw ChainError.badSequence(epoch: 1)
                }
                guard VaultRoot.fingerprint(vaultId: vaultId, epochOne: e.linkPublicKeys) == root else {
                    throw ChainError.notRooted
                }
                guard first.contains(authorFP) else { throw ChainError.authorNotListed(epoch: 1) }
                removals.append([])
            } else {
                let prev = chain[i - 1]
                guard e.parent == prev.epochId, reason != .create else { throw ChainError.badSequence(epoch: e.epoch) }
                guard EpochLinks.verify(e.link, keys: prev.linkPublicKeys, epoch: e.epoch, childEpochId: e.epochId,
                                        vaultId: vaultId) else { throw ChainError.brokenLink(epoch: e.epoch) }
                let parentList = lists[i - 1].list
                guard parentList.contains(authorFP) else { throw ChainError.authorNotListed(epoch: e.epoch) }
                let new = first.subtracting(parentList)
                if !new.isEmpty {
                    guard reason.mayAddRecovery, new.count == 1, let n = new.first, directory.keys[n] == nil else {
                        throw ChainError.introducesDevice(epoch: e.epoch)
                    }
                }
                removals.append(Set(e.parentList).intersection(parentList).subtracting(first))
            }
            guard e.epochSig.verifies(e.epochMessage(vaultId: vaultId, root: root), keys: authorKeys) else {
                throw ChainError.badEpochSig(epoch: e.epoch)
            }
            let admitted = try admit(e.additions, epoch: e.epoch, firstList: e.list, vaultId: vaultId,
                                     directory: directory)
            for a in admitted.admitted where approvers[a.fingerprint] == nil { approvers[a.fingerprint] = a.approver }
            lists.append(admitted)
        }
        return Verified(entries: chain, lists: lists, removals: removals, approvers: approvers,
                        founders: Set(chain[0].list))
    }
}
