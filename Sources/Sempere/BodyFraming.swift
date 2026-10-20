import Crypto
import Foundation

/// Errors from framing and unframing a decrypted body (format.md §4).
public enum BodyFramingError: Error, Hashable, Sendable {
    /// Shorter than the 37-byte header.
    case tooShort
    /// The first four bytes are not `SMPR`.
    case badMagic
    /// A body version this reader does not know.
    case unsupportedVersion(UInt8)
    /// The HMAC tag does not match: the body, note id or file name was changed,
    /// or the file was written under another epoch's key.
    case tagMismatch
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
/// Tag = HMAC-SHA256(tagKey, `"sempere/1" ‖ 0x00 ‖ noteId ‖ 0x00 ‖
/// filename ‖ 0x00 ‖ gzipBytes`), with `tagKey` derived from the epoch's key `K_e`
/// (`VaultEpochKey.tagKey`, format.md §15.2). Every `secret:` below is `K_e`.
public enum BodyFraming {
    /// Bytes before the gzip member; `tail -c +38` skips them.
    public static let headerSize = 37
    /// HMAC-SHA256 output length.
    public static let tagSize = 32

    /// A body taken apart by `unframe`.
    public struct Unframed: Hashable, Sendable {
        /// The `gzip(JSON)` bytes, exactly as stored.
        public var gzip: Data
        /// True when the tag was checked under the epoch's key and matched.
        /// False only in unverified mode (no key supplied).
        public var verified: Bool
    }

    /// The tag over `gzip` for the file `filename` in note directory `noteId`.
    public static func tag(gzip: Data, noteId: String, filename: String, secret: VaultEpochKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(gzip: gzip, noteId: noteId, filename: filename),
                                             using: SymmetricKey(data: secret.tagKey)))
    }

    /// Frames already-compressed bytes.
    public static func frame(gzip: Data, noteId: String, filename: String, secret: VaultEpochKey) -> Data {
        var out = Data(SempereFormat.bodyMagic)
        out.append(SempereFormat.bodyVersion)
        out += tag(gzip: gzip, noteId: noteId, filename: filename, secret: secret)
        out += gzip
        return out
    }

    /// Compresses `json` with gzip framing and frames it.
    public static func frame(json: Data, noteId: String, filename: String, secret: VaultEpochKey) throws -> Data {
        frame(gzip: try Gzip.compress(json), noteId: noteId, filename: filename, secret: secret)
    }

    /// Checks magic and version and, when `secret` is given, the tag (in
    /// constant time). With `secret == nil` (no epoch key, e.g. recovery with
    /// only an identity) the body is returned with `verified == false`;
    /// callers must surface that.
    ///
    /// - Throws: `BodyFramingError.tooShort`, `.badMagic`,
    ///   `.unsupportedVersion`, or `.tagMismatch`.
    public static func unframe(_ body: Data, noteId: String, filename: String, secret: VaultEpochKey?) throws -> Unframed {
        let b = Data(body)   // rebase indices to 0
        guard b.count >= headerSize else { throw BodyFramingError.tooShort }
        guard Array(b[0..<4]) == SempereFormat.bodyMagic else { throw BodyFramingError.badMagic }
        guard b[4] == SempereFormat.bodyVersion else { throw BodyFramingError.unsupportedVersion(b[4]) }
        let tag = b[5..<headerSize]
        let gzip = Data(b[headerSize...])
        guard let secret else { return Unframed(gzip: gzip, verified: false) }
        let ok = HMAC<SHA256>.isValidAuthenticationCode(
            tag, authenticating: message(gzip: gzip, noteId: noteId, filename: filename),
            using: SymmetricKey(data: secret.tagKey))
        guard ok else { throw BodyFramingError.tagMismatch }
        return Unframed(gzip: gzip, verified: true)
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
