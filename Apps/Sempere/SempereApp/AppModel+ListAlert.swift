import Age
import Foundation
import Sempere

/// The keys a vault was unlocked with: a listed device's key (with its
/// signing keys when they are known), or the recovery key (read-only), with
/// the root it is checked against when one came with it (the passphrase copy).
struct UnlockKeys: Sendable {
    var identities: [any AgeIdentity] = []
    /// This device's signing keys (`DeviceKeys.signing`): only home needs them, for list changes.
    var signing: DeviceSigningKeys?
    /// The vault's root fingerprint the list is checked against (format.md §15.2); nil checks it
    /// against this device's trust record.
    var root: Data?
}

/// The blocking alert for a vault whose `vault.json` does not check (design
/// §4.3, `ListStatus.refused`): "This vault's device list was changed without
/// its key". The vault stays readable and nothing is written to it.
///
/// TODO(KH5): offer the repair here (a new epoch from home, a takeover with
/// the recovery key); until then the alert only explains and closes.
struct ListAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    var problem: ListProblem
    /// The vault was opened with the recovery key.
    var recovery: Bool

    /// The alert for `vault`'s list status, or nil when it checks. A recovery
    /// read with no root to check against (a pasted recovery key) is not
    /// shown: it is read-only anyway, and the banner says so.
    init?(vault: Vault) {
        guard let problem = vault.listStatus.problem else { return nil }
        if vault.isRecoveryOpen && problem.reason == .rootUnconfirmed { return nil }
        self.problem = problem
        recovery = vault.isRecoveryOpen
    }

    init(problem: ListProblem, recovery: Bool = false) {
        self.problem = problem
        self.recovery = recovery
    }

    static let title = String(localized: "This vault's device list was changed without its key", comment: "Alert title: vault.json's recipients were edited without the vault key")
    static let markersTitle = String(localized: "This vault's format was changed without its key", comment: "Alert title: vault.json's format or features were edited without the vault key")

    /// Whether the problem is about `format` and `features` rather than the list.
    var isMarkers: Bool { problem.reason == .markersTag || problem.reason == .markersRolledBack }

    /// `title`, or `markersTitle` for a version-marker problem.
    var displayTitle: String { isMarkers ? Self.markersTitle : Self.title }

    /// The alert's text: what happened and what it means.
    var message: String {
        var lines: [String] = []
        switch problem.reason {
        case .listTag, .authorSig, .addSig, .epochSig, .introducesDevice, .entriesChanged:
            lines.append(String(localized: "Someone who can change the vault's folder (a sync service, a shared folder) edited its list of devices without the vault's key."))
        case .markersTag, .markersRolledBack:
            lines.append(String(localized: "Someone who can change the vault's folder changed which version of Sempere may write to it, without the vault's key. This version would otherwise write to a vault it must only read."))
        case .rootMismatch:
            lines.append(String(localized: "The vault's list of devices does not belong to the vault this device knows by that name, or to its recovery kit."))
        case .otherEpoch:
            lines.append(String(localized: "The vault's keys were changed in a way this version of Sempere cannot check yet, or an older list of devices was put back."))
        case .recordUnreadable:
            lines.append(String(localized: "This device's record of the vault's devices cannot be read, so the list cannot be checked against it."))
        case .rootUnconfirmed:
            lines.append(String(localized: "This device has no record of the vault's devices yet, and nothing to check the list against."))
        }
        lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until the list is fixed."))
        lines.append(String(localized: "Restore vault.json from a backup, or check the vault with sempere on a computer that has opened it before. Repairing the list in the app is not available yet."))
        return lines.joined(separator: "\n\n")
    }
}

extension AppModel {
    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `VaultError.untrustedList`.
    func dismissListAlert() {
        listAlert = nil
    }
}
