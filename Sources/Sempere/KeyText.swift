import Age
import Foundation

/// What someone gives as "an existing key": pasted text or a picked file.
/// It must be a post-quantum secret key, `AGE-SECRET-KEY-PQ-1…`, alone or in
/// `age-keygen -pq` output (comments, `Public key:` lines, CRLF, stray
/// whitespace are fine), or a passphrase-wrapped key file (`keys/*.key.age`
/// of a vault, `age -p` of such a file; binary or ASCII-armored), which
/// `unwrap` opens with its passphrase.
///
/// Everything else is refused with what it looks like: a public key
/// (`age1pq1…`, which only encrypts to the key), a classic X25519 key
/// (`AGE-SECRET-KEY-1…` / `age1…`: vaults take only post-quantum keys,
/// format.md §3.1), a file encrypted to a key rather than a passphrase. The
/// text is never echoed back except a public key, abbreviated.
///
/// The app's New Vault sheet ("Use an existing key") and the CLI's identity
/// files (`--store-key`, `keys show`) share it.
public enum KeyText {
    /// Larger input is refused before it is read: a key file is a few kilobytes.
    public static let maximumBytes = 64 * 1024

    /// A usable key, or a file that needs its passphrase.
    public enum Content: Sendable {
        case identity(NativeIdentity)
        /// An age file encrypted to a passphrase (an scrypt stanza).
        case passphraseWrapped(Data)
    }

    /// Why the input is not a usable key, naming what it looks like.
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        /// Over `maximumBytes` (the size, in bytes).
        case tooLarge(Int)
        /// A post-quantum public key (`age1pq1…`, abbreviated): it encrypts to the key, it cannot open anything.
        case publicKey(String)
        /// A classic X25519 public key (`age1…`).
        case classicPublicKey(String)
        /// A classic X25519 secret key (`AGE-SECRET-KEY-1…`).
        case classicSecretKey
        /// Starts like a post-quantum secret key but does not decode (cut short, mistyped).
        case damagedSecretKey
        /// The `# public key:` / `Public key:` line names another key than the secret key.
        case mismatchedPublicKey(String)
        /// More than one different secret key (the count).
        case severalSecretKeys(Int)
        /// An age file encrypted to keys, not to a passphrase.
        case encryptedToKeys
        /// An age file that cannot be read.
        case damagedFile
        /// The passphrase does not open the wrapped key file.
        case wrongPassphrase
        /// The wrapped key file needs more scrypt work than readers allow.
        case workFactorTooHigh
        /// This platform has no ML-KEM (Apple OSes before 26).
        case postQuantumUnavailable
        /// Nothing that looks like a key.
        case notAKey

        public var description: String {
            switch self {
            case .empty: return "no key given"
            case .tooLarge(let bytes): return "that is \(bytes) bytes, too large for a key (at most \(KeyText.maximumBytes))"
            case .publicKey(let key):
                return "\(key) is a public key (age1pq1…): it can only encrypt to the key. Give the secret key, "
                    + "AGE-SECRET-KEY-PQ-1…, or its passphrase-wrapped key file"
            case .classicPublicKey(let key):
                return "\(key) is a classic X25519 public key; vaults take only post-quantum keys "
                    + "(AGE-SECRET-KEY-PQ-1…, from age-keygen -pq or sempere keys generate)"
            case .classicSecretKey:
                return "that is a classic X25519 secret key (AGE-SECRET-KEY-1…); vaults take only post-quantum keys "
                    + "(AGE-SECRET-KEY-PQ-1…, from age-keygen -pq or sempere keys generate)"
            case .damagedSecretKey: return "the AGE-SECRET-KEY-PQ-1… key is damaged or incomplete; copy all of it"
            case .mismatchedPublicKey(let key): return "the public key line (\(key)) does not belong to the secret key"
            case .severalSecretKeys(let count): return "that holds \(count) different secret keys; give one"
            case .encryptedToKeys: return "that age file is encrypted to keys, not to a passphrase"
            case .damagedFile: return "that age file is damaged"
            case .wrongPassphrase: return "the passphrase does not open that key file"
            case .workFactorTooHigh: return "that key file needs more scrypt work than allowed"
            case .postQuantumUnavailable: return "\(AgeError.postQuantumUnavailable)"
            case .notAKey:
                return "that is not an age key: give a secret key, AGE-SECRET-KEY-PQ-1…, or a passphrase-wrapped key file"
            }
        }
    }

    /// Reads a picked file or pasted bytes.
    public static func classify(_ data: Data) -> Result<Content, Problem> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge(data.count)) }
        if Armor.isArmored(data) || data.starts(with: Data(binaryPrefix.utf8)) { return classifyAgeFile(data) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notAKey) }
        return classify(text)
    }

    /// Reads pasted text.
    public static func classify(_ text: String) -> Result<Content, Problem> {
        let size = text.utf8.count
        guard size <= maximumBytes else { return .failure(.tooLarge(size)) }
        let data = Data(text.utf8)
        if Armor.isArmored(data) { return classifyAgeFile(data) }

        var secrets: [String] = [], classicSecrets = 0, damaged = false
        var publicKeys: [String] = [], classicPublicKeys: [String] = []
        var declared: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: ignorable)
            if line.isEmpty { continue }
            let comment = line.hasPrefix("#")
            for token in line.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "," || $0 == ";" }) {
                let word = String(token).trimmingCharacters(in: ignorable.union(CharacterSet(charactersIn: "\"'`")))
                let upper = word.uppercased()
                if upper.hasPrefix("AGE-SECRET-KEY-PQ-1") {
                    if comment { continue }
                    do {
                        _ = try NativeIdentity(string: upper)
                        secrets.append(upper)
                    } catch AgeError.postQuantumUnavailable {
                        return .failure(.postQuantumUnavailable)
                    } catch {
                        damaged = true
                    }
                } else if upper.hasPrefix("AGE-SECRET-KEY-1") {
                    if !comment { classicSecrets += 1 }
                } else if word.lowercased().hasPrefix("age1pq1") {
                    publicKeys.append(word)
                    if line.lowercased().contains("public key") { declared = word }
                } else if word.lowercased().hasPrefix("age1") {
                    classicPublicKeys.append(word)
                }
            }
        }
        let distinct = Array(Set(secrets))
        if distinct.count > 1 { return .failure(.severalSecretKeys(distinct.count)) }
        if let secret = distinct.first {
            let identity: NativeIdentity
            do { identity = try NativeIdentity(string: secret) } catch AgeError.postQuantumUnavailable {
                return .failure(.postQuantumUnavailable)
            } catch {
                return .failure(.damagedSecretKey)
            }
            if let declared, declared != identity.recipient.string {
                return .failure(.mismatchedPublicKey(RecipientsProblem.abbreviate(declared)))
            }
            return .success(.identity(identity))
        }
        if damaged { return .failure(.damagedSecretKey) }
        if classicSecrets > 0 { return .failure(.classicSecretKey) }
        if let key = publicKeys.first { return .failure(.publicKey(RecipientsProblem.abbreviate(key))) }
        if let key = classicPublicKeys.first { return .failure(.classicPublicKey(RecipientsProblem.abbreviate(key))) }
        return .failure(size == 0 || text.trimmingCharacters(in: ignorable).isEmpty ? .empty : .notAKey)
    }

    /// The identity in a passphrase-wrapped key file (`classify`'s
    /// `.passphraseWrapped`), with the same checks as pasted text.
    ///
    /// - Parameter maxWorkFactor: the scrypt cap, as for a vault's key files.
    public static func unwrap(_ data: Data, passphrase: String,
                              maxWorkFactor: Int = IdentityFile.defaultMaxWorkFactor) -> Result<NativeIdentity, Problem> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge(data.count)) }
        guard !passphrase.isEmpty else { return .failure(.wrongPassphrase) }
        let cap = min(max(maxWorkFactor, 1), IdentityFile.maxAllowedWorkFactor)
        let identity = ScryptIdentity(passphrase: passphrase, maxWorkFactor: cap, maxMemoryBytes: 1 << (cap + 10))
        let plain: Data
        do { plain = try AgeFile.decrypt(data, with: [identity]) } catch let error as AgeError {
            switch error {
            case .noMatchingIdentity: return .failure(.wrongPassphrase)
            case .scryptWorkFactor: return .failure(.workFactorTooHigh)
            default: return .failure(.damagedFile)
            }
        } catch {
            return .failure(.damagedFile)
        }
        switch classify(plain) {
        case .success(.identity(let id)): return .success(id)
        case .success(.passphraseWrapped): return .failure(.damagedFile)
        case .failure(let problem): return .failure(problem)
        }
    }

    // MARK: - Private

    private static let binaryPrefix = "age-encryption.org/v1\n"

    /// Whitespace, plus what copying from web pages and editors adds (BOM, zero-width and no-break spaces).
    private static let ignorable = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}\u{00A0}"))

    private static func classifyAgeFile(_ data: Data) -> Result<Content, Problem> {
        let binary: Data
        if Armor.isArmored(data) {
            guard let decoded = try? Armor.decode(data) else { return .failure(.damagedFile) }
            binary = decoded
        } else {
            binary = data
        }
        guard let header = try? AgeFile.parseHeader(binary).header else { return .failure(.damagedFile) }
        guard header.stanzas.contains(where: { $0.type == "scrypt" }) else { return .failure(.encryptedToKeys) }
        return .success(.passphraseWrapped(binary))
    }
}
