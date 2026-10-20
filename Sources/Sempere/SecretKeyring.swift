import Age
import Crypto
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Secret keyring (docs/design/device-first-sync.md §6.3)
//
// A device-local record, per vault, of every vault secret this device has
// held and when each was replaced. It lets this device verify and rewrap the
// files it wrote under an older secret after a change (R3, the catch-up of a
// device that was away), and set aside, never accept, another device's files
// under one (every key change takes effect at once, decided 2026-10-20). It
// also holds this device's provenance of names (`receivedOwnNames`), whether
// it found itself removed from the vault (`removed`), and a rotation it owes
// (`rotationOwed`). It lives outside the vault, is never synced, and is sealed
// at rest (`KeyringSealer`): the app with a key held in the Keychain, the CLI
// to the device's own age identity. It holds only secrets this device already
// knew, so it reveals nothing new if the device is compromised.

/// The secrets one device held for one vault.
public struct SecretKeyring: Hashable, Sendable, Codable {
    /// The format identifier of the sealed plaintext.
    public static let formatName = "sempere-keyring/1"
    /// The most entries kept (oldest dropped first); a vault rotates its secret once per removal.
    public static let maxEntries = 64

    /// One secret.
    public struct Entry: Hashable, Sendable, Codable {
        /// `secretId` (format.md §2.1) in lowercase hex: names the secret without revealing it.
        public var id: String
        /// The secret, lowercase hex (sealed at rest with the whole keyring).
        var secret: String
        /// When this device first held it.
        public var added: Date
        /// When this device first held a `vault.json` with a later secret
        /// (design R1, K2). Nil while current.
        public var replaced: Date?
        /// True when this device took the list under this secret on the user's confirmation, with no
        /// link from a secret it held (it missed a rotation in between): a copy elsewhere of one of its
        /// own revisions under a secret it never held is then its own file rewrapped there, not a newer one.
        public var confirmedUnlinked: Bool?
    }

    public var format: String
    public var vaultId: UUID
    public var entries: [Entry]
    /// Bumped whenever a sync run rewrote a local file of the vault by a
    /// rewrap (design §5.2, R3): every target's pair then compares its copies
    /// again, so a copy one target settled is carried to the others.
    public var generation: Int?
    /// Names (`<noteId>/<file name>`) of revisions that carry this device's id but came from elsewhere
    /// (a sync download, a late file): this device did not write them. "Own" (R3, rewrap-replace of a
    /// copy under a secret this device missed) is decided from this provenance, never from the name
    /// alone, which a removed device can forge (review round 2).
    public var receivedOwnNames: Set<String>?
    /// When this device found a `vault.json` that no longer lists any of its keys: it stops syncing the
    /// vault (no transfer, ever), keeps its copy readable and offers its unsynced changes for export.
    public var removed: Date?
    /// When `removed`: this device's own files (by provenance) that no target it synced with had recorded,
    /// as `notes/<noteId>/<file name>` or `notes/<noteId>/att/<blob>`: its unsynced changes, for export.
    public var unsynced: Set<String>?
    /// Keys a "keep the other change" dropped under one secret (they still open what was written
    /// meanwhile): the rotation this device owes. Recorded before the adopted `vault.json` is written,
    /// kept here (not in the coordinator's ledger, which a repair sets aside) until the rotation finished.
    public var rotationOwed: [String]?

    public init(vaultId: UUID) {
        format = Self.formatName
        self.vaultId = vaultId
        entries = []
    }

    /// The `secretId` of `secret` (format.md §2.1) in lowercase hex.
    public static func id(of secret: VaultSecret) -> String { Hex.encode(RecipientsAuth.secretId(secret)) }

    /// The entry of `secret`, if held.
    public func entry(for secret: VaultSecret) -> Entry? {
        let id = Self.id(of: secret)
        return entries.first { $0.id == id }
    }

    /// Adds `secret` if it is not held yet.
    public mutating func remember(_ secret: VaultSecret, now: Date) {
        let id = Self.id(of: secret)
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(Entry(id: id, secret: Hex.encode(secret.bytes), added: now))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// Records that `secret` was replaced (the first time only): this device
    /// now holds a `vault.json` with another secret.
    public mutating func noteReplaced(_ secret: VaultSecret, now: Date) {
        remember(secret, now: now)
        let id = Self.id(of: secret)
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].replaced == nil else { return }
        entries[i].replaced = now
    }

    /// Records that this device took `secret`'s list on the user's confirmation without a link (`Entry.confirmedUnlinked`).
    public mutating func noteConfirmedUnlinked(_ secret: VaultSecret) {
        let id = Self.id(of: secret)
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].confirmedUnlinked = true
    }

    /// Every held secret other than `current`, newest replaced first.
    public func secrets(excluding current: VaultSecret) -> [VaultSecret] {
        let currentId = Self.id(of: current)
        return entries.filter { $0.id != currentId }
            .sorted { ($0.replaced ?? .distantFuture) > ($1.replaced ?? .distantFuture) }
            .compactMap { Hex.decode($0.secret).flatMap { try? VaultSecret(bytes: $0) } }
    }

    /// True when `secret` is held and was replaced: a file tagged under it is a late file (another
    /// device's is set aside, never taken in; this device's own is rewrapped, R3).
    public func isReplaced(_ secret: VaultSecret) -> Bool { entry(for: secret)?.replaced != nil }

    /// True when `path` (`<noteId>/<file name>`) carries this device's id but came from elsewhere.
    public func receivedAsOwn(_ path: String) -> Bool { receivedOwnNames?.contains(path) ?? false }

    /// Records that `path`, carrying this device's id, came from elsewhere.
    public mutating func noteReceivedOwn(_ path: String) {
        receivedOwnNames = (receivedOwnNames ?? []).union([path])
    }
}

/// Seals a keyring at rest. Implementations use swift-crypto or age only.
public protocol KeyringSealer: Sendable {
    func seal(_ plaintext: Data, vaultId: UUID) throws -> Data
    func open(_ sealed: Data, vaultId: UUID) throws -> Data
}

/// Errors of the keyring stores.
public enum SecretKeyringError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The sealed file does not open with this device's sealing key, or is not a keyring.
    case unreadable(String)
    /// The keyring names another vault.
    case wrongVault

    public var description: String {
        switch self {
        case .unreadable(let why): return "the secret keyring cannot be read: \(why)"
        case .wrongVault: return "the secret keyring belongs to another vault"
        }
    }
}

/// ChaCha20-Poly1305 under a 256-bit key the platform keeps (the app: a
/// Keychain item, `ThisDeviceOnly`), with the vault id as associated data.
public struct SymmetricKeyringSealer: KeyringSealer {
    let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    static func associatedData(_ vaultId: UUID) -> Data {
        var d = Data(SecretKeyring.formatName.utf8)
        d.append(0)
        d.append(contentsOf: vaultId.uuidString.lowercased().utf8)
        return d
    }

    public func seal(_ plaintext: Data, vaultId: UUID) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key, authenticating: Self.associatedData(vaultId)).combined
    }

    public func open(_ sealed: Data, vaultId: UUID) throws -> Data {
        do {
            return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: sealed), using: key,
                                       authenticating: Self.associatedData(vaultId))
        } catch {
            throw SecretKeyringError.unreadable("\(error)")
        }
    }
}

/// An age file to this device's own identity (the CLI's state directory):
/// only that identity opens it, and the vault id inside is checked on load.
///
/// When the CLI's identity is also a vault key and gets replaced (a key change that replaces this very
/// key), pass both: the keyring opens with either and is sealed again, to every one given, at its next
/// save. Drop the old identity only after that (`SealedFileKeyringStore.reseal`); otherwise the keyring
/// no longer opens, which is reported (`SecretKeyringError.unreadable`) and repaired by
/// `SealedFileKeyringStore.setAside` (its secrets are lost to this device, never guessed).
public struct AgeKeyringSealer: KeyringSealer {
    let identities: [NativeIdentity]

    public init(identity: NativeIdentity) { identities = [identity] }

    /// Opens with any of `identities`, seals to all of them.
    public init(identities: [NativeIdentity]) { self.identities = identities }

    public func seal(_ plaintext: Data, vaultId: UUID) throws -> Data {
        try AgeFile.encrypt(plaintext, to: identities.map(\.recipient))
    }

    public func open(_ sealed: Data, vaultId: UUID) throws -> Data {
        do { return try AgeFile.decrypt(sealed, with: identities) } catch {
            throw SecretKeyringError.unreadable("\(error)")
        }
    }
}

/// Where a device keeps its keyrings, one per vault.
public protocol SecretKeyringStore: Sendable {
    /// The keyring of `vaultId`; nil when there is none yet.
    ///
    /// - Throws: `SecretKeyringError` when one exists and cannot be read
    ///   (never taken as "none": that would forget secrets).
    func load(vaultId: UUID) throws -> SecretKeyring?
    func save(_ keyring: SecretKeyring) throws
    /// Loads (or starts) the keyring of `vaultId`, changes it and saves it when it changed, as one step:
    /// two runs (two targets, the app and the CLI) never lose each other's entries.
    @discardableResult
    func update(vaultId: UUID, _ body: (inout SecretKeyring) throws -> Void) throws -> SecretKeyring
}

extension SecretKeyringStore {
    /// `update` without a lock of its own (stores that serialize otherwise).
    func unlockedUpdate(vaultId: UUID, _ body: (inout SecretKeyring) throws -> Void) throws -> SecretKeyring {
        let old = try load(vaultId: vaultId)
        var ring = old ?? SecretKeyring(vaultId: vaultId)
        try body(&ring)
        if ring != old { try save(ring) }
        return ring
    }
}

/// Keyrings in memory (tests).
public final class MemorySecretKeyringStore: SecretKeyringStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rings: [UUID: SecretKeyring] = [:]

    public init() {}

    public func load(vaultId: UUID) throws -> SecretKeyring? {
        lock.lock(); defer { lock.unlock() }
        return rings[vaultId]
    }

    public func save(_ keyring: SecretKeyring) throws {
        lock.lock(); defer { lock.unlock() }
        rings[keyring.vaultId] = keyring
    }

    private let updates = NSLock()

    @discardableResult
    public func update(vaultId: UUID, _ body: (inout SecretKeyring) throws -> Void) throws -> SecretKeyring {
        updates.lock(); defer { updates.unlock() }
        return try unlockedUpdate(vaultId: vaultId, body)
    }
}

/// Keyrings as sealed files `<directory>/<vaultId>.keyring` (mode 0600 in a
/// 0700 folder), each sealed by `sealer`.
public struct SealedFileKeyringStore: SecretKeyringStore {
    public let directory: URL
    let sealer: any KeyringSealer

    /// The largest sealed keyring read (`SecretKeyring.maxEntries` entries fit many times over).
    static let maxBytes = 1 << 20

    public init(directory: URL, sealer: any KeyringSealer) {
        self.directory = directory
        self.sealer = sealer
    }

    func url(_ vaultId: UUID) -> URL { directory.appendingPathComponent("\(vaultId.uuidString.lowercased()).keyring") }

    public func load(vaultId: UUID) throws -> SecretKeyring? {
        let file = url(vaultId)
        guard FileIO.exists(file) else { return nil }
        let sealed = try BoundedRead.contents(of: file, maxBytes: Self.maxBytes)
        let plain = try sealer.open(sealed, vaultId: vaultId)
        let ring: SecretKeyring
        do {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            ring = try d.decode(SecretKeyring.self, from: plain)
        } catch {
            throw SecretKeyringError.unreadable("not a keyring: \(error)")
        }
        guard ring.format == SecretKeyring.formatName else { throw SecretKeyringError.unreadable("format \(ring.format.prefix(32))") }
        guard ring.vaultId == vaultId else { throw SecretKeyringError.wrongVault }
        return ring
    }

    /// Seals and writes the keyring: a temporary file created 0600 (`O_EXCL`), flushed, renamed into
    /// place, the folder flushed. The bytes never sit in a file anyone else can open.
    public func save(_ keyring: SecretKeyring) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        let sealed = try sealer.seal(try e.encode(keyring), vaultId: keyring.vaultId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = FileIO.tempURL(in: directory)
        do { try FileIO.writeNewFile(tmp) { try $0(sealed) } } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try FileIO.place(tmp, at: url(keyring.vaultId))
    }

    /// One update at a time, across threads of this process and across processes (`flock(2)` on a lock
    /// file beside the keyring).
    @discardableResult
    public func update(vaultId: UUID, _ body: (inout SecretKeyring) throws -> Void) throws -> SecretKeyring {
        try locked(vaultId) { try unlockedUpdate(vaultId: vaultId, body) }
    }

    /// Runs `body` holding the keyring's lock: across threads of this process and across processes.
    func locked<T>(_ vaultId: UUID, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = url(vaultId).path + ".lock"
        let local = KeyringLocks.shared.lock(for: lockPath)
        local.lock(); defer { local.unlock() }
        let fd = lockPath.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw SecretKeyringError.unreadable("lock \(lockPath): errno \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SecretKeyringError.unreadable("lock \(lockPath): errno \(errno)") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Sets an unreadable keyring aside (kept, never deleted: `<id>.keyring.unreadable-<n>`) so sync can
    /// keep a keyring again. The secrets it held are lost to this device: files under them become
    /// invalid here (quarantined, never accepted), never more acceptable. Returns where it went, nil when
    /// the keyring reads fine or there is none.
    @discardableResult
    public func setAside(vaultId: UUID) throws -> URL? {
        try locked(vaultId) {
            let file = url(vaultId)
            guard FileIO.exists(file) else { return nil }
            do { _ = try load(vaultId: vaultId); return nil } catch {}
            let aside = directory.appendingPathComponent(file.lastPathComponent + ".unreadable-\(UUID().uuidString.prefix(8))")
            try FileManager.default.moveItem(at: file, to: aside)
            return aside
        }
    }

    /// Seals the keyring again under the current sealer (after adding an identity to `AgeKeyringSealer`).
    public func reseal(vaultId: UUID) throws {
        try locked(vaultId) {
            guard let ring = try load(vaultId: vaultId) else { return }
            try save(ring)
        }
    }
}

/// One `NSLock` per keyring lock file in this process (`flock` does not exclude threads of one process
/// on every platform).
final class KeyringLocks: @unchecked Sendable {
    static let shared = KeyringLocks()
    private let guardLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        guardLock.lock(); defer { guardLock.unlock() }
        if let l = locks[path] { return l }
        let l = NSLock()
        locks[path] = l
        return l
    }
}
