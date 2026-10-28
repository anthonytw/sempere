import Crypto
import Foundation

private let x25519Label = "age-encryption.org/v1/X25519"

/// An age X25519 recipient (public key), `age1...`.
public struct X25519Recipient: AgeRecipient, Hashable {
    let publicKey: Data

    init(publicKey: Data) {
        self.publicKey = publicKey
    }

    /// Parses a Bech32 `age1...` recipient (lowercase only, as `age` does).
    public init(string: String) throws {
        guard let (hrp, data) = Bech32.decode(string), hrp == "age", data.count == 32 else {
            throw AgeError.invalidKey
        }
        publicKey = Data(data)
    }

    /// The Bech32 encoding, `age1...`.
    public var string: String {
        Bech32.encode(hrp: "age", data: [UInt8](publicKey)) ?? ""
    }

    /// Wraps `fileKey` in one `X25519` stanza using a fresh ephemeral key.
    ///
    /// - Throws: `AgeError.invalidKey` if this recipient is a low-order
    ///   point (the shared secret would be all zeros).
    public func wrap(fileKey: FileKey) throws -> [Stanza] {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: theirs)
        let secret = shared.withUnsafeBytes { Data($0) }
        guard secret.contains(where: { $0 != 0 }) else { throw AgeError.invalidKey }
        let key = hkdfSHA256(ikm: secret, salt: share + publicKey, info: x25519Label)
        let body = try aeadSealFileKey(key: key, fileKey: fileKey)
        return [Stanza(type: "X25519", args: [Base64.encodeRaw(share)], body: body)]
    }
}

/// An age X25519 identity (private key), `AGE-SECRET-KEY-1...`.
public struct X25519Identity: AgeIdentity {
    // Raw bytes rather than swift-crypto key objects, which are not
    // `Sendable` on Linux. The key object is rebuilt on use.
    let secretKey: Data
    let publicKey: Data

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        secretKey = privateKey.rawRepresentation
        publicKey = privateKey.publicKey.rawRepresentation
    }

    /// Generates a new random identity.
    public init() {
        self.init(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Parses a Bech32 `AGE-SECRET-KEY-1...` identity (uppercase only, as
    /// `age-keygen` writes it and `age` accepts it).
    public init(string: String) throws {
        guard let (hrp, data) = Bech32.decode(string), hrp == "AGE-SECRET-KEY-", data.count == 32,
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { throw AgeError.invalidKey }
        self.init(privateKey: key)
    }

    /// The Bech32 encoding, uppercase `AGE-SECRET-KEY-1...`.
    public var string: String {
        Bech32.encode(hrp: "AGE-SECRET-KEY-", data: [UInt8](secretKey)) ?? ""
    }

    /// The matching public recipient.
    public var recipient: X25519Recipient {
        X25519Recipient(publicKey: publicKey)
    }

    /// Tries every `X25519` stanza and returns the first file key that
    /// decrypts; other stanza types are ignored.
    ///
    /// - Returns: nil if no `X25519` stanza is addressed to this identity.
    /// - Throws: `AgeError.invalidStanza` for a malformed `X25519` stanza
    ///   (argument count, non-canonical or wrong-length share, body not 32
    ///   bytes) or a share that yields an all-zero shared secret.
    public func unwrap(stanzas: [Stanza]) throws -> FileKey? {
        for stanza in stanzas where stanza.type == "X25519" {
            if let key = try unwrap(stanza) { return key }
        }
        return nil
    }

    private func unwrap(_ stanza: Stanza) throws -> FileKey? {
        guard stanza.args.count == 1, let share = Base64.decodeRaw(stanza.args[0].utf8), share.count == 32 else {
            throw AgeError.invalidStanza
        }
        let shareData = Data(share)
        guard let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: shareData) else {
            throw AgeError.invalidStanza
        }
        // Low-order shares make X25519 return all zeros; the spec says abort.
        // Some backends throw here instead, which is the same outcome.
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: secretKey),
            let shared = try? privateKey.sharedSecretFromKeyAgreement(with: theirs)
        else {
            throw AgeError.invalidStanza
        }
        let secret = shared.withUnsafeBytes { Data($0) }
        guard secret.contains(where: { $0 != 0 }) else { throw AgeError.invalidStanza }
        let key = hkdfSHA256(ikm: secret, salt: shareData + publicKey, info: x25519Label)
        return try aeadOpenFileKey(key: key, body: stanza.body)
    }
}
