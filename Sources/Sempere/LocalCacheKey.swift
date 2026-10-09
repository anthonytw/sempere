import Crypto
import Foundation

/// Keys, names and sealing for a per-device cache derived from a vault
/// (format.md §10.1), such as the app's drawing cache. Like the summary cache
/// (`SummaryCache`, §10) it never lives in the vault, and nothing about it is
/// readable or linkable to the vault without the vault secret:
///
/// - the folder name is HKDF-SHA256 of the secret (`"sempere/1 <purpose> name"`);
/// - each entry's file name is HMAC-SHA256 of a caller label (a note id and
///   its revision file names, say) under a third derived key (`entryName`);
/// - each file is `magic ‖ ChaCha20-Poly1305(nonce ‖ ciphertext ‖ tag)` with
///   the magic and the file name as associated data, so a file renamed or
///   copied over another entry fails to open.
///
/// A vault whose secret rotates (§3.3) derives other names: its old entries
/// are never read again.
public struct LocalCacheKey: Sendable {
    /// Lowercase hex of the 16-byte derived name: the cache's folder name.
    public let name: String
    private let key: Data
    private let entryKey: Data
    private let magic: [UInt8]

    static let nonceSize = 12, tagSize = 16

    /// The keys of `purpose` (a short ASCII word, e.g. `drawing-cache`) for
    /// `vault`; files start with `magic`.
    ///
    /// - Throws: `VaultError.locked` when the vault secret is not known.
    public init(vault: Vault, purpose: String, magic: [UInt8]) throws {
        self.init(secret: try vault.requireSecret(), purpose: purpose, magic: magic)
    }

    init(secret: VaultSecret, purpose: String, magic: [UInt8]) {
        // Purposes are constants of the caller: a reserved one is a bug, and
        // would hand a cache the key of a vault-wide use (format.md §10.1).
        precondition(Self.isUsablePurpose(purpose), "reserved or malformed cache purpose: \(purpose)")
        key = Self.derive(secret, "sempere/1 \(purpose) key", 32)
        entryKey = Self.derive(secret, "sempere/1 \(purpose) entry", 32)
        name = Hex.encode(Self.derive(secret, "sempere/1 \(purpose) name", 16))
        self.magic = magic
    }

    /// Words whose `"sempere/1 <word> key"` (or `name`) is a vault-wide key
    /// of format.md: the summary cache (§10), authenticated recipients (§2.1)
    /// and captures (§11.1). No cache may use them.
    static let reservedPurposes: Set<String> = ["summary-cache", "recipients", "capture"]

    /// True when `purpose` is lowercase ASCII letters and digits in
    /// hyphen-separated words (so no info string of §2.1, which hold spaces,
    /// can be formed) and not a reserved word (format.md §10.1).
    static func isUsablePurpose(_ purpose: String) -> Bool {
        let words = purpose.split(separator: "-", omittingEmptySubsequences: false)
        guard purpose.utf8.count <= 64, !reservedPurposes.contains(purpose) else { return false }
        return words.allSatisfy { w in
            !w.isEmpty && w.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
        }
    }

    static func derive(_ secret: VaultSecret, _ info: String, _ bytes: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.key, info: Data(info.utf8), outputByteCount: bytes)
            .withUnsafeBytes { Data($0) }
    }

    /// Lowercase hex SHA-256 of `text` (UTF-8): a stable name for a
    /// non-secret value (a vault id) that does not show the value itself.
    public static func digestHex(_ text: String) -> String {
        FileDigest.sha256(Data(text.utf8))
    }

    /// A file name stem for `label`: lowercase hex of the first 16 bytes of
    /// HMAC-SHA256(entry key, label). Equal labels give equal names; the name
    /// says nothing about the label without the vault secret.
    public func entryName(_ label: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: entryKey))
        return Hex.encode(Data(mac).prefix(16))
    }

    /// Encrypts `plain` for the file named `fileName`.
    public func seal(_ plain: Data, fileName: String) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(),
                                      authenticating: aad(fileName))
        return Data(magic) + box.combined
    }

    /// Decrypts a file sealed for `fileName`.
    ///
    /// - Throws: `LocalCacheError.damaged` when it is not such a file, was
    ///   sealed for another name or key, or was changed.
    public func open(_ data: Data, fileName: String) throws -> Data {
        guard data.count >= magic.count + Self.nonceSize + Self.tagSize,
              data.prefix(magic.count).elementsEqual(magic) else {
            throw LocalCacheError.damaged("not a cache file")
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(magic.count))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad(fileName))
        } catch {
            throw LocalCacheError.damaged("does not authenticate")
        }
    }

    private func aad(_ fileName: String) -> Data { Data(magic) + Data(fileName.utf8) }
}

/// Why a local cache file was ignored.
public enum LocalCacheError: Error, Hashable, Sendable {
    case damaged(String)
}
