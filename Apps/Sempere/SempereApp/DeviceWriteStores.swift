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
                                 key: { try LedgerKeychain.key(unsignedFallback: fallback) })
    }

    /// Stores under `root` with a fixed key (tests).
    static func inMemoryKey(root: URL) -> DeviceWriteStores {
        let key = LedgerKeychain.randomKey()
        return DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger", isDirectory: true),
                                 setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside", isDirectory: true)),
                                 key: { key })
    }
}

/// The write ledger's key (design §5.4): 32 random bytes in one generic-password item, readable after the
/// first unlock and on this device only, never synchronized. Made on first use.
enum LedgerKeychain {
    static let service = "io.github.anthonytw.sempere.write-ledger"
    static let account = "key"

    enum Failure: Error, Equatable {
        case status(OSStatus)
        case badKey
        /// The ledger holds records but its key is gone: a new key would orphan them. Fails closed.
        case keyLostForExistingLedger
    }

    private static let lock = NSLock()

    /// The key, made and stored when there is none and no ledger exists yet under `ledgerDirectory`.
    ///
    /// Release builds use the Keychain only and fail closed on any error (review S1). DEBUG builds (CI, the test
    /// hosts, ad-hoc signed UI-test runs, which have no Keychain entitlement) keep it in `unsignedFallback`
    /// (mode 0600) instead; once one of the two holds a key, that one is used and the other is never minted.
    static func key(unsignedFallback: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        if let data = try? BoundedRead.contents(of: unsignedFallback, maxBytes: 64), data.count == 32 { return data }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &out)
        if status == errSecSuccess {
            guard let data = out as? Data, data.count == 32 else { throw Failure.badKey }
            return data
        }
        #if DEBUG
        if status == errSecMissingEntitlement { return try fileKey(unsignedFallback) }
        #endif
        guard status == errSecItemNotFound else { throw Failure.status(status) }
        // A ledger that already holds records was sealed with a key this Keychain no longer has: never mint a new
        // one over it (it would orphan every entry); the ledger stays unreadable and writes fail closed.
        if hasLedgerData(unsignedFallback.deletingLastPathComponent()) { throw Failure.keyLostForExistingLedger }
        let bytes = randomKey()
        var add = query
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Sempere — write ledger"
        let added = SecItemAdd(add as CFDictionary, nil)
        #if DEBUG
        if added == errSecMissingEntitlement { return try fileKey(unsignedFallback) }
        #endif
        guard added == errSecSuccess else { throw Failure.status(added) }
        return bytes
    }

    /// True when any vault's ledger folder under `directory` holds a log or a state file.
    static func hasLedgerData(_ directory: URL) -> Bool {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where UUID(uuidString: name) != nil {
            let folder = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: folder.appendingPathComponent("log").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("state").path) { return true }
        }
        return false
    }

    /// 32 bytes from the system's secure generator.
    static func randomKey() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    #if DEBUG
    private static func fileKey(_ url: URL) throws -> Data {
        if hasLedgerData(url.deletingLastPathComponent()) { throw Failure.keyLostForExistingLedger }
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
