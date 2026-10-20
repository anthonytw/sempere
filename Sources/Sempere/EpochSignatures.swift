import Age
import Crypto
import Foundation

// Device signing pairs and the three author signatures of the key hierarchy
// (docs/design/key-hierarchy.md §4.1, format.md §15.5): `addSig` over an
// entry, `epochSig` over an epoch, `authorSig` over a `vault.json`. Each is a
// P-256 ECDSA signature (SHA-256, `r ‖ s`, 64 bytes) and an ML-DSA-65
// signature (pure, empty context) over the same `lp()` message; both must
// verify. Pure functions: on Apple devices the private halves live in the
// Secure Enclave (KH5), so this file only verifies, plus a software pair for
// the CLI and tests.

/// A device's signing public keys (`sign` in `vault.json`): uncompressed
/// P-256 (65 bytes, X9.63) and ML-DSA-65 (1952 bytes).
public struct DeviceSigningPublicKeys: Hashable, Sendable {
    public static let p256Size = 65
    public static let mldsa65Size = 1952

    public let p256: Data
    public let mldsa65: Data

    /// Nil unless both have their exact sizes.
    public init?(p256: Data, mldsa65: Data) {
        guard p256.count == Self.p256Size, mldsa65.count == Self.mldsa65Size else { return nil }
        self.p256 = p256; self.mldsa65 = mldsa65
    }

    /// From the lowercase hex of `vault.json`; nil for anything else.
    public init?(p256Hex: String, mldsa65Hex: String) {
        guard let p = Hex.decode(p256Hex, count: Self.p256Size),
              let m = Hex.decode(mldsa65Hex, count: Self.mldsa65Size) else { return nil }
        self.init(p256: p, mldsa65: m)
    }

    public var p256Hex: String { Hex.encode(p256) }
    public var mldsa65Hex: String { Hex.encode(mldsa65) }
}

/// One author signature (`addSig`, `epochSig`, `authorSig`): P-256 `r ‖ s`
/// (64 bytes) and ML-DSA-65 (3309 bytes).
public struct AuthorSignature: Hashable, Sendable {
    public static let p256Size = 64
    public static let mldsa65Size = 3309

    public let p256: Data
    public let mldsa65: Data

    /// Nil unless both have their exact sizes.
    public init?(p256: Data, mldsa65: Data) {
        guard p256.count == Self.p256Size, mldsa65.count == Self.mldsa65Size else { return nil }
        self.p256 = p256; self.mldsa65 = mldsa65
    }

    /// From lowercase hex; nil for anything else.
    public init?(p256Hex: String, mldsa65Hex: String) {
        guard let p = Hex.decode(p256Hex, count: Self.p256Size),
              let m = Hex.decode(mldsa65Hex, count: Self.mldsa65Size) else { return nil }
        self.init(p256: p, mldsa65: m)
    }

    public var p256Hex: String { Hex.encode(p256) }
    public var mldsa65Hex: String { Hex.encode(mldsa65) }

    /// True when BOTH signatures verify under `keys` over `message`. Both are
    /// checked whatever the first says. ECDSA signatures with a high `s` are
    /// accepted (the design does not require low-S, and swift-crypto does
    /// not produce canonical ones).
    public func verifies(_ message: Data, keys: DeviceSigningPublicKeys) -> Bool {
        var p256Valid = false
        if let key = try? P256.Signing.PublicKey(x963Representation: keys.p256),
           let sig = try? P256.Signing.ECDSASignature(rawRepresentation: p256) {
            p256Valid = key.isValidSignature(sig, for: message)
        }
        let mlValid = MLDSA65Bridge.verify(mldsa65, for: message, publicKey: keys.mldsa65)
        return p256Valid && mlValid
    }
}

extension AuthorSignature: Codable {
    enum CodingKeys: String, CodingKey { case p256, mldsa65 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let s = AuthorSignature(p256Hex: try c.decode(String.self, forKey: .p256),
                                      mldsa65Hex: try c.decode(String.self, forKey: .mldsa65)) else {
            throw DecodingError.dataCorruptedError(forKey: .p256, in: c,
                                                   debugDescription: "not 64 + 3309 bytes of lowercase hex")
        }
        self = s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p256Hex, forKey: .p256)
        try c.encode(mldsa65Hex, forKey: .mldsa65)
    }
}

extension DeviceSigningPublicKeys: Codable {
    enum CodingKeys: String, CodingKey { case p256, mldsa65 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let k = DeviceSigningPublicKeys(p256Hex: try c.decode(String.self, forKey: .p256),
                                              mldsa65Hex: try c.decode(String.self, forKey: .mldsa65)) else {
            throw DecodingError.dataCorruptedError(forKey: .p256, in: c,
                                                   debugDescription: "not 65 + 1952 bytes of lowercase hex")
        }
        self = k
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p256Hex, forKey: .p256)
        try c.encode(mldsa65Hex, forKey: .mldsa65)
    }
}

/// A software signing pair (the CLI's, and tests'): a P-256 private scalar
/// and an ML-DSA-65 seed (FIPS 204 `KeyGen_internal`). Apple devices keep
/// theirs in the Secure Enclave instead (KH5).
public struct DeviceSigningKeys: Sendable {
    let p256: P256.Signing.PrivateKey
    let mldsa65Seed: Data

    /// From a 32-byte P-256 scalar and a 32-byte ML-DSA-65 seed.
    ///
    /// - Throws: `EpochKeyError.invalidKey` for bad sizes or an invalid scalar.
    public init(p256Scalar: Data, mldsa65Seed: Data) throws {
        guard p256Scalar.count == 32, mldsa65Seed.count == 32,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: p256Scalar) else {
            throw EpochKeyError.invalidKey
        }
        p256 = key; self.mldsa65Seed = Data(mldsa65Seed)
    }

    /// A fresh pair.
    public static func generate() -> DeviceSigningKeys {
        let p = P256.Signing.PrivateKey()
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return DeviceSigningKeys(p256: p, mldsa65Seed: seed)
    }

    private init(p256: P256.Signing.PrivateKey, mldsa65Seed: Data) { self.p256 = p256; self.mldsa65Seed = mldsa65Seed }

    /// The P-256 scalar (32 bytes), for storing a CLI device's keys.
    public var p256Scalar: Data { p256.rawRepresentation }

    /// The public keys.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public func publicKeys() throws -> DeviceSigningPublicKeys {
        guard let k = DeviceSigningPublicKeys(p256: p256.publicKey.x963Representation,
                                              mldsa65: try MLDSA65Bridge.publicKey(seed: mldsa65Seed)) else {
            throw EpochKeyError.invalidKey
        }
        return k
    }

    /// Both signatures over `message`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public func sign(_ message: Data) throws -> AuthorSignature {
        let p = try p256.signature(for: message).rawRepresentation
        let m = try MLDSA65Bridge.sign(message, seed: mldsa65Seed)
        guard let s = AuthorSignature(p256: p, mldsa65: m) else { throw EpochKeyError.invalidKey }
        return s
    }
}

// MARK: - The signed messages (design §4.1)

/// The fields `addSig` covers: an entry as approved (design §4.1). Every
/// value is the JSON text of `vault.json` (signing keys lowercase hex,
/// `addedEpoch` decimal).
public struct EntryClaim: Hashable, Sendable, Codable {
    public var key: String
    public var sign: DeviceSigningPublicKeys
    public var kind: String
    public var added: String
    public var addedEpoch: Int
    /// The approver's id, or `recovery` for a kit join (self-signed).
    public var addedBy: String

    public init(key: String, sign: DeviceSigningPublicKeys, kind: String, added: String, addedEpoch: Int,
                addedBy: String) {
        self.key = key; self.sign = sign; self.kind = kind; self.added = added; self.addedEpoch = addedEpoch
        self.addedBy = addedBy
    }

    /// The entry's device fingerprint (design §3).
    public var fingerprint: Data {
        KeyFingerprint.device(key: key, signP256: sign.p256Hex, signMLDSA65: sign.mldsa65Hex)
    }

    /// True for `addedBy: "recovery"`.
    public var claimsKitJoin: Bool { addedBy == EntryClaim.recovery }

    public static let recovery = "recovery"
}

/// The three messages of design §4.1: `"sempere/1 author "` ‖ kind ‖ `lp()`
/// fields. Values held in JSON are their JSON text (hex stays hex, numbers
/// decimal ASCII); a digest the message computes itself is its 32 raw bytes;
/// a list is `lp(count)` followed by `lp()` of each element, sorted by bytes.
public enum AuthorMessage {
    /// `addSig`: `entry` ‖ lp(vaultId) ‖ lp(addedEpoch) ‖ lp(key) ‖ lp(sign.p256) ‖ lp(sign.mldsa65)
    /// ‖ lp(kind) ‖ lp(added) ‖ lp(addedBy).
    public static func entry(vaultId: UUID, _ e: EntryClaim) -> Data {
        var m = LPMessage("sempere/1 author entry")
        m.field(vaultId.uuidString.lowercased()); m.field(e.addedEpoch); m.field(e.key)
        m.field(e.sign.p256Hex); m.field(e.sign.mldsa65Hex); m.field(e.kind); m.field(e.added); m.field(e.addedBy)
        return m.bytes
    }

    /// `epochSig`: `epoch` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(parent) ‖ lp(reason)
    /// ‖ lp(n) ‖ n fingerprints ‖ lp(m) ‖ m fingerprints. `root`, `epochId`, `parent` and each
    /// fingerprint as 64 lowercase hex digits; `parent` empty at epoch 1; both lists sorted.
    public static func epoch(vaultId: UUID, root: Data, epoch: Int, epochId: Data, parent: Data?, reason: String,
                             list: [Data], parentList: [Data]) -> Data {
        var m = LPMessage("sempere/1 author epoch")
        m.field(vaultId.uuidString.lowercased()); m.field(Hex.encode(root)); m.field(epoch)
        m.field(Hex.encode(epochId)); m.field(parent.map { Hex.encode($0) } ?? ""); m.field(reason)
        for l in [list, parentList] {
            let sorted = l.map { Hex.encode($0) }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            m.field(sorted.count)
            for f in sorted { m.field(f) }
        }
        return m.bytes
    }

    /// `authorSig`: `manifest` ‖ lp(vaultId) ‖ lp(root) ‖ lp(epoch) ‖ lp(epochId) ‖ lp(epochRecordHash)
    /// ‖ lp(SHA-256(listMessage)) ‖ lp(format) ‖ lp(k) ‖ the k distinct features, sorted. The list
    /// digest is raw (32 bytes); `root`, `epochId` and `epochRecordHash` hex.
    public static func manifest(vaultId: UUID, root: Data, epoch: Int, epochId: Data, epochRecordHash: Data,
                                listMessage: Data, format: String, features: [String]) -> Data {
        var m = LPMessage("sempere/1 author manifest")
        m.field(vaultId.uuidString.lowercased()); m.field(Hex.encode(root)); m.field(epoch)
        m.field(Hex.encode(epochId)); m.field(Hex.encode(epochRecordHash))
        m.field(Data(SHA256.hash(data: listMessage))); m.field(format)
        let distinct = Array(Set(features)).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        m.field(distinct.count)
        for f in distinct { m.field(f) }
        return m.bytes
    }
}
