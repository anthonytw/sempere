import Foundation
import Sempere

/// Vaults holding content of a newer format version (format.md §7.3): the
/// app shows what it understands and writes nothing. The library refuses
/// every write of such a vault (`Vault.requireWritable`); the model refuses
/// earlier, so nothing starts that would fail half way, and the UI says why.
extension AppModelCore {
    /// Why the open vault is read-only: its manifest (a later `format`,
    /// unknown `features`) and the listed notes a newer version wrote. Empty
    /// when it can be changed. Observable through `vault` and `notes`.
    public var readOnlyReasons: ReadOnlyReasons {
        var reasons = vault?.readOnlyReasons ?? ReadOnlyReasons()
        let listed = notes.lazy.filter { $0.newer != nil }.map(\.id)
        if !listed.isEmpty {
            reasons.newerNotes = Set(reasons.newerNotes).union(listed).sorted { $0.uuidString < $1.uuidString }
        }
        return reasons
    }

    /// Why this device is not on the newest device list: the open vault's state at open, or what a run of one of
    /// its targets met since (the vault is opened again then, `reopenIfUnlisted`). Nil while listed.
    var unlistedNotice: String? {
        guard let vault, !vault.isRecoveryOpen else { return nil }
        return vault.unlistedNotice ?? syncSessions.lazy.compactMap { $0.lastReport?.epoch?.unlisted }.first
    }

    /// True when the open vault was unlocked with its recovery key (or the
    /// recovery key's passphrase copy): it reads everything and writes nothing
    /// (design §4.3 step 4).
    public var isRecoveryOpen: Bool { vault?.isRecoveryOpen ?? false }

    /// Why the unlocked vault's device list does not check here (design §4.3; `ListStatus.refused`): the library
    /// refuses every write then (`requireWritable`), so the app is read-only too. Nil when it checks, while locked,
    /// and for a recovery read (read-only anyway).
    public var listProblem: ListProblem? {
        guard phase == .unlocked, !isRecoveryOpen else { return nil }
        return vault?.listStatus.problem
    }

    /// True when this device's key opened the vault but the device has not confirmed it (no trust record, no root:
    /// a key pasted from elsewhere, such as the demo vault's): typing the kit's root confirms it (`confirmVaultRoot`).
    public var needsVaultConfirmation: Bool { listProblem?.reason == .rootUnconfirmed }

    /// True when nothing may be written to the open vault.
    public var isVaultReadOnly: Bool {
        isRecoveryOpen || !readOnlyReasons.isEmpty || unlistedNotice != nil || listProblem != nil
    }

    /// Throws `VaultError.readOnly` for a read-only vault (format.md §7.3).
    public func requireWritableVault() throws {
        if isRecoveryOpen { throw VaultError.recoveryKeyReadOnly }
        // Not on the newest device list (key-hierarchy design §5.5): the library refuses every write too.
        if let notice = unlistedNotice { throw VaultError.removedFromVault(notice) }
        let reasons = readOnlyReasons
        if !reasons.isEmpty { throw VaultError.readOnly(reasons) }
        if let problem = listProblem { throw VaultError.untrustedList(problem) }
    }

    /// Confirms the open vault with the root fingerprint from its recovery kit (typed: 16 groups, or 64 hex digits;
    /// or the kit's root code), for a device key that opened it without this device having confirmed it
    /// (`needsVaultConfirmation`). `vault.json` is checked against that root, this device's trust record is saved
    /// (later opens check against it, as after a join), and the vault is writable from then on. The CLI does the
    /// same with `--root` on a write.
    public func confirmVaultRoot(_ text: String) async throws {
        guard phase == .unlocked, let current = vault, let url = vaultURL, !isRecoveryOpen else { throw ModelError.noVaultOpen }
        let root = try Self.kitRoot(text, vaultId: current.vaultId)
        let keys = unlockKeys, trust = self.trust, stores = writeStores, gen = generation
        let opened = try await offMain { () throws -> Vault in
            let v = try Vault.open(at: url, identities: keys.identities, signing: keys.signing, trust: trust, root: root,
                                   ledger: stores?.ledger(for: current.vaultId), setAside: stores?.setAside)
            if let problem = v.listStatus.problem { throw VaultError.untrustedList(problem) }
            try v.requireWritable()   // a writer keeps the record: from now on the list is checked against it
            return v
        }
        try ensureCurrent(gen)
        adoptReopened(opened)
    }

    /// The root fingerprint the user gave from the kit: its root code (of this vault), or the 16 groups typed.
    nonisolated static func kitRoot(_ text: String, vaultId: UUID) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let qr = KitRecovery.parseRootQR(trimmed) {
            guard qr.vaultId == vaultId else { throw DeviceJoinError.otherVaultsRoot }
            return qr.root
        }
        guard let typed = KitRecovery.parseRootText(trimmed) else { throw DeviceJoinError.rootUnreadable }
        return typed
    }
}
