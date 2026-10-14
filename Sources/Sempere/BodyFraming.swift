import Crypto
import Foundation

/// The 32-byte per-vault secret that keys the body tag (format.md §2, §4).
/// It is never written in plaintext; `vault.json` holds it age-encrypted.
public struct VaultSecret: Hashable, Sendable {
    /// Length in bytes.
    public static let byteCount = 32

    /// The raw secret.
    public let bytes: Data

    /// Wraps existing bytes; throws `BodyFramingError.invalidSecret` unless
    /// exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw BodyFramingError.invalidSecret }
        self.bytes = Data(bytes)
    }

    /// A fresh secret from the system CSPRNG.
    public static func random() -> VaultSecret {
        let key = SymmetricKey(size: .bits256)
        // 32 bytes by construction, so the throwing init cannot fail.
        return key.withUnsafeBytes { VaultSecret(unchecked: Data($0)) }
    }

    private init(unchecked bytes: Data) { self.bytes = bytes }

    var key: SymmetricKey { SymmetricKey(data: bytes) }
}

/// Errors from framing and unframing a decrypted body (format.md §4).
public enum BodyFramingError: Error, Hashable, Sendable {
    /// Shorter than the 37-byte header.
    case tooShort
    /// The first four bytes are not `SMPR`.
    case badMagic
    /// A body version this reader does not know.
    case unsupportedVersion(UInt8)
    /// The HMAC tag does not match: the body, note id or file name was changed,
    /// or the file was written under another vault secret.
    case tagMismatch
    /// A vault secret that is not 32 bytes.
    case invalidSecret
}

/// The plaintext layout of every `.age` file under `notes/` (format.md §4):
///
/// | offset | size | content |
/// | --- | --- | --- |
/// | 0 | 4 | `SMPR` |
/// | 4 | 1 | version `0x01` |
/// | 5 | 32 | HMAC-SHA256 tag |
/// | 37 | rest | `gzip(JSON)` |
///
/// Tag = HMAC-SHA256(vaultSecret, `"sempere/1" ‖ 0x00 ‖ noteId ‖ 0x00 ‖
/// filename ‖ 0x00 ‖ gzipBytes`).
public enum BodyFraming {
    /// Bytes before the gzip member; `tail -c +38` skips them.
    public static let headerSize = 37
    /// HMAC-SHA256 output length.
    public static let tagSize = 32

    /// A body taken apart by `unframe`.
    public struct Unframed: Hashable, Sendable {
        /// The `gzip(JSON)` bytes, exactly as stored.
        public var gzip: Data
        /// True when the tag was checked against a vault secret and matched.
        /// False only in unverified mode (no secret supplied).
        public var verified: Bool
    }

    /// The tag over `gzip` for the file `filename` in note directory `noteId`.
    public static func tag(gzip: Data, noteId: String, filename: String, secret: VaultSecret) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(gzip: gzip, noteId: noteId, filename: filename),
                                             using: secret.key))
    }

    /// Frames already-compressed bytes.
    public static func frame(gzip: Data, noteId: String, filename: String, secret: VaultSecret) -> Data {
        var out = Data(SempereFormat.bodyMagic)
        out.append(SempereFormat.bodyVersion)
        out += tag(gzip: gzip, noteId: noteId, filename: filename, secret: secret)
        out += gzip
        return out
    }

    /// Compresses `json` with gzip framing and frames it.
    public static func frame(json: Data, noteId: String, filename: String, secret: VaultSecret) throws -> Data {
        frame(gzip: try Gzip.compress(json), noteId: noteId, filename: filename, secret: secret)
    }

    /// Checks magic and version and, when `secret` is given, the tag (in
    /// constant time). With `secret == nil` (vault secret unavailable, e.g.
    /// recovery with only an identity) the body is returned with
    /// `verified == false`; callers must surface that.
    ///
    /// - Throws: `BodyFramingError.tooShort`, `.badMagic`,
    ///   `.unsupportedVersion`, or `.tagMismatch`.
    public static func unframe(_ body: Data, noteId: String, filename: String, secret: VaultSecret?) throws -> Unframed {
        let b = Data(body)   // rebase indices to 0
        guard b.count >= headerSize else { throw BodyFramingError.tooShort }
        guard Array(b[0..<4]) == SempereFormat.bodyMagic else { throw BodyFramingError.badMagic }
        guard b[4] == SempereFormat.bodyVersion else { throw BodyFramingError.unsupportedVersion(b[4]) }
        let tag = b[5..<headerSize]
        let gzip = Data(b[headerSize...])
        guard let secret else { return Unframed(gzip: gzip, verified: false) }
        let ok = HMAC<SHA256>.isValidAuthenticationCode(
            tag, authenticating: message(gzip: gzip, noteId: noteId, filename: filename), using: secret.key)
        guard ok else { throw BodyFramingError.tagMismatch }
        return Unframed(gzip: gzip, verified: true)
    }

    /// Re-tags a framed body under another secret, keeping the gzip bytes.
    /// Used by the recipient-change rewrap after the secret is rotated.
    static func retag(_ unframed: Unframed, noteId: String, filename: String, secret: VaultSecret) -> Data {
        frame(gzip: unframed.gzip, noteId: noteId, filename: filename, secret: secret)
    }

    private static func message(gzip: Data, noteId: String, filename: String) -> Data {
        var m = Data(SempereFormat.tagLabel.utf8)
        m.append(0)
        m += Data(noteId.utf8)
        m.append(0)
        m += Data(filename.utf8)
        m.append(0)
        m += gzip
        return m
    }
}
