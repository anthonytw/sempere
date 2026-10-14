import Age
import Crypto
import Foundation

// MARK: - Attachment blobs: names, framing, padding (docs/format.md §8.1)
//
// A blob is the large, immutable bytes of an attachment (an image, a PDF, a
// recording, a transcript), stored once per note as
// `notes/<noteId>/att/<blobName>.<kind>.age`. This file holds the parts that
// do not touch the disk: the keyed name (§8.1.2), the plaintext framing and
// Padmé padding (§8.1.3) and a streaming checker for decrypted plaintext
// (§8.1.4). `BlobStore.swift` reads and writes the files.

/// Why a blob could not be written, found, read or verified (format.md §8.1).
public enum BlobError: Error, Hashable, Sendable {
    /// The reference is malformed: `sha256` is not 64 lowercase hex digits or
    /// `size` is outside 0 … 1 GiB (§8.1.1, §8.4).
    case invalidReference
    /// Content over the 1 GiB blob limit (§8.4); the size is given.
    case tooLarge(Int64)
    /// No blob file for the reference under the current name (nor, during an
    /// unfinished secret rotation, the previous one); the path tried is given.
    case missing(String)
    /// The file could not be opened or read (not a regular file, I/O, over
    /// the size limit of `BoundedRead.maxBlobFileBytes`).
    case unreadable(String)
    /// age decryption failed (no matching identity, bad header, a chunk that
    /// does not authenticate, truncation).
    case undecryptable(String)
    /// The plaintext does not start with `INKB`.
    case badMagic
    /// A blob version other than 1.
    case unsupportedVersion(UInt8)
    /// The plaintext ends inside the 45-byte header or inside the content.
    case truncated
    /// The header's content length is over the 1 GiB limit.
    case lengthOutOfRange(UInt64)
    /// A padding byte after the content is not zero.
    case nonZeroPadding
    /// The content does not hash to the value in the header.
    case contentHashMismatch
    /// The file name is not the keyed name of the header's hash under the
    /// vault secret (nor, during a rotation, the previous one): planted,
    /// renamed, or named under another secret (§8.1.2, §8.1.5).
    case nameMismatch
    /// The header's hash or length differs from the reference read through.
    case referenceMismatch
    /// The content is longer than the caller's `maxBytes`.
    case contentTooLarge(limit: Int64)
    /// The source file changed while it was being written as a blob.
    case sourceChanged
}

/// The 45-byte header at the start of a blob's plaintext (format.md §8.1.3).
public struct BlobHeader: Hashable, Sendable {
    /// SHA-256 of the content, 32 bytes.
    public var digest: Data
    /// Content length `L`.
    public var length: Int64

    /// The digest as 64 lowercase hex digits (a reference's `sha256`).
    public var sha256: String { Hex.encode(digest) }
}

/// The blob plaintext layout (format.md §8.1.3):
///
/// | offset | size | content |
/// | --- | --- | --- |
/// | 0 | 4 | `INKB` |
/// | 4 | 1 | version `0x01` |
/// | 5 | 32 | SHA-256 of the content |
/// | 37 | 8 | content length `L`, big-endian |
/// | 45 | `L` | content |
/// | 45 + `L` | rest | zero padding (Padmé) |
public enum BlobFraming {
    /// `INKB`.
    public static let magic: [UInt8] = Array("INKB".utf8)
    /// The only blob version.
    public static let version: UInt8 = 1
    /// Bytes before the content; `tail -c +46` skips them (§8.1.7).
    public static let headerSize = 45

    /// The header for content with this digest and length.
    public static func header(digest: Data, length: Int64) -> Data {
        precondition(digest.count == 32 && length >= 0)
        var out = Data(magic)
        out.append(version)
        out += digest
        let l = UInt64(length)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: l >> UInt64(shift))) }
        return out
    }

    /// Parses the first 45 bytes of a plaintext.
    ///
    /// - Throws: `BlobError.truncated`, `.badMagic`, `.unsupportedVersion`,
    ///   `.lengthOutOfRange` (over 1 GiB).
    public static func parseHeader(_ bytes: Data) throws -> BlobHeader {
        let b = Data(bytes.prefix(headerSize))   // rebase indices to 0
        guard b.count == headerSize else { throw BlobError.truncated }
        guard Array(b[0..<4]) == magic else { throw BlobError.badMagic }
        guard b[4] == version else { throw BlobError.unsupportedVersion(b[4]) }
        var l: UInt64 = 0
        for i in 37..<45 { l = l << 8 | UInt64(b[i]) }
        // Range-checked before any arithmetic on it (format.md §9).
        guard l <= UInt64(BlobRef.maxSize) else { throw BlobError.lengthOutOfRange(l) }
        return BlobHeader(digest: Data(b[5..<37]), length: Int64(l))
    }

    /// Padmé (Nikitin et al., PETS 2019): the padded length for a plaintext
    /// of `n` bytes (format.md §8.1.3). At most 12 % larger, and only
    /// O(log log n) bits of `n` remain visible.
    public static func padme(_ n: Int64) -> Int64 {
        precondition(n >= 0)
        guard n >= 2 else { return n }
        let e = Int64(63 - n.leadingZeroBitCount)            // floor(log2 n)
        let s = Int64(63 - e.leadingZeroBitCount) + 1        // floor(log2 E) + 1
        let z = e - s
        let mask = (Int64(1) << z) - 1
        return (n + mask) & ~mask
    }

    /// The padded plaintext length of a blob with `contentLength` bytes of
    /// content: `padme(45 + L)`.
    public static func paddedPlaintextLength(contentLength: Int64) -> Int64 {
        padme(Int64(headerSize) + contentLength)
    }
}

/// Keyed blob names and the file names built from them (format.md §8.1.2).
public enum BlobName {
    /// `blobName = hex(HMAC-SHA256(vaultSecret, "sempere/1" ‖ 0 ‖ "blob" ‖ 0 ‖ sha256))`,
    /// with `sha256` the 32 raw bytes of the content hash.
    public static func name(digest: Data, secret: VaultSecret) -> String {
        var m = Data(SempereFormat.tagLabel.utf8)
        m.append(0)
        m += Data("blob".utf8)
        m.append(0)
        m += digest
        return Hex.encode(HMAC<SHA256>.authenticationCode(for: m, using: secret.key))
    }

    /// `<name>.<kind>.age`.
    public static func fileName(name: String, kind: BlobKind) -> String { "\(name).\(kind.rawValue).age" }

    /// The name and kind of a blob file name: 64 lowercase hex digits, `.`,
    /// a kind (1–16 lowercase ASCII letters or digits), `.age`. Anything else
    /// in `att/` is an unknown file (§1).
    public static func parse(_ fileName: String) -> (name: String, kind: BlobKind)? {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "age", parts[0].utf8.count == 64,
              parts[0].utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        let kind = BlobKind(rawValue: String(parts[1]))
        guard kind.isValidName else { return nil }
        return (String(parts[0]), kind)
    }

    /// True when the name verifies (in constant time) against `digest` under
    /// one of `secrets`; returns the index of the secret that matched.
    static func verify(_ name: String, digest: Data, secrets: [VaultSecret]) -> Int? {
        guard let given = Hex.decode(name) else { return nil }
        var m = Data(SempereFormat.tagLabel.utf8)
        m.append(0)
        m += Data("blob".utf8)
        m.append(0)
        m += digest
        for (i, s) in secrets.enumerated()
        where HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: m, using: s.key) {
            return i
        }
        return nil
    }
}

/// Checks a blob's decrypted plaintext as it streams past, chunk by chunk
/// (format.md §8.1.4): the header, the content hash and length, and that
/// every padding byte is zero. Memory: the header and one SHA-256 state.
///
/// Content is handed to the sink as it arrives, before the hash is known to
/// match: a caller that shows it early must stop and discard it if `finish`
/// throws.
struct BlobPlaintextChecker {
    /// The reference this blob is read through, if any: its hash and size
    /// must equal the header's.
    let expected: BlobRef?
    /// Largest content accepted.
    let maxContent: Int64
    private var head = Data()
    private(set) var header: BlobHeader?
    private var hasher = SHA256()
    private var contentSeen: Int64 = 0

    init(expected: BlobRef? = nil, maxContent: Int64 = BlobRef.maxSize) {
        self.expected = expected
        self.maxContent = maxContent
    }

    /// Consumes the next plaintext piece; content bytes go to `sink`.
    mutating func consume(_ piece: Data, sink: (Data) throws -> Void = { _ in }) throws {
        var rest = piece[...]
        if header == nil {
            let need = BlobFraming.headerSize - head.count
            head += rest.prefix(need)
            rest = rest.dropFirst(need)
            guard head.count == BlobFraming.headerSize else { return }
            let h = try BlobFraming.parseHeader(head)
            if let expected {
                guard expected.sha256 == h.sha256, expected.size == h.length else { throw BlobError.referenceMismatch }
            }
            guard h.length <= maxContent else { throw BlobError.contentTooLarge(limit: maxContent) }
            header = h
        }
        guard let header, !rest.isEmpty else { return }
        let want = header.length - contentSeen
        if want > 0 {
            let content = rest.prefix(Int(min(want, Int64(rest.count))))
            hasher.update(data: content)
            contentSeen += Int64(content.count)
            try sink(Data(content))
            rest = rest.dropFirst(content.count)
        }
        guard rest.allSatisfy({ $0 == 0 }) else { throw BlobError.nonZeroPadding }
    }

    /// Call once the plaintext is known complete (the age stream ended):
    /// checks length and hash and returns the header.
    func finish() throws -> BlobHeader {
        guard let header, contentSeen == header.length else { throw BlobError.truncated }
        guard Data(hasher.finalize()) == header.digest else { throw BlobError.contentHashMismatch }
        return header
    }
}
