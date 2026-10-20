import Crypto
import Foundation

// The public chain of an epoch record and its check (docs/design/key-hierarchy.md
// §4.1, §4.3, §5.2.1, §5.6; format.md §15.6, §15.7): every epoch since epoch 1,
// with its link keys, its author and `epochSig`, its first list, the parent list
// its author signed, its home, and the same-epoch additions its successor
// carried. A single writer: only the home device signs epochs and approves
// additions; a takeover is signed by the recovery key and the new home. Pure
// functions.

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
    /// Epoch 1's author is not in its own first list.
    case authorNotListed(epoch: Int)
    /// The author is not the parent's home (a home-signed epoch), or not the new home (a takeover).
    case notHome(epoch: Int)
    /// `home` is not listed, changes outside a handoff or takeover, or a handoff names the same home
    /// or no device (epoch 1: home is not its author).
    case badHome(epoch: Int)
    /// A takeover without a valid `recoverySig` by the parent's recovery key, or a `recoverySig`
    /// outside a takeover.
    case badTakeover(epoch: Int)
    /// `epochSig` does not verify under the author's signing keys.
    case badEpochSig(epoch: Int)
    /// The first list holds a device that is not in the parent's list (a takeover: other than its new
    /// home), or more than one new key, or a new key outside a recovery replacement.
    case introducesDevice(epoch: Int)
    /// More than `EpochChain.maxAdditions` additions.
    case tooManyAdditions(epoch: Int)
    /// The reason is not one of the six.
    case badReason(epoch: Int)
    /// The recovery fingerprint is not in the first list, or a `recovery`/`reencrypt` epoch does
    /// not replace it, or another epoch changes it (review M1).
    case badRecovery(epoch: Int)
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

    /// The recovery fingerprint, for a takeover's `recoveryAuthor` (design §3).
    public var recoveryFingerprint: Data { KeyFingerprint.recovery(key: key, signP256: p256, signMLDSA65: mldsa65) }
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

/// The reasons an epoch is made (design §5.2.1, §5.6).
public enum EpochReason: String, Hashable, Sendable, Codable, CaseIterable {
    case create, remove, recovery, reencrypt, handoff, takeover

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
    /// The recovery key's fingerprint in this epoch's list (review M1).
    public var recovery: Data
    /// The home device after this epoch (design §5.6): the author's own, except in a handoff (the device
    /// it names) and a takeover (the new home, its author).
    public var home: Data
    /// A takeover's recovery key: its key and derived signing keys (their recovery fingerprint must be
    /// the parent's `recovery`). Nil otherwise.
    public var recoveryAuthor: ChainAuthor?
    /// A takeover's signature by the recovery key, over the same message as `epochSig`. Nil otherwise.
    public var recoverySig: AuthorSignature?

    public init(epoch: Int, epochId: Data, parent: Data?, linkPublicKeys: LinkPublicKeys, link: EpochLink?,
                reason: String, list: [Data], parentList: [Data], author: ChainAuthor, epochSig: AuthorSignature,
                additions: [ChainAddition] = [], recovery: Data, home: Data, recoveryAuthor: ChainAuthor? = nil,
                recoverySig: AuthorSignature? = nil) {
        self.epoch = epoch; self.epochId = epochId; self.parent = parent; self.linkPublicKeys = linkPublicKeys
        self.link = link; self.reason = reason; self.list = list; self.parentList = parentList; self.author = author
        self.epochSig = epochSig; self.additions = additions; self.recovery = recovery; self.home = home
        self.recoveryAuthor = recoveryAuthor; self.recoverySig = recoverySig
    }

    /// The message its `epochSig` (and a takeover's `recoverySig`) signs.
    public func epochMessage(vaultId: UUID, root: Data) -> Data {
        AuthorMessage.epoch(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId, parent: parent,
                            reason: reason, recovery: recovery, home: home, list: list, parentList: parentList)
    }
}

extension ChainEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case epoch, epochId, parent, linkPublicKeys, link, reason, list, parentList, author, epochSig, additions
        case recovery, home, recoveryAuthor, recoverySig
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
        recovery = try Self.hex32(c, .recovery)
        home = try Self.hex32(c, .home)
        recoveryAuthor = try c.decodeIfPresent(ChainAuthor.self, forKey: .recoveryAuthor)
        recoverySig = try c.decodeIfPresent(AuthorSignature.self, forKey: .recoverySig)
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
        try c.encode(Hex.encode(recovery), forKey: .recovery)
        try c.encode(Hex.encode(home), forKey: .home)
        try c.encodeIfPresent(recoveryAuthor, forKey: .recoveryAuthor)
        try c.encodeIfPresent(recoverySig, forKey: .recoverySig)
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
    /// Each admitted addition's fingerprint and its approver (the epoch's home), in order.
    public var admitted: [(fingerprint: Data, approver: Data)]
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

    /// Admits `additions` of epoch `epoch` in one pass, in order (design §4.1, §5.6): each must name
    /// this epoch and be approved by the epoch's home (`addedBy` its id, `addSig` under its keys). No
    /// other device approves, and no entry approves itself: a kit join is a takeover.
    ///
    /// - Throws: `ChainError.tooManyAdditions` above the bound.
    public static func admit(_ additions: [ChainAddition], epoch: Int, firstList: [Data], home: Data, vaultId: UUID,
                             directory: DeviceDirectory) throws -> AdmittedAdditions {
        guard additions.count <= maxAdditions else { throw ChainError.tooManyAdditions(epoch: epoch) }
        var list = Set(firstList)
        var admitted: [(fingerprint: Data, approver: Data)] = []
        var rejected: [Int] = []
        let homeKeys = directory.keys[home]
        for (i, a) in additions.enumerated() {
            let fp = a.fingerprint
            guard a.claim.addedEpoch == epoch, a.claim.addedBy == String(Hex.encode(home).prefix(8)), fp != home,
                  let homeKeys, a.addSig.verifies(AuthorMessage.entry(vaultId: vaultId, a.claim), keys: homeKeys) else {
                rejected.append(i); continue
            }
            list.insert(fp); admitted.append((fp, home))
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
        /// Per entry: the home device after it (design §5.6).
        public var homes: [Data] { entries.map(\.home) }
        /// Every recovery fingerprint the chain names (never re-applied, never a device).
        public var recoveryKeys: Set<Data> { Set(entries.map(\.recovery)) }
    }

    /// Checks `chain` from epoch 1 (design §4.3, §5.6): rooted at `root`, each link under the previous
    /// link keys; epoch 1 by its home, listed; every later epoch signed by its parent's home, except a
    /// takeover, signed by its new home and (`recoverySig`) by the parent's recovery key; `home`
    /// unchanged except in a handoff (a listed device) or a takeover; each first list within the
    /// parent's list plus at most one new key in a recovery replacement or re-encryption, or the new
    /// home of a takeover; additions approved by the epoch's home.
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
        for (i, e) in chain.enumerated() {
            guard e.epoch == i + 1 else { throw ChainError.badSequence(epoch: e.epoch) }
            guard let reason = EpochReason(rawValue: e.reason) else { throw ChainError.badReason(epoch: e.epoch) }
            guard let authorKeys = e.author.sign else { throw ChainError.badEpochSig(epoch: e.epoch) }
            let authorFP = e.author.fingerprint
            let first = Set(e.list)
            let message = e.epochMessage(vaultId: vaultId, root: root)
            if reason != .takeover {
                guard e.recoveryAuthor == nil, e.recoverySig == nil else { throw ChainError.badTakeover(epoch: e.epoch) }
            }
            if i == 0 {
                guard e.parent == nil, e.link == nil, e.parentList.isEmpty, reason == .create else {
                    throw ChainError.badSequence(epoch: 1)
                }
                guard VaultRoot.fingerprint(vaultId: vaultId, epochOne: e.linkPublicKeys) == root else {
                    throw ChainError.notRooted
                }
                guard first.contains(authorFP) else { throw ChainError.authorNotListed(epoch: 1) }
                guard e.home == authorFP else { throw ChainError.badHome(epoch: 1) }
                removals.append([])
            } else {
                let prev = chain[i - 1]
                guard e.parent == prev.epochId, reason != .create else { throw ChainError.badSequence(epoch: e.epoch) }
                guard EpochLinks.verify(e.link, keys: prev.linkPublicKeys, epoch: e.epoch, childEpochId: e.epochId,
                                        vaultId: vaultId) else { throw ChainError.brokenLink(epoch: e.epoch) }
                let parentList = lists[i - 1].list
                let new = first.subtracting(parentList)
                switch reason {
                case .takeover:
                    // Signed by the recovery key of the parent and by the new home, which may be a device
                    // the parent never listed (a kit join); the list is the user's pick (design §5.6).
                    guard authorFP == e.home else { throw ChainError.notHome(epoch: e.epoch) }
                    guard let ra = e.recoveryAuthor, let rk = ra.sign, let rs = e.recoverySig,
                          ra.recoveryFingerprint == prev.recovery, rs.verifies(message, keys: rk) else {
                        throw ChainError.badTakeover(epoch: e.epoch)
                    }
                    guard new.isSubset(of: [e.home]) else { throw ChainError.introducesDevice(epoch: e.epoch) }
                    guard e.recovery == prev.recovery else { throw ChainError.badRecovery(epoch: e.epoch) }
                default:
                    guard authorFP == prev.home else { throw ChainError.notHome(epoch: e.epoch) }
                    if reason == .handoff {
                        guard e.home != prev.home, e.home != e.recovery else { throw ChainError.badHome(epoch: e.epoch) }
                    } else {
                        guard e.home == prev.home else { throw ChainError.badHome(epoch: e.epoch) }
                    }
                    if reason.mayAddRecovery {
                        // A recovery replacement or re-encryption replaces the recovery key: the new one is
                        // the only new fingerprint, and the old one is gone (review M1).
                        guard new.isSubset(of: [e.recovery]) else { throw ChainError.introducesDevice(epoch: e.epoch) }
                        guard new == [e.recovery], e.recovery != prev.recovery, !first.contains(prev.recovery) else {
                            throw ChainError.badRecovery(epoch: e.epoch)
                        }
                    } else {
                        guard new.isEmpty else { throw ChainError.introducesDevice(epoch: e.epoch) }
                        guard e.recovery == prev.recovery else { throw ChainError.badRecovery(epoch: e.epoch) }
                    }
                }
                removals.append(Set(e.parentList).intersection(parentList).subtracting(first))
            }
            guard first.contains(e.home) else { throw ChainError.badHome(epoch: e.epoch) }
            guard first.contains(e.recovery), directory.keys[e.recovery] == nil else {
                throw ChainError.badRecovery(epoch: e.epoch)
            }
            guard e.epochSig.verifies(message, keys: authorKeys) else { throw ChainError.badEpochSig(epoch: e.epoch) }
            lists.append(try admit(e.additions, epoch: e.epoch, firstList: e.list, home: e.home, vaultId: vaultId,
                                   directory: directory))
        }
        return Verified(entries: chain, lists: lists, removals: removals)
    }
}
