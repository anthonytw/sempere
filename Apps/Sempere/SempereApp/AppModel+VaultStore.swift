import Foundation
import Sempere
import SempereSync

/// What "Open Vault…" does with the folder it copied a vault from (docs/design/device-first-sync.md §8.1).
enum CopyInFollowUp: Sendable, Equatable {
    /// A one-time import: the source is never written, and the in-app copy is the only one from then on.
    case importOnly
    /// "Keep syncing with this folder": the source becomes a folder target of the in-app copy.
    case keepSyncing

    /// The default for a picked folder: keep syncing with iCloud Drive and other providers' folders, a
    /// one-time import for a local folder (an export) and always for a backup (`isBackup`).
    static func suggested(for url: URL, hooks: CloudVault.Hooks = .live) -> CopyInFollowUp {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if isBackupLocked(url) || !isWritableLocked(url) { return .importOnly }
        return hooks.isUbiquitous(url) || StorageLocation.classify(url).needsCoordination ? .keepSyncing : .importOnly
    }

    /// Whether this account may write to the folder a vault picked at `url` would sync with (`VaultLocator`, else
    /// `url`): not when another user owns it or it is read-only (build 12: the demo vault in /Users/Shared, made by
    /// another account, kept as a sync target, failed every run with "errno 13"). Then the vault is only copied in.
    static func isWritable(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return isWritableLocked(url)
    }

    static func isWritableLocked(_ url: URL) -> Bool {
        let folder = (try? VaultLocator.resolve(url)) ?? url
        return AppModel.isWritableFolder(folder)
    }

    /// Whether the vault `url` stands for (`VaultLocator`) is a backup (`backup.json`): opening one is a
    /// one-time import, never "keep syncing" (a sync would write into the backup and pass deletions on).
    static func isBackup(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return isBackupLocked(url)
    }

    /// Whether the vault `url` stands for (`VaultLocator`; a backup's too) is in `store` already, by its id: then
    /// `copyIn` opens that copy and copies nothing (the Open Vault sheet says so; review of #109). The id is read the
    /// way `copyIn` reads it, under one coordinated read in iCloud Drive or another provider's storage (review of
    /// #113); false when it cannot be read (not downloaded yet), and `copyIn` finds out then.
    nonisolated static func isOnDevice(_ url: URL, store: VaultStore, hooks: CloudVault.Hooks = .live) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = try? VaultLocator.resolve(url) else { return false }
        let coordinated = hooks.isUbiquitous(source) || StorageLocation.classify(source).needsCoordination
        guard let id = try? CloudVault.coordinatedRead(coordinated ? source : nil, { try Vault.open(at: source).vaultId })
        else { return false }
        return store.entry(id: id) != nil
    }

    /// `isBackup` with the security scope already held.
    private static func isBackupLocked(_ url: URL) -> Bool {
        BackupDestination.isBackup((try? VaultLocator.resolve(url)) ?? url)
    }
}

/// A copy-in in progress, for the overlay (`VaultCopyOverlay`).
struct VaultCopyProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Asking iCloud Drive (or the provider) for files not on this device yet.
        case downloading(done: Int, total: Int)
        /// Copying and checking files (`VaultStore.importVault`).
        case copying(done: Int, total: Int)
    }

    /// The vault's name, as the user sees it.
    var name: String
    var stage: Stage

    var fraction: Double? {
        switch stage {
        case .downloading(let done, let total), .copying(let done, let total):
            return total > 0 ? Double(done) / Double(total) : nil
        }
    }

    var text: String {
        switch stage {
        case .downloading(let done, let total):
            return String(localized: "Downloading “\(name)”: \(done) of \(total) files…",
                          comment: "Copy-in progress: %1$@ is the vault's name, then files downloaded of all files")
        case .copying(let done, let total):
            return String(localized: "Copying “\(name)” onto this device: \(done) of \(total) files…",
                          comment: "Copy-in progress: %1$@ is the vault's name, then files copied of all files")
        }
    }
}

/// A vault store failure, worded for the app (`VaultStoreError` is the CLI's English).
struct VaultStoreProblem: Error, Equatable, CustomStringConvertible {
    let error: VaultStoreError

    var description: String {
        switch error {
        case .alreadyInStore(_, let name):
            return String(localized: "This vault is already on this device as “\(name)”. Open it from the list.",
                          comment: "%@ is the vault's name")
        case .notDownloaded(_, let count):
            return String(localized: "\(count) files of this vault are not on this device yet. Download the vault (in Files, choose Download Now) and try again.",
                          comment: "%lld is a number of files")
        case .partialCopy:
            return String(localized: "That vault is an incomplete copy. Finish downloading or syncing it, then open it again.")
        case .unfinishedRestore:
            return String(localized: "That vault is a restore that did not finish. Finish the restore, then open it again.")
        case .unsupportedEntry(let path):
            return String(localized: "That vault holds “\(path)”, a link or special file. A vault holds only folders and regular files.",
                          comment: "%@ is a path inside the vault")
        case .notAVault(let path, _):
            return String(localized: "“\(URL(fileURLWithPath: path).lastPathComponent)” is not a Sempere vault (it has no readable vault.json).",
                          comment: "%@ is a folder's name")
        case .sourceChanged:
            return String(localized: "The vault changed while it was being copied, so nothing was added. Try again.")
        case .copyMismatch:
            return String(localized: "The copy did not match the original, so nothing was added. Try again; if it happens again, check the storage the vault is on.")
        case .restoreIncomplete(let count):
            return String(localized: "\(count) files of the backup could not be restored, so nothing was added. Check the backup, or restore from another copy of it.",
                          comment: "%lld is a number of files")
        case .inUse:
            return String(localized: "That vault is open. Close it first.")
        case .busy:
            return String(localized: "That vault is busy. Try again in a moment.")
        case .sourceInsideStore, .invalidName, .notFound, .ambiguous, .io:
            return String(localized: "Sempere could not copy the vault: \(error.description)",
                          comment: "%@ is the reason, in English")
        }
    }
}

/// The in-app vault store in the app (docs/design/device-first-sync.md §2, §8.1): New Vault creates
/// vaults there (`createVault`), "Open Vault…" copies a vault folder there and opens the copy
/// (`copyIn`), and the welcome list opens and removes them.
extension AppModel {
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
    func copyIn(picked url: URL, library: VaultLibrary, external: Bool = false,
                followUp: CopyInFollowUp = .importOnly) async throws {
        guard vaultCopy == nil else { throw VaultStoreProblem(error: .busy(UUID())) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FolderAccess.check(url, scoped: scoped)
        let source = try VaultLocator.resolve(url)
        // A backup is copied in once, never kept in sync (`VaultStore.checkFolderTarget` refuses it too); so is a folder
        // this account cannot write to (build 12, "errno 13"; the Open Vault sheet says so).
        let followUp = BackupDestination.isBackup(source) || !Self.isWritableFolder(source) ? .importOnly : followUp
        let hooks = iCloudHooks
        let ubiquitous = hooks.isUbiquitous(source)
        let coordinated = ubiquitous || StorageLocation.classify(source).needsCoordination
        // A vault already on this device opens its copy, before anything is downloaded or copied.
        let sourceID = try? await offMain { try CloudVault.coordinatedRead(coordinated ? source : nil) { try Vault.open(at: source).vaultId } }
        if let sourceID, let existing = library.vaultStore.entry(id: sourceID) {
            return try await openExistingCopy(existing, from: source, scope: url, library: library, external: external,
                                              followUp: followUp)
        }
        vaultCopy = VaultCopyProgress(name: VaultLibrary.displayName(of: source), stage: .copying(done: 0, total: 0))
        defer { vaultCopy = nil }
        if ubiquitous { try await downloadForCopyIn(source, hooks: hooks) }
        let entry: VaultStore.Entry
        do {
            entry = try await library.copyIn(source, coordinated: coordinated) { [weak self] done, total in
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
    func openStored(_ entry: VaultStore.Entry, library: VaultLibrary) async throws {
        if let joining = joiningWebDAVLocation(of: entry.vaultId) {
            return try await openWebDAV(joining, library: library)
        }
        try await openVault(at: entry.url)
        library.rememberStored(entry)
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
    func downloadSourceFolder(_ url: URL, hooks: CloudVault.Hooks,
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

extension VaultLibrary {
    /// Lists the store again (off the main actor), after removing what interrupted operations left.
    func refreshStoredVaults() async {
        let store = vaultStore
        let listed = await Task.detached(priority: .utility) { () -> [VaultStore.Entry] in
            store.sweep()
            let listed = store.list()
            // Every store vault, at launch and after each change to the store (a create, copy-in or restore keeps
            // the source's Finder flags): never a package (`BundleBitRepair`).
            for entry in listed { BundleBitRepair.clear(entry.url, .storeVault) }
            return listed
        }.value
        // Only a real change is published: an `@Observable` property notifies on every write, and a list that
        // redraws under a finger drops the row's swipe (build 10).
        if listed != storedVaults { storedVaults = listed }
    }

    /// Copies the vault folder `source` into the store (`VaultStore.importVault`), off the main actor;
    /// `coordinated` reads it under one coordinated read (iCloud Drive, another provider).
    func copyIn(_ source: URL, coordinated: Bool,
                progress: @escaping @Sendable (Int, Int) -> Void) async throws -> VaultStore.Entry {
        let store = vaultStore
        let entry = try await Task.detached(priority: .userInitiated) {
            try CloudVault.coordinatedRead(coordinated ? source : nil) {
                try store.importVault(from: source, options: VaultStore.ImportOptions(progress: progress))
            }
        }.value
        if !storedVaults.contains(where: { $0.vaultId == entry.vaultId }) { storedVaults.append(entry) }
        return entry
    }

    /// Deletes a store vault from this device, permanently (`VaultStore.remove`), and forgets it.
    func removeStored(_ entry: VaultStore.Entry) async throws {
        let store = vaultStore
        do {
            try await Task.detached(priority: .userInitiated) { try store.remove(entry.vaultId) }.value
        } catch let error as VaultStoreError {
            throw VaultStoreProblem(error: error)
        }
        storedVaults.removeAll { $0.vaultId == entry.vaultId }
        let gone = recents.filter { $0.storeID == entry.vaultId }.map(\.id)
        if !gone.isEmpty {
            recents.removeAll { gone.contains($0.id) }
            for id in gone { states[id] = nil }
            save()
        }
    }

    /// The store's vaults, the most recently opened first, then the others by name.
    var storedVaultsByUse: [VaultStore.Entry] {
        let order = Dictionary(recents.enumerated().compactMap { i, r in r.storeID.map { ($0, i) } },
                               uniquingKeysWith: { a, _ in a })
        return storedVaults.sorted { a, b in
            switch (order[a.vaultId], order[b.vaultId]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
