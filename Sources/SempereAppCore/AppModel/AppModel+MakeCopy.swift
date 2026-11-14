import Foundation
import Sempere

/// What "Make a Copy…" was asked for (docs/design/1.2-make-a-copy.md).
public struct MakeCopyRequest: Identifiable, Equatable, WindowTargeted {
    public let id = UUID()
    /// The window that asked (`WindowUI.id`): its sheet shows there. Nil: the library window with the canvas.
    public var window: UUID?

    public init(window: UUID? = nil) {
        self.window = window
    }
}

/// What is worth telling before a copy starts, as a value the app words. `CopyReport.warnings` is the CLI's English.
public enum MakeCopyNotice: Hashable, Sendable {
    /// The vault is of a newer format version (or holds notes of one): what this version does not understand is not
    /// in the copy.
    case newerContent
    /// This device could not confirm the vault's device list (no confirmed root, or a refused list): the copy starts
    /// its own trust.
    case unconfirmedList
    /// This device was removed from the vault: notes of later epochs cannot be read and are left out.
    case removedDevice
    /// The vault is open with its recovery key (a copy gives the person a vault they can write).
    case recoveryKey
}

/// What a finished copy made: the new vault, its recovery key (for the receipt) and the report.
public struct MadeCopy: Sendable {
    public var created: CreatedVault
    public var entry: VaultStore.Entry
    public var report: CopyReport
}

/// Make a Copy…: the open vault's notes, in their current state, as a new vault of the person's own
/// (`VaultCopier`, shared with `sempere store copy`). The source is the open store vault, only read.
extension AppModelCore {
    /// Whether File ▸ Make a Copy… applies: an unlocked vault whose notes are all on this device (a partial copy
    /// cannot be copied, format.md §1.2), a writable one included.
    public var canMakeCopy: Bool {
        phase == .unlocked && vault != nil && pendingNoteIDs.isEmpty && placeholderNoteIDs.isEmpty
    }

    /// Opens the Make a Copy… sheet.
    public func requestMakeCopy(window: UUID? = nil) {
        guard canMakeCopy, makeCopyRequest == nil, !isMakingCopy else { return }
        makeCopyRequest = MakeCopyRequest(window: window)
    }

    /// What the sheet says before the copy starts.
    public var makeCopyNotices: [MakeCopyNotice] {
        guard let vault else { return [] }
        var out: [MakeCopyNotice] = []
        if vault.isRecoveryOpen { out.append(.recoveryKey) }
        if listProblem != nil { out.append(.unconfirmedList) }
        if unlistedNotice != nil { out.append(.removedDevice) }
        if !readOnlyReasons.isEmpty { out.append(.newerContent) }
        return out
    }

    /// Makes the copy `request` names (`VaultLibrary.vaultStore`, `VaultCopier`): built in the store's staging folder
    /// as New Vault builds a vault, this device its home, so it appears complete or not at all. The copy writes one
    /// checkpoint delta per note through the model's one `DeviceClock`. Open editors save first.
    ///
    /// A note that cannot be copied is in the report's `failed` (unless `strict`, which stops and leaves no vault).
    /// When the vault closes meanwhile the copy stops (nothing is left) or, once made, is returned but not opened.
    ///
    /// - Throws: `ModelError.noVaultOpen`, `CopyError`, `VaultStoreError.invalidName`, `CancellationError`.
    public func makeCopy(_ request: NewVaultRequest, includeDeleted: Bool, strict: Bool = false,
                         library: VaultLibrary) async throws -> MadeCopy {
        guard let source = vault, phase == .unlocked else { throw ModelError.noVaultOpen }
        guard canMakeCopy else { throw CopyError.partialSource }
        guard !isMakingCopy else { throw CancellationError() }
        _ = try VaultStore.folderName(for: request.name)
        isMakingCopy = true
        let cancellation = CopyCancellation()
        makeCopyCancellation = cancellation
        makeCopyProgress = CopyProgress(done: 0, total: notes.count, notes: 0, blobBytes: 0)
        let relay = ProgressRelay<CopyProgress> { [weak self] in self?.makeCopyProgress = $0 }
        defer {
            relay.finish()
            isMakingCopy = false
            makeCopyProgress = nil
            makeCopyCancellation = nil
        }
        let gen = generation
        // What the canvas shows is what is copied.
        if !isVaultReadOnly { _ = await flushEditors(for: Set(notes.map(\.id))) }
        try ensureCurrent(gen)
        let clock = try deviceClockForWriting()
        let device = clock.device
        let keys = try request.keys()
        let options = request.options
        let store = library.vaultStore
        let trust = self.trust
        let fileLedger = writeStores?.ledger(for: keys.vaultId)
        let ledger: (any WriteLedgerStore)? = fileLedger
        let copyOptions = VaultCopier.Options(includeDeleted: includeDeleted, strict: strict, app: services.appName,
                                              sourceName: VaultLibrary.displayName(of: vaultURL ?? source.url),
                                              ledger: ledger)
        let name = request.name
        let hook = makeCopyStepHook
        // The whole copy runs on the device clock (`withClock`), as an import does: nothing else may stamp revisions with
        // this state file meanwhile (never a second clock on it), so a save in another window of a writable source waits
        // until the copy ends. That is intended: a copy takes seconds for a typical vault, and Cancel stops it.
        let made: (VaultStore.Entry, Vault, CopyReport)
        do {
            made = try await clock.withClock(save: true) { c -> (VaultStore.Entry, Vault, CopyReport) in
                let (entry, made) = try store.create(name: name) { url -> (Vault, CopyReport) in
                    let destination = try VaultCreation.create(at: url, keys: keys, options: options, trust: trust)
                    let report = try VaultCopier.copy(from: source, into: destination, device: device, clock: &c,
                                                      options: copyOptions, progress: { hook?($0); relay.post($0) },
                                                      cancellation: cancellation)
                    return (destination, report)
                }
                return (entry, made.0, made.1)
            }
        } catch {
            // The ledger of a vault that was never made.
            if let fileLedger { try? FileManager.default.removeItem(at: fileLedger.folder) }
            throw error
        }
        let (entry, built, report) = made
        let created = VaultLibrary.created(built, url: entry.url, keys: keys)
        library.rememberStored(entry)
        return MadeCopy(created: created, entry: entry, report: report)
    }

    /// Cancel on the copy's progress: it stops after the note it is writing and leaves no vault.
    public func cancelMakeCopy() {
        makeCopyCancellation?.cancel()
    }

    /// "Open the Copy": closes this vault and opens the new one, unlocked with this device's new key, as New Vault does
    /// after creating one.
    public func openMadeCopy(_ copy: MadeCopy, library: VaultLibrary) async throws {
        try await openVault(at: copy.created.url)
        let opened = generation
        try ensureCurrent(opened)
        try await unlock(device: copy.created.device)
        try ensureCurrent(opened)
        remember(in: library)
    }
}
