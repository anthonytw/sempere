import Crypto
import Foundation

// The MLKEM768-X25519 ("X-Wing") hybrid post-quantum recipient type of
// age v1.3 (c2sp.org/age, "The MLKEM768-X25519 (i.e. X-Wing) hybrid
// post-quantum recipient type"): HPKE SealBase with KEM MLKEM768-X25519
// (0x647a, draft-ietf-hpke-pq-03 / filippo.io/hpke-pq, which is X-Wing,
// draft-connolly-cfrg-xwing-kem), KDF HKDF-SHA256, AEAD ChaCha20-Poly1305.
//
// The lattice and KEM code is swift-crypto's: CryptoKit on Apple platforms
// (macOS / iOS / Mac Catalyst 26 and later), BoringSSL elsewhere. Nothing
// here implements ML-KEM; this file only frames age stanzas around it.

private let pqLabel = "age-encryption.org/mlkem768x25519"
/// The stanza type, which is also the first stanza argument.
let pqStanzaType = "mlkem768x25519"
/// Bech32 HRPs (c2sp.org/age).
let pqRecipientHRP = "age1pq"
let pqIdentityHRP = "AGE-SECRET-KEY-PQ-"
/// X-Wing sizes: a 32-byte seed, a 1216-byte public key (ML-KEM-768 1184 +
/// X25519 32) and a 1120-byte encapsulation (1088 + 32).
let pqSeedSize = 32
let pqPublicKeySize = 1216
let pqEncSize = 1120

/// True when this build and OS can use the hybrid recipient type.
///
/// On Apple platforms it needs the CryptoKit of macOS / iOS / Mac Catalyst
/// 26 (X-Wing and HPKE with it), and an SDK new enough to declare it (Swift
/// 6.2, Xcode 26). On Linux and other platforms swift-crypto's BoringSSL
/// backend always provides it.
public var postQuantumAvailable: Bool {
    #if !canImport(Darwin) || compiler(>=6.2)
    if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) { return true }
    #endif
    return false
}

/// An age MLKEM768-X25519 hybrid post-quantum recipient, `age1pq1...`.
///
/// Encrypting to it is secure against an adversary with a future
/// cryptographically-relevant quantum computer as long as **every** stanza
/// in the file is post-quantum: an `X25519` stanza next to it still lets
/// such an adversary recover the file key.
public struct MLKEM768X25519Recipient: AgeRecipient, Hashable {
    /// The 1216-byte X-Wing public key.
    let publicKey: Data

    init(publicKey: Data) {
        self.publicKey = publicKey
    }

    /// Parses a Bech32 `age1pq1...` recipient (lowercase only, as `age` does).
    /// Parsing needs no ML-KEM support; `wrap` does.
    public init(string: String) throws {
        guard let (hrp, data) = Bech32.decode(string), hrp == pqRecipientHRP, data.count == pqPublicKeySize else {
            throw AgeError.invalidKey
        }
        publicKey = Data(data)
    }

    /// The Bech32 encoding, `age1pq1...` (1959 characters).
    public var string: String {
        Bech32.encode(hrp: pqRecipientHRP, data: [UInt8](publicKey)) ?? ""
    }

    /// Wraps `fileKey` in one `mlkem768x25519` stanza (HPKE SealBase with a
    /// fresh encapsulation).
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform lacks
    ///   X-Wing; `AgeError.invalidKey` if the public key is rejected.
    public func wrap(fileKey: FileKey) throws -> [Stanza] {
        let (enc, body) = try XWingHPKE.seal(fileKey.bytes, to: publicKey)
        return [Stanza(type: pqStanzaType, args: [Base64.encodeRaw(enc)], body: body)]
    }
}

/// An age MLKEM768-X25519 identity, `AGE-SECRET-KEY-PQ-1...`: a 32-byte seed
/// from which both the ML-KEM-768 and the X25519 keys are derived.
public struct MLKEM768X25519Identity: AgeIdentity, Hashable {
    /// The 32-byte X-Wing seed.
    let seed: Data
    /// Derived from the seed when the identity is made, so `recipient` and
    /// equality do not need the KEM again.
    let publicKey: Data

    init(seed: Data) throws {
        guard seed.count == pqSeedSize else { throw AgeError.invalidKey }
        self.seed = Data(seed)
        publicKey = try XWingHPKE.publicKey(seed: seed)
    }

    /// Generates a new random identity.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` where the platform lacks X-Wing.
    public init() throws {
        try self.init(seed: Data(secureRandomBytes(pqSeedSize)))
    }

    /// Parses a Bech32 `AGE-SECRET-KEY-PQ-1...` identity (uppercase only, as
    /// `age-keygen -pq` writes it).
    ///
    /// - Throws: `AgeError.invalidKey` for a malformed string,
    ///   `AgeError.postQuantumUnavailable` where the platform lacks X-Wing
    ///   (deriving the public key needs it).
    public init(string: String) throws {
        guard let (hrp, data) = Bech32.decode(string), hrp == pqIdentityHRP, data.count == pqSeedSize else {
            throw AgeError.invalidKey
        }
        try self.init(seed: Data(data))
    }

    /// The Bech32 encoding, uppercase `AGE-SECRET-KEY-PQ-1...` (77 characters).
    public var string: String {
        Bech32.encode(hrp: pqIdentityHRP, data: [UInt8](seed)) ?? ""
    }

    /// The matching public recipient.
    public var recipient: MLKEM768X25519Recipient {
        MLKEM768X25519Recipient(publicKey: publicKey)
    }

    /// Tries every `mlkem768x25519` stanza and returns the first file key
    /// that decrypts; other stanza types are ignored.
    ///
    /// - Returns: nil if no `mlkem768x25519` stanza is addressed to this identity.
    /// - Throws: `AgeError.invalidStanza` for a malformed `mlkem768x25519`
    ///   stanza (argument count, non-canonical or wrong-length enc, body not
    ///   32 bytes) or one whose X25519 share yields the all-zero secret.
    public func unwrap(stanzas: [Stanza]) throws -> FileKey? {
        for stanza in stanzas where stanza.type == pqStanzaType {
            if let key = try unwrap(stanza) { return key }
        }
        return nil
    }

    private func unwrap(_ stanza: Stanza) throws -> FileKey? {
        // Checked before any decryption, in this order, as the spec requires.
        guard stanza.args.count == 1, let enc = Base64.decodeRaw(stanza.args[0].utf8), enc.count == pqEncSize,
            stanza.body.count == 32
        else {
            throw AgeError.invalidStanza
        }
        let encData = Data(enc)
        // A low-order X25519 share makes the X25519 secret all zeros, which
        // age rejects (CCTV hybrid_low_order, hybrid_identity). Detected
        // without the secret key: every clamped scalar is a multiple of the
        // cofactor, so X25519(k, P) is zero for all k exactly when P has
        // small order. Some backends throw instead of returning zeros.
        guard let share = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encData.suffix(32)),
            let shared = try? Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: share),
            shared.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) })
        else {
            throw AgeError.invalidStanza
        }
        // ML-KEM decapsulation never fails (implicit rejection): a stanza
        // for another key opens to garbage that the AEAD then rejects.
        guard let plain = try XWingHPKE.open(stanza.body, enc: encData, seed: seed) else { return nil }
        return try FileKey(bytes: plain)
    }
}

/// HPKE (RFC 9180) base mode with MLKEM768-X25519 / HKDF-SHA256 /
/// ChaCha20-Poly1305 and the age info string, via swift-crypto.
enum XWingHPKE {
    static func publicKey(seed: Data) throws -> Data {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            do {
                let key = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: nil)
                return key.publicKey.rawRepresentation
            } catch {
                throw AgeError.invalidKey
            }
        }
        #endif
        throw AgeError.postQuantumUnavailable
    }

    static func seal(_ plaintext: Data, to publicKey: Data) throws -> (enc: Data, ciphertext: Data) {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            let key: XWingMLKEM768X25519.PublicKey
            do { key = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey) } catch {
                throw AgeError.invalidKey
            }
            var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: Data(pqLabel.utf8))
            let ciphertext = try sender.seal(plaintext, authenticating: Data())
            return (sender.encapsulatedKey, ciphertext)
        }
        #endif
        throw AgeError.postQuantumUnavailable
    }

    /// Nil when the AEAD rejects the ciphertext (wrong key).
    static func open(_ ciphertext: Data, enc: Data, seed: Data) throws -> Data? {
        #if !canImport(Darwin) || compiler(>=6.2)
        if #available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *) {
            let key: XWingMLKEM768X25519.PrivateKey
            do { key = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: nil) } catch {
                throw AgeError.invalidKey
            }
            var recipient: HPKE.Recipient
            do {
                recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: Data(pqLabel.utf8),
                                               encapsulatedKey: enc)
            } catch {
                throw AgeError.invalidStanza
            }
            return try? recipient.open(ciphertext, authenticating: Data())
        }
        #endif
        throw AgeError.postQuantumUnavailable
    }

    #if !canImport(Darwin) || compiler(>=6.2)
    @available(macOS 26, iOS 26, macCatalyst 26, tvOS 26, watchOS 26, visionOS 26, *)
    static var suite: HPKE.Ciphersuite {
        HPKE.Ciphersuite(kem: .XWingMLKEM768X25519, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    }
    #endif
}
