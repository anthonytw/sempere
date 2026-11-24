import Foundation
import Sempere
import SempereSync

/// What the Sync Targets sheet, Open Vault and Vault Details need of iCloud (CloudKit) beyond running a target
/// (docs/design/1.4-cloudkit.md §8, §9): the account's state, the vaults it holds, opening one onto this device, the one-time
/// suggestion on a device that lacks a target, recovery (Upload Again, Use This Account) and Delete from iCloud. Each has a
/// `sempere cloudkit` command (CLI first); the logic is `CloudVaults` and `CloudTargetRun` in `SempereSync`.
extension AppModelCore {
    /// Whether this build can use iCloud (CloudKit) at all (the app's entitlement, a headless model: none).
    public var cloudKitIsAvailable: Bool { services.cloudKit?.isAvailable() == true }

    /// The signed-in account's status, for the Add sheet ("Sign in to iCloud in Settings first."); nil when this build has
    /// no CloudKit.
    public func cloudKitAccountStatus() async -> CloudAccount.Status? {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { return nil }
        return (try? await offMain { try cloud.makeStore().account() })?.status ?? .couldNotDetermine
    }

    /// The vaults the signed-in account's iCloud holds, by name (Open Vault ▸ From iCloud).
    public func cloudKitVaults() async throws -> [CloudVaultListing] {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        do {
            let store = cloud.makeStore()
            let account = try await offMain { try store.account() }
            guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
            return try await offMain { try CloudVaults.list(store: store) }
        } catch let e as CloudKitTargetProblem {
            throw e
        } catch {
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
    }

    /// Opens a vault of the account's iCloud on this device: copies it into the store (a vault already in the store is opened
    /// as it is), adds the CloudKit target to the copy and opens it. A keyless copy opens locked, as after Open Vault from a
    /// folder: Join This Device (the words or the code) takes it from there.
    ///
    /// The copy is downloaded whole before it opens (the progress shows in `vaultCopy`); a partial copy that opens first, as for
    /// WebDAV, is not done for CloudKit (design §8 says "a partial copy first"; recorded in §15).
    public func openCloudKitVault(_ vaultId: String, library: VaultLibrary) async throws {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        guard let id = UUID(uuidString: vaultId) else { throw CloudKitTargetProblem.noSuchVault }
        guard vaultCopy == nil else { throw VaultStoreProblem(error: .busy(id)) }
        if let existing = library.vaultStore.entry(id: id) {
            if !syncStore.targets.targets(of: id).contains(where: { $0.kind == .cloudkit }) { _ = try await addCloudKitTarget(to: id) }
            try await openVault(at: existing.url)
            library.rememberStored(existing)
            return
        }
        let store = cloud.makeStore()
        let account = try await offMain { try store.account() }
        guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
        let listing = try await offMain { try CloudVaults.list(store: store) }.first { $0.vaultId == id.uuidString.lowercased() }
        guard let listing else { throw CloudKitTargetProblem.noSuchVault }
        vaultCopy = VaultCopyProgress(name: listing.name, stage: .downloading(done: 0, total: 0))
        defer { vaultCopy = nil }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = work.appendingPathComponent("vault.sempere", isDirectory: true)
        let state = work.appendingPathComponent("state", isDirectory: true).appendingPathComponent("sync-state.json")
        let entry: VaultStore.Entry
        do {
            try await offMain { try CloudVaults.download(vaultId: id, store: store, into: folder, stateURL: state,
                                                         expectedUser: account.userHash).requireComplete() }
            vaultCopy?.stage = .copying(done: 0, total: 0)
            entry = try await library.copyIn(folder, coordinated: false, files: services.files) { [weak self] done, total in
                Task { @MainActor in self?.vaultCopy?.stage = .copying(done: done, total: total) }
            }
        } catch let e as VaultStoreError {
            throw VaultStoreProblem(error: e)
        } catch let e as CloudKitTargetProblem {
            throw e
        } catch {
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
        _ = try await addCloudKitTarget(to: entry.vaultId)
        try await openVault(at: entry.url)
        remember(in: library)
    }

    // MARK: The suggestion on another device (design §8, step 3)

    static func cloudKitSuggestedKey(_ vault: UUID) -> String { "cloudkit.suggestion.\(vault.uuidString.lowercased())" }

    /// True when the account's iCloud holds this vault's zone, the vault has no CloudKit target here, and the suggestion
    /// was not made before ("This vault is in iCloud (CloudKit). Sync with it here too?"). Suggested, never added by itself.
    public func cloudKitSuggestion(for vaultID: UUID) async -> Bool {
        guard let cloud = services.cloudKit, cloud.isAvailable(), syncStore.entry(id: vaultID) != nil,
              !services.settings.bool(forKey: Self.cloudKitSuggestedKey(vaultID)),
              !syncStore.targets.targets(of: vaultID).contains(where: { $0.kind == .cloudkit }) else { return false }
        let zone = CloudTargetRun.zone(vaultId: vaultID)
        let found = try? await offMain { () -> Bool in
            let store = cloud.makeStore()
            guard try store.account().status == .available else { return false }
            return try store.zones().contains(zone)
        }
        return found == true
    }

    /// The suggestion was answered (taken, or "Not Now"): it is not made again for this vault on this device.
    public func cloudKitSuggestionAnswered(for vaultID: UUID) {
        services.settings.set(true, forKey: Self.cloudKitSuggestedKey(vaultID))
    }

    // MARK: Recovery and deleting (design §4, §9)

    /// "Upload Again" (a zone that is gone or was deleted in iCloud settings) and "Use This Account" (another Apple Account):
    /// the target is removed and made again for the account signed in now. The first run is a union into that account's zone
    /// (a new one when the old is gone); nothing on this device is deleted.
    @discardableResult
    public func restartCloudKitTarget(_ targetID: UUID, of vaultID: UUID) async throws -> SyncTarget {
        try await removeSyncTarget(targetID, of: vaultID)
        return try await addCloudKitTarget(to: vaultID)
    }

    /// "Delete from iCloud…": removes this vault's CloudKit target and deletes its zone with everything in it; other devices
    /// stop syncing through it. Only for a vault that has another target (the caller checks `hasOtherCopy`, as the sheet does).
    public func deleteFromICloud(_ targetID: UUID, of vaultID: UUID) async throws {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        let zone = CloudTargetRun.zone(vaultId: vaultID)
        try await removeSyncTarget(targetID, of: vaultID)
        do { try await offMain { try cloud.makeStore().deleteZone(zone) } } catch {
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
    }

    /// True when the vault has a copy that is not CloudKit's: another target. (Backups are the sheet's note, §7.)
    public func hasCopyBesidesICloud(_ vaultID: UUID) -> Bool {
        syncStore.targets.targets(of: vaultID).contains { $0.kind != .cloudkit }
    }
}

extension SyncReport {
    /// A first download that stopped short (an error, a bound) is not a copy to import.
    func requireComplete() throws {
        guard errors.isEmpty, stoppedEarly == nil else {
            throw CloudKitTargetProblem.other(SyncReport.printable(errors.first.map { "\($0.path): \($0.message)" } ?? "the download stopped early"))
        }
    }
}
