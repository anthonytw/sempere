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
/// Vaults use MLKEM768-X25519 identities (`AGE-SECRET-KEY-PQ-1...`,
/// `age-keygen -pq`). `parse` also reads a classic X25519 one
/// (`AGE-SECRET-KEY-1...`, `age-keygen`), so that it can be refused with a
/// clear error (`VaultError.classicIdentity`, `classicRecipient`).
public enum IdentityFile {
    /// Writers use scrypt work factors in this range (format.md §3.2).
    public static let writerWorkFactors = 15...18
    /// Readers accept up to 20 by default.
    public static let defaultMaxWorkFactor = 20
    /// The largest cap a reader may choose (format.md §3.2: "may accept up to 22").
    public static let maxAllowedWorkFactor = 22

    private static let suffix = ".key.age"
    private static let pqPrefix = "age1pq-"

    /// The `keys/` file name (format.md §3.2):
    /// `age1pq-<SHA-256 of the recipient string, hex>.key.age`, since a
    /// post-quantum recipient's 1959-character string is too long for a file
    /// name. The name holds only a hash; see `Vault.identityFiles()`.
    public static func fileName(for recipient: NativeRecipient) -> String {
        pqPrefix + FileDigest.sha256(Data(recipient.string.utf8)) + suffix
    }

    /// True for a `keys/` file name (`fileName(for:)`'s form).
    public static func isKeyFileName(_ name: String) -> Bool {
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
    /// - Throws: `classicRecipient` for a classic X25519 identity (vaults
    ///   take only post-quantum keys, format.md §3.1); `emptyPassphrase`;
    ///   `workFactorOutOfRange` outside 15...18; `alreadyExists` unless `replace`.
    @discardableResult
    public func writeIdentityFile(_ identity: NativeIdentity, passphrase: String, workFactor: Int = 18,
                                  created: Date = Date(), replace: Bool = false) throws -> URL {
        try requireWritable()
        guard identity.isPostQuantum else { throw VaultError.classicRecipient(identity.recipient.string) }
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

    /// Every stored key that `passphrase` opens: finishing an interrupted key
    /// replacement (`resumeRewrap`) may need the old and the new key.
    /// A key file the passphrase does not open is skipped; any other error
    /// (a damaged file, a work factor above the cap) is thrown at once.
    ///
    /// - Parameter recipients: the key files to try; default `identityFiles()`
    ///   and, while a recipient change is unfinished (`pendingRewrap`), after
    ///   them every other `keys/` file the passphrase opens (the old key of a
    ///   replacement is no longer listed, and the files not yet rewrapped are
    ///   encrypted only to it). Those are only used to decrypt: one that does
    ///   not open, or cannot be read, is skipped.
    /// - Throws: `wrongPassphrase` when no key file opens (or there is none),
    ///   or what `readIdentityFile` throws besides it.
    public func identitiesFromKeyFiles(passphrase: String, recipients: [NativeRecipient]? = nil,
                                       maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) throws -> [NativeIdentity] {
        var opened: [NativeIdentity] = []
        let listed = try recipients ?? identityFiles()
        for recipient in listed {
            do {
                opened.append(try readIdentityFile(recipient: recipient, passphrase: passphrase,
                                                   maxWorkFactor: maxWorkFactor))
            } catch VaultError.wrongPassphrase {
                continue
            }
        }
        if recipients == nil, pendingRewrap {
            let tried = Set(listed.map(IdentityFile.fileName(for:)))
            for name in (try? FileIO.entries(keysURL)) ?? [] where IdentityFile.isKeyFileName(name) && !tried.contains(name) {
                if let id = try? readUnlistedIdentityFile(named: name, passphrase: passphrase, maxWorkFactor: maxWorkFactor) {
                    opened.append(id)
                }
            }
        }
        guard !opened.isEmpty else { throw VaultError.wrongPassphrase }
        return opened
    }

    /// The identity in `keys/<name>`, a recipient not listed in `vault.json`:
    /// read like `readIdentityFile`, and kept only when the file is the one
    /// named for the key it holds.
    private func readUnlistedIdentityFile(named name: String, passphrase: String, maxWorkFactor: Int) throws -> NativeIdentity {
        let file = keysURL.appendingPathComponent(name)
        let cap = min(max(maxWorkFactor, 1), IdentityFile.maxAllowedWorkFactor)
        let identity = ScryptIdentity(passphrase: passphrase, maxWorkFactor: cap, maxMemoryBytes: 1 << (cap + 10))
        let plain = try AgeFile.decrypt(try FileIO.read(file, maxBytes: BoundedRead.maxSmallFileBytes), with: [identity])
        let id = try IdentityFile.parse(String(decoding: plain, as: UTF8.self))
        guard IdentityFile.fileName(for: id.recipient) == name else { throw VaultError.identityMismatch(id.recipient.string) }
        return id
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

    /// Recipients of this vault (in the manifest) that have a
    /// passphrase-wrapped identity file in `keys/`, found by computing each
    /// recipient's file name (a post-quantum name holds only a hash).
    ///
    /// Key files of recipients no longer listed are left out: after
    /// `replaceRecipient` the old key file stays in `keys/`, and offering it
    /// would make a passphrase that opens both files unlock with a key that
    /// no longer opens the vault. `readIdentityFile(recipient:)` still reads
    /// such a file when asked.
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
