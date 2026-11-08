import Foundation
import Observation
import Sempere

/// Why this device's keys for a vault cannot be used (`RememberedKeys.Attempt.keyProblem`): the unlock sheet offers
/// to forget them and join again (review of #88, M3). Worded by the app.
public enum DeviceKeyProblem: Equatable, Sendable {
    /// The keys can no longer be read (gone after a Face ID change) or do not read as keys.
    case unreadable
    /// This device's request to join expired: home deletes requests after 7 days.
    case expired
    /// Keys not on the device list, with no request to join (a failed kit join, a request home deleted).
    case stray
}

/// Why an unlock with this device's keys failed although they are there (`RememberedKeys.Attempt.failed`); the keys
/// are kept and Unlock is offered again. Worded by the app.
public enum DeviceUnlockFailure: Error {
    /// The keys could not be read: a failed Face ID, a Keychain error, a build without the entitlement.
    case keysNotRead(any Error)
    /// The keys were read but did not unlock the vault.
    case keysDidNotUnlock(any Error)
}

/// The keys this device keeps per vault (key-hierarchy design §6.1; KH5): its own device keys, in a `DeviceKeyStore`
/// (the app's: the Keychain, with the signing pair in the Secure Enclave). It unlocks a vault with them when it
/// opens (Face ID first when the vault asks for it), tracks a join of this device in progress (`joinStage`), and
/// holds the vault's "Require Face ID" setting. The recovery key is never kept: it opens a vault read-only, or signs a
/// takeover and is dropped.
///
/// Kept apart from the model (it calls the model): the unlock sheet's model, one per app; tests give it a
/// `MemoryDeviceKeyStore`.
@MainActor
@Observable
public final class RememberedKeys {
    /// How an attempt to unlock with this device's keys ended.
    public enum Attempt: Sendable {
        case unlocked
        /// This device has no keys for the vault.
        case noKey
        /// This device has keys and is joining: the join screen shows where it stands (`joinStage`).
        case joining
        /// The user canceled Face ID, or the vault changed meanwhile.
        case cancelled
        /// The keys could not be read, or did not open the vault.
        case failed(DeviceUnlockFailure)
        /// This device has keys for the vault that cannot be used (unreadable after a Face ID change, or of a join
        /// that cannot go on): the unlock sheet offers to forget them and join again (review of #88, M3).
        case keyProblem(DeviceKeyProblem)
    }

    public let store: any DeviceKeyStore
    /// The open vault has keys on this device (`refresh`).
    public private(set) var hasKeysVaultID: UUID?
    /// "Require Face ID to open this vault" for the open vault.
    public private(set) var requiresBiometry = false
    /// While the open, locked vault is being joined by this device: where it stands.
    public var joinStage: JoinStage?
    /// This device's keys for the open vault cannot be used: why (`Attempt.keyProblem`).
    public private(set) var keyProblem: DeviceKeyProblem?
    /// True while Face ID / the Keychain is being asked.
    public private(set) var isUnlocking = false
    /// True while an unlock with a passphrase or pasted key runs.
    public private(set) var isManualUnlocking = false

    public init(store: any DeviceKeyStore) {
        self.store = store
    }

    /// Whether this device has keys for the open vault (as of the last `refresh`).
    public func hasKeys<Host>(for model: AppModelCore<Host>) -> Bool {
        guard let id = model.vault?.vaultId else { return false }
        return hasKeysVaultID == id
    }

    /// Looks up, without reading or prompting, whether this device has keys for the open vault.
    public func refresh<Host>(_ model: AppModelCore<Host>) async {
        guard let id = model.vault?.vaultId else { return }
        let has = await store.hasKeys(for: id)
        let biometry = has ? await store.requiresBiometry(for: id) : false
        guard model.vault?.vaultId == id else { return }
        hasKeysVaultID = has ? id : (hasKeysVaultID == id ? nil : hasKeysVaultID)
        requiresBiometry = biometry
    }

    // MARK: - Unlocking

    /// Unlocks the locked vault with this device's keys; a device that is joining gets its join stage instead.
    public func unlockWithDeviceKey<Host>(_ model: AppModelCore<Host>) async -> Attempt {
        guard model.phase == .locked, let vault = model.vault, !isUnlocking else { return .cancelled }
        let id = vault.vaultId
        let gen = model.generation
        isUnlocking = true
        defer { isUnlocking = false }
        keyProblem = nil
        guard await store.hasKeys(for: id) else {
            if model.vault?.vaultId == id { hasKeysVaultID = nil }
            return .noKey
        }
        hasKeysVaultID = id
        let keys: DeviceKeys
        do {
            keys = try await store.keys(for: id, reason: .unlock(vaultName: model.vaultName))
        } catch {
            let outcome = Self.readOutcome(error)
            if case .keyProblem(let problem) = outcome { keyProblem = problem }
            return outcome
        }
        // The vault changed meanwhile: nothing about these keys is known from that (re-check of #88, R1).
        do { try model.ensureCurrent(gen) } catch { return .cancelled }
        switch await model.joinStage(keys) {
        case .stage(let stage):
            joinStage = stage
            return .joining
        case .stray:
            keyProblem = .stray
            joinStage = nil
            return .keyProblem(.stray)
        case .expired:
            keyProblem = .expired
            joinStage = nil
            return .keyProblem(.expired)
        case .member:
            break
        }
        joinStage = nil
        keyProblem = nil
        do {
            try await model.unlock(device: keys, awaitNotes: false)
            return .unlocked
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.keysDidNotUnlock(error))
        }
    }

    /// What a failed read of this device's keys means (re-check of #88, R1): only keys that are gone (a Face ID
    /// change invalidated them) or do not read as keys are a key problem, offered to be forgotten; a cancel is a
    /// cancel; anything else (a failed Face ID, a Keychain error, a build without the entitlement) is a failure
    /// that leaves the keys alone and Unlock offered again.
    public static func readOutcome(_ error: any Error) -> Attempt {
        if error is CancellationError { return .cancelled }
        switch error as? DeviceKeyStoreError {
        case .notFound, .malformed: return .keyProblem(.unreadable)
        case .cancelled: return .cancelled
        case .some, nil: return .failed(.keysNotRead(error))
        }
    }

    /// Unlocks with pasted key text: the recovery key (read-only), or a device key file made with sempere.
    public func unlock<Host>(_ model: AppModelCore<Host>, identityText: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        try await model.unlock(identityText: identityText, awaitNotes: false)
    }

    /// Unlocks read-only with the passphrase of the recovery key's copy in the vault.
    public func unlock<Host>(_ model: AppModelCore<Host>, passphrase: String) async throws {
        isManualUnlocking = true
        defer { isManualUnlocking = false }
        try await model.unlock(passphrase: passphrase, awaitNotes: false)
    }

    /// Forgets this device's keys for the open vault (a key that cannot be used, review of #88 M3): the unlock
    /// sheet then offers Join and Take Over.
    public func forgetKeys<Host>(_ model: AppModelCore<Host>) async throws {
        guard let id = model.vault?.vaultId else { return }
        try await store.delete(for: id)
        model.clearJoinRequested(id)
        keyProblem = nil
        joinStage = nil
        await refresh(model)
    }

    /// Keeps the keys of a vault this device just created (its home), with no other copy anywhere.
    public func saveCreatedVaultKeys(_ device: DeviceKeys, vaultID: UUID, vaultName: String) async throws {
        try await store.save(device, for: vaultID, vaultName: vaultName)
        hasKeysVaultID = vaultID
    }

    /// Whether the unlock sheet stays up although the vault is unlocked: a manual unlock is finishing.
    public func holdsUnlockSheet<Host>(_ model: AppModelCore<Host>) -> Bool { isManualUnlocking }

    /// Turns "Require Face ID to open this vault" on or off (design §6.1).
    public func setRequiresBiometry<Host>(_ on: Bool, model: AppModelCore<Host>) async throws {
        guard let id = model.vault?.vaultId else { return }
        try await store.setRequiresBiometry(on, for: id, vaultName: model.vaultName ?? "")
        requiresBiometry = await store.requiresBiometry(for: id)
    }
}
