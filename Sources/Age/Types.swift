import Crypto
import Foundation

/// Errors thrown by the age implementation. The cases follow the failure
/// classes of the C2SP CCTV test vectors.
public enum AgeError: Error, Hashable, Sendable {
    /// The header is malformed (version line, stanza syntax, MAC line), or
    /// the file ends before the 16-byte payload nonce.
    case headerParse
    /// The version line names a version other than `v1`.
    case unsupportedVersion
    /// A stanza addressed to a supported identity type is malformed: wrong
    /// argument count, non-canonical or wrong-length encodings, a body that
    /// is not 32 bytes, or an X25519 share yielding an all-zero secret.
    case invalidStanza
    /// An scrypt stanza appears alongside other stanzas.
    case scryptNotAlone
    /// The scrypt work factor exceeds the identity's limit or memory budget
    /// (or, when encrypting, is outside 1...30).
    case scryptWorkFactor
    /// The header MAC does not match.
    case headerMAC
    /// No identity could unwrap any stanza.
    case noMatchingIdentity
    /// `decrypt` was called with no identities.
    case noIdentities
    /// `encrypt` was called with no recipients (or the header to encode has
    /// no stanzas).
    case noRecipients
    /// The STREAM payload failed to authenticate, was truncated, or has
    /// trailing data.
    case payload
    /// The ASCII armor is malformed.
    case armor
    /// A Bech32 key string is malformed or of the wrong type.
    case invalidKey
    /// A stanza type or argument is empty or contains bytes outside `!`...`~`.
    case invalidStanzaEncoding
    /// The MLKEM768-X25519 post-quantum recipient type needs ML-KEM, which
    /// this platform's crypto library lacks (Apple platforms before 26).
    case postQuantumUnavailable
    /// `encrypt` was given post-quantum and classic recipients together
    /// without opting in: the file would not be quantum-safe (the `age` CLI
    /// refuses the same mix).
    case incompatibleRecipients
    /// Reading or writing a file or stream failed (the message says what
    /// and why), or a streaming output file already exists.
    case io(String)
    /// A streaming encryptor or decryptor was used after it finished or
    /// failed.
    case streamFinished
}

/// The 128-bit symmetric key that encrypts an age payload.
public struct FileKey: Sendable {
    /// The raw 16 key bytes.
    public let bytes: Data

    /// Generates a fresh random file key.
    public init() {
        bytes = Data(secureRandomBytes(16))
    }

    /// Wraps existing key bytes; throws unless exactly 16 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == 16 else { throw AgeError.invalidStanza }
        self.bytes = Data(bytes)
    }
}

/// A recipient stanza: `-> type args...` followed by a binary body.
public struct Stanza: Sendable, Hashable {
    /// The first argument after `->`, naming the recipient type (for
    /// example `X25519` or `scrypt`). Must be non-empty VCHAR to encode.
    public var type: String
    /// The remaining space-separated arguments, each non-empty VCHAR.
    public var args: [String]
    /// The decoded binary body (written as wrapped, unpadded base64).
    public var body: Data

    /// Creates a stanza. Validity of `type` and `args` is checked when the
    /// header is encoded (`AgeError.invalidStanzaEncoding`).
    public init(type: String, args: [String], body: Data) {
        self.type = type
        self.args = args
        self.body = body
    }
}

/// A parsed age header.
public struct Header: Sendable, Hashable {
    /// The recipient stanzas, in file order.
    public var stanzas: [Stanza]
    /// The 32-byte header MAC.
    public var mac: Data
    /// The header bytes the MAC covers: everything up to and including `---`.
    public var macInput: Data
}

/// Something that can wrap a file key into one or more stanzas.
public protocol AgeRecipient: Sendable {
    func wrap(fileKey: FileKey) throws -> [Stanza]
}

/// Something that can unwrap a file key from a header's stanzas.
///
/// Return `nil` when no stanza is addressed to this identity (or none
/// decrypts); throw when a stanza this identity recognizes is malformed,
/// which aborts decryption.
public protocol AgeIdentity: Sendable {
    func unwrap(stanzas: [Stanza]) throws -> FileKey?
}

// MARK: - Shared helpers

func secureRandomBytes(_ count: Int) -> [UInt8] {
    // SystemRandomNumberGenerator is a CSPRNG on every supported platform
    // (arc4random_buf on Apple, getrandom(2) on Linux).
    var rng = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
}

func hkdfSHA256(ikm: some DataProtocol, salt: some DataProtocol, info: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: Data(ikm)),
        salt: Data(salt),
        info: Data(info.utf8),
        outputByteCount: 32
    )
}

/// The fixed all-zero 12-byte nonce used for wrapping file keys. Built on
/// use: swift-crypto's `ChaChaPoly.Nonce` is not `Sendable` on Linux, so it
/// cannot be a global.
func zeroNonce() throws -> ChaChaPoly.Nonce {
    try ChaChaPoly.Nonce(data: [UInt8](repeating: 0, count: 12))
}

/// ChaCha20-Poly1305 with a zero nonce, for wrapping a 16-byte file key.
func aeadSealFileKey(key: SymmetricKey, fileKey: FileKey) throws -> Data {
    Data(try ChaChaPoly.seal(fileKey.bytes, using: key, nonce: try zeroNonce()).combined.dropFirst(12))
}

/// Opens a 32-byte wrapped file key. Throws `invalidStanza` if `body` is
/// not exactly 32 bytes (checked first, against partitioning oracles);
/// returns nil if authentication fails.
func aeadOpenFileKey(key: SymmetricKey, body: Data) throws -> FileKey? {
    guard body.count == 32 else { throw AgeError.invalidStanza }
    let b = Data(body)
    guard let box = try? ChaChaPoly.SealedBox(nonce: zeroNonce(), ciphertext: b.prefix(16), tag: b.suffix(16)),
        let plain = try? ChaChaPoly.open(box, using: key)
    else { return nil }
    return try FileKey(bytes: plain)
}

/// True if `s` is a non-empty run of VCHAR (0x21...0x7E).
func isValidStanzaString(_ s: String) -> Bool {
    let u = s.utf8
    return !u.isEmpty && u.allSatisfy { $0 >= 33 && $0 <= 126 }
}

extension AgeError: CustomStringConvertible {
    /// A human sentence for each case.
    public var description: String {
        switch self {
        case .headerParse: return "not an age file (bad header)"
        case .unsupportedVersion: return "unsupported age version"
        case .invalidStanza: return "malformed age recipient stanza"
        case .scryptNotAlone: return "malformed age file: scrypt stanza mixed with others"
        case .scryptWorkFactor: return "scrypt work factor too high"
        case .headerMAC: return "age header MAC does not match (file damaged)"
        case .noMatchingIdentity: return "none of the given keys matches this file"
        case .noIdentities: return "no key given"
        case .noRecipients: return "no recipients"
        case .payload: return "age payload is damaged or truncated"
        case .armor: return "malformed ASCII armor"
        case .invalidKey: return "malformed age key"
        case .invalidStanzaEncoding: return "invalid stanza encoding"
        case .incompatibleRecipients:
            return "can't mix post-quantum (age1pq) and classic recipients: the file would not be quantum-safe"
        case .postQuantumUnavailable:
            return "post-quantum (age1pq) keys need ML-KEM, which this system lacks (needs macOS / iPadOS 26 or later)"
        case .io(let message): return message
        case .streamFinished: return "age stream already finished"
        }
    }
}
