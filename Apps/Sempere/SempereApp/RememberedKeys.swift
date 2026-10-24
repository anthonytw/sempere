import Age
import Foundation
import LocalAuthentication
import Observation
import Sempere

/// The keys this device keeps per vault (key-hierarchy design §6.1; KH5): its own device keys, in the Keychain
/// with the signing pair in the Secure Enclave (`DeviceKeyStore`). It unlocks a vault with them when it opens
/// (Face ID first when the vault asks for it), tracks a join of this device in progress (`joinStage`), and holds
/// the vault's "Require Face ID" setting. The recovery key is never kept: it opens a vault read-only, or signs a
/// takeover and is dropped.
///
/// Kept apart from `AppModel` (it calls the model), so tests give it a `MemoryDeviceKeyStore`.
@MainActor
@Observable
final class RememberedKeys {
    /// How an attempt to unlock with this device's keys ended.
    enum Attempt: Equatable {
        case unlocked
        /// This device has no keys for the vault.
        case noKey
        /// This device has keys and is joining: the join screen shows where it stands (`joinStage`).
        case joining
        /// The user canceled Face ID, or the vault changed meanwhile.
        case cancelled
        /// The keys could not be read, or did not open the vault.
        case failed(String)
    }

    let store: any DeviceKeyStore
    /// The open vault has keys on this device (`refresh`).
    private(set) var hasKeysVaultID: UUID?
    /// "Require Face ID to open this vault" for the open vault.
    private(set) var requiresBiometry = false
    /// While the open, locked vault is being joined by this device: where it stands.
    var joinStage: JoinStage?
    /// True while Face ID / the Keychain is being asked.
    private(set) var isUnlocking = false
    /// True while an unlock with a passphrase or pasted key runs.
    private(set) var isManualUnlocking = false

    init(store: any DeviceKeyStore = KeychainDeviceKeyStore()) {
        self.store = store
    }

    /// "this iPad", "this iPhone", or "this Mac" under Mac Catalyst.
    @MainActor static var deviceName: String {
        name(isMac: ProcessInfo.processInfo.isMacCatalystApp, isPhone: Platform.isPhone)
    }

    nonisolated static func name(isMac: Bool, isPhone: Bool) -> String {
        if isMac { return String(localized: "this Mac", comment: "Device phrase inside sentences: “Saved on this Mac”") }
        return isPhone
            ? String(localized: "this iPhone", comment: "Device phrase inside sentences: “Saved on this iPhone”")
            : String(localized: "this iPad", comment: "Device phrase inside sentences: “Saved on this iPad”")
    }

    /// The device's biometry ("Face ID", "Touch ID", "Optic ID") when one is enrolled.
    static var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// Whether this device has keys for the open vault (as of the last `refresh`).
    func hasKeys(for model: AppModel) -> Bool {
        guard let id = model.vault?.vaultId else { return false }
        return hasKeysVaultID == id
    }

    /// Looks up, without reading or prompting, whether this device has keys for the open vault.
    func refresh(_ model: AppModel) async {
        guard let id = model.vault?.vaultId else { return }
        let has = await store.hasKeys(for: id)
        let biometry = has ? await store.requiresBiometry(for: id) : false
        guard model.vault?.vaultId == id else { return }
        hasKeysVaultID = has ? id : (hasKeysVaultID == id ? nil : hasKeysVaultID)
        requiresBiometry = biometry
    }

    // MARK: - Unlocking

    /// Unlocks the locked vault with this device's keys; a device that is joining gets its join stage instead.
    func unlockWithDeviceKey(_ model: AppModel) async -> Attempt {
        guard model.phase == .locked, let vault = model.vault, !isUnlocking else { return .cancelled }
        let id = vault.vaultId
        let gen = model.generation
        isUnlocking = true
        defer { isUnlocking = false }
        let reason = model.vaultName.map { String(localized: "Unlock “\($0)”", comment: "Face ID prompt") }
            ?? String(localized: "Unlock the vault", comment: "Face ID prompt")
        var has = await store.hasKeys(for: id)
        if !has { has = await store.moveLegacyKey(for: id, vaultName: model.vaultName ?? "", reason: reason) }
        guard has else {
            if model.vault?.vaultId == id { hasKeysVaultID = nil }
            return .noKey
        }
        hasKeysVaultID = id
        let keys: DeviceKeys
        do {
            keys = try await store.keys(for: id, reason: reason)
            try model.ensureCurrent(gen)
        } catch is CancellationError {
            return .cancelled
        } catch DeviceKeyStoreError.cancelled {
            return .cancelled
        } catch {
            return .failed(String(localized: "This device's key could not be read: \(String(describing: error))",
                                  comment: "The error text follows (English)"))
        }
        if let stage = await model.joinStage(keys) {
            joinStage = stage
            return .joining
        }
        joinStage = nil
        do {
            try await model.unlock(device: keys, awaitNotes: false)
            return .unlocked
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(String(localized: "This device's key did not unlock the vault: \(String(describing: error))",
                                  comment: "The error text follows (English)"))
        }
    }

    /// Unlocks with pasted key text: the recovery key (read-only), or a device key file made with sempere.
    func unlock(_ model: AppModel, identityText: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        try await model.unlock(identityText: identityText, awaitNotes: false)
    }

    /// Unlocks read-only with the passphrase of the recovery key's copy in the vault.
    func unlock(_ model: AppModel, passphrase: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        try await model.unlock(passphrase: passphrase, awaitNotes: false)
    }

    /// Keeps the keys of a vault this device just created (its home), with no other copy anywhere.
    func saveCreatedVaultKeys(_ device: DeviceKeys, vaultID: UUID, vaultName: String) async throws {
        try await store.save(device, for: vaultID, vaultName: vaultName)
        hasKeysVaultID = vaultID
    }

    /// Whether the unlock sheet stays up although the vault is unlocked: a manual unlock is finishing.
    func holdsUnlockSheet(_ model: AppModel) -> Bool { isManualUnlocking }

    /// Turns "Require Face ID to open this vault" on or off (design §6.1).
    func setRequiresBiometry(_ on: Bool, model: AppModel) async throws {
        guard let id = model.vault?.vaultId else { return }
        try await store.setRequiresBiometry(on, for: id, vaultName: model.vaultName ?? "")
        requiresBiometry = await store.requiresBiometry(for: id)
    }
}
