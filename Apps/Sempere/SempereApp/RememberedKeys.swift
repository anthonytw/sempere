import Age
import Foundation
import Sempere
import LocalAuthentication
import Observation

/// Vault keys remembered in the Keychain (task 3d): offers to remember the key
/// after a manual unlock, unlocks with the remembered key (Face ID first) when
/// a vault opens, and forgets it on request.
///
/// What is remembered is this device's key file (`DeviceKeys.fileText`: its
/// decryption key and its signing keys, format.md §15.4), never the recovery
/// key, which opens a vault read-only and is kept by no device.
///
/// Kept apart from `AppModel` (it only calls the model's unlock methods), so
/// the key store can be swapped for a fake in tests. The key text lives in
/// memory only while an offer is on screen; it is never logged and never
/// written anywhere but the key store.
@MainActor
@Observable
final class RememberedKeys {
    /// An unlock the user may want remembered (the remember sheet, `RememberKeyView`).
    /// TODO(KH5): made again once devices join in the app; nothing makes one now.
    struct Offer: Identifiable, Equatable {
        let vaultID: UUID
        let vaultName: String
        /// The device key file text (`DeviceKeys.fileText`).
        let identity: String
        /// The vault folder it unlocked: a key remembered from this offer is offered there (`RememberedKeyLocations`).
        var folder: URL?
        /// Where a key for this vault id is remembered already, when it is not
        /// offered at `folder` (another copy of the vault, a WebDAV vault added
        /// again): answering replaces it, and the sheet starts on its storage.
        var replacing: KeyStorage? = nil
        var id: UUID { vaultID }
    }

    /// How an attempt to unlock with the remembered key ended.
    enum Attempt: Equatable {
        case unlocked
        /// Nothing is remembered for this vault (or it was invalidated).
        case noKey
        /// A key is remembered for this vault id, but not offered at this
        /// location (`offersSavedKey`): the user pastes the key or the passphrase.
        case notHere
        /// The user canceled Face ID / the passcode, or the vault changed meanwhile.
        case cancelled
        /// A key was read but did not unlock the vault, or the Keychain failed.
        case failed(String)
    }

    let store: any VaultKeyStore
    /// Where each remembered key may be offered (security review 2026-10 stage 4, S16).
    let locations: RememberedKeyLocations
    /// Shown after a manual unlock until the user answers.
    var offer: Offer?
    /// Where the open vault's key is remembered (nil: not remembered, or not known yet).
    private(set) var storage: KeyStorage?
    /// The vault `storage` describes.
    private(set) var storageVaultID: UUID?
    /// True while Face ID / the Keychain is being asked.
    private(set) var isUnlocking = false
    /// True while an unlock with a passphrase or pasted key runs.
    private(set) var isManualUnlocking = false
    /// The remembered key was tried and does not work (wrong key, invalidated).
    private var brokenVaultID: UUID?

    /// - Parameter locations: the app passes `RememberedKeyLocations.onDisk()`; tests get one in memory.
    init(store: any VaultKeyStore = KeychainVaultKeyStore(), locations: RememberedKeyLocations = RememberedKeyLocations()) {
        self.store = store
        self.locations = locations
    }

    /// Whether the open vault's remembered key may be offered where the vault
    /// is (S16): the vault id comes from a `vault.json` nothing has checked
    /// yet, so a lookalike folder could claim it. Offered at a location the
    /// key (or a confirmed pasted key) unlocked before; a key with no location
    /// yet (one that arrived through iCloud Keychain) only for a vault
    /// opened in the app, never for one another app or AirDrop handed over.
    func offersSavedKey(for model: AppModel) -> Bool {
        guard let id = model.vault?.vaultId, let folder = model.vaultURL else { return false }
        let bound = locations.locations(for: id)
        if bound.isEmpty { return !model.vaultOpenedExternally }
        return bound.contains(locations.location(of: folder))
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

    /// The device's biometry ("Face ID", "Touch ID", "Optic ID") when one is
    /// enrolled, else nil (a device-only key is then read with the passcode).
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

    /// `biometryName`, or "Face ID or Touch ID" when none is enrolled: for
    /// sentences that name the check (the passcode stands in for it then).
    static var biometryPhrase: String {
        biometryName ?? String(localized: "Face ID or Touch ID", comment: "The biometry, inside sentences, when the device has none enrolled")
    }

    /// The footer under "Remember on this device". A device-only key is
    /// `.biometryCurrentSet` (`KeychainVaultKeyStore`): only that biometry
    /// reads it, never the passcode, so after a lockout the user unlocks with
    /// the key or passphrase. Without biometrics it is `.userPresence`.
    static func deviceOnlyFooter(vaultName: String, biometry: String?) -> String {
        guard let biometry else {
            return String(localized: "Next time, \(vaultName) opens after your device passcode. The key stays in this device's Keychain and is not included in backups.",
                          comment: "Unlock sheet footer; the value is the vault name")
        }
        return String(localized: "Next time, \(vaultName) opens after \(biometry), and only \(biometry): the passcode cannot read the saved key. If \(biometry) is locked out after failed attempts, turned off, or re-enrolled, unlock with the key or the passphrase instead. The key stays in this device's Keychain and is not included in backups.",
                      comment: "Unlock sheet footer; the first value is the vault name, the others the biometry (Face ID, Touch ID)")
    }

    /// The remembered storage for the open vault, if known.
    func storage(for model: AppModel) -> KeyStorage? {
        guard let id = model.vault?.vaultId, storageVaultID == id else { return nil }
        return storage
    }

    /// Looks up (without reading or prompting) whether the open vault's key
    /// is remembered.
    func refresh(_ model: AppModel) async {
        guard let id = model.vault?.vaultId else { return }
        let found = try? await store.storage(for: id)
        guard model.vault?.vaultId == id else { return }
        storageVaultID = id
        storage = found
    }

    // MARK: - Unlocking

    /// Unlocks the locked vault with its remembered key: the key store asks
    /// for Face ID / Touch ID (or the passcode) first.
    func unlockWithRememberedKey(_ model: AppModel) async -> Attempt {
        guard model.phase == .locked, let vault = model.vault, !isUnlocking else { return .cancelled }
        let id = vault.vaultId
        let gen = model.generation
        isUnlocking = true
        defer { isUnlocking = false }
        let identity: String
        do {
            let stored = try await store.storage(for: id)
            try model.ensureCurrent(gen)
            storageVaultID = id
            storage = stored
            guard stored != nil else { return .noKey }
            // Not even a Face ID prompt for a key this location may not have (S16).
            guard offersSavedKey(for: model) else { return .notHere }
            let reason = model.vaultName.map { String(localized: "Unlock “\($0)” with its saved key", comment: "Face ID prompt") }
                ?? String(localized: "Unlock the vault with its saved key", comment: "Face ID prompt")
            identity = try await store.readKey(for: id, reason: reason)
            try model.ensureCurrent(gen)
        } catch is CancellationError {
            return .cancelled
        } catch KeyStoreError.cancelled {
            return .cancelled
        } catch KeyStoreError.notFound {
            if model.vault?.vaultId == id { storage = nil }
            return .noKey
        } catch {
            // Face ID failed or the Keychain could not be read: the key itself
            // may be fine, so it is not marked broken (replacing it could
            // delete a working iCloud Keychain copy on every device).
            return .failed(String(localized: "The saved key could not be read: \(String(describing: error))",
                                  comment: "The error text follows (English)"))
        }
        do {
            // The notes load in the background (`AppModel.startLoadingNotes`): the
            // sheet closes as soon as the key works, and no view can cancel the listing.
            try await model.unlock(identityText: identity, awaitNotes: false)
            brokenVaultID = nil
            // A key that arrived through iCloud Keychain is bound to where it first unlocked.
            if model.vault?.vaultId == id, let folder = model.vaultURL { locations.bind(id, to: folder) }
            return .unlocked
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Only a key that is not one, or that opens nothing, is broken; an
            // I/O failure (e.g. iCloud) says nothing about the key.
            if model.vault?.vaultId == id, Self.isWrongKey(error) { brokenVaultID = id }
            return .failed(String(localized: "The saved key did not unlock this vault: \(String(describing: error))",
                                  comment: "The error text follows (English)"))
        }
    }

    /// Whether an unlock failed because of the key rather than the vault's files.
    static func isWrongKey(_ error: any Error) -> Bool {
        switch error {
        case AppModel.ModelError.notAnIdentity, AppModel.ModelError.notJoined, VaultError.keyNotListed,
             VaultError.classicIdentity:
            return true
        default: return false
        }
    }

    /// Unlocks with pasted key text, then offers to remember it when it is
    /// a device key file of a listed device (a recovery key is never offered).
    ///
    /// TODO(KH5): offer to remember a pasted device key once devices join in
    /// the app. Until then nothing is offered: a device key file carries its
    /// signing seeds and stays on its device (design §6.1); only the key of a
    /// vault this device created is remembered (`rememberThisDeviceKey`). A
    /// key remembered already is bound to this folder when the list checks.
    func unlock(_ model: AppModel, identityText: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        let device = try await model.unlock(identityText: identityText, awaitNotes: false)
        if device != nil, !(model.vault?.isRecoveryOpen ?? true) { bindConfirmedLocation(model) }
    }

    /// A key remembered for the open vault but not offered at its folder: the
    /// folder becomes a place to offer it once this device's trust record
    /// confirms the list (not a first use, S16).
    private func bindConfirmedLocation(_ model: AppModel) {
        guard let id = model.vault?.vaultId, storageVaultID == id, storage != nil, brokenVaultID != id,
              !offersSavedKey(for: model), let folder = model.vaultURL,
              Self.listIsConfirmed(model.vault?.listStatus) else { return }
        locations.bind(id, to: folder)
    }

    /// Unlocks read-only with the passphrase of the recovery key's copy in
    /// the vault. Nothing is offered: no device keeps the recovery key.
    func unlock(_ model: AppModel, passphrase: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        try await model.unlock(passphrase: passphrase, awaitNotes: false)
    }

    /// Remembers the key of a vault this device just created (its home): no
    /// other copy of the device key exists, and without it this device could
    /// only read the vault with the recovery key. Kept in this device's
    /// Keychain only (`thisDevice`), bound to the vault's folder.
    func rememberThisDeviceKey(_ device: DeviceKeys, vaultID: UUID, vaultName: String, folder: URL?) async throws {
        try await store.save(device.fileText(created: Date()), for: vaultID, vaultName: vaultName, storage: .thisDevice)
        if let folder { locations.bind(vaultID, to: folder) }
        storageVaultID = vaultID
        storage = .thisDevice
        if brokenVaultID == vaultID { brokenVaultID = nil }
    }

    /// Whether the unlock sheet stays up although the vault is unlocked: a
    /// manual unlock is finishing (its offer comes next) or an offer is open.
    func holdsUnlockSheet(_ model: AppModel) -> Bool {
        if isManualUnlocking { return true }
        guard let offer else { return false }
        return model.phase == .unlocked && offer.vaultID == model.vault?.vaultId
    }

    /// The device list verified against this device's trust record (design §4.3), not on first use.
    nonisolated static func listIsConfirmed(_ status: ListStatus?) -> Bool {
        switch status {
        case .verified(.unchanged), .verified(.added), .verified(.renamed): return true
        default: return false
        }
    }

    // MARK: - Remembering and forgetting

    /// Answers the offer: nil does not remember the key. Clears the offer.
    func answer(_ offer: Offer, storage: KeyStorage?) async throws {
        if self.offer?.vaultID == offer.vaultID { self.offer = nil }
        guard let asked = storage else { return }
        // A device key never goes to iCloud Keychain (design §6.1).
        let storage = KeychainVaultKeyStore.storage(for: offer.identity, asked: asked)
        try await store.save(offer.identity, for: offer.vaultID, vaultName: offer.vaultName, storage: storage)
        if let folder = offer.folder { locations.bind(offer.vaultID, to: folder) }
        storageVaultID = offer.vaultID
        self.storage = storage
        if brokenVaultID == offer.vaultID { brokenVaultID = nil }
    }

    /// Forgets the open vault's remembered key.
    func forget(_ model: AppModel) async throws {
        guard let id = model.vault?.vaultId else { return }
        try await store.deleteKey(for: id)
        locations.forget(id)
        if model.vault?.vaultId == id {
            storageVaultID = id
            storage = nil
        }
    }

    /// Drops an offer for a vault that is no longer open.
    func discardStaleOffer(_ model: AppModel) {
        if let offer, offer.vaultID != model.vault?.vaultId || model.phase != .unlocked { self.offer = nil }
    }
}
