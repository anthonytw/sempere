import Age
import Foundation
import Sempere

/// The keys a vault was unlocked with: a listed device's key (with its
/// signing keys when they are known), or the recovery key (read-only), with
/// the root it is checked against when one came with it (the passphrase copy).
public struct UnlockKeys: Sendable {
    public var identities: [any AgeIdentity] = []
    /// This device's signing keys (`DeviceKeys.signing`): only home needs them, for list changes.
    public var signing: (any AuthorSigner)?
    /// This device's keys when it unlocked as a device (a takeover signs with them).
    public var device: DeviceKeys?
    /// The vault's root fingerprint the list is checked against (format.md §15.2); nil checks it
    /// against this device's trust record.
    public var root: Data?

    public init(identities: [any AgeIdentity] = [], signing: (any AuthorSigner)? = nil, device: DeviceKeys? = nil,
                root: Data? = nil) {
        self.identities = identities
        self.signing = signing
        self.device = device
        self.root = root
    }
}

/// The blocking alert for a vault whose `vault.json` does not check (design
/// §4.3, `ListStatus.refused`): "This vault's device list was changed without
/// its key". The vault stays readable and nothing is written to it.
///
/// The way out is a takeover with the recovery kit (design §5.6), from the
/// device list; the alert explains and closes. Its words are the app's (`ListAlert.displayTitle`, `message`).
public struct ListAlert: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var problem: ListProblem
    /// The vault was opened with the recovery key.
    public var recovery: Bool

    /// The alert for `vault`'s list status, or nil when it checks. A recovery
    /// read with no root to check against (a pasted recovery key) is not
    /// shown: it is read-only anyway, and the banner says so.
    public init?(vault: Vault) {
        guard let problem = vault.listStatus.problem else { return nil }
        if vault.isRecoveryOpen && problem.reason == .rootUnconfirmed { return nil }
        self.problem = problem
        recovery = vault.isRecoveryOpen
    }

    public init(problem: ListProblem, recovery: Bool = false) {
        self.problem = problem
        self.recovery = recovery
    }

    /// Whether the problem is about `format` and `features` rather than the list.
    public var isMarkers: Bool { problem.reason == .markersTag || problem.reason == .markersRolledBack }
}

/// This device's write ledger and set-aside store for each vault (key-hierarchy design §5.4, §5.8; phase KH3).
/// In the app both live in the App Group container next to the in-app vault store (`DeviceWriteStores.app`, whose
/// ledger key is in the Keychain). Tests pass none (no ledger: nothing is recorded or caught up) or one with a key
/// in memory.
public struct DeviceWriteStores: Sendable {
    /// `<…>/Ledger/<vault id>/` per vault (`FileWriteLedger`).
    public let ledgerDirectory: URL
    public let setAside: SetAsideStore
    public let key: @Sendable () throws -> Data

    public init(ledgerDirectory: URL, setAside: SetAsideStore, key: @escaping @Sendable () throws -> Data) {
        self.ledgerDirectory = ledgerDirectory
        self.setAside = setAside
        self.key = key
    }

    /// The ledger of `vaultId`.
    public func ledger(for vaultId: UUID) -> FileWriteLedger {
        FileWriteLedger(directory: ledgerDirectory, vaultId: vaultId, keyBytes: key)
    }

    /// Stores under `root` with a fixed key (tests).
    public static func inMemoryKey(root: URL) -> DeviceWriteStores {
        let key = randomKey()
        return DeviceWriteStores(ledgerDirectory: root.appendingPathComponent("Ledger", isDirectory: true),
                                 setAside: SetAsideStore(directory: root.appendingPathComponent("SetAside", isDirectory: true)),
                                 key: { key })
    }

    /// 32 random bytes: a ledger key.
    public static func randomKey() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

/// Why a join, an approval or a takeover could not go on.
public enum DeviceJoinError: Error, Equatable, Sendable {
    /// No request with the words, and no target a request could come through.
    case noMatchingRequest
    /// No request with the words in the copy even after syncing every target: it may not have arrived yet.
    case requestNotArrived
    /// No request with the words is in the copy yet, and a run left a request arriving: the provider has listed it
    /// but not delivered it.
    case requestArriving
    case notARecoveryKey
    case rootNeeded
    case rootUnreadable
    case otherVaultsRoot
}
