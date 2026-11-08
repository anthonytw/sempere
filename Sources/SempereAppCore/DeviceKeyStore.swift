import Foundation
import Sempere

// This device's own keys per vault (key-hierarchy design §4.1, §6.1; phase KH5), as the model reads them: the
// protocol, its errors and the reasons a read asks for, and a memory version for tests and previews. The app's store
// is the Keychain and the Secure Enclave (`KeychainDeviceKeyStore`), which words the reasons as the Face ID prompt.

/// Why this device's keys could not be stored or read; worded by the app.
public enum DeviceKeyStoreError: Error, Equatable, Sendable {
    /// No keys for the vault here (or Face ID re-enrollment invalidated them).
    case notFound
    /// The user canceled Face ID or the passcode.
    case cancelled
    case authenticationFailed
    /// This build cannot use the Keychain (unsigned).
    case missingEntitlement
    /// A stored item does not read as keys.
    case malformed
    /// Another Keychain status (`OSStatus`).
    case keychain(Int32)

    /// The Keychain's `errSecDuplicateItem`: keys are stored for the vault already.
    public static let duplicateItem = DeviceKeyStoreError.keychain(-25299)
}

/// What a read of this device's keys is for: the app's store shows it in the Face ID prompt.
public enum DeviceKeyReason: Equatable, Sendable {
    /// Unlocking the vault of this name (nil: its name is not known).
    case unlock(vaultName: String?)
    /// Going on with a join of the vault of this name (the join screen).
    case join(vaultName: String)
    /// Signing a takeover with the recovery kit.
    case takeover
    /// Withdrawing a join request (the keys only name the request file).
    case withdrawJoin
}

/// This device's keys per vault id. The model talks to this protocol; tests use `MemoryDeviceKeyStore`.
public protocol DeviceKeyStore: Sendable {
    /// Whether this device holds keys for `vaultID` (no prompt).
    func hasKeys(for vaultID: UUID) async -> Bool
    /// Whether reading them asks for Face ID ("Require Face ID to open this vault").
    func requiresBiometry(for vaultID: UUID) async -> Bool
    /// The keys, after Face ID when the vault asks for it; `reason` is what the prompt says it is for.
    func keys(for vaultID: UUID, reason: DeviceKeyReason) async throws -> DeviceKeys
    /// New keys: the signing pair in the Secure Enclave where there is one (else in software, in the Keychain).
    func generate() throws -> DeviceKeys
    /// Stores `keys` for `vaultID`; refuses to replace keys stored for it.
    func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws
    /// Turns "Require Face ID" on or off (the device key is read first, which asks when it is on).
    func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws
    /// Deletes the keys (the vault removed from this device, or a join given up).
    func delete(for vaultID: UUID) async throws
    /// The device fingerprint of the keys stored for `vaultID`, without a prompt (whether this device is a vault's
    /// home, before its copy is deleted); nil when there are none.
    func fingerprint(for vaultID: UUID) async -> Data?
}

/// `DeviceKeyStore` in memory (tests, previews): software signing pairs.
public final class MemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: (keys: DeviceKeys, biometry: Bool)] = [:]
    private var _reads = 0
    private var _unreadable = false
    private var _reasons: [DeviceKeyReason] = []

    public init() {}

    /// Reads made (tests count Face ID prompts).
    public var reads: Int { lock.withLock { _reads } }
    /// The reason of each read, in order.
    public var reasons: [DeviceKeyReason] { lock.withLock { _reasons } }
    /// Set: every read fails as an unreadable key would (Face ID re-enrolled), tests.
    public var unreadable: Bool {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }

    public func hasKeys(for vaultID: UUID) async -> Bool { lock.withLock { stored[vaultID] != nil } }
    public func requiresBiometry(for vaultID: UUID) async -> Bool { lock.withLock { stored[vaultID]?.biometry ?? false } }
    public func fingerprint(for vaultID: UUID) async -> Data? { lock.withLock { stored[vaultID]?.keys.fingerprint } }

    public func keys(for vaultID: UUID, reason: DeviceKeyReason) async throws -> DeviceKeys {
        try lock.withLock {
            _reads += 1
            _reasons.append(reason)
            if _unreadable { throw DeviceKeyStoreError.notFound }
            guard let k = stored[vaultID]?.keys else { throw DeviceKeyStoreError.notFound }
            return k
        }
    }

    public func generate() throws -> DeviceKeys { try DeviceKeys.generate() }

    public func save(_ keys: DeviceKeys, for vaultID: UUID, vaultName: String) async throws {
        try lock.withLock {
            guard stored[vaultID] == nil else { throw DeviceKeyStoreError.duplicateItem }
            stored[vaultID] = (keys, false)
        }
    }

    public func setRequiresBiometry(_ on: Bool, for vaultID: UUID, vaultName: String) async throws {
        try lock.withLock {
            guard stored[vaultID] != nil else { throw DeviceKeyStoreError.notFound }
            stored[vaultID]?.biometry = on
        }
    }

    public func delete(for vaultID: UUID) async throws {
        lock.withLock {
            stored[vaultID] = nil
            _unreadable = false
        }
    }
}

// MARK: - The device owner

/// What a check of the device owner is for: the app's check shows it in the Face ID or passcode prompt.
public enum OwnerCheckReason: Equatable, Sendable {
    /// Add Passphrase Copy (design §6.5).
    case addPassphraseCopy
    /// Add Device's approval of a new device (design §6.2 step 2).
    case approveDevice
    /// Replace Recovery Kit (design §6.5 step 3).
    case replaceRecoveryKit
    /// Re-encrypt Everything (design §7.1).
    case reencrypt
}

/// Asks the device owner to prove they are there before a secret key leaves the app, or a list change that needs
/// the owner at the device (Replace Recovery Kit, key-hierarchy design §6.5; `AppModel.ownerAuthenticator`). The app's
/// is `SystemOwnerAuthenticator` (Face ID, Touch ID or the passcode); tests use `ScriptedOwnerCheck`.
public protocol OwnerAuthenticator: Sendable {
    func authenticate(reason: OwnerCheckReason) async throws
}

/// No device owner can be asked (a front end without one): every check fails with this.
public struct OwnerCheckUnavailable: Error, Equatable, Sendable {
    public init() {}
}

/// The owner check of a front end with no device owner to ask (headless, `AppModelServices.headless()`): every check
/// fails with `OwnerCheckUnavailable`, so nothing that needs the owner happens by accident.
public struct NoOwnerCheck: OwnerAuthenticator {
    public init() {}

    public func authenticate(reason: OwnerCheckReason) async throws { throw OwnerCheckUnavailable() }
}

/// An owner check with a scripted answer, which records what it was asked (tests).
public final class ScriptedOwnerCheck: OwnerAuthenticator, @unchecked Sendable {
    public enum Answer: Sendable {
        case pass
        /// Fails with this error (`CancellationError` for a cancel).
        case refuse(any Error)
    }

    private let lock = NSLock()
    private var _answer: Answer
    private var _reasons: [OwnerCheckReason] = []

    public init(_ answer: Answer) { _answer = answer }

    /// The answer the next checks get.
    public var answer: Answer {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    /// The reason of each check, in order.
    public var reasons: [OwnerCheckReason] { lock.withLock { _reasons } }

    public func authenticate(reason: OwnerCheckReason) async throws {
        let answer = lock.withLock { () -> Answer in
            _reasons.append(reason)
            return _answer
        }
        if case .refuse(let error) = answer { throw error }
    }
}
