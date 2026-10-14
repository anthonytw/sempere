import Foundation

/// A native age public key (c2sp.org/age "Native recipient types") parsed
/// from its Bech32 string: X25519 (`age1...`) or the MLKEM768-X25519 hybrid
/// post-quantum type (`age1pq1...`).
public enum NativeRecipient: AgeRecipient, Hashable {
    case x25519(X25519Recipient)
    case mlkem768x25519(MLKEM768X25519Recipient)

    /// Parses `age1pq1...` or `age1...`.
    ///
    /// - Throws: `AgeError.invalidKey` if it is neither.
    public init(string: String) throws {
        if string.hasPrefix(pqRecipientHRP + "1") {
            self = .mlkem768x25519(try MLKEM768X25519Recipient(string: string))
        } else {
            self = .x25519(try X25519Recipient(string: string))
        }
    }

    /// The Bech32 encoding.
    public var string: String {
        switch self {
        case .x25519(let r): return r.string
        case .mlkem768x25519(let r): return r.string
        }
    }

    /// True for the hybrid post-quantum type.
    public var isPostQuantum: Bool {
        if case .mlkem768x25519 = self { return true }
        return false
    }

    /// The stanza type this recipient produces (`X25519` or `mlkem768x25519`).
    public var stanzaType: String {
        isPostQuantum ? pqStanzaType : "X25519"
    }

    /// Wraps `fileKey` with the underlying recipient.
    public func wrap(fileKey: FileKey) throws -> [Stanza] {
        switch self {
        case .x25519(let r): return try r.wrap(fileKey: fileKey)
        case .mlkem768x25519(let r): return try r.wrap(fileKey: fileKey)
        }
    }
}

/// A native age secret key parsed from its Bech32 string: X25519
/// (`AGE-SECRET-KEY-1...`) or MLKEM768-X25519 (`AGE-SECRET-KEY-PQ-1...`).
public enum NativeIdentity: AgeIdentity, Hashable {
    case x25519(X25519Identity)
    case mlkem768x25519(MLKEM768X25519Identity)

    /// Which native type to generate.
    public enum Kind: String, Sendable, CaseIterable {
        /// MLKEM768-X25519 hybrid, post-quantum (`age-keygen -pq`).
        case postQuantum = "pq"
        /// Classic X25519 (`age-keygen`).
        case x25519
    }

    /// Generates a new random identity of `kind`.
    ///
    /// - Throws: `AgeError.postQuantumUnavailable` for `.postQuantum` where
    ///   the platform lacks ML-KEM.
    public static func generate(_ kind: Kind) throws -> NativeIdentity {
        switch kind {
        case .postQuantum: return .mlkem768x25519(try MLKEM768X25519Identity())
        case .x25519: return .x25519(X25519Identity())
        }
    }

    /// Parses `AGE-SECRET-KEY-PQ-1...` or `AGE-SECRET-KEY-1...`.
    ///
    /// - Throws: `AgeError.invalidKey` if it is neither,
    ///   `AgeError.postQuantumUnavailable` for a PQ key where the platform
    ///   lacks ML-KEM.
    public init(string: String) throws {
        if string.hasPrefix(pqIdentityHRP + "1") {
            self = .mlkem768x25519(try MLKEM768X25519Identity(string: string))
        } else {
            self = .x25519(try X25519Identity(string: string))
        }
    }

    /// The Bech32 encoding.
    public var string: String {
        switch self {
        case .x25519(let i): return i.string
        case .mlkem768x25519(let i): return i.string
        }
    }

    /// The matching public recipient.
    public var recipient: NativeRecipient {
        switch self {
        case .x25519(let i): return .x25519(i.recipient)
        case .mlkem768x25519(let i): return .mlkem768x25519(i.recipient)
        }
    }

    /// True for the hybrid post-quantum type.
    public var isPostQuantum: Bool { recipient.isPostQuantum }

    /// Unwraps with the underlying identity.
    public func unwrap(stanzas: [Stanza]) throws -> FileKey? {
        switch self {
        case .x25519(let i): return try i.unwrap(stanzas: stanzas)
        case .mlkem768x25519(let i): return try i.unwrap(stanzas: stanzas)
        }
    }
}

extension X25519Identity: Hashable {
    public static func == (a: X25519Identity, b: X25519Identity) -> Bool { a.secretKey == b.secretKey }
    public func hash(into h: inout Hasher) { h.combine(publicKey) }
}
