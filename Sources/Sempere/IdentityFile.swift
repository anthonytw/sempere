import Age
import Crypto
import Foundation

/// The `age-keygen` style identity text (format.md §3.1–§3.2):
///
/// ```
/// # created: 2026-10-04T16:20:00Z
/// # public key: age1...
/// AGE-SECRET-KEY-1...
/// ```
///
/// The identity is either type `NativeIdentity` covers: X25519
/// (`AGE-SECRET-KEY-1...`, `age-keygen`) or MLKEM768-X25519
/// (`AGE-SECRET-KEY-PQ-1...`, `age-keygen -pq`).
public enum IdentityFile {
    /// Writers use scrypt work factors in this range (format.md §3.2).
    public static let writerWorkFactors = 15...18
    /// Readers accept up to 20 by default.
    public static let defaultMaxWorkFactor = 20
    /// The largest cap a reader may choose (format.md §3.2: "may accept up to 22").
    public static let maxAllowedWorkFactor = 22

    private static let suffix = ".key.age"
    private static let pqPrefix = "age1pq-"

    /// The `keys/` file name (format.md §3.2): `<recipient>.key.age` for an
    /// X25519 recipient; `age1pq-<SHA-256 of the recipient string, hex>.key.age`
    /// for a post-quantum one, whose 1959-character string is too long for a
    /// file name.
    public static func fileName(for recipient: NativeRecipient) -> String {
        switch recipient {
        case .x25519(let r): return r.string + suffix
        case .mlkem768x25519(let r):
            let digest = FileDigest.sha256(Data(r.string.utf8))
            return pqPrefix + digest + suffix
        }
    }

    /// `fileName(for:)` of an X25519 recipient.
    public static func fileName(for recipient: X25519Recipient) -> String { fileName(for: .x25519(recipient)) }

    /// The X25519 recipient named by a `keys/` file name, or nil if it is not one.
    /// Post-quantum file names hold only a hash; see `isKeyFileName` and
    /// `Vault.identityFiles()`.
    public static func recipient(fromFileName name: String) -> NativeRecipient? {
        guard name.hasSuffix(suffix) else { return nil }
        return (try? X25519Recipient(string: String(name.dropLast(suffix.count)))).map(NativeRecipient.x25519)
    }

    /// True for either form of `keys/` file name.
    public static func isKeyFileName(_ name: String) -> Bool {
        if recipient(fromFileName: name) != nil { return true }
        guard name.hasPrefix(pqPrefix), name.hasSuffix(suffix) else { return false }
        let hex = name.dropFirst(pqPrefix.count).dropLast(suffix.count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The name the app suggests when it saves or shares a plaintext key
    /// file (`render`'s text): `Sempere key - <label>.txt`. The label is cut
    /// to one line of at most 60 characters, without path separators,
    /// or control characters; an empty one gives `Sempere key.txt`.
    public static func exportFileName(label: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(label.unicodeScalars.map { banned.contains($0) ? " " : $0 }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Sempere key.txt" : "Sempere key - \(name).txt"
    }

    /// The plaintext, `age-keygen` style, newline-terminated.
    public static func render(_ identity: NativeIdentity, created: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "# created: \(f.string(from: created))\n# public key: \(identity.recipient.string)\n\(identity.string)\n"
    }

    /// `render` for an X25519 identity.
    public static func render(_ identity: X25519Identity, created: Date) -> String {
        render(.x25519(identity), created: created)
    }

    /// Parses `age-keygen` style text: the first line that is neither blank
    /// nor a `#` comment must be the identity. A `# public key:` comment, if
    /// present, must match it.
    ///
    /// - Throws: `identityFileMalformed`, `identityMismatch`, or
    ///   `AgeError.postQuantumUnavailable` for a post-quantum identity on a
    ///   platform without ML-KEM.
    public static func parse(_ text: String) throws -> NativeIdentity {
        var declared: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let prefix = "# public key:"
                if line.hasPrefix(prefix) {
                    declared = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let id: NativeIdentity
            do { id = try NativeIdentity(string: line) } catch AgeError.postQuantumUnavailable {
                throw AgeError.postQuantumUnavailable
            } catch { throw VaultError.identityFileMalformed }
            if let declared, declared != id.recipient.string { throw VaultError.identityMismatch(declared) }
            return id
        }
        throw VaultError.identityFileMalformed
    }
}

extension Vault {
    /// Writes `keys/<recipient>.key.age`: the identity, `age-keygen` style,
    /// encrypted to a single scrypt recipient (`age -d` with the passphrase
    /// reads it).
    ///
    /// - Throws: `emptyPassphrase`; `workFactorOutOfRange` outside 15...18;
    ///   `alreadyExists` unless `replace`.
    @discardableResult
    public func writeIdentityFile(_ identity: NativeIdentity, passphrase: String, workFactor: Int = 18,
                                  created: Date = Date(), replace: Bool = false) throws -> URL {
        try requireWritable()
        guard !passphrase.isEmpty else { throw VaultError.emptyPassphrase }
        guard IdentityFile.writerWorkFactors.contains(workFactor) else {
            throw VaultError.workFactorOutOfRange(workFactor)
        }
        let text = IdentityFile.render(identity, created: created)
        let encrypted = try AgeFile.encrypt(Data(text.utf8),
                                            to: [ScryptRecipient(passphrase: passphrase, workFactor: workFactor)])
        try FileIO.createDirectory(keysURL)
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: identity.recipient))
        try FileIO.writeAtomically(encrypted, to: file, replacing: replace)
        return file
    }

    /// `writeIdentityFile` for an X25519 identity.
    @discardableResult
    public func writeIdentityFile(_ identity: X25519Identity, passphrase: String, workFactor: Int = 18,
                                  created: Date = Date(), replace: Bool = false) throws -> URL {
        try writeIdentityFile(.x25519(identity), passphrase: passphrase, workFactor: workFactor, created: created,
                              replace: replace)
    }

    /// Reads `keys/<recipient>.key.age` with `passphrase`.
    ///
    /// - Parameter maxWorkFactor: the reader's scrypt cap, default 20, at
    ///   most 22 (larger values are clamped).
    /// - Throws: `identityFileMissing`, `wrongPassphrase`, `workFactorTooHigh`,
    ///   `identityFileMalformed`, `identityMismatch`.
    public func readIdentityFile(recipient: NativeRecipient, passphrase: String,
                                 maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) throws -> NativeIdentity {
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: recipient))
        guard FileIO.exists(file) else { throw VaultError.identityFileMissing(file.lastPathComponent) }
        let cap = min(max(maxWorkFactor, 1), IdentityFile.maxAllowedWorkFactor)
        let identity = ScryptIdentity(passphrase: passphrase, maxWorkFactor: cap, maxMemoryBytes: 1 << (cap + 10))
        let plain: Data
        do { plain = try AgeFile.decrypt(try FileIO.read(file, maxBytes: BoundedRead.maxSmallFileBytes), with: [identity]) } catch let e as AgeError {
            switch e {
            case .scryptWorkFactor: throw VaultError.workFactorTooHigh
            case .noMatchingIdentity: throw VaultError.wrongPassphrase
            default: throw VaultError.identityFileMalformed
            }
        }
        let id = try IdentityFile.parse(String(decoding: plain, as: UTF8.self))
        guard id.recipient == recipient else { throw VaultError.identityMismatch(recipient.string) }
        return id
    }

    /// Every stored key that `passphrase` opens, post-quantum first: during a
    /// migration the vault lists the classic and the post-quantum key, and
    /// finishing it (`rewrapResume`) may need both (docs/post-quantum.md).
    /// A key file the passphrase does not open is skipped; any other error
    /// (a damaged file, a work factor above the cap) is thrown at once.
    ///
    /// - Parameter recipients: the key files to try; default `identityFiles()`.
    /// - Throws: `wrongPassphrase` when no key file opens (or there is none),
    ///   or what `readIdentityFile` throws besides it.
    public func identitiesFromKeyFiles(passphrase: String, recipients: [NativeRecipient]? = nil,
                                       maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) throws -> [NativeIdentity] {
        var opened: [NativeIdentity] = []
        for recipient in try recipients ?? identityFiles() {
            do {
                opened.append(try readIdentityFile(recipient: recipient, passphrase: passphrase,
                                                   maxWorkFactor: maxWorkFactor))
            } catch VaultError.wrongPassphrase {
                continue
            }
        }
        guard !opened.isEmpty else { throw VaultError.wrongPassphrase }
        // Post-quantum keys first: they are the ones the vault keeps.
        return opened.filter(\.isPostQuantum) + opened.filter { !$0.isPostQuantum }
    }

    /// `readIdentityFile` for an X25519 recipient.
    public func readIdentityFile(recipient: X25519Recipient, passphrase: String,
                                 maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) throws -> NativeIdentity {
        try readIdentityFile(recipient: .x25519(recipient), passphrase: passphrase, maxWorkFactor: maxWorkFactor)
    }

    /// The raw bytes of a `keys/` file (still passphrase-wrapped), for
    /// printing or copying the file as it is.
    ///
    /// - Throws: `identityFileMissing`, `VaultError.io`.
    public func identityFileData(recipient: NativeRecipient) throws -> Data {
        let file = keysURL.appendingPathComponent(IdentityFile.fileName(for: recipient))
        guard FileIO.exists(file) else { throw VaultError.identityFileMissing(file.lastPathComponent) }
        return try FileIO.read(file, maxBytes: BoundedRead.maxSmallFileBytes)
    }

    /// `identityFileData` for an X25519 recipient.
    public func identityFileData(recipient: X25519Recipient) throws -> Data {
        try identityFileData(recipient: .x25519(recipient))
    }

    /// Recipients of this vault (in the manifest) that have a
    /// passphrase-wrapped identity file in `keys/`, found by computing each
    /// recipient's file name (a post-quantum name holds only a hash).
    ///
    /// Key files of recipients no longer listed are left out: after a
    /// migration (`replaceRecipient`) the old X25519 key file stays in
    /// `keys/` (format.md §3.3.2), and offering it would make a passphrase
    /// that opens both files unlock with a key that no longer opens the vault.
    /// `readIdentityFile(recipient:)` still reads such a file when asked.
    ///
    /// - Throws: `VaultError.io` if `keys/` exists but cannot be listed.
    public func identityFiles() throws -> [NativeRecipient] {
        let listed = Dictionary(
            ((try? ageRecipients()) ?? []).map { (IdentityFile.fileName(for: $0), $0) },
            uniquingKeysWith: { a, _ in a })
        return try FileIO.entries(keysURL).compactMap { n in
            if FileIO.isDirectory(keysURL.appendingPathComponent(n)) { return nil }
            return listed[n]
        }
    }
}
