import Foundation
import Sempere

/// The blocking alert for a vault whose `vault.json` recipients do not check
/// (format.md §2.1): "This vault's device list was changed without its key".
/// Remove rewrites the last verified list and rotates the vault secret
/// (`Vault.repairRecipients`); Cancel leaves the vault readable and unwritten.
struct RecipientsAlert: Identifiable, Equatable, Sendable {
    /// One recipient the alert names.
    struct Entry: Equatable, Sendable {
        var key: String
        var label: String

        /// `Label (age1pq1abcdefg…)`, or the abbreviated key alone.
        var display: String {
            let short = RecipientsProblem.abbreviate(key)
            return label.isEmpty ? short : "\(label) (\(short))"
        }
    }

    let id = UUID()
    var problem: RecipientsProblem
    /// The keys listed now that are not in the last verified list.
    var unexpected: [Entry]

    init(problem: RecipientsProblem, entries: [VaultManifest.Recipient]) {
        self.problem = problem
        let labels = Dictionary(entries.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })
        unexpected = problem.unexpected.map { Entry(key: $0, label: labels[$0] ?? "") }
    }

    static let title = String(localized: "This vault's device list was changed without its key", comment: "Alert title: vault.json's recipients were edited without the vault key")
    static let markersTitle = String(localized: "This vault's format was changed without its key", comment: "Alert title: vault.json's format or features were edited without the vault key")

    /// `title`, or `markersTitle` for a version-marker problem (format.md §2.1).
    var displayTitle: String { problem.reason.isMarkers ? Self.markersTitle : Self.title }

    /// Remove is offered when the library can write the last verified list:
    /// not after an unconfirmed secret change (the files are tagged under a
    /// secret this device no longer holds), nor when no list is known.
    var canRemove: Bool { problem.reason != .secretUnconfirmed && !problem.reason.isMarkers && problem.restore != nil }

    /// Trust This List is offered when this device's own record of the list
    /// cannot be read (security review 2026-10, R5): the list itself checks
    /// under the vault's key, so after the user checked the devices the
    /// record is written again (`Vault.confirmRecipients`).
    var canConfirm: Bool { problem.reason == .recordUnreadable }

    /// Choose Devices to Keep… (`sempere vault recipients repair --keep`) is
    /// offered whenever a repair is possible at all: the list to restore may
    /// be unknown (the user picks it) or known (the user may keep less).
    var canChoose: Bool { problem.reason != .secretUnconfirmed }

    /// The alert's text: what happened, the unknown devices, what Remove does.
    var message: String {
        var lines: [String] = []
        switch problem.reason {
        case .tagMismatch:
            lines.append(String(localized: "Someone who can change the vault's folder (a sync service, a shared folder) edited its list of devices without the vault's key."))
        case .tagRemoved:
            lines.append(String(localized: "The list of devices lost its authentication: someone who can change the vault's folder removed it."))
        case .secretUnconfirmed:
            lines.append(String(localized: "The vault's key was replaced in a way this device cannot confirm."))
        case .recordUnreadable:
            lines.append(String(localized: "This device's record of the vault's devices cannot be read, so the list cannot be checked against it."))
        case .markersMismatch, .markersRemoved, .markersRolledBack:
            // Security review 2026-10, N3: format and features are authenticated too.
            lines.append(String(localized: "Someone who can change the vault's folder changed which version of Sempere may write to it, without the vault's key. This version would otherwise write to a vault it must only read."))
            lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until this is fixed."))
            lines.append(String(localized: "Repair it with `sempere vault markers repair` on a computer that has opened this vault before, or restore vault.json from a backup."))
            return lines.joined(separator: "\n\n")
        }
        if unexpected.isEmpty {
            lines.append(String(localized: "No unknown device was added, but the list is not the one this device last checked."))
        } else {
            let devices = unexpected.map(\.display).joined(separator: ", ")
            lines.append(String(localized: "Devices this device never confirmed: \(devices).", comment: "The value is a list of device names and abbreviated keys"))
        }
        lines.append(String(localized: "Your notes can still be read. Nothing is written to this vault until the list is fixed."))
        if canConfirm {
            lines.append(String(localized: "If every device listed is yours, Trust This List records it again on this device."))
        } else if canRemove {
            lines.append(String(localized: "Remove restores the last checked list and re-encrypts every note with a new vault key, so no other device can read them."))
        } else if problem.reason == .secretUnconfirmed {
            lines.append(String(localized: "If you changed the vault's keys on another device, open the vault there, or check the list with `sempere vault recipients confirm`. Otherwise restore vault.json from a backup."))
        }
        if canChoose {
            lines.append(String(localized: "Choose Devices to Keep lets you pick the devices yourself; the others are removed and every note is re-encrypted with a new vault key."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The one-time report of an untagged vault's upgrade.
    static func upgradeNotice(_ recipients: [VaultManifest.Recipient]) -> String {
        let names = recipients.map { Entry(key: $0.key, label: $0.label).display }
        let list = names.joined(separator: ", ")
        return String(localized: "This vault's list of devices is now protected: a change made without the vault's key will be detected. It trusts these \(recipients.count) devices: \(list). If one is not yours, remove it in Keys.",
                      comment: "Notice after unlocking; the values are the number of devices and their names")
    }
}

/// Choose Devices to Keep (format.md §2.1 "Repair" with a list the user
/// picks; the CLI's `vault recipients repair --keep`): every key listed now
/// and every key of this device's record that was taken off the list, with
/// what this device knows about each. The repair itself is
/// `Vault.repairRecipients(keeping:)`, as in the CLI.
///
/// Rules the app adds to the CLI's, because a wrong pick cannot be undone
/// from this device: the key this device unlocked with is always kept (or
/// it could not open the vault afterwards), and keeping a key this device
/// never confirmed (possibly the one that was slipped in) asks the owner to
/// authenticate first, as adding a key does (security review 2026-10, P1).
struct RecipientsRepairChoice: Identifiable, Equatable, Sendable {
    struct Candidate: Identifiable, Equatable, Sendable {
        var key: String
        var label: String
        /// This device unlocked the vault with it: always kept.
        var isHeld: Bool
        /// Listed now but not in the last verified list (or no list is
        /// known): nothing confirms it belongs to the vault's owner.
        var isUnconfirmed: Bool
        /// In this device's record but no longer listed: someone took it off.
        var isRemoved: Bool

        var id: String { key }
        var display: String { RecipientsAlert.Entry(key: key, label: label).display }
    }

    let id = UUID()
    /// The vault the choice was made for: the repair checks it is still open.
    var vault: UUID
    var reason: RecipientsProblem.Reason
    var candidates: [Candidate]
    /// What is ticked when the sheet opens: the last verified list when this
    /// device knows it, else only this device's own key. Never an
    /// unconfirmed key.
    var initial: Set<String>

    init(problem: RecipientsProblem, recipients: [VaultManifest.Recipient], held: Set<String>, vault: UUID) {
        self.vault = vault
        reason = problem.reason
        let unexpected = Set(problem.unexpected)
        var list = recipients.map {
            Candidate(key: $0.key, label: $0.label, isHeld: held.contains($0.key),
                      isUnconfirmed: unexpected.contains($0.key) && !held.contains($0.key), isRemoved: false)
        }
        for key in problem.missing where !list.contains(where: { $0.key == key }) {
            list.append(Candidate(key: key, label: "", isHeld: held.contains(key), isUnconfirmed: false, isRemoved: true))
        }
        candidates = list
        let base = Set(problem.restore ?? []).union(list.filter(\.isHeld).map(\.key))
        initial = Set(list.filter { base.contains($0.key) && !$0.isUnconfirmed }.map(\.key))
    }

    /// The kept keys in list order (the order `repairRecipients` writes).
    func keeping(_ selected: Set<String>) -> [String] {
        candidates.map(\.key).filter(selected.contains)
    }

    /// Why `selected` cannot be written, or nil.
    func problem(with selected: Set<String>) -> AppModel.KeyError? {
        let kept = keeping(selected)
        guard kept.count == selected.count else { return .notListed }
        guard !kept.isEmpty else { return .lastKey }
        let held = candidates.filter(\.isHeld)
        guard !held.isEmpty else { return .heldKeyMissing }
        guard held.allSatisfy({ selected.contains($0.key) }) else { return .keepHeldKey }
        return nil
    }

    /// Whether keeping `selected` lets a key nothing confirms read the vault.
    func needsOwner(_ selected: Set<String>) -> Bool {
        candidates.contains { $0.isUnconfirmed && selected.contains($0.key) }
    }

    /// The confirmation's text: what stays, what goes, what it costs.
    func summary(_ selected: Set<String>) -> String {
        let kept = candidates.filter { selected.contains($0.key) }
        let dropped = candidates.filter { !selected.contains($0.key) && !$0.isRemoved }
        var lines = [String(localized: "Keep: \(kept.map(\.display).joined(separator: ", ")).",
                            comment: "Repair confirmation; the value is a list of device names and abbreviated keys")]
        if !dropped.isEmpty {
            lines.append(String(localized: "Remove: \(dropped.map(\.display).joined(separator: ", ")).",
                                comment: "Repair confirmation; the value is a list of device names and abbreviated keys"))
        }
        lines.append(String(localized: "Every note is re-encrypted with a new vault key. Devices you do not keep can no longer open new or changed notes; they keep what they already copied."))
        if needsOwner(selected) {
            lines.append(String(localized: "You are keeping a device this device never confirmed. Keep it only if you know it is yours."))
        }
        return lines.joined(separator: "\n\n")
    }
}

extension AppModel {
    /// Remove in the alert: rewrites the last verified list and rotates the
    /// vault secret, re-encrypting every note (format.md §2.1 "Repair"), as a
    /// key change (editors closed first, `keyEpoch` bumped).
    func repairRecipients() async throws {
        guard let alert = recipientsAlert, alert.canRemove else { return }
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.repairRecipients(policy: policy) }
        if vault?.recipientsStatus.problem == nil { recipientsAlert = nil }
    }

    /// Choose Devices to Keep in the alert: the choice for the open vault's
    /// current problem, or nil when no repair is possible.
    func recipientsRepairChoice() -> RecipientsRepairChoice? {
        guard let vault, phase == .unlocked, let problem = vault.recipientsStatus.problem,
              problem.reason != .secretUnconfirmed else { return nil }
        return RecipientsRepairChoice(problem: problem, recipients: vault.recipients, held: heldRecipients,
                                      vault: vault.vaultId)
    }

    /// Repairs the list keeping exactly `selected` (`Vault.repairRecipients(keeping:)`,
    /// the CLI's `repair --keep`): the secret rotates and every file is
    /// rewrapped, as a key change. The choice is rebuilt from the vault as
    /// it is now, so a stale sheet cannot write a list it no longer offers.
    /// The owner authenticates first when an unconfirmed key is kept.
    func repairRecipients(keeping selected: Set<String>, expectedVault: UUID,
                          authenticator: any OwnerAuthenticator = SystemOwnerAuthenticator()) async throws {
        guard vault != nil, phase == .unlocked else { throw KeyError.notUnlocked }
        guard vault?.vaultId == expectedVault else { throw KeyError.vaultChanged }
        guard let choice = recipientsRepairChoice() else { throw KeyError.nothingToRepair }
        if let problem = choice.problem(with: selected) { throw problem }
        if choice.needsOwner(selected) {
            let name = vaultName ?? String(localized: "Vault", comment: "Name shown for a vault that has none")
            try await requireOwner(authenticator, reason: String(localized: "Keep an unconfirmed device key in “\(name)”"),
                                   vault: expectedVault)
        }
        let keys = choice.keeping(selected)
        let policy = RewrapSettings.policy()
        try await changeRecipients { try $0.repairRecipients(keeping: keys, policy: policy) }
        if vault?.recipientsStatus.problem == nil { recipientsAlert = nil }
    }

    /// Trust This List in the alert (an unreadable trust record): records
    /// the current list again after the user checked it. Nothing in the
    /// vault changes unless the list was untagged (it is tagged then).
    /// As a key change (editors closed first, `keyEpoch` bumped), but
    /// without downloading the vault: no file under `notes/` changes.
    func confirmRecipientsList() async throws {
        guard let alert = recipientsAlert, alert.canConfirm, let start = vault, phase == .unlocked else { return }
        await editGate.acquire()
        defer { editGate.release() }
        let gen = generation
        try await openEditor(for: nil)   // saved, and closed: it holds the tampered status
        await closeWindowEditors()
        try ensureCurrent(gen)
        let coordinate = coordinationURL
        let next = try await offMain { () throws -> Vault in
            try CloudVault.coordinatedWrite(coordinate) { () throws -> Vault in
                var copy = start
                try copy.confirmRecipients()
                return copy
            }
        }
        try ensureCurrent(gen)
        adoptRewrapped(next)
    }

    /// Cancel in the alert: the vault stays open for reading; writes keep
    /// failing with `untrustedRecipients` until it is repaired.
    func dismissRecipientsAlert() {
        recipientsAlert = nil
    }
}
