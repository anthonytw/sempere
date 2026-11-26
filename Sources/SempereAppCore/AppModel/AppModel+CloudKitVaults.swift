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
        // The download shows how far it is (files of the listing), so a large vault does not sit at "0 of 0".
        let relay = WebDAVProgressRelay { [weak self] p in
            if case .downloading? = self?.vaultCopy?.stage { self?.vaultCopy?.stage = .downloading(done: p.filesDone, total: p.filesTotal) }
        }
        defer { relay.close() }
        var downloadOptions = SyncOptions()
        downloadOptions.progress = { relay.send($0) }
        do {
            try await offMain { [downloadOptions] in
                try CloudVaults.download(vaultId: id, store: store, into: folder, stateURL: state, expectedUser: account.userHash,
                                         options: downloadOptions).requireComplete()
            }
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
        _ = try await addCloudKitTarget(to: entry.vaultId, seedState: state, seedUser: account.userHash)   // `work` is removed when this returns
        try await openVault(at: entry.url)
        remember(in: library)
    }

    // MARK: The vault's name in iCloud

    /// A vault in iCloud is listed by the `label` in its `vault.json` (`CloudVaults.list`, Open Vault ▸ From iCloud, `sempere
    /// cloudkit list`); the app's own name for a vault is its folder name in the store. A vault with a CloudKit target and no
    /// label (made before 1.4 wrote one, or by a build that did not) gets its store name as the label, once, while it is open
    /// and unlocked here (the label is covered by no tag or signature, so any listed device may write it, format.md §2; folder
    /// and WebDAV targets of the same vault, and 1.3 devices, take it as a label-only change). A label that is there is never
    /// replaced. Best effort: a read-only or recovery-key open writes nothing. The CloudKit sessions run at once (`demandRun`),
    /// so the name is in the zone within moments; `beforeTarget`: the target is about to be added (its first run carries the name).
    func ensureICloudLabel(demandRun: Bool = true, beforeTarget: Bool = false) async {
        guard let open = vault, phase == .unlocked, open.label == nil,
              let entry = syncStore.entry(id: open.vaultId),
              beforeTarget || syncStore.targets.targets(of: open.vaultId).contains(where: { $0.kind == .cloudkit }) else { return }
        let lock = syncStore.writeLock(for: open.vaultId), name = entry.name
        // On a copy, off the main actor: `setLabel` is a write (it catches this device's files up first, design §5.4), so it takes the
        // vault's write lock like any other. `attempted`: the copy may have written something even when the label did not go in.
        let result = try? await offMain { () -> (next: Vault?, attempted: Bool) in
            var copy = open
            let wrote = try lock.withLock(timeout: 10) { copy.setLabelIfMissing(name) }
            return (wrote ? copy : nil, true)
        }
        if let next = result?.next {
            // Only when the open vault is still the one copied: a write made meanwhile keeps its own state.
            guard vault?.manifest == open.manifest else { await checkOpenVaultAgainstDisk(); return }
            adoptLabeled(next)   // the open vault's manifest is the file's again (nothing reopens: only the label changed)
            if demandRun { for session in syncCoordinator.sessions(of: next.vaultId) where session.kind == .cloudkit { session.demand() } }
        } else {
            // The label did not go in (read-only, locked, a lock timeout), but the attempt may have changed the file (a catch-up):
            // the model's vault is checked against the disk, and reopened if it differs.
            await checkOpenVaultAgainstDisk()
        }
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

    /// "Upload Again" (a zone that is gone or was deleted in iCloud settings) and "Use This Account" (another Apple Account): the
    /// target is made again for the account signed in now, **in place**: its account is replaced and its mirror and sync state
    /// are reset (the first run is a union into that account's zone, a new one when the old is gone, and deletes nothing), while its
    /// quarantine and the files staged for the next unlock stay. A failure before the change leaves the target as it was.
    @discardableResult
    public func restartCloudKitTarget(_ targetID: UUID, of vaultID: UUID) async throws -> SyncTarget {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        guard syncStore.targets.targets(of: vaultID).contains(where: { $0.id == targetID && $0.kind == .cloudkit }) else {
            throw CloudKitTargetProblem.notACloudKitTarget
        }
        let account = try await offMain { try cloud.makeStore().account() }
        guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
        await syncCoordinator.stop(targetID)?.value
        let targets = syncStore.targets
        do {
            try targets.update(targetID, of: vaultID) { $0.cloudUser = account.userHash; $0.lastSuccess = nil; $0.restarted = Date() }
        } catch {
            syncTargetsChanged()
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
        targets.resetState(targetID, of: vaultID)
        try? FileManager.default.removeItem(at: targets.stateDirectory(targetID, of: vaultID).appendingPathComponent("cloudkit", isDirectory: true))
        // The staged files stay (placed at the next unlock, a union); the staging's own sync state was the old zone's.
        LockedStaging(targetState: targets.stateURL(targetID, of: vaultID)).resetState()
        syncTargetsChanged()
        syncCoordinator.sessions[targetID]?.demand()
        guard let made = targets.targets(of: vaultID).first(where: { $0.id == targetID }) else { throw CloudKitTargetProblem.notACloudKitTarget }
        return made
    }

    /// "Delete from iCloud…": deletes this vault's zone with everything in it (other devices stop syncing through it), then removes
    /// the CloudKit target. Refused unless the target is this vault's CloudKit target, it was made with the account signed in now
    /// (another account's zone is not deleted by a switch), and another copy exists: another target, or this vault's own backup. The
    /// zone goes first, so a failure (offline, say) leaves the target and the retry in place.
    public func deleteFromICloud(_ targetID: UUID, of vaultID: UUID) async throws {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        guard let target = syncStore.targets.targets(of: vaultID).first(where: { $0.id == targetID && $0.kind == .cloudkit }) else {
            throw CloudKitTargetProblem.notACloudKitTarget
        }
        guard hasCopyBesidesICloud(vaultID) else { throw CloudKitTargetProblem.noOtherCopy }
        let zone = CloudTargetRun.zone(vaultId: vaultID)
        do {
            try await offMain {
                let store = cloud.makeStore()
                let account = try store.account()
                guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
                if let mine = target.cloudUser, account.userHash != mine { throw CloudKitTargetProblem.otherAccount }
                try store.deleteZone(zone)
            }
        } catch let e as CloudKitTargetProblem {
            throw e
        } catch {
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
        try await removeSyncTarget(targetID, of: vaultID)
    }

    /// What deleting the iCloud vault `vaultId` (a row of Open Vault ▸ From iCloud) leaves behind, for the confirmation: whether the
    /// store here holds a copy, and whether any copy besides iCloud's is kept (another target, or a backup).
    public struct ICloudDeletionImpact: Equatable, Sendable {
        /// This device's store holds the vault (a copy stays here).
        public var copyHere: Bool
        /// Another sync target or this vault's backup holds it too.
        public var otherCopy: Bool
        /// Nothing besides iCloud holds the vault: deleting loses it for good (unless another of the user's devices has it).
        public var onlyICloud: Bool { !copyHere && !otherCopy }
    }

    public func iCloudDeletionImpact(_ vaultId: String, library: VaultLibrary) -> ICloudDeletionImpact {
        guard let id = UUID(uuidString: vaultId) else { return ICloudDeletionImpact(copyHere: false, otherCopy: false) }
        return ICloudDeletionImpact(copyHere: library.vaultStore.entry(id: id) != nil, otherCopy: hasCopyBesidesICloud(id))
    }

    /// "Delete from iCloud" for a vault the account's iCloud lists (Open Vault ▸ From iCloud, `sempere cloudkit delete`): deletes
    /// the vault's zone with everything in it (every other device that syncs through it stops), and this device's iCloud targets of
    /// the vault, if any. It needs no copy on this device, which is the point: a zone no device here has (a vault another device
    /// made and removed, a half-made one) is listed and can be deleted only this way. A vault with no copy here and none besides
    /// iCloud is deleted only when the caller says the user was told so (`acknowledgingNoOtherCopy`: the confirmation names it). Unlike Vault Details' `deleteFromICloud`, which refuses a vault whose only other copy is the store's own (it needs another target or a backup), this accepts a store copy as the copy that stays, because the list also holds zones that no copy of is here at all and those must be deletable; the difference is stated in docs/design/1.4-cloudkit.md §16.
    /// Targets made with another Apple Account are not removed (the zone deleted is the signed-in account's).
    public func deleteICloudVault(_ vaultId: String, library: VaultLibrary, acknowledgingNoOtherCopy: Bool) async throws {
        guard let cloud = services.cloudKit, cloud.isAvailable() else { throw CloudKitTargetProblem.unavailable }
        guard let id = UUID(uuidString: vaultId) else { throw CloudKitTargetProblem.noSuchVault }
        let zone = CloudTargetRun.zone(vaultId: id)
        if iCloudDeletionImpact(vaultId, library: library).onlyICloud, !acknowledgingNoOtherCopy { throw CloudKitTargetProblem.noOtherCopy }
        // This device's CloudKit targets of the vault stop first: a run that is going (or one that never synced) could make the zone
        // again right after it is deleted. A failure puts them back (`syncTargetsChanged` makes the sessions again).
        let mine = syncStore.targets.targets(of: id).filter { $0.kind == .cloudkit }
        for target in mine {
            syncCoordinator.sessions[target.id]?.interruptRun(hard: true)   // stopped at once in any phase (a large first feed too), not waited for
            await syncCoordinator.stop(target.id)?.value
        }
        let user: String
        do {
            let account = try await offMain { try cloud.makeStore().account() }
            guard account.status == .available else { throw CloudKitTargetProblem.account(account.status) }
            user = account.userHash ?? ""
            try await offMain { try cloud.makeStore().deleteZone(zone) }
        } catch let e as CloudKitTargetProblem {
            syncTargetsChanged()
            throw e
        } catch {
            syncTargetsChanged()
            throw CloudKitTargetProblem.other(services.describeError(error))
        }
        // The zone is gone: this device's targets for it (made with this account) go too; they would only report "iCloud data gone".
        // One that cannot be removed leaves the rest; the caller lists the account again (the zone is gone, the list says so).
        for target in mine where target.cloudUser == nil || target.cloudUser == user {
            try await removeSyncTarget(target.id, of: id)
        }
        syncTargetsChanged()
    }

    /// True when the vault has a copy that is not CloudKit's: another target, or this vault's own backup folder (not the open
    /// vault's: Vault Details shows vaults that are not open).
    public func hasCopyBesidesICloud(_ vaultID: UUID) -> Bool {
        syncStore.targets.targets(of: vaultID).contains { $0.kind != .cloudkit } || backupStore.record(for: vaultID).bookmark != nil
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
