import Foundation
import Security
import Sempere

/// This device's write ledger and set-aside store for each vault (key-hierarchy design §5.4, §5.8; phase KH3).
/// Both live in the App Group container next to the in-app vault store (`VaultStoreRoot`), so quick capture
/// can record a voice note while the device is locked; the ledger is sealed with one key in a this-device-only
/// Keychain item of class `AfterFirstUnlockThisDeviceOnly` (`LedgerKeychain`). Tests pass none (no ledger:
/// nothing is recorded or caught up) or one with a key in memory.
struct DeviceWriteStores: Sendable {
    /// `<…>/Ledger/<vault id>/` per vault (`FileWriteLedger`).
    let ledgerDirectory: URL
    let setAside: SetAsideStore
    let key: @Sendable () throws -> Data

    /// The ledger of `vaultId`.
    func ledger(for vaultId: UUID) -> FileWriteLedger {
        FileWriteLedger(directory: ledgerDirectory, vaultId: vaultId, keyBytes: key)
    }

    /// The app's: folders beside the vault store's `Vaults` folder, the key in the Keychain.
    static func app(storeRoot: URL) -> DeviceWriteStores {
        let base = storeRoot.deletingLastPathComponent()
        let ledger = base.appendingPathComponent("Ledger", isDirectory: true)
        let fallback = ledger.appendingPathComponent(".unsigned-build-key")
        return DeviceWriteStores(ledgerDirectory: ledger,
                                 setAside: SetAsideStore(directory: base.appendingPathComponent("SetAside", isDirectory: true)),
                                 key: { try LedgerKeychain.key(items: KeychainLedgerKeyItems(), ledgerDirectory: ledger,
                                                               unsignedFallback: fallback) })
    }

    /// Stores under `root` with a fixed key (tests).
    static func inMemoryKey(root: URL) -> DeviceWriteStores {
        let key = LedgerKeychain.randomKey()
        return DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger", isDirectory: true),
                                 setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside", isDirectory: true)),
                                 key: { key })
    }
}

/// Where the ledger key is kept: the Keychain in the app, memory in tests.
protocol LedgerKeyItems: Sendable {
    /// The stored key, nil when there is none. Throws when the store cannot be read (the device locked before its
    /// first unlock, any other error): the ledger then fails closed and nothing is made or moved.
    func read() throws -> Data?
    func add(_ key: Data) throws
}

/// The Keychain item: a generic password, `AfterFirstUnlockThisDeviceOnly`, never synchronized.
struct KeychainLedgerKeyItems: LedgerKeyItems {
    static let service = "io.github.anthonytw.sempere.write-ledger"
    static let account = "key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read() throws -> Data? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        if status == errSecMissingEntitlement { throw LedgerKeychain.Failure.missingEntitlement }
        guard status == errSecSuccess, let data = out as? Data else { throw LedgerKeychain.Failure.status(status) }
        return data
    }

    func add(_ key: Data) throws {
        var add = query
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Sempere — write ledger"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw LedgerKeychain.Failure.missingEntitlement }
        guard status == errSecSuccess else { throw LedgerKeychain.Failure.status(status) }
    }
}

/// `LedgerKeyItems` in memory (tests): `failRead` stands for a store that cannot be read.
final class MemoryLedgerKeyItems: LedgerKeyItems, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    var failRead = false
    init(key: Data? = nil) { self.key = key }
    func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failRead { throw LedgerKeychain.Failure.status(errSecInteractionNotAllowed) }
        return key
    }
    func add(_ key: Data) throws { lock.lock(); self.key = key; lock.unlock() }
}

/// The write ledger's key (design §5.4): 32 random bytes in one this-device-only item, made on first use.
enum LedgerKeychain {
    enum Failure: Error, Equatable {
        case status(OSStatus)
        case badKey
        case missingEntitlement
    }

    private static let lock = NSLock()

    /// The key. When the store holds none, it is made; ledgers already under `ledgerDirectory` were sealed with a
    /// key this device does not have (a backup restored onto another device, or a migration: the item is
    /// this-device-only), so they are moved aside first, kept, never deleted, and the device starts a fresh
    /// ledger, as design §5.4 "Restores" says (review R2). A store that cannot be read fails closed: nothing is
    /// moved or made.
    ///
    /// Release builds use `items` only (review S1). DEBUG builds without the Keychain entitlement (CI, the test
    /// hosts, ad-hoc signed UI-test runs) keep the key in `unsignedFallback` (mode 0600) instead; once that file
    /// exists it is used, and the Keychain is never minted for it.
    static func key(items: any LedgerKeyItems, ledgerDirectory: URL, unsignedFallback: URL, now: Date = Date()) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        if let data = try? BoundedRead.contents(of: unsignedFallback, maxBytes: 64), data.count == 32 { return data }
        #endif
        do {
            if let data = try items.read() {
                guard data.count == 32 else { throw Failure.badKey }
                return data
            }
        } catch Failure.missingEntitlement {
            #if DEBUG
            return try fileKey(unsignedFallback, ledgerDirectory: ledgerDirectory, now: now)
            #else
            throw Failure.missingEntitlement
            #endif
        }
        try moveOrphanedLedgersAside(ledgerDirectory, now: now)
        let bytes = randomKey()
        do { try items.add(bytes) } catch Failure.missingEntitlement {
            #if DEBUG
            return try fileKey(unsignedFallback, ledgerDirectory: ledgerDirectory, now: now)
            #else
            throw Failure.missingEntitlement
            #endif
        }
        return bytes
    }

    /// Moves every vault's ledger folder under `directory` into `directory/.orphaned-<time>/` (kept for
    /// diagnostics, never read again): they were sealed with a key this device no longer has.
    static func moveOrphanedLedgersAside(_ directory: URL, now: Date) throws {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { UUID(uuidString: $0) != nil }
        guard !names.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let aside = directory.appendingPathComponent(".orphaned-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in names {
            try fm.moveItem(at: directory.appendingPathComponent(name), to: aside.appendingPathComponent(name))
        }
    }

    /// 32 bytes from the system's secure generator.
    static func randomKey() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    #if DEBUG
    private static func fileKey(_ url: URL, ledgerDirectory: URL, now: Date) throws -> Data {
        try moveOrphanedLedgersAside(ledgerDirectory, now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = randomKey()
        do { try bytes.write(to: url, options: [.withoutOverwriting]) } catch {
            // Another writer made it first.
            if let data = try? BoundedRead.contents(of: url, maxBytes: 64), data.count == 32 { return data }
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return bytes
    }
    #endif
}
