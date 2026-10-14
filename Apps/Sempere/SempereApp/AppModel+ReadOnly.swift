import Foundation
import Sempere

/// Vaults holding content of a newer format version (format.md §7.3): the
/// app shows what it understands and writes nothing. The library refuses
/// every write of such a vault (`Vault.requireWritable`); the model refuses
/// earlier, so nothing starts that would fail half way, and the UI says why.
extension AppModel {
    /// Why the open vault is read-only: its manifest (a later `format`,
    /// unknown `features`) and the listed notes a newer version wrote. Empty
    /// when it can be changed. Observable through `vault` and `notes`.
    var readOnlyReasons: ReadOnlyReasons {
        var reasons = vault?.readOnlyReasons ?? ReadOnlyReasons()
        let listed = notes.lazy.filter { $0.newer != nil }.map(\.id)
        if !listed.isEmpty {
            reasons.newerNotes = Set(reasons.newerNotes).union(listed).sorted { $0.uuidString < $1.uuidString }
        }
        return reasons
    }

    /// True when nothing may be written to the open vault.
    var isVaultReadOnly: Bool { !readOnlyReasons.isEmpty }

    /// The banner over the note list of a read-only vault; nil when writable.
    var readOnlyBanner: String? {
        let reasons = readOnlyReasons
        guard !reasons.isEmpty else { return nil }
        return Self.readOnlyText(reasons)
    }

    /// "Read-only: <reasons>. Update Sempere to change this vault."
    nonisolated static func readOnlyText(_ reasons: ReadOnlyReasons) -> String {
        let details = readOnlyDetails(reasons).joined(separator: "; ")
        return String(localized: "Read-only: \(details). Update Sempere to change this vault.")
    }

    /// The reasons, localized. `ReadOnlyReasons.descriptions` is the CLI's English, which in the
    /// banner left an English clause inside the Spanish sentence; the format and feature names
    /// themselves are identifiers and stay as they are.
    nonisolated static func readOnlyDetails(_ reasons: ReadOnlyReasons) -> [String] {
        var out: [String] = []
        if let format = reasons.vaultFormat {
            let current = SempereFormat.identifier
            out.append(String(localized: "the vault uses format \(format), newer than this version's \(current)"))
        }
        if !reasons.unknownFeatures.isEmpty {
            let features = reasons.unknownFeatures.joined(separator: ", ")
            out.append(String(localized: "the vault uses format extensions this version does not know: \(features)"))
        }
        if !reasons.newerNotes.isEmpty {
            out.append(String(localized: "\(reasons.newerNotes.count) notes hold revisions written by a newer version"))
        }
        return out
    }

    /// Throws `VaultError.readOnly` for a read-only vault (format.md §7.3).
    func requireWritableVault() throws {
        let reasons = readOnlyReasons
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
    }
}
