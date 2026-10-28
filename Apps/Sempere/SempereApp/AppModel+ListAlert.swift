import Age
import Foundation
import Sempere

/// The keys a vault was unlocked with: a listed device's key (with its
/// signing keys when they are known), or the recovery key (read-only), with
/// the root it is checked against when one came with it (the passphrase copy).
struct UnlockKeys: Sendable {
    var identities: [any AgeIdentity] = []
    /// This device's signing keys (`DeviceKeys.signing`): only home needs them, for list changes.
    var signing: (any AuthorSigner)?
    /// This device's keys when it unlocked as a device (a takeover signs with them).
    var device: DeviceKeys?
    /// The vault's root fingerprint the list is checked against (format.md §15.2); nil checks it
    /// against this device's trust record.
    var root: Data?
}

/// The blocking alert for a vault whose `vault.json` does not check (design
/// §4.3, `ListStatus.refused`): "This vault's device list was changed without
/// its key". The vault stays readable and nothing is written to it.
///
/// The way out is a takeover with the recovery kit (design §5.6), from the
/// device list; the alert explains and closes.
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

    static let unconfirmedTitle = String(localized: "This device has not confirmed this vault", comment: "Alert title: a device key opened the vault, and this device has no record of it and no root to check it against")

    /// `title`, `markersTitle` for a version-marker problem, or `unconfirmedTitle` when nothing is wrong with the list
    /// but this device cannot check it yet (a pasted device key: nobody edited anything).
    var displayTitle: String {
        if problem.reason == .rootUnconfirmed { return Self.unconfirmedTitle }
        return isMarkers ? Self.markersTitle : Self.title
    }

    /// What the root fingerprint is, where the kit prints it, and that it is not the recovery key (build 12: "What is
    /// the root key and how does it compare with the recovery key?"). The alert and Confirm Vault both say it.
    static let rootExplained = String(localized: "The check uses the vault's root fingerprint: 16 groups of 4 letters and digits printed on the first page of the recovery kit, under the heading “The vault's root fingerprint”, below the recovery key's lines (the second page has it as a QR code). It is not the recovery key: it opens nothing and is not secret, it only identifies the vault. Take it only from the printed kit, never from a device or the vault's folder.")

    /// The alert's text: what happened and what it means.
    var message: String {
        if problem.reason == .rootUnconfirmed {
            // Not a tampered list (demovault-mac, build 11): a key from elsewhere, and no record here yet.
            return [
                String(localized: "This device's key is on the vault's list, but this device has never checked that this vault is the one the key belongs to: someone could make a copy of a vault that lists the same key. Until it checks, you can read the notes, and nothing is written."),
                Self.rootExplained,
                String(localized: "Choose Confirm Vault… above the note list and type it there."),
            ].joined(separator: "\n\n")
        }
        var lines: [String] = []
        switch problem.reason {
        case .listTag, .authorSig, .addSig, .epochSig, .introducesDevice, .entriesChanged:
            lines.append(String(localized: "Someone who can change the vault's folder (a sync service, a shared folder) edited its list of devices without the vault's key."))
        case .markersTag, .markersRolledBack:
            lines.append(String(localized: "Someone who can change the vault's folder changed which version of Sempere may write to it, without the vault's key. This version would otherwise write to a vault it must only read."))
        case .rootMismatch:
            lines.append(String(localized: "The vault's list of devices does not belong to the vault this device knows by that name, or to its recovery kit."))
        case .otherEpoch, .reencryptRolledBack:
            lines.append(String(localized: "The vault's keys were changed in a way this version of Sempere cannot check yet, or an older list of devices was put back."))
        case .recordUnreadable:
            lines.append(String(localized: "This device's record of the vault's devices cannot be read, so the list cannot be checked against it."))
        case .rootUnconfirmed:
            lines.append(String(localized: "This device has no record of the vault's devices yet, and nothing to check the list against."))
        }
        lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until the list is fixed."))
        lines.append(String(localized: "If a sync service or another device is at fault, the next sync from a device that manages devices puts the list back. Otherwise take over with the recovery kit: in Settings ▸ Sync & Devices ▸ Devices, or with sempere devices takeover on a computer."))
        return lines.joined(separator: "\n\n")
    }
}

extension AppModel {
    /// While the list alert or Confirm Vault is up, About Your Key and the tour wait (build 12: the key notice, a sheet
    /// presented a second after the unlock, dismissed the "has not confirmed this vault" alert at once, before it could
    /// be read). They show after it is closed.
    var holdsOnboardingForVaultNotice: Bool { listAlert != nil || confirmingVault }

    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `VaultError.untrustedList`.
    func dismissListAlert() {
        listAlert = nil
    }
}
