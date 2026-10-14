import Crypto
import Foundation

/// Spec-exact implementation of the age v1 file format
/// ([age-encryption.org/v1](https://c2sp.org/age)).
///
/// Scope (age v1, plus the age v1.3 post-quantum type):
/// MLKEM768-X25519, X25519 and scrypt recipients, header
/// parsing and formatting, header HMAC, STREAM payload, ASCII armor, Bech32
/// identity and recipient encoding; streaming encryption and decryption,
/// header-only rewrap and re-encryption (`Streaming.swift`, attachments task
/// B1). Validated against the C2SP CCTV vectors under Tests/AgeTests/Vectors
/// (through both the buffer and the streaming paths) and against the
/// reference `age` CLI.
public enum AgeVersion {
    public static let header = "age-encryption.org/v1"
}

/// One-shot age encryption and decryption of in-memory buffers.
///
/// Named `AgeFile`, not `Age`, so it does not shadow the `Age` module and
/// clients can still write `Age.X25519Identity` to disambiguate.
public enum AgeFile {
    /// Encrypts `plaintext` to `recipients`.
    ///
    /// - Parameters:
    ///   - armor: wrap the result in the PEM-style ASCII armor.
    ///   - allowMixedPostQuantum: permit `mlkem768x25519` stanzas next to
    ///     classic ones. The spec says a file SHOULD NOT mix them (the
    ///     classic stanza voids the post-quantum protection) and `age`
    ///     refuses; a vault opts in only while it moves between key types
    ///     (format.md §3.3). `age` decrypts such files.
    /// - Throws: `AgeError.noRecipients` for an empty list,
    ///   `AgeError.scryptNotAlone` if a scrypt recipient is mixed with any
    ///   other recipient, `AgeError.incompatibleRecipients` for a
    ///   post-quantum / classic mix not allowed, or whatever a recipient's
    ///   `wrap` throws.
    public static func encrypt(_ plaintext: Data, to recipients: [any AgeRecipient], armor: Bool = false,
                               allowMixedPostQuantum: Bool = false) throws -> Data
    {
        let fileKey = FileKey()
        var out = try header(fileKey: fileKey, recipients: recipients, allowMixedPostQuantum: allowMixedPostQuantum)
        let nonce = Data(secureRandomBytes(Stream.nonceSize))
        out += nonce
        out += try Stream.encrypt(plaintext, key: Stream.payloadKey(fileKey: fileKey, nonce: nonce))
        return armor ? Armor.encode(out) : out
    }

    /// Decrypts an age file, binary or ASCII-armored (detected the way the
    /// `age` CLI does it: the BEGIN line after optional whitespace).
    ///
    /// Identities are tried in order; the first that unwraps the file key
    /// wins. An identity that throws aborts decryption.
    public static func decrypt(_ ciphertext: Data, with identities: [any AgeIdentity]) throws -> Data {
        let binary = Armor.isArmored(ciphertext) ? try Armor.decode(ciphertext) : ciphertext
        var released = Data()
        _ = try decrypt(binary: binary, with: identities, released: &released)
        return released
    }

    /// Parses the header of a binary age file. Returns the header and the
    /// offset of the payload (the 16-byte nonce) from `data.startIndex`.
    public static func parseHeader(_ data: Data) throws -> (header: Header, payloadStart: Int) {
        let (header, start) = try HeaderCodec.parse(data)
        return (header, start)
    }

    /// Decrypts a binary age file, appending authenticated plaintext to
    /// `released` chunk by chunk (so after a payload failure it holds what a
    /// streaming reader would already have handed out). Returns the file key.
    static func decrypt(binary data: Data, with identities: [any AgeIdentity], released: inout Data) throws
        -> FileKey
    {
        let (header, start) = try HeaderCodec.parse(data)
        let fileKey = try unwrapFileKey(header: header, identities: identities)

        let payload = data.dropFirst(start)
        // A file that ends before the nonce is a header-level failure in
        // the reference implementation (and the CCTV vectors).
        guard payload.count >= Stream.nonceSize else { throw AgeError.headerParse }
        let nonce = payload.prefix(Stream.nonceSize)
        let key = Stream.payloadKey(fileKey: fileKey, nonce: nonce)
        try Stream.decrypt(payload.dropFirst(Stream.nonceSize), key: key, released: &released)
        return fileKey
    }

    /// Wraps `fileKey` to `recipients` and returns the encoded header, MAC
    /// line included (age spec "Header": the stanzas, then `---` and the
    /// base64 HMAC-SHA-256 under `HKDF(file key, "header")` of everything
    /// before it). Every encryption path builds its header here, so the
    /// recipient rules below hold for all of them.
    ///
    /// - Throws: `noRecipients` for an empty list; `scryptNotAlone` when an
    ///   scrypt stanza is not the only one (spec "scrypt recipient stanza":
    ///   it MUST be the only stanza); `incompatibleRecipients` for a
    ///   post-quantum / classic mix not allowed (spec "MLKEM768-X25519":
    ///   such files SHOULD NOT mix types); whatever a recipient's `wrap`
    ///   throws.
    static func header(fileKey: FileKey, recipients: [any AgeRecipient], allowMixedPostQuantum: Bool) throws -> Data {
        guard !recipients.isEmpty else { throw AgeError.noRecipients }
        var stanzas = [Stanza]()
        for r in recipients { stanzas += try r.wrap(fileKey: fileKey) }
        let hasScrypt: Bool = stanzas.contains { (s: Stanza) -> Bool in s.type == "scrypt" }
        if hasScrypt && stanzas.count != 1 {
            throw AgeError.scryptNotAlone
        }
        let pq = stanzas.filter { $0.type == pqStanzaType }.count
        if !allowMixedPostQuantum && pq > 0 && pq != stanzas.count {
            throw AgeError.incompatibleRecipients
        }
        var out = Data(try HeaderCodec.encodeWithoutMAC(stanzas))
        let mac = HeaderCodec.mac(fileKey: fileKey, macInput: out)
        out += Data(" \(Base64.encodeRaw(mac))\n".utf8)
        return out
    }

    /// Recovers the file key of a parsed header with the first identity that
    /// unwraps a stanza, then checks the header MAC (age spec "Header": a
    /// reader MUST verify the MAC before using the file key).
    ///
    /// - Throws: `scryptNotAlone`, `noIdentities`, `noMatchingIdentity`,
    ///   `headerMAC`, or whatever an identity throws.
    static func unwrapFileKey(header: Header, identities: [any AgeIdentity]) throws -> FileKey {
        // An scrypt stanza must be the only stanza (spec "scrypt recipient
        // stanza"). Enforced here, not only in ScryptIdentity, so that a
        // mixed header is rejected whichever identity would match.
        let hasScrypt: Bool = header.stanzas.contains { (s: Stanza) -> Bool in s.type == "scrypt" }
        if hasScrypt && header.stanzas.count != 1 { throw AgeError.scryptNotAlone }
        guard !identities.isEmpty else { throw AgeError.noIdentities }
        var fileKey: FileKey?
        for identity in identities {
            if let key = try identity.unwrap(stanzas: header.stanzas) {
                fileKey = key
                break
            }
        }
        guard let fileKey else { throw AgeError.noMatchingIdentity }
        guard HeaderCodec.verifyMAC(fileKey: fileKey, header: header) else { throw AgeError.headerMAC }
        return fileKey
    }
}
