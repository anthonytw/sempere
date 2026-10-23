import Age
import Crypto
import Foundation

// The key schedule of the key hierarchy (docs/design/key-hierarchy.md, phase
// KH1a: K_e, the vault identity, the §2.2 derivations, the per-key wraps of
// K_e, fingerprints, listTag, epochLink, the root fingerprint and trust
// records v3). KH1b adds the author signatures, the chain, the single-writer
// precedence rule (home, handoff, takeover), join codes, the epoch record, the
// journal, the passphrase copy and the kit.
//
// Pure functions only: nothing here reads or writes a vault, and no `Vault`
// path uses it yet (KH2 wires it in). Every primitive is swift-crypto's or
// the Age module's: HKDF-SHA256, HMAC-SHA256, SHA-256, X-Wing, Ed25519 and
// ML-DSA-65 (the secret link's `LinkSigningKeys`).
//
// Byte layouts the design leaves open are decided here and stated
// normatively in format.md §15.

/// Errors of the key schedule.
public enum EpochKeyError: Error, Hashable, Sendable {
    /// A vault epoch key that is not exactly 32 bytes.
    case invalidKey
    /// An epoch number below 1 (or below 2 for a link: epoch 1 has no parent).
    case invalidEpoch
    /// A wrap whose plaintext is not the identity file of design §3.
    case wrapMalformed
    /// A wrap whose identity is not the one derived from its epoch key: it
    /// was tampered with (design §4.3).
    case wrapIdentityMismatch
    /// A wrap made for another vault or another epoch.
    case wrapOtherEpoch
    /// A wrap that does not open with the given identities.
    case wrapUnreadable
}

/// A vault epoch key `K_e`: the 32 random bytes of one epoch, the HKDF-SHA256
/// input key material of every key of the epoch (key-hierarchy design §1,
/// §2.2). Never stored in plaintext in a vault: it travels in wraps and epoch
/// records only.
public struct VaultEpochKey: Hashable, Sendable {
    /// Length in bytes.
    public static let byteCount = 32

    /// The raw key.
    public let bytes: Data

    /// Wraps existing bytes.
    ///
    /// - Throws: `EpochKeyError.invalidKey` unless exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw EpochKeyError.invalidKey }
        self.bytes = Data(bytes)
    }

    /// A fresh key from the system CSPRNG.
    public static func random() -> VaultEpochKey {
        SymmetricKey(size: .bits256).withUnsafeBytes { VaultEpochKey(unchecked: Data($0)) }
    }

    private init(unchecked bytes: Data) { self.bytes = bytes }

    /// The HKDF `info` strings of design §2.2 (RFC 5869, empty salt, `L = 32`).
    public enum Info {
        public static let identitySeed = "sempere/1 vault identity seed"
        public static let tagKey = "sempere/1 body tag"
        public static let blobNameKey = "sempere/1 blob name"
        public static let listKey = "sempere/1 list key"
        public static let markersKey = "sempere/1 markers key"
        public static let epochId = "sempere/1 epoch id"
        public static let linkEd25519Seed = "sempere/1 epoch link ed25519 seed"
        public static let linkMLDSA65Seed = "sempere/1 epoch link ml-dsa-65 seed"
        public static let pendingKey = "sempere/1 reencrypt pending key"
        /// Followed by `0x00` and the device's fingerprint (format.md §11.1).
        public static let deviceCaptureKey = "sempere/1 device capture key"
    }

    /// HKDF-SHA256 of this key with an empty salt and `info`, `count` bytes.
    /// The derivations of format.md §10, §10.1 and §12.1 keep their own
    /// `info` and take this key as their input instead of `vaultSecret`.
    public func derive(info: Data, count: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    /// The key as HKDF input key material, for the derivations that keep their own `info` (format.md
    /// §10, §10.1, §11.1, §12.1). Never an HMAC or cipher key itself.
    var key: SymmetricKey { SymmetricKey(data: bytes) }

    /// `derive(info:count:)` with a UTF-8 `info`.
    public func derive(_ info: String, count: Int = 32) -> Data { derive(info: Data(info.utf8), count: count) }

    /// The seed of the vault identity `V_e` (design §2.1): never `K_e` itself,
    /// so `K_e` feeds only HKDF and the seed only X-Wing's expansion.
    public var identitySeed: Data { derive(Info.identitySeed) }

    /// The vault identity `V_e`, an age MLKEM768-X25519 identity
    /// (`AGE-SECRET-KEY-PQ-1…`); its recipient `v_e` is `age1pq1…`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform lacks X-Wing.
    public func vaultIdentity() throws -> MLKEM768X25519Identity {
        try MLKEM768X25519Identity(seed: identitySeed)
    }

    /// The HMAC key of body tags (format.md §4, §13.1, §14.1) and of the epoch record.
    public var tagKey: Data { derive(Info.tagKey) }
    /// The key of blob names (format.md §8.1.2).
    public var blobNameKey: Data { derive(Info.blobNameKey) }
    /// The HMAC key of `listTag` (design §4).
    public var listKey: Data { derive(Info.listKey) }
    /// The HMAC key of `markersTag` (format.md §2.1 "Version markers").
    public var markersKey: Data { derive(Info.markersKey) }
    /// `epochId`: names the epoch (its record's file name) and is what an
    /// `epochLink` signs. Public.
    public var epochId: Data { derive(Info.epochId) }
    /// The key that binds a re-encryption journal (design §7, format.md §3.3.1's mechanism).
    public var pendingKey: Data { derive(Info.pendingKey) }

    /// The device capture key of the device whose fingerprint is `fingerprint`
    /// (format.md §11.1, unchanged except the input).
    public func captureKey(device fingerprint: String) -> CaptureKey {
        var info = Data(Info.deviceCaptureKey.utf8)
        info.append(0)
        info.append(contentsOf: fingerprint.utf8)
        // 32 bytes by construction.
        guard let key = try? CaptureKey(bytes: derive(info: info)) else { preconditionFailure("HKDF length") }
        return key
    }

    /// The epoch's link signing keys (never stored).
    func linkSigningKeys() throws -> LinkSigningKeys {
        try LinkSigningKeys(ed25519Seed: derive(Info.linkEd25519Seed), mldsa65Seed: derive(Info.linkMLDSA65Seed))
    }
}

extension LinkPublicKeys {
    /// The public keys of an epoch's link signing keys (design §2.2, §4):
    /// Ed25519 from `linkEdSeed`, ML-DSA-65 `KeyGen_internal` from `linkMLSeed`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public init(epochKey: VaultEpochKey) throws {
        self = try epochKey.linkSigningKeys().publicKeys()
    }
}

// MARK: - Root fingerprint (design §4.2)

/// The vault's root fingerprint: constant for the vault's life, printed on
/// every kit, and what every chain is checked from.
public enum VaultRoot {
    /// `SHA-256("sempere/1" ‖ 0 ‖ "root" ‖ 0 ‖ vaultId ‖ 0 ‖ ed25519 ‖ mldsa65)`
    /// over epoch 1's link public keys (32 + 1952 raw bytes), `vaultId`
    /// lowercase UTF-8.
    public static func fingerprint(vaultId: UUID, epochOne keys: LinkPublicKeys) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "root".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(keys.ed25519); m.append(keys.mldsa65)
        return Data(SHA256.hash(data: m))
    }

    /// The root of a vault whose epoch 1 key is `key`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public static func fingerprint(vaultId: UUID, epochOne key: VaultEpochKey) throws -> Data {
        fingerprint(vaultId: vaultId, epochOne: try LinkPublicKeys(epochKey: key))
    }
}

// MARK: - epochLink (design §4)

/// `epochLink` of `vault.json`: two signatures by the link signing keys of
/// the parent epoch's key `K_{e-1}` over the link message. The JSON shape,
/// sizes and the both-must-verify rule are the secret link's (format.md §2.1),
/// so it is the same type.
public typealias EpochLink = SecretLink

/// Making and checking epoch links.
public enum EpochLinks {
    /// `"sempere/1" ‖ 0 ‖ "epoch link" ‖ 0 ‖ vaultId ‖ 0 ‖ e ‖ 0 ‖ epochId(K_e)`:
    /// `vaultId` lowercase, `e` in decimal ASCII without leading zeros (as in
    /// `vault.json`), `epochId` its 32 raw bytes.
    ///
    /// The design (§4 table) gives this
    /// NUL-separated message, today's secret-link encoding, while its other
    /// signed messages moved to `lp()` (§4.1). Built to the text as written.
    static func message(vaultId: UUID, epoch: Int, epochId: Data) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "epoch link".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(contentsOf: String(epoch).utf8)
        m.append(0); m.append(epochId)
        return m
    }

    /// The link into epoch `epoch` (at least 2), keyed `child`, signed by the
    /// parent epoch's key.
    ///
    /// - Throws: `EpochKeyError.invalidEpoch` below 2,
    ///   `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public static func link(from parent: VaultEpochKey, to child: VaultEpochKey, epoch: Int,
                            vaultId: UUID) throws -> EpochLink {
        guard epoch >= 2 else { throw EpochKeyError.invalidEpoch }
        return try parent.linkSigningKeys().sign(message(vaultId: vaultId, epoch: epoch, epochId: child.epochId))
    }

    /// True when `link` is signed and BOTH signatures verify under the parent
    /// epoch's link public keys `keys`, over the link into epoch `epoch` whose
    /// `epochId` is `childEpochId` (public: a chain is checked without keys).
    public static func verify(_ link: EpochLink?, keys: LinkPublicKeys, epoch: Int, childEpochId: Data,
                              vaultId: UUID) -> Bool {
        guard epoch >= 2, childEpochId.count == 32 else { return false }
        return LinkSigningKeys.verify(link, keys: keys,
                                      message: message(vaultId: vaultId, epoch: epoch, epochId: childEpochId))
    }
}

// MARK: - Wraps of K_e (design §3; format.md §15.3)

/// A wrap: `K_e` and `V_e` age-encrypted (armored, one stanza) to one listed
/// key. Its plaintext is an age identity file, so stock `age -d -i` reads it:
///
/// ```
/// # sempere vault key: vault <vaultId>, epoch <e>
/// # sempere-epoch-key: <64 hex digits of K_e>
/// AGE-SECRET-KEY-PQ-1…
/// ```
///
/// Frozen with the kit (format.md §15.3): the printed script reads it.
/// Readers here are strict: exactly these three lines, the
/// first naming the vault and epoch the reader expects, and the identity the
/// one derived from the key (design §4.3: anything else is tampering).
package enum EpochKeyWrap {
    /// The largest armored wrap read (one PQ stanza armored is about 2.5 KB).
    package static let maxWrapBytes = 16 * 1024
    /// The largest plaintext read.
    static let maxPlaintextBytes = 1024

    /// The plaintext for `key` in epoch `epoch` of `vaultId`.
    ///
    /// - Throws: `EpochKeyError.invalidEpoch` below 1,
    ///   `AgeError.postQuantumUnavailable` where the platform lacks X-Wing.
    package static func plaintext(_ key: VaultEpochKey, vaultId: UUID, epoch: Int) throws -> String {
        guard epoch >= 1 else { throw EpochKeyError.invalidEpoch }
        return "# sempere vault key: vault \(vaultId.uuidString.lowercased()), epoch \(epoch)\n"
            + "# sempere-epoch-key: \(Hex.encode(key.bytes))\n"
            + "\(try key.vaultIdentity().string)\n"
    }

    /// The key in a wrap's plaintext, after every check.
    ///
    /// - Throws: `EpochKeyError.wrapMalformed`, `.wrapOtherEpoch` or
    ///   `.wrapIdentityMismatch`; `AgeError.postQuantumUnavailable`.
    package static func parse(_ plaintext: Data, vaultId: UUID, epoch: Int) throws -> VaultEpochKey {
        guard plaintext.count <= maxPlaintextBytes, let text = String(data: plaintext, encoding: .utf8),
              text.hasSuffix("\n") else { throw EpochKeyError.wrapMalformed }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let keyPrefix = "# sempere-epoch-key: "
        guard lines.count == 3, lines[0].hasPrefix("# sempere vault key: "), lines[1].hasPrefix(keyPrefix),
              let raw = Hex.decode(String(lines[1].dropFirst(keyPrefix.count))),
              let identity = try? MLKEM768X25519Identity(string: lines[2]) else {
            throw EpochKeyError.wrapMalformed
        }
        guard lines[0] == "# sempere vault key: vault \(vaultId.uuidString.lowercased()), epoch \(epoch)" else {
            throw EpochKeyError.wrapOtherEpoch
        }
        let key = try VaultEpochKey(bytes: raw)
        // Compared in constant time (review L6).
        guard VaultAuth.constantTimeEqual(Data(try key.vaultIdentity().string.utf8), Data(identity.string.utf8)) else {
            throw EpochKeyError.wrapIdentityMismatch
        }
        return key
    }

    /// The wrap of `key` to `recipient`: an armored age file with one stanza.
    ///
    /// - Throws: whatever age encryption throws (`AgeError.postQuantumUnavailable`).
    package static func seal(_ key: VaultEpochKey, vaultId: UUID, epoch: Int, to recipient: NativeRecipient) throws -> String {
        let data = try AgeFile.encrypt(Data(try plaintext(key, vaultId: vaultId, epoch: epoch).utf8),
                                       to: [recipient], armor: true)
        return String(decoding: data, as: UTF8.self)
    }

    /// The key in `wrap`, opened with `identities` and checked by `parse`.
    ///
    /// - Throws: `EpochKeyError.wrapUnreadable` when it is too large or does
    ///   not open, else what `parse` throws.
    package static func open(_ wrap: String, with identities: [any AgeIdentity], vaultId: UUID, epoch: Int) throws
        -> VaultEpochKey
    {
        let data = Data(wrap.utf8)
        guard data.count <= maxWrapBytes, let plaintext = try? AgeFile.decrypt(data, with: identities) else {
            throw EpochKeyError.wrapUnreadable
        }
        return try parse(plaintext, vaultId: vaultId, epoch: epoch)
    }
}

// MARK: - lp() messages, fingerprints and listTag (design §3, §4)

/// The `lp()` encoding of design §3: each field is its 4-byte big-endian
/// length followed by its bytes. The design's messages are a literal prefix
/// followed by `lp()` fields.
package struct LPMessage {
    package private(set) var bytes: Data

    /// Starts with the literal `prefix` (no length).
    package init(_ prefix: String) { bytes = Data(prefix.utf8) }

    /// Appends `lp(field)`.
    package mutating func field(_ field: Data) {
        let n = UInt32(field.count)
        bytes.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        bytes.append(field)
    }

    /// Appends `lp(UTF-8 of field)`.
    package mutating func field(_ field: String) { self.field(Data(field.utf8)) }

    /// Appends `lp(decimal ASCII of n)`.
    package mutating func field(_ n: Int) { self.field(String(n)) }
}

/// Fingerprints of listed keys (design §3). A device's binds its decryption
/// key and its signing keys; its `id` is the first 8 hex digits.
/// (format.md §11.1's fingerprint stays what capture keys use.)
///
/// The encoding (format.md §15.1): the design writes `lp(sign.p256)`
/// without saying whether that is the hex text of `vault.json` or the raw
/// key. Here, as everywhere in this file, a value that `vault.json` holds is
/// taken as the UTF-8 of its JSON text (so signing keys as lowercase hex),
/// and a digest a message computes itself is its 32 raw bytes.
package enum KeyFingerprint {
    /// `SHA-256("sempere/1 device" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`.
    package static func device(key: String, signP256: String, signMLDSA65: String) -> Data {
        var m = LPMessage("sempere/1 device")
        m.field(key); m.field(signP256); m.field(signMLDSA65)
        return Data(SHA256.hash(data: m.bytes))
    }

    /// `SHA-256("sempere/1 recovery" ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65))`: the recovery key and
    /// its signing pair (derived from it, design §5.6), hex as in `vault.json`.
    package static func recovery(key: String, signP256: String, signMLDSA65: String) -> Data {
        var m = LPMessage("sempere/1 recovery")
        m.field(key); m.field(signP256); m.field(signMLDSA65)
        return Data(SHA256.hash(data: m.bytes))
    }

    /// The recovery fingerprint of a recovery identity (its key and derived signing pair).
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    package static func recovery(identity: MLKEM768X25519Identity) throws -> Data {
        let keys = try DeviceSigningKeys.recovery(identity: identity).publicKeys()
        return recovery(key: identity.recipient.string, signP256: keys.p256Hex, signMLDSA65: keys.mldsa65Hex)
    }

    /// A device's `id`: the first 8 hex digits of its fingerprint.
    package static func deviceId(key: String, signP256: String, signMLDSA65: String) -> String {
        String(Hex.encode(device(key: key, signP256: signP256, signMLDSA65: signMLDSA65)).prefix(8))
    }
}

/// One entry of `vault.json`'s `keys` as `listMessage` covers it: every field
/// as the JSON text written in `vault.json`, an absent one (the recovery
/// entry has no `id`, `sign`, `kind`, `addedEpoch`, `addedBy` or `addSig`) as
/// the empty string, `addedEpoch` in decimal ASCII.
///
/// The entry model of design §3; the field encoding is decided here
/// (format.md §15 states it).
package struct EpochListEntry: Hashable, Sendable {
    package var role: String
    package var key: String
    package var id: String
    package var signP256: String
    package var signMLDSA65: String
    package var kind: String
    package var added: String
    package var addedEpoch: String
    package var addedBy: String
    package var addSigP256: String
    package var addSigMLDSA65: String
    package var name: String
    package var wrap: String

    package init(role: String, key: String, id: String = "", signP256: String = "", signMLDSA65: String = "",
                 kind: String = "", added: String, addedEpoch: String = "", addedBy: String = "",
                 addSigP256: String = "", addSigMLDSA65: String = "", name: String, wrap: String) {
        self.role = role; self.key = key; self.id = id; self.signP256 = signP256; self.signMLDSA65 = signMLDSA65
        self.kind = kind; self.added = added; self.addedEpoch = addedEpoch; self.addedBy = addedBy
        self.addSigP256 = addSigP256; self.addSigMLDSA65 = addSigMLDSA65; self.name = name; self.wrap = wrap
    }
}

/// `listTag` (design §4): HMAC-SHA256 under the epoch's `listKey` over
///
/// ```
/// listMessage = "sempere/1 list" ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash)
///   ‖ lp(count) ‖ per entry in list order: lp(role) ‖ lp(key) ‖ lp(id) ‖ lp(sign.p256) ‖ lp(sign.mldsa65)
///   ‖ lp(kind) ‖ lp(added) ‖ lp(addedEpoch) ‖ lp(addedBy) ‖ lp(addSig.p256) ‖ lp(addSig.mldsa65)
///   ‖ lp(name) ‖ lp(SHA-256(wrap))
/// ```
///
/// `vaultId` lowercase; `root`, `epochId` and `epochRecordHash` their 64 hex
/// digits as written; numbers decimal ASCII; `SHA-256(wrap)` the 32 raw bytes
/// of the digest of the wrap string's UTF-8 (format.md §15.1, see
/// `KeyFingerprint`). `authorSig` signs `SHA-256(listMessage)` (not here).
package enum EpochListTag {
    package static func message(vaultId: UUID, root: String, epoch: Int, epochId: String, epochRecordHash: String,
                                entries: [EpochListEntry]) -> Data {
        var m = LPMessage("sempere/1 list")
        m.field(vaultId.uuidString.lowercased()); m.field(root); m.field(epoch); m.field(epochId)
        m.field(epochRecordHash); m.field(entries.count)
        for e in entries {
            for f in [e.role, e.key, e.id, e.signP256, e.signMLDSA65, e.kind, e.added, e.addedEpoch, e.addedBy,
                      e.addSigP256, e.addSigMLDSA65, e.name] { m.field(f) }
            m.field(Data(SHA256.hash(data: Data(e.wrap.utf8))))
        }
        return m.bytes
    }

    static func tagBytes(key: VaultEpochKey, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key.listKey)))
    }

    /// `listTag` (64 lowercase hex digits).
    package static func tag(key: VaultEpochKey, vaultId: UUID, root: String, epoch: Int, epochId: String,
                            epochRecordHash: String, entries: [EpochListEntry]) -> String {
        Hex.encode(tagBytes(key: key, message: message(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId,
                                                       epochRecordHash: epochRecordHash, entries: entries)))
    }

    /// True when `tag` is 64 lowercase hex digits and verifies (constant time).
    package static func verify(_ tag: String, key: VaultEpochKey, vaultId: UUID, root: String, epoch: Int,
                               epochId: String, epochRecordHash: String, entries: [EpochListEntry]) -> Bool {
        guard let given = Hex.decode(tag) else { return false }
        let expected = tagBytes(key: key, message: message(vaultId: vaultId, root: root, epoch: epoch, epochId: epochId,
                                                           epochRecordHash: epochRecordHash, entries: entries))
        return VaultAuth.constantTimeEqual(given, expected)
    }
}

// MARK: - Trust record v3 (design §4)

/// What a device remembers about a vault under the key hierarchy (design §4,
/// replacing `sempere-trust/2`): never stored in the vault, public values
/// only. The vault id, the root, the kept chain this device has verified
/// (each epoch's number, id, parent id, link public keys and first list of
/// fingerprints), the current list, the markers, `reencryptFinished`, and
/// the current home device (design §5.6). Not wired to any store yet (KH2).
public struct EpochTrustRecord: Codable, Hashable, Sendable {
    /// The record format. A file of any other format does not decode.
    public static let formatName = "sempere-trust/3"

    /// One verified epoch of the kept chain (design §4 table: number, id, parent, link keys, first list),
    /// with what the precedence rule needs to weigh it against another chain (KH3, design §5.6): its
    /// recovery key's fingerprint, its home and its reason, all signed in its `epochSig`.
    public struct ChainEpoch: Hashable, Sendable {
        public var epoch: Int
        /// 32 bytes.
        public var epochId: Data
        /// The parent's `epochId` (32 bytes); nil at epoch 1.
        public var parent: Data?
        public var linkPublicKeys: LinkPublicKeys
        /// The epoch's first list: fingerprints (32 bytes each), sorted.
        public var list: [Data]
        /// The epoch's recovery fingerprint (32 bytes).
        public var recovery: Data
        /// The home device after this epoch (32 bytes).
        public var home: Data
        /// The epoch's reason (`create`, `remove`, `recovery`, `reencrypt`, `handoff`, `takeover`).
        public var reason: String

        public init(epoch: Int, epochId: Data, parent: Data?, linkPublicKeys: LinkPublicKeys, list: [Data],
                    recovery: Data, home: Data, reason: String) {
            self.epoch = epoch; self.epochId = epochId; self.parent = parent
            self.linkPublicKeys = linkPublicKeys; self.list = list
            self.recovery = recovery; self.home = home; self.reason = reason
        }

        /// The chain entry of the epoch keyed `key`.
        ///
        /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
        public init(epoch: Int, key: VaultEpochKey, parent: Data?, list: [Data], recovery: Data, home: Data,
                    reason: String) throws {
            self.init(epoch: epoch, epochId: key.epochId, parent: parent,
                      linkPublicKeys: try LinkPublicKeys(epochKey: key), list: list, recovery: recovery, home: home,
                      reason: reason)
        }

        /// The verified chain entry `e`, as a trust record keeps it.
        public init(_ e: ChainEntry) {
            self.init(epoch: e.epoch, epochId: e.epochId, parent: e.parent, linkPublicKeys: e.linkPublicKeys,
                      list: e.list.sorted { $0.lexicographicallyPrecedes($1) }, recovery: e.recovery, home: e.home,
                      reason: e.reason)
        }
    }

    /// One entry of the current list: role, key, signing keys (devices) and name.
    public struct Entry: Hashable, Sendable {
        /// `device` or `recovery`.
        public var role: String
        /// The `age1pq1…` key.
        public var key: String
        /// Nil for the recovery entry.
        public var sign: SigningKeys?
        public var name: String

        public init(role: String, key: String, sign: SigningKeys?, name: String) {
            self.role = role; self.key = key; self.sign = sign; self.name = name
        }
    }

    /// A device's signing public keys (design §4.1).
    public typealias SigningKeys = DeviceSigningPublicKeys

    public var vaultId: UUID
    /// The root fingerprint (32 bytes).
    public var root: Data
    /// The kept chain from epoch 1, in order; the last entry is the pinned epoch.
    public var chain: [ChainEpoch]
    /// The current list, in order.
    public var list: [Entry]
    /// The version markers last verified.
    public var markers: VaultMarkers
    /// True once this device saw the pinned epoch with no re-encryption into it pending (design §7.1).
    public var reencryptFinished: Bool
    /// The home device of the pinned epoch (design §5.6): the only device whose epochs this device
    /// follows, until a handoff or a takeover.
    public var home: Data

    /// The pinned (last verified) epoch.
    public var pinned: ChainEpoch? { chain.last }

    /// - Throws: `EpochKeyError.invalidKey` for a root that is not 32 bytes,
    ///   `.invalidEpoch` for a chain that is not well formed (`wellFormed`).
    public init(vaultId: UUID, root: Data, chain: [ChainEpoch], list: [Entry], markers: VaultMarkers,
                reencryptFinished: Bool = false, home: Data) throws {
        guard root.count == 32, home.count == 32 else { throw EpochKeyError.invalidKey }
        guard Self.wellFormed(chain) else { throw EpochKeyError.invalidEpoch }
        self.vaultId = vaultId; self.root = root; self.chain = chain; self.list = list; self.markers = markers
        self.reencryptFinished = reencryptFinished; self.home = home
    }

    /// Epochs 1, 2, … in order, each `parent` the previous `epochId` (none at
    /// epoch 1), ids and fingerprints 32 bytes. Not a signature check: the
    /// record holds what this device already verified.
    static func wellFormed(_ chain: [ChainEpoch]) -> Bool {
        guard !chain.isEmpty else { return false }
        for (i, c) in chain.enumerated() {
            guard c.epoch == i + 1, c.epochId.count == 32, c.list.allSatisfy({ $0.count == 32 }), c.recovery.count == 32,
                  c.home.count == 32, EpochReason(rawValue: c.reason) != nil else { return false }
            if i == 0 {
                guard c.parent == nil else { return false }
            } else {
                guard c.parent == chain[i - 1].epochId else { return false }
            }
        }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case format, vaultId, root, chain, list, markers, reencryptFinished, home
    }
    enum ChainKeys: String, CodingKey { case epoch, epochId, parent, linkPublicKeys, list, recovery, home, reason }
    enum LinkKeys: String, CodingKey { case ed25519, mldsa65 }
    enum EntryKeys: String, CodingKey { case role, key, sign, name }
    enum SignKeys: String, CodingKey { case p256, mldsa65 }

    static func hex32<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Data {
        guard let d = Hex.decode(try c.decode(String.self, forKey: key)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not 64 lowercase hex digits")
        }
        return d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "not \(Self.formatName)")
        }
        vaultId = try c.decode(LowercaseUUID.self, forKey: .vaultId).uuid
        root = try Self.hex32(c, .root)
        var chain: [ChainEpoch] = []
        var cc = try c.nestedUnkeyedContainer(forKey: .chain)
        while !cc.isAtEnd {
            let e = try cc.nestedContainer(keyedBy: ChainKeys.self)
            let k = try e.nestedContainer(keyedBy: LinkKeys.self, forKey: .linkPublicKeys)
            guard let ed = Hex.decode(try k.decode(String.self, forKey: .ed25519), count: LinkPublicKeys.ed25519Size),
                  let ml = Hex.decode(try k.decode(String.self, forKey: .mldsa65), count: LinkPublicKeys.mldsa65Size),
                  let keys = LinkPublicKeys(ed25519: ed, mldsa65: ml) else {
                throw DecodingError.dataCorruptedError(forKey: .linkPublicKeys, in: e,
                                                       debugDescription: "not 32 + 1952 bytes of lowercase hex")
            }
            let fingerprints = try e.decode([String].self, forKey: .list)
            let list = fingerprints.compactMap { Hex.decode($0) }
            guard list.count == fingerprints.count else {
                throw DecodingError.dataCorruptedError(forKey: .list, in: e, debugDescription: "not fingerprints")
            }
            chain.append(ChainEpoch(epoch: try e.decode(Int.self, forKey: .epoch), epochId: try Self.hex32(e, .epochId),
                                    parent: try e.contains(.parent) ? Self.hex32(e, .parent) : nil,
                                    linkPublicKeys: keys, list: list, recovery: try Self.hex32(e, .recovery),
                                    home: try Self.hex32(e, .home), reason: try e.decode(String.self, forKey: .reason)))
        }
        guard Self.wellFormed(chain) else {
            throw DecodingError.dataCorruptedError(forKey: .chain, in: c, debugDescription: "not a chain from epoch 1")
        }
        self.chain = chain
        var entries: [Entry] = []
        var l = try c.nestedUnkeyedContainer(forKey: .list)
        while !l.isAtEnd {
            let e = try l.nestedContainer(keyedBy: EntryKeys.self)
            var sign: SigningKeys?
            if try e.contains(.sign) && !e.decodeNil(forKey: .sign) {
                let s = try e.nestedContainer(keyedBy: SignKeys.self, forKey: .sign)
                guard let p = Hex.decode(try s.decode(String.self, forKey: .p256), count: SigningKeys.p256Size),
                      let m = Hex.decode(try s.decode(String.self, forKey: .mldsa65), count: SigningKeys.mldsa65Size),
                      let pair = SigningKeys(p256: p, mldsa65: m) else {
                    throw DecodingError.dataCorruptedError(forKey: .sign, in: e,
                                                           debugDescription: "not 65 + 1952 bytes of lowercase hex")
                }
                sign = pair
            }
            entries.append(Entry(role: try e.decode(String.self, forKey: .role), key: try e.decode(String.self, forKey: .key),
                                 sign: sign, name: try e.decode(String.self, forKey: .name)))
        }
        list = entries
        let m = try c.decode(VaultMarkers.self, forKey: .markers)
        markers = VaultMarkers(format: m.format, features: m.features)
        reencryptFinished = try c.decodeIfPresent(Bool.self, forKey: .reencryptFinished) ?? false
        home = try Self.hex32(c, .home)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatName, forKey: .format)
        try c.encode(LowercaseUUID(vaultId), forKey: .vaultId)
        try c.encode(Hex.encode(root), forKey: .root)
        try c.encode(Hex.encode(home), forKey: .home)
        var cc = c.nestedUnkeyedContainer(forKey: .chain)
        for epoch in chain {
            var e = cc.nestedContainer(keyedBy: ChainKeys.self)
            try e.encode(epoch.epoch, forKey: .epoch)
            try e.encode(Hex.encode(epoch.epochId), forKey: .epochId)
            if let p = epoch.parent { try e.encode(Hex.encode(p), forKey: .parent) }
            var k = e.nestedContainer(keyedBy: LinkKeys.self, forKey: .linkPublicKeys)
            try k.encode(Hex.encode(epoch.linkPublicKeys.ed25519), forKey: .ed25519)
            try k.encode(Hex.encode(epoch.linkPublicKeys.mldsa65), forKey: .mldsa65)
            try e.encode(epoch.list.map { Hex.encode($0) }, forKey: .list)
            try e.encode(Hex.encode(epoch.recovery), forKey: .recovery)
            try e.encode(Hex.encode(epoch.home), forKey: .home)
            try e.encode(epoch.reason, forKey: .reason)
        }
        var l = c.nestedUnkeyedContainer(forKey: .list)
        for entry in list {
            var e = l.nestedContainer(keyedBy: EntryKeys.self)
            try e.encode(entry.role, forKey: .role)
            try e.encode(entry.key, forKey: .key)
            if let s = entry.sign {
                var sc = e.nestedContainer(keyedBy: SignKeys.self, forKey: .sign)
                try sc.encode(Hex.encode(s.p256), forKey: .p256)
                try sc.encode(Hex.encode(s.mldsa65), forKey: .mldsa65)
            }
            try e.encode(entry.name, forKey: .name)
        }
        try c.encode(markers, forKey: .markers)
        if reencryptFinished { try c.encode(true, forKey: .reencryptFinished) }
    }
}
