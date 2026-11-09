import Foundation
import Sempere
import SempereSync

/// What Vault Details shows for one store vault (docs/design/device-first-sync.md §8.3, §8.4; P9): the copy's
/// sizes and each target with its devices, quarantine and staging. The same as `sempere store info`.
public struct VaultDetailsSnapshot: Sendable, Equatable {
    public var storage: VaultStorage
    public var targets: [TargetDetails]

    init(storage: VaultStorage, targets: [TargetDetails]) {
        self.storage = storage
        self.targets = targets
    }
}

/// Why Repair could not act on a quarantined file; worded by the app.
public enum RepairProblem: Error, Equatable, Sendable {
    /// Adopting checks the file under the vault's keys: the vault must be open and unlocked.
    case unlockFirst
}

extension AppModelCore {
    /// Vault Details for the store vault `vaultID`, read off the main actor from this device only.
    public func vaultDetails(_ vaultID: UUID, measureFolders: Bool = false) async throws -> VaultDetailsSnapshot {
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let device = try? deviceClockForWriting().device
        let bookmarks = services.bookmarks
        return try await offMain(priority: .utility) {
            // A folder target is measured through its bookmark (its path alone is outside the sandbox on iOS).
            var opened: [FolderTargetAccess] = []
            defer { opened.forEach { $0.close() } }
            let targets = try store.targetDetails(entry, thisDevice: device, measureFolders: measureFolders) { target in
                guard let access = try? FolderTargetAccess.open(target, bookmarks: bookmarks) else { return nil }
                opened.append(access)
                return access.folder
            }
            return VaultDetailsSnapshot(storage: TargetInspection.storage(of: entry.url), targets: targets)
        }
    }

    /// Repair ▸ Adopt: checks the quarantined `path` of target `target` again under the open vault's keys and
    /// places it if it passes (`TargetQuarantine.adopt`); what it brought reaches the list as an arrival.
    public func adoptQuarantined(_ path: String, target: UUID, of vaultID: UUID) async throws {
        guard let vault, vault.vaultId == vaultID, phase == .unlocked, vault.canRead else { throw RepairProblem.unlockFirst }
        try requireWritableVault()
        let store = syncStore
        guard let entry = store.entry(id: vaultID) else { throw SyncTargetProblem.notAStoreVault }
        let quarantine = store.quarantine(target, of: vaultID), lock = store.writeLock(for: vaultID)
        let changed = try await offMain {
            try quarantine.adopt(path, vaultFolder: entry.url, vault: vault, writeLock: lock)
        }
        if let changed { applySyncChanges(changed) }
    }

    /// Repair ▸ Export: a copy of the quarantined file in `folder` (picked: its security scope is held for the
    /// copy). The quarantine keeps it.
    @discardableResult
    public func exportQuarantined(_ path: String, target: UUID, of vaultID: UUID, to folder: URL) async throws -> URL {
        let quarantine = syncStore.quarantine(target, of: vaultID)
        let bookmarks = services.bookmarks
        return try await offMain {
            try bookmarks.withAccess(to: folder) { try quarantine.export(path, to: folder) }
        }
    }

    /// Repair ▸ Delete: the user's choice; no sync run ever deletes a quarantined file.
    public func deleteQuarantined(_ path: String, target: UUID, of vaultID: UUID) async throws {
        let quarantine = syncStore.quarantine(target, of: vaultID)
        try await offMain { try quarantine.delete(path) }
    }
}
