import Foundation
import Sempere
import SempereSync

/// What "Open Vault…" does with the folder it copied a vault from (docs/design/device-first-sync.md §8.1).
public enum CopyInFollowUp: Sendable, Equatable {
    /// A one-time import: the source is never written, and the in-app copy is the only one from then on.
    case importOnly
    /// "Keep syncing with this folder": the source becomes a folder target of the in-app copy.
    case keepSyncing

    /// The default for a picked folder: keep syncing with iCloud Drive and other providers' folders, a
    /// one-time import for a local folder (an export) and always for a backup (`isBackup`).
    public static func suggested(for url: URL, hooks: CloudVault.Hooks, bookmarks: any FolderBookmarks) -> CopyInFollowUp {
        bookmarks.withAccess(to: url) {
            if isBackupLocked(url) || !isWritableLocked(url) { return .importOnly }
            return hooks.isUbiquitous(url) || FolderLocation.classify(url).needsCoordination ? .keepSyncing : .importOnly
        }
    }

    /// Whether this account may write to the folder a vault picked at `url` would sync with (`VaultLocator`, else
    /// `url`): not when another user owns it or it is read-only (build 12: the demo vault in /Users/Shared, made by
    /// another account, kept as a sync target, failed every run with "errno 13"). Then the vault is only copied in.
    public static func isWritable(_ url: URL, bookmarks: any FolderBookmarks) -> Bool {
        bookmarks.withAccess(to: url) { isWritableLocked(url) }
    }

    static func isWritableLocked(_ url: URL) -> Bool {
        let folder = (try? VaultLocator.resolve(url)) ?? url
        return FolderAccess.isWritableFolder(folder)
    }

    /// Whether the vault `url` stands for (`VaultLocator`) is a backup (`backup.json`): opening one is a
    /// one-time import, never "keep syncing" (a sync would write into the backup and pass deletions on).
    public static func isBackup(_ url: URL, bookmarks: any FolderBookmarks) -> Bool {
        bookmarks.withAccess(to: url) { isBackupLocked(url) }
    }

    /// Whether the vault `url` stands for (`VaultLocator`; a backup's too) is in `store` already, by its id: then
    /// `copyIn` opens that copy and copies nothing (the Open Vault sheet says so; review of #109). The id is read the
    /// way `copyIn` reads it, under one coordinated read in iCloud Drive or another provider's storage (review of
    /// #113); false when it cannot be read (not downloaded yet), and `copyIn` finds out then.
    public static func isOnDevice(_ url: URL, store: VaultStore, hooks: CloudVault.Hooks,
                                  bookmarks: any FolderBookmarks, files: any FileCoordinating) -> Bool {
        bookmarks.withAccess(to: url) {
            guard let source = try? VaultLocator.resolve(url) else { return false }
            let coordinated = hooks.isUbiquitous(source) || FolderLocation.classify(source).needsCoordination
            guard let id = try? files.coordinatedRead(coordinated ? source : nil, { try Vault.open(at: source).vaultId })
            else { return false }
            return store.entry(id: id) != nil
        }
    }

    /// `isBackup` with the security scope already held.
    private static func isBackupLocked(_ url: URL) -> Bool {
        BackupDestination.isBackup((try? VaultLocator.resolve(url)) ?? url)
    }
}

/// A copy-in in progress, for the overlay (`VaultCopyOverlay`; its words are the app's).
public struct VaultCopyProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Asking iCloud Drive (or the provider) for files not on this device yet.
        case downloading(done: Int, total: Int)
        /// Copying and checking files (`VaultStore.importVault`).
        case copying(done: Int, total: Int)
    }

    /// The vault's name, as the user sees it.
    public var name: String
    public var stage: Stage

    public init(name: String, stage: Stage) {
        self.name = name
        self.stage = stage
    }

    public var fraction: Double? {
        switch stage {
        case .downloading(let done, let total), .copying(let done, let total):
            return total > 0 ? Double(done) / Double(total) : nil
        }
    }
}

/// A vault store failure the app words (`VaultStoreError` is the CLI's English; the app's sentence is
/// `VaultStoreProblem.description`).
public struct VaultStoreProblem: Error, Equatable {
    public let error: VaultStoreError

    public init(error: VaultStoreError) { self.error = error }
}

/// A vault name `VaultStore.folderName` refuses (`VaultStoreError.invalidName`), worded by the app: New Vault and
/// Restore from Backup.
public struct InvalidVaultName: Error, Equatable {
    public init() {}

    /// Throws `InvalidVaultName` for a name the store would refuse.
    public static func check(_ name: String) throws {
        do { _ = try VaultStore.folderName(for: name) } catch { throw InvalidVaultName() }
    }
}

/// The in-app vault store (docs/design/device-first-sync.md §2, §8.1): New Vault creates
/// vaults there (`createVault`), "Open Vault…" copies a vault folder there and opens the copy
/// (`copyIn`), and the welcome list opens and removes them.
extension AppModelCore {
    /// "Open Vault…" and vaults handed to the app: copies the vault the user picked (a `.sempere` folder,
    /// a plain folder, a folder holding one vault: `VaultLocator`) into the store, then opens the copy.
    /// The picked folder is only read. A vault in iCloud Drive is downloaded completely first. The open
    /// vault stays open until the copy is in place, so a refused copy changes nothing. A vault whose id
    /// the store already holds is not copied again: its copy opens (`openExistingCopy`).
    ///
    /// - Parameters:
    ///   - external: the vault was handed to the app from outside (`handleOpened`, S16).
    ///   - followUp: what happens to the picked folder afterwards (P6 adds keeping it as a sync target).
    /// - Throws: `VaultStoreProblem` (not downloaded, incomplete…), or what
    ///   opening the copy throws.
    public func copyIn(picked url: URL, library: VaultLibrary, external: Bool = false,
                       followUp: CopyInFollowUp = .importOnly) async throws {
        guard vaultCopy == nil else { throw VaultStoreProblem(error: .busy(UUID())) }
        let bookmarks = services.bookmarks
        let scoped = bookmarks.startAccessing(url)
        defer { if scoped { bookmarks.stopAccessing(url) } }
        try FolderAccess.check(url, scoped: scoped)
        let source = try VaultLocator.resolve(url)
        // A backup is copied in once, never kept in sync (`VaultStore.checkFolderTarget` refuses it too); so is a folder
        // this account cannot write to (build 12, "errno 13"; the Open Vault sheet says so).
        let followUp = BackupDestination.isBackup(source) || !Self.isWritableFolder(source) ? .importOnly : followUp
        let hooks = iCloudHooks
        let ubiquitous = hooks.isUbiquitous(source)
        let coordinated = ubiquitous || FolderLocation.classify(source).needsCoordination
        // A vault already on this device opens its copy, before anything is downloaded or copied.
        let files = services.files
        let sourceID = try? await offMain { try files.coordinatedRead(coordinated ? source : nil) { try Vault.open(at: source).vaultId } }
        if let sourceID, let existing = library.vaultStore.entry(id: sourceID) {
            return try await openExistingCopy(existing, from: source, scope: url, library: library, external: external,
                                              followUp: followUp)
        }
        vaultCopy = VaultCopyProgress(name: VaultLibrary.displayName(of: source), stage: .copying(done: 0, total: 0))
        defer { vaultCopy = nil }
        if ubiquitous { try await downloadForCopyIn(source, hooks: hooks) }
        let entry: VaultStore.Entry
        do {
            entry = try await library.copyIn(source, coordinated: coordinated, files: files) { [weak self] done, total in
                Task { @MainActor in self?.vaultCopy?.stage = .copying(done: done, total: total) }
            }
        } catch VaultStoreError.alreadyInStore(let id, _) {
            // Its vault.json could not be read up front (iCloud had not delivered it yet).
            guard let existing = library.vaultStore.entry(id: id) else { throw VaultStoreProblem(error: .notFound(id.uuidString)) }
            vaultCopy = nil
            return try await openExistingCopy(existing, from: source, scope: url, library: library, external: external,
                                              followUp: followUp)
        } catch let error as VaultStoreError {
            throw VaultStoreProblem(error: error)
        }
        if followUp == .keepSyncing {
            // The two are equal now when `source` is the vault's `.sempere` sync folder: the first run finds nothing to do.
            try addKeepSyncingTarget(source, scope: url, entry: entry)
        }
        try await openVault(at: entry.url, external: external)
        remember(in: library)
    }

    /// "Open Vault…" on a vault whose id the store already holds: opens that copy (the store keeps one
    /// copy per vault id), and leaves `source` as it is.
    ///
    /// With "Keep syncing with this folder" (`.keepSyncing`, docs/design/device-first-sync.md §8.1) `source`
    /// becomes a target of that copy (unless it already is one): the first run is a union, which brings in
    /// what `source` has that the copy lacks, and the other way round.
    private func openExistingCopy(_ entry: VaultStore.Entry, from source: URL, scope: URL, library: VaultLibrary,
                                  external: Bool, followUp: CopyInFollowUp) async throws {
        if followUp == .keepSyncing {
            do { try addKeepSyncingTarget(source, scope: scope, entry: entry) } catch SyncTargetProblem.duplicate {}
        }
        if vaultURL?.standardizedFileURL != entry.url.standardizedFileURL {
            try await openVault(at: entry.url, external: external)
        }
        library.rememberStored(entry)
    }

    /// "Keep syncing with this folder": the folder `folderTargetLocation` gives for `source` (the `.sempere` sync
    /// folder itself; any other folder holding the vault, such as one build 10 synced bare, gets `<source>/<name>.sempere`).
    private func addKeepSyncingTarget(_ source: URL, scope: URL, entry: VaultStore.Entry) throws {
        let folder = try Self.folderTargetLocation(picked: source, vaultFolderName: entry.url.lastPathComponent,
                                                   vaultId: entry.vaultId)
        try addFolderTarget(folder, scope: scope, to: entry.vaultId)
    }

    /// Opens a vault of the in-app store (the welcome list) and remembers it.
    public func openStored(_ entry: VaultStore.Entry, library: VaultLibrary) async throws {
        if let joining = joiningWebDAVLocation(of: entry.vaultId) {
            return try await openWebDAV(joining, library: library)
        }
        try await openVault(at: entry.url)
        library.rememberStored(entry)
    }

    /// Reopens a recent vault: a store vault by its id, a WebDAV one by its location.
    ///
    /// - Throws: `VaultLibrary.LibraryError.cannotResolve` when the store no longer holds the vault;
    ///   otherwise whatever opening throws. The entry is kept either way.
    public func open(recent entry: RecentVault, library: VaultLibrary) async throws {
        if let location = entry.webdav {
            guard webdavLocations.location(location) != nil else {
                library.forget(entry)
                throw VaultLibrary.LibraryError.cannotResolve(name: entry.name)
            }
            return try await openWebDAV(location, library: library)
        }
        if let id = entry.storeID, let joining = joiningWebDAVLocation(of: id) {
            return try await openWebDAV(joining, library: library)
        }
        let url = try library.resolve(entry)
        try await copyIn(picked: url, library: library)
    }

    /// Everything of an iCloud Drive vault, before it is copied: root files, notes, attachments and the
    /// quick-capture inbox (a copy-in must be complete: `VaultStore.importVault` refuses placeholders).
    private func downloadForCopyIn(_ url: URL, hooks: CloudVault.Hooks) async throws {
        try await downloadSourceFolder(url, hooks: hooks) { [weak self] progress in
            await self?.showCopyDownload(progress)
        }
    }

    /// Downloads every file of the vault folder `url` in iCloud Drive (or another provider that reports its
    /// files): what a copy-in or a restore reads (`CloudVault.download`). The only iCloud reading the app
    /// does: every vault it opens is an in-app copy.
    public func downloadSourceFolder(_ url: URL, hooks: CloudVault.Hooks,
                                     progress: @escaping @Sendable (CloudProgress) async -> Void) async throws {
        let stall = cloudStallTimeout
        let poll = cloudPollInterval
        _ = try await CloudVault.download(vault: url, scope: .everything, hooks: hooks, stallTimeout: stall,
                                          pollInterval: poll, progress: progress)
        let extra = try await offMain {
            try CloudScan.inboxItems(inVault: url).map(\.item)
                + CloudScan.noteGroups(inVault: url).compactMap(\.id)
                    .flatMap { try CloudScan.blobItems(inVault: url, id: $0).map(\.item) }
        }
        try await CloudVault.download(items: extra, hooks: hooks, stallTimeout: stall, pollInterval: poll, progress: progress)
    }

    private func showCopyDownload(_ progress: CloudProgress) {
        vaultCopy?.stage = .downloading(done: progress.downloaded, total: progress.total)
    }
}
