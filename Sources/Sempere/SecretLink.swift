import Age
import Crypto
import Foundation

// The signed secret link (format.md §2.1 "Secret link"; security review
// 2026-10, R2).
//
// Two signing key pairs are derived from each vault secret: Ed25519
// (RFC 8032) and ML-DSA-65 (FIPS 204), each from its own 32-byte HKDF seed.
// A rotation's `secretLink` holds both signatures, made with the outgoing
// secret's keys, over the link message; it verifies only when both do. A
// device's trust record keeps the two public keys, which check a link but
// cannot make one.

/// The verification keys of a vault secret's link signing keys (format.md
/// §2.1): what a trust record holds.
public struct LinkPublicKeys: Hashable, Sendable {
    /// Ed25519 public key size (RFC 8032).
    public static let ed25519Size = 32
    /// ML-DSA-65 public key size (FIPS 204, `pk`).
    public static let mldsa65Size = 1952

    /// The Ed25519 public key (32 bytes).
    public let ed25519: Data
    /// The ML-DSA-65 public key (1952 bytes).
    public let mldsa65: Data

    /// Nil unless both keys have their exact sizes.
    public init?(ed25519: Data, mldsa65: Data) {
        guard ed25519.count == Self.ed25519Size, mldsa65.count == Self.mldsa65Size else { return nil }
        self.ed25519 = ed25519; self.mldsa65 = mldsa65
    }

    /// The public keys of `secret`'s link signing keys.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no
    ///   ML-DSA (Apple OSes before 26, SDKs before Xcode 26).
    public init(secret: VaultSecret) throws {
        let keys = try LinkSigningKeys(secret: secret)
        self.ed25519 = keys.ed25519.publicKey.rawRepresentation
        self.mldsa65 = try MLDSA65Bridge.publicKey(seed: keys.mldsa65Seed)
    }
}

/// `secretLink` as found in `vault.json` (format.md §2.1).
public enum SecretLink: Hashable, Sendable {
    /// Ed25519 signature size (RFC 8032).
    public static let ed25519SignatureSize = 64
    /// ML-DSA-65 signature size (FIPS 204).
    public static let mldsa65SignatureSize = 3309

    /// The current form: both signatures, by the outgoing secret's keys.
    case signed(ed25519: Data, mldsa65: Data)
    /// The form written before signed links: an HMAC under the outgoing
    /// secret's `linkKey`, 64 lowercase hex digits as written (not checked
    /// here). It never confirms a rotation to a trust record; only a rewrap
    /// journal's secret, which the reader holds, may be checked with it.
    case legacy(String)
    /// Present but neither form (or a signature of the wrong size): never
    /// verifies, and writers drop it.
    case malformed

    /// True for `.legacy`.
    public var isLegacy: Bool { if case .legacy = self { return true }; return false }
}

extension SecretLink: Codable {
    enum CodingKeys: String, CodingKey { case ed25519, mldsa65 }

    /// Never throws: a value of any other shape reads as `.malformed`, so a
    /// hostile file cannot make the manifest unreadable (format.md §9).
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self = .legacy(s); return }
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let ed = (try? c.decode(String.self, forKey: .ed25519)).flatMap({ Hex.decode($0, count: Self.ed25519SignatureSize) }),
              let ml = (try? c.decode(String.self, forKey: .mldsa65)).flatMap({ Hex.decode($0, count: Self.mldsa65SignatureSize) })
        else { self = .malformed; return }
        self = .signed(ed25519: ed, mldsa65: ml)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .signed(let ed, let ml):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(Hex.encode(ed), forKey: .ed25519)
            try c.encode(Hex.encode(ml), forKey: .mldsa65)
        case .legacy(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .malformed:
            // Writers drop a malformed link (VaultManifest.encode); encoding
            // one alone writes null.
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }
}

/// The signing keys of a vault secret (never stored).
struct LinkSigningKeys {
    let ed25519: Curve25519.Signing.PrivateKey
    let mldsa65Seed: Data

    init(secret: VaultSecret) throws {
        let edSeed = RecipientsAuth.bytes(RecipientsAuth.derive(secret, RecipientsAuth.linkEd25519Info))
        ed25519 = try Curve25519.Signing.PrivateKey(rawRepresentation: edSeed)
        mldsa65Seed = RecipientsAuth.bytes(RecipientsAuth.derive(secret, RecipientsAuth.linkMLDSA65Info))
    }
}

/// ML-DSA-65 through swift-crypto: CryptoKit on Apple OSes 26 and later,
/// BoringSSL elsewhere. Keys come from a 32-byte seed by FIPS 204
/// `ML-DSA.KeyGen_internal` (Algorithm 16); signing is the hedged
/// `ML-DSA.Sign` with an empty context, verifying `ML-DSA.Verify`.
enum MLDSA65Bridge {
    static func publicKey(seed: Data) throws -> Data {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil).publicKey.rawRepresentation
        }
        #endif
        throw AgeError.postQuantumUnavailable
    }

    static func sign(_ message: Data, seed: Data) throws -> Data {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return try MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil).signature(for: message)
        }
        #endif
        throw AgeError.postQuantumUnavailable
    }

    /// False for a malformed key or signature, and where ML-DSA is unavailable.
    static func verify(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            guard let key = try? MLDSA65.PublicKey(rawRepresentation: publicKey) else { return false }
            return key.isValidSignature(signature, for: message)
        }
        #endif
        return false
    }
}

extension RecipientsAuth {
    static let linkEd25519Info = "sempere/1 secret link ed25519 seed"
    static let linkMLDSA65Info = "sempere/1 secret link ml-dsa-65 seed"

    /// The link message: `"sempere/1" ‖ 0 ‖ "secret link" ‖ 0 ‖ vaultId ‖ 0 ‖ secretId(new)`.
    static func linkMessage(to new: VaultSecret, vaultId: UUID) -> Data {
        var m = Data("sempere/1".utf8)
        m.append(0); m.append(contentsOf: "secret link".utf8)
        m.append(0); m.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        m.append(0); m.append(secretId(new))
        return m
    }

    /// `secretLink` from the outgoing secret to the new one: both signatures
    /// by `old`'s link signing keys.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform has no ML-DSA.
    public static func link(from old: VaultSecret, to new: VaultSecret, vaultId: UUID) throws -> SecretLink {
        let keys = try LinkSigningKeys(secret: old)
        let message = linkMessage(to: new, vaultId: vaultId)
        return .signed(ed25519: try keys.ed25519.signature(for: message),
                       mldsa65: try MLDSA65Bridge.sign(message, seed: keys.mldsa65Seed))
    }

    /// True when `link` is a signed link whose Ed25519 AND ML-DSA-65
    /// signatures both verify under `keys` (a trust record's) over the link
    /// to `new`. A legacy (HMAC) link never does.
    public static func verifyLink(_ link: SecretLink?, keys: LinkPublicKeys, to new: VaultSecret, vaultId: UUID) -> Bool {
        guard case .signed(let ed, let ml)? = link,
              let edKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keys.ed25519) else { return false }
        let message = linkMessage(to: new, vaultId: vaultId)
        // Both are checked whatever the first says: no early exit on which one failed.
        let edValid = edKey.isValidSignature(ed, for: message)
        let mlValid = MLDSA65Bridge.verify(ml, for: message, publicKey: keys.mldsa65)
        return edValid && mlValid
    }

    /// True when `link` links `previous` to `current`, for a reader that
    /// holds both secrets (a rewrap journal's previous secret, format.md
    /// §3.3.1): a signed link under `previous`'s public keys, or a legacy
    /// HMAC link under its `linkKey`. Accepting the legacy form here gives
    /// nothing to a holder of a trust record: forging it needs
    /// `secretId(current)`, which only holders of the current secret know.
    static func linkConnects(_ link: SecretLink?, from previous: VaultSecret, to current: VaultSecret, vaultId: UUID) -> Bool {
        switch link {
        case .signed?:
            guard let keys = try? LinkPublicKeys(secret: previous) else { return false }
            return verifyLink(link, keys: keys, to: current, vaultId: vaultId)
        case .legacy(let hex)?:
            return verifyLegacyLink(hex, linkKey: legacyLinkKey(previous), to: current, vaultId: vaultId)
        case .malformed?, nil:
            return false
        }
    }

    // MARK: Legacy (HMAC) links and records

    static let legacyLinkInfo = "sempere/1 secret link key"

    /// The legacy `linkKey` of a secret: what a `sempere-trust/1` record kept.
    static func legacyLinkKey(_ secret: VaultSecret) -> Data { bytes(derive(secret, legacyLinkInfo)) }

    /// A legacy link, for tests and the upgrade's own checks.
    static func legacyLink(from old: VaultSecret, to new: VaultSecret, vaultId: UUID) -> SecretLink {
        .legacy(Hex.encode(legacyLinkBytes(linkKey: legacyLinkKey(old), to: new, vaultId: vaultId)))
    }

    static func legacyLinkBytes(linkKey: Data, to new: VaultSecret, vaultId: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: linkMessage(to: new, vaultId: vaultId), using: SymmetricKey(data: linkKey)))
    }

    static func verifyLegacyLink(_ link: String, linkKey: Data, to new: VaultSecret, vaultId: UUID) -> Bool {
        guard let given = Hex.decode(link), linkKey.count == 32 else { return false }
        return constantTimeEqual(given, legacyLinkBytes(linkKey: linkKey, to: new, vaultId: vaultId))
    }
}

/// What `Vault.upgradeSecretLink` changed (format.md §2.1 "Upgrading to
/// signed links").
public struct SecretLinkUpgrade: Hashable, Sendable, Codable {
    /// What happened to `vault.json`'s `secretLink`.
    public enum LinkChange: String, Hashable, Sendable, Codable {
        /// Nothing: absent or already signed.
        case none
        /// A legacy link replaced by a signed one from the same outgoing
        /// secret (known from an unfinished rewrap).
        case reSigned
        /// A legacy (or malformed) link removed: it cannot be re-signed
        /// without the outgoing secret, and no trust record accepts it.
        case retired
    }

    public var link: LinkChange
    /// True when `signed-secret-link` was added to `features`.
    public var featureAdded: Bool
    /// True when this device's `sempere-trust/1` record was replaced by a
    /// `sempere-trust/2` one.
    public var recordUpgraded: Bool

    /// True when anything changed.
    public var changed: Bool { link != .none || featureAdded || recordUpgraded }
}

/// How a vault and this device stand with respect to signed secret links
/// (format.md §2.1), for `sempere vault link` and the app.
public struct SecretLinkStatus: Hashable, Sendable, Codable {
    /// The form of a `secretLink` or a trust record.
    public enum Form: String, Hashable, Sendable, Codable {
        case none, signed, legacy, malformed
        /// A trust record that exists but cannot be read (security review R5).
        case unreadable
    }

    /// `vault.json`'s `secretLink`.
    public var link: Form
    /// True when `features` lists `signed-secret-link`.
    public var featureListed: Bool
    /// This device's trust record: `none`, `signed` (`sempere-trust/2`),
    /// `legacy` (`sempere-trust/1`) or `unreadable`.
    public var record: Form

    /// True when `Vault.upgradeSecretLink` would change something in the
    /// vault (a missing feature, a legacy or malformed link).
    public var vaultNeedsUpgrade: Bool { !featureListed || link == .legacy || link == .malformed }
    /// True when the vault or this device's record is not current.
    public var needsUpgrade: Bool { vaultNeedsUpgrade || record == .legacy }
}

extension Vault {
    /// The vault's and this device's secret link forms (format.md §2.1).
    public var secretLinkStatus: SecretLinkStatus {
        let link: SecretLinkStatus.Form
        switch manifest.secretLink {
        case nil: link = .none
        case .signed?: link = .signed
        case .legacy?: link = .legacy
        case .malformed?: link = .malformed
        }
        let record: SecretLinkStatus.Form
        do {
            switch try trustStore?.record(for: vaultId)?.anchor {
            case nil: record = .none
            case .signed?: record = .signed
            case .legacy?: record = .legacy
            }
        } catch {
            record = .unreadable   // recipientsStatus reports it (recordUnreadable)
        }
        return SecretLinkStatus(link: link, featureListed: manifest.features.contains(VaultManifest.signedLinkFeature),
                                record: record)
    }

    /// The `secretLink` a writer keeps when the secret does not rotate: a
    /// signed link unchanged; a legacy one re-signed when it links this
    /// vault's unfinished rewrap's outgoing secret to the current one (it can
    /// only be signed with that secret), else dropped; a malformed one dropped.
    func upgradedLink(_ link: SecretLink?) throws -> (link: SecretLink?, change: SecretLinkUpgrade.LinkChange) {
        switch link {
        case nil: return (nil, .none)
        case .signed?: return (link, .none)
        case .malformed?: return (nil, .retired)
        case .legacy?:
            if let current = secret, let previous = previousSecret,
               !RecipientsAuth.constantTimeEqual(previous.bytes, current.bytes),
               RecipientsAuth.linkConnects(link, from: previous, to: current, vaultId: vaultId) {
                return (try RecipientsAuth.link(from: previous, to: current, vaultId: vaultId), .reSigned)
            }
            return (nil, .retired)
        }
    }

    /// Adds `recipients-tag` and `signed-secret-link` to `features`.
    static func addAuthFeatures(_ m: inout VaultManifest) {
        for f in [VaultManifest.recipientsTagFeature, VaultManifest.signedLinkFeature] where !m.features.contains(f) {
            m.features.append(f)
        }
    }
}
