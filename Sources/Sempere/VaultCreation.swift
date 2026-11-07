import Age
import Foundation

/// Making a new vault (key-hierarchy design §8): the one implementation behind the app's New Vault
/// (`VaultLibrary.create`) and the CLI's `vault init` and `store create`.
///
/// The keys are chosen first (`Keys`), so a caller can keep them before the vault exists: the app
/// stores this device's keys in the Keychain under `Keys.vaultId`, the CLI writes its device key file
/// and the new recovery key's file. Then `create(at:…)` writes the vault, or `create(in:name:…)`
/// builds it in a store's staging folder (`VaultStore.create`), where it appears only complete.
public enum VaultCreation {
    /// Where the vault's recovery key comes from.
    public enum RecoverySource: Sendable {
        /// Generate a post-quantum MLKEM768-X25519 recovery key, which the caller shows or writes once:
        /// no device keeps it (docs/post-quantum.md).
        case generate
        /// Use a post-quantum secret key the user already has.
        case identity(NativeIdentity)
    }

    public enum CreationError: Error, Equatable, Sendable {
        /// The given recovery key is a classic `AGE-SECRET-KEY-1…` key, which is not quantum-safe.
        case classicRecoveryKey
    }

    /// The keys a new vault is made with, chosen before anything is written.
    public struct Keys: Sendable {
        public var recovery: MLKEM768X25519Identity
        /// Whether `recovery` was generated here (the caller must hand it to the user).
        public var recoveryGenerated: Bool
        /// This device's keys: the vault's home.
        public var device: DeviceKeys
        /// The new vault's id.
        public var vaultId: UUID

        /// - Parameters:
        ///   - recovery: generate a recovery key, or use the given one (post-quantum only).
        ///   - device: this device's keys; nil makes software keys (`DeviceKeys.generate`).
        /// - Throws: `CreationError.classicRecoveryKey` for a classic identity.
        public init(recovery source: RecoverySource, device: DeviceKeys? = nil, vaultId: UUID = UUID()) throws {
            switch source {
            case .generate:
                recovery = try MLKEM768X25519Identity()
                recoveryGenerated = true
            case .identity(let identity):
                guard case .mlkem768x25519(let pq) = identity else { throw CreationError.classicRecoveryKey }
                recovery = pq
                recoveryGenerated = false
            }
            self.device = try device ?? DeviceKeys.generate()
            self.vaultId = vaultId
        }

        /// The recovery key as an identity (for its file, the kit and the app's Save to Files).
        public var recoveryIdentity: NativeIdentity { .mlkem768x25519(recovery) }
    }

    /// Everything a new vault is made with besides its keys.
    public struct Options: Sendable {
        /// This device's name and kind in the vault's list (format.md §15.3).
        public var deviceName: String
        public var deviceKind: String
        /// Also keep a copy of the recovery key in `keys/` under this passphrase (format.md §15.11); nil for
        /// none. An empty one is refused (`VaultError.emptyPassphrase`).
        public var recoveryPassphrase: String?
        /// The passphrase copy's scrypt work factor: writers use 20; tests less.
        public var workFactor: Int
        /// The vault's display name (`vault.json` label, stored unencrypted).
        public var label: String?

        public init(deviceName: String, deviceKind: String, recoveryPassphrase: String? = nil,
                    workFactor: Int = RecoveryPassphraseCopy.workFactor, label: String? = nil) {
            self.deviceName = deviceName
            self.deviceKind = deviceKind
            self.recoveryPassphrase = recoveryPassphrase
            self.workFactor = workFactor
            self.label = label
        }
    }

    /// Writes a new vault at `url` (a folder named `….sempere`, which must not hold a vault already).
    ///
    /// - Parameter trust: this device's trust records; the new vault's is saved there (format.md §15.10).
    public static func create(at url: URL, keys: Keys, options: Options,
                              trust: (any EpochTrustStore)? = nil) throws -> Vault {
        try Vault.create(at: url, device: keys.device, deviceName: options.deviceName, kind: options.deviceKind,
                         recovery: keys.recovery, recoveryPassphrase: options.recoveryPassphrase,
                         workFactor: options.workFactor, vaultId: keys.vaultId, trust: trust, label: options.label)
    }

    /// Builds a new vault called `name` in `store` (`VaultStore.create`: in its staging folder, checked,
    /// then moved in with one `rename`). The returned `Vault` was opened at the staging path: read its
    /// id, root and passphrase copies, never its files; the entry names where it is now.
    ///
    /// - Throws: `VaultStoreError.invalidName` for a name `VaultStore.folderName` refuses, before anything
    ///   is written; else what `create(at:…)` throws.
    public static func create(in store: VaultStore, name: String, keys: Keys, options: Options,
                              trust: (any EpochTrustStore)? = nil) throws -> (entry: VaultStore.Entry, vault: Vault) {
        let (entry, vault) = try store.create(name: name) { url in
            try create(at: url, keys: keys, options: options, trust: trust)
        }
        return (entry, vault)
    }
}
